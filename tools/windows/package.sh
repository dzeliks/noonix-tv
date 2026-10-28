#!/usr/bin/env bash
# the windows release files from a finished app folder (build.sh):
# Noonix-TV-<version>-windows-x64-setup.exe and a portable zip
#   tools/windows/package.sh <app folder> <out dir>
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
app="$(cd "${1:?usage: package.sh <app folder> <out dir>}" && pwd)"
out="$(mkdir -p "${2:?}" && cd "$2" && pwd)"
version="$(sed -n 's/^version = "\(.*\)"/\1/p' "$root/core/Cargo.toml" | head -1)"

setup="$out/Noonix-TV-$version-windows-x64-setup.exe"
# windows wants a plain a.b.c.d in the file version
makensis -V2 -DVERSION="$version" -DVERSION_NUM="${version%%-*}" -DSRC="$app" -DOUT="$setup" "$here/installer.nsi"
zip="$out/Noonix-TV-$version-windows-x64.zip"
rm -f "$zip"
(cd "$(dirname "$app")" && zip -qr -9 "$zip" "$(basename "$app")")
ls -la "$setup" "$zip"
