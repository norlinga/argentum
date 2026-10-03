# Vendored browser libraries

These third-party assets retain their own licenses, independently of
argentum's Zero-Clause BSD license. Keep the adjacent license and notice
files when redistributing these assets. The JavaScript and CSS are unchanged.

| Library | Version | Files | License | Upstream |
|---|---|---|---|---|
| htmx | 2.0.4 | `htmx/htmx.min.js` | [Zero-Clause BSD (0BSD)](htmx/LICENSE) | [htmx](https://github.com/bigskysoftware/htmx/tree/v2.0.4) |
| Video.js | 8.16.1 | `videojs/video.min.js`, `videojs/video-js.min.css` | [Apache-2.0](videojs/LICENSE) | [Video.js](https://github.com/videojs/video.js/tree/v8.16.1) |

Video.js includes vtt.js and streaming components. Their license and
attribution comments are preserved in the bundle and collected in
[THIRD_PARTY_NOTICES.txt](videojs/THIRD_PARTY_NOTICES.txt).

When updating these libraries, refresh their license files and any upstream
NOTICE files, including notices for bundled dependencies.
