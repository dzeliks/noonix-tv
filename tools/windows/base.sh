#!/usr/bin/env bash
# apt side of the windows cross build: fetch / unpack tools, python for aqt, the installer maker,
# a host compiler for build scripts, and what the linux qt tools (moc, qmlcachegen, qsb) load
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q --no-install-recommends ca-certificates curl xz-utils zstd p7zip-full unzip zip git \
    python3 python3-venv ninja-build pkg-config nsis file make perl gcc g++ libc6-dev \
    libglib2.0-0t64 libgl1 libegl1 libfontconfig1 libxkbcommon0 libdbus-1-3
