#!/usr/bin/env bash
# the appimage's build base: ubuntu 22.04 (glibc 2.35), so the image runs on ubuntu 22.04,
# debian 12 and anything newer. this installs the distro side: compilers, headers of what
# stays the host's (glibc, gl/egl, fontconfig, harfbuzz, pipewire's pulse), and what the
# smoke test needs. qt, ffmpeg, mpv & co come from deps.sh. lld: next to plain bfd cxx-qt
# falls back to gold, which can't link its initializers
#   tools/appimage/base.sh   (as root, in an ubuntu:22.04 container; aarch64: ubuntu:24.04, qt's arm64 build needs glibc 2.38)
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    build-essential gcc-12 g++-12 lld git curl ca-certificates xz-utils zstd file patchelf nasm \
    pkg-config python3 python3-pip python3-venv sudo \
    libexpat1-dev libffi-dev libxml2-dev libxkbcommon-dev libegl-dev libgl-dev libgles-dev \
    libegl1-mesa-dev libdrm-dev libssl-dev zlib1g-dev libfreetype-dev libfribidi-dev \
    libharfbuzz-dev libfontconfig-dev liblcms2-dev libuchardet-dev libzimg-dev libpulse-dev \
    libasound2-dev libdbus-1-dev libudev-dev libglib2.0-dev \
    libxkbcommon0 libfontconfig1 libgl1 libegl1 libgl1-mesa-dri libglib2.0-0 libdbus-1-3 \
    weston dbus
update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-12 100 --slave /usr/bin/g++ g++ /usr/bin/g++-12
update-alternatives --install /usr/bin/cc cc /usr/bin/gcc-12 100
update-alternatives --install /usr/bin/c++ c++ /usr/bin/g++-12 100
