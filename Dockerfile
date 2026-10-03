ARG RUBY_IMAGE=ruby:3.4-slim-bookworm
FROM ${RUBY_IMAGE} AS base

WORKDIR /app
ENV APP_ENV=production \
    BUNDLE_FROZEN=true \
    BUNDLE_WITHOUT=development:test \
    ARGENTUM_MEDIA_DIR=/media \
    ARGENTUM_DATA_DIR=/data

FROM base AS build

RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential libsqlite3-dev \
 && rm -rf /var/lib/apt/lists/*

COPY Gemfile Gemfile.lock ./
RUN bundle install --jobs 2 --retry 3 \
 && rm -rf /usr/local/bundle/cache \
 && find /usr/local/bundle -type f -name '*.o' -delete

# Development toolchain: all gems, FFmpeg, and Node (for the JS/Ruby tag-hue parity
# test). Nothing from here reaches production. The source is copied so the image
# works on its own (CI); compose bind-mounts the working copy over it instead.
FROM build AS dev
ENV APP_ENV=development BUNDLE_WITHOUT=""
RUN apt-get update \
 && apt-get install -y --no-install-recommends ffmpeg nodejs \
 && rm -rf /var/lib/apt/lists/* \
 && bundle install --jobs 2 --retry 3
COPY lib/ lib/
COPY config/ config/
COPY public/ public/
COPY views/ views/
COPY test/ test/
COPY Rakefile config.ru ./
EXPOSE 4567
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]

# Runs the suite when the container runs (not at build time), so output is visible
# and a cached layer can never stand in for a test run.
FROM dev AS test
ENV APP_ENV=test
CMD ["bundle", "exec", "rake", "test"]

FROM base AS production
# The app runs as "argentum" (uid 1000, the usual first desktop user, so files it
# reads from a bind-mounted media folder are typically already accessible).
#
# Debian's FFmpeg drags in a desktop GPU stack (LLVM, Mesa's DRI drivers, Z3: ~160 MB)
# for ffplay and OpenGL filters. ffmpeg/ffprobe don't link it; it's only loaded when
# something opens an OpenGL context, which a headless server never does. Remove it
# (matched by pattern so a newer Debian's libllvmNN is caught too), then fail the
# build if either binary is missing a library. dpkg now considers those dependencies
# broken, so this must stay the last package operation in this stage.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ffmpeg libsqlite3-0 \
 && rm -rf /var/lib/apt/lists/* \
 && dpkg --purge --force-depends \
      $(dpkg-query -W -f '${db:Status-Status} ${Package}\n' 'libllvm*' 'libgl1-mesa-dri' 'libz3-*' \
        | awk '$1 == "installed" { print $2 }') \
 && ! ldd /usr/bin/ffmpeg /usr/bin/ffprobe | grep 'not found' \
 && groupadd --gid 1000 argentum \
 && useradd --uid 1000 --gid argentum --create-home --shell /usr/sbin/nologin argentum \
 && mkdir -p /data \
 && chown argentum:argentum /data # a fresh named volume inherits this ownership

COPY --from=build /usr/local/bundle /usr/local/bundle
COPY Gemfile Gemfile.lock config.ru LICENSE README.md ./
COPY lib/ lib/
COPY config/ config/
COPY public/ public/
COPY views/ views/
COPY bin/docker-entrypoint /usr/local/bin/docker-entrypoint

VOLUME /data
EXPOSE 4567
ENTRYPOINT ["docker-entrypoint"]
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
