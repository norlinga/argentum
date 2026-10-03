# argentum

*argentum* (Latin: silver) — a self-hosted family video library for the silver screen.
Ruby · Sinatra · HTMX · Video.js (both vendored in `public/vendor`) · HLS (m3u8) · Sequel · SQLite · ffmpeg.

## Why?

Imagine just one scenario.
You're at a family gathering, a team after-game party or film session, or similar.
Everyone's got videos to share on their phones, but not everyone has a modern phone or the type of phone that connects with the TV.
Not everyone's phone can use a USB-C to HDMI adapter.
Run *argentum* on your laptop, create a directory to receive videos.
Turn on [localsend](https://localsend.org) and have everyone dump their videos into the *argentum* directory.
Videos index automatically and become playable after processing. Large files or
older hardware can take longer, especially when video needs transcoding.

## Run

```sh
cp .env.example .env        # set ARGENTUM_MEDIA_HOST_DIR to your videos folder
docker compose up --build
# → http://localhost:4567
```

Videos are mounted read-only and never moved or modified. Everything argentum
generates (SQLite DB, thumbnails, previews, HLS segments) lives in the `argentum-data` volume.

Compose publishes port 4567 on all host interfaces. This is a trusted household/LAN
application: anyone who can reach it can watch videos and edit library metadata.
For access outside that network, put it behind an authenticated HTTPS proxy or VPN.
To restrict it to this computer, change the port mapping to
`127.0.0.1:${ARGENTUM_PORT:-4567}:4567`.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `ARGENTUM_MEDIA_HOST_DIR` | `./media` | Host folder with your videos (compose only) |
| `ARGENTUM_MEDIA_DIR` | `/media` | Media path inside the container |
| `ARGENTUM_DATA_DIR` | `/data` | DB + generated assets |
| `ARGENTUM_SCAN_INTERVAL` | `60` | Seconds between rescans; `0` = startup/manual only |
| `ARGENTUM_SETTLE_SECONDS` | `20` | A file is processed once untouched this long, so videos still being copied in aren't processed half-written |
| `ARGENTUM_FFMPEG_THREADS` | `1` | Positive codec/filter thread count per FFmpeg operation |
| `ARGENTUM_PORT` | `4567` | Host port (compose only) |
| `ARGENTUM_TITLE` | `argentum` | Site name in the header and browser tab |
| `ARGENTUM_TAGLINE` | `family video library` | Line under the title; empty hides it |
| `ARGENTUM_LOGO` | built-in icon | Image URL or file path in the container (e.g. `/media/logo.png`); `none` hides it |
| `ARGENTUM_THEME` | `dark` | Initial theme: `dark`, `light` or `system` (viewers can toggle) |

## How it works

- **Scan**: new files are registered as *pending* (title from filename, tags from folder names);
  changed files are re-queued; vanished files are marked *missing* (metadata kept). Files modified
  in the last `ARGENTUM_SETTLE_SECONDS` are still arriving: they're left alone and looked at again
  as soon as they've been quiet that long, rather than at the next periodic scan.
- **Ingest** (one background worker): ffprobe → static thumbnail → motion preview (8×1s samples,
  shown on card hover) → HLS segments. Compatible H.264 video and AAC audio are copied
  without re-encoding; incompatible video or audio is transcoded separately.
- **Playback**: Video.js plays the HLS playlist, falling back to the original file (byte-range).
  Position is saved every ~5s and resumed on return; views are counted per play.
- **Duplicates**: each video's stills get a perceptual hash; videos with matching duration and
  frames (e.g. the same clip in two encodings) are grouped on `/duplicates`. You choose which copies
  to remove — removed files stay on disk untouched but are hidden, their generated assets deleted,
  and they're never re-ingested. Restore them from the same page.
- **Home**: well-watched/favorite videos first, with a few random picks mixed in, plus
  *Continue watching* and *Recently added*. **Related** = shared tags and title words.

## Development

Everything runs in Docker; the host needs only Docker (Compose v2) and `make`.
Run `make` on its own for the full list.

| Command | What it does |
|---|---|
| `make test` | Run the test suite against your working copy (no rebuild needed after edits) |
| `make test TEST=test/app_test.rb TESTOPTS=--name=/favorite/` | Run one file, or matching tests |
| `make dev` | Serve the working copy on http://localhost:4568, with its own data volume |
| `make shell` | Bash in the dev image (all gems, FFmpeg, Node) |
| `make smoke` | Build the production image, feed it a generated clip, check ingest, HLS and serving |
| `make check` | `test` + `smoke`: run before pushing or releasing |
| `make up` / `down` / `logs` | Run the production app in the background (reads `.env`) |
| `make clean` | Remove dev/test images and the dev data volume; never touches the production library |

Without Docker: `bundle install`, install FFmpeg, then `make test-local`, or run the app with
`ARGENTUM_MEDIA_DIR=~/Videos ARGENTUM_DATA_DIR=./data bundle exec puma -C config/puma.rb`.

The Dockerfile's stages map onto those targets: `build` compiles gems; `dev` adds test gems,
FFmpeg and Node, and `test` is `dev` with `rake test` as its command (both bind-mount the working
copy via the `dev` profile in `docker-compose.yml`); `production` (the default target) is the
delivered image.

## Production image and older hardware

The Dockerfile uses separate build and production stages. Compilers, development
headers, gem download caches, tests and test dependencies stay out of the delivered
image. Production copies only the application, runtime gems and license files, and
installs FFmpeg without recommended packages. Both stages use the same Debian
Bookworm Ruby slim base to keep native extensions compatible.

FFmpeg and its codec libraries remain a substantial part of the image. A custom
codec build could reduce that further, but would narrow format support and require
maintaining a separate FFmpeg build. Debian slim keeps the existing codec support.
The production build does remove some obviously unnecessary libraries - fiddle with the ffmpeg
guts that remain at your own risk.

Ingestion runs one video at a time. Preview samples decode sequentially, and
`ARGENTUM_FFMPEG_THREADS=1` limits codec/filter threading by default. This trades
some throughput for lower memory use and leaves more CPU available for the web
server. Set it to `2` or more on a faster machine. It is a per-operation setting,
not a total container CPU or memory limit. Set `ARGENTUM_SCAN_INTERVAL=0` to scan
only at startup and when requested. Invalid numeric settings stop the app at startup with
the variable's name, rather than failing later in the background.

argentum has been tested on x86-64; ARM is untested. On an older laptop, HEVC/4K software transcoding can still be slow;
H.264/AAC videos largely avoid that work. There is no automatic hardware
acceleration. HLS copies also consume disk space in the data volume.

`make smoke` builds the production image and checks it end to end; for its size and layers:

```sh
docker image inspect argentum --format '{{.Size}}' # uncompressed bytes
docker history argentum
```

The production image runs as the unprivileged user `argentum` (uid 1000). It starts as root
only to hand the data volume to that user, which on the first start after upgrading from an
older root-run image is a one-time `chown`, and then drops privileges. The media folder only
needs to be readable by uid 1000 (or world-readable).

Keep Puma single-process: its in-process worker must not be duplicated
by multiple web workers or multiple containers sharing the same data volume.

## Tests

`make test` (see [Development](#development)). Tests run against a throwaway data/media dir.
The ingest and duplicate-detection tests generate tiny clips with `ffmpeg`, and one test checks
the JavaScript tag colours with `node`; on the host they're skipped if those aren't installed.

## License

argentum is licensed under the [Zero-Clause BSD license (0BSD)](LICENSE),
the same license as htmx. Vendored libraries retain their own licenses; see
[public/vendor/README.md](public/vendor/README.md).
