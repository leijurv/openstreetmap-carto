FROM ubuntu:noble

# https://serverfault.com/questions/949991/how-to-install-tzdata-on-a-ubuntu-docker-image
ARG DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# Patched Mapnik
#
# This image builds Mapnik from source so we can test the `!unbuffered_bbox!`
# SQL token before it is merged upstream (mapnik/mapnik). Override these to
# point at a different fork/branch/commit.
ARG MAPNIK_REPO=https://github.com/leijurv/mapnik.git
ARG MAPNIK_REF=unbuffered-bbox
# node-mapnik release to build against the patched core. 4.7.x targets Mapnik
# 4.2.x (matches this fork). The older 4.5.x line only builds against Mapnik
# 4.0 and will NOT compile against 4.2 — do not downgrade this.
ARG NODE_MAPNIK_REF=v4.7.8
# Parallelism for the C++ builds. Each compile job can use ~1.5 GB RAM; raise
# this on machines with plenty of memory, lower it if the build is OOM-killed.
ARG JOBS=4

# Style dependencies + Mapnik/node-mapnik build and runtime dependencies. The
# -dev packages are needed both to build libmapnik and to compile node-mapnik
# against it (they also pull in the runtime shared libraries). Node.js is NOT
# installed here: node-mapnik 4.7.x needs a modern Node (Ubuntu noble ships
# Node 18, whose finalizer GC rule aborts node-mapnik), so we add Node 22 from
# NodeSource below.
RUN apt-get update && apt-get install --no-install-recommends -y \
    ca-certificates gnupg wget curl unzip git \
    postgresql-client python3 \
    pkg-config g++ make ninja-build \
    fonts-unifont mapnik-utils \
    libpq-dev libsqlite3-dev \
    libicu-dev libfreetype6-dev libharfbuzz-dev libxml2-dev \
    libjpeg-dev libtiff-dev libwebp-dev libavif-dev libcairo2-dev \
    libproj-dev libgdal-dev \
    libboost-filesystem-dev libboost-program-options-dev libboost-regex-dev \
    libboost-url-dev libboost-context-dev libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Node.js 22 (node-mapnik 4.7.x requires a modern Node runtime).
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install --no-install-recommends -y nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && node --version && npm --version

# Mapnik requires CMake >= 3.30; Ubuntu noble ships 3.28, so pull CMake from
# Kitware's APT repository.
RUN wget -qO - https://apt.kitware.com/keys/kitware-archive-latest.asc \
      | gpg --dearmor - > /usr/share/keyrings/kitware-archive-keyring.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/kitware-archive-keyring.gpg] https://apt.kitware.com/ubuntu/ noble main" \
      > /etc/apt/sources.list.d/kitware.list \
    && apt-get update && apt-get install --no-install-recommends -y cmake \
    && rm -rf /var/lib/apt/lists/*

# Build and install the patched Mapnik to /usr/local (tests/demo disabled).
RUN git clone "$MAPNIK_REPO" /tmp/mapnik \
    && cd /tmp/mapnik \
    && git checkout "$MAPNIK_REF" \
    && git submodule update --init --recursive deps \
    && cmake --preset linux-gcc-release -DBUILD_TESTING:BOOL=OFF -DBUILD_DEMO_VIEWER:BOOL=OFF \
    && cmake --build build -j "$JOBS" \
    && cmake --install build \
    && echo /usr/local/lib > /etc/ld.so.conf.d/mapnik.conf && ldconfig \
    && rm -rf /tmp/mapnik

# node-mapnik's build is driven entirely by `mapnik-config`, which Mapnik's
# CMake build does not produce. This shim emits the exact flags libmapnik was
# compiled with.
COPY scripts/mapnik-config /usr/local/bin/mapnik-config
RUN chmod +x /usr/local/bin/mapnik-config

# Build node-mapnik against the patched Mapnik. We omit the optional
# @mapnik/core prebuilt package so its preinstall script falls back to building
# against our local mapnik-config, and patch the wkt/json library names to
# match Mapnik's CMake output (static libmapnikwkt.a / libmapnikjson.a).
RUN git clone --depth 1 --branch "$NODE_MAPNIK_REF" https://github.com/mapnik/node-mapnik.git /opt/node-mapnik \
    && cd /opt/node-mapnik \
    && git submodule update --init --recursive \
    && npm install --omit=optional --ignore-scripts \
    && sed -i 's/-lmapnik-wkt/-lmapnikwkt/g; s/-lmapnik-json/-lmapnikjson/g' binding.gyp \
    && npx --yes node-gyp configure \
    && npx --yes node-gyp build -j "$JOBS" \
    && printf '%s\n' \
      'var path = require("path");' \
      'module.exports.paths = {' \
      '  "fonts": "/usr/local/lib/mapnik/fonts",' \
      '  "input_plugins": "/usr/local/lib/mapnik/input",' \
      '  "mapnik_index": "/usr/local/bin/mapnik-index",' \
      '  "shape_index": "/usr/local/bin/shapeindex"' \
      '};' \
      'module.exports.env = { "GDAL_DATA": "/usr/share/gdal", "PROJ_LIB": "/usr/share/proj" };' \
      > /opt/node-mapnik/build/Release/mapnik_settings.js

# Kosmtik from leijurv's fork (upstream kosmtik is abandoned). The `my-patches`
# branch already depends on @mapnik/mapnik and carries the projection fix that
# modern node-mapnik needs (ProjTransform-based tile bounds), plus the
# buffer-size / retina / timeout / metatile-cache fixes. Force the npm prefix to
# /usr because Ubuntu's default /usr/local breaks the global install.
ARG KOSMTIK_REPO=https://github.com/leijurv/kosmtik.git
ARG KOSMTIK_REF=my-patches
# --ignore-scripts + --omit=optional: skip @mapnik/mapnik's prebuilt-download /
# native build (and its @mapnik/core); we drop our patched build in right after.
RUN npm set prefix /usr \
    && npm install -g --unsafe-perm --ignore-scripts --omit=optional "git+$KOSMTIK_REPO#$KOSMTIK_REF"

# Replace the @mapnik/mapnik dependency with the one we built against the patched
# Mapnik 4.2 (the only thing that adds !unbuffered_bbox!). Done before the
# plugins step because the kosmtik CLI loads @mapnik/mapnik on startup.
RUN rm -rf /usr/lib/node_modules/kosmtik/node_modules/@mapnik/mapnik \
    && mkdir -p /usr/lib/node_modules/kosmtik/node_modules/@mapnik \
    && cp -a /opt/node-mapnik /usr/lib/node_modules/kosmtik/node_modules/@mapnik/mapnik

WORKDIR /usr/lib/node_modules/kosmtik/
RUN kosmtik plugins --install kosmtik-overpass-layer \
                    --install kosmtik-fetch-remote \
                    --install kosmtik-overlay \
                    --install kosmtik-open-in-josm \
                    --install kosmtik-map-compare \
                    --install kosmtik-osm-data-overlay \
                    --install kosmtik-mapnik-reference \
                    --install kosmtik-geojson-overlay \
    && cp /root/.config/kosmtik.yml /tmp/.kosmtik-config.yml

# Closing section
RUN mkdir -p /openstreetmap-carto
WORKDIR /openstreetmap-carto

USER 1000
CMD sh scripts/docker-startup.sh kosmtik
