#!/usr/bin/env bash
# the windows build inside the cross image: configure, build, install into <out>/Noonix TV,
# then the dlls and qml it needs (deploy.py)
#   tools/windows/build.sh <prefix> <build dir> <out>
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
prefix="${1:?usage: build.sh <prefix> <build dir> <out>}"
build="${2:?}"
out="${3:?}"
# shellcheck source=/dev/null
source "$prefix/env.sh"

cmake -S "$root" -B "$build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_TOOLCHAIN_FILE="$here/toolchain.cmake" -DCMAKE_INSTALL_PREFIX="$out/Noonix TV"
cmake --build "$build"
rm -rf "$out/Noonix TV"
cmake --install "$build"
python3 "$here/deploy.py" "$out/Noonix TV" "$root/qml"
python3 "$root/tools/third-party.py" windows x86_64-pc-windows-gnullvm > "$out/Noonix TV/THIRD-PARTY.txt"
