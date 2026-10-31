#!/usr/bin/env bash
# packaging/aur/bump.sh <version>: both packages to a published release (version, the appimages'
# sums from its SHA256SUMS, .SRCINFO)
set -euo pipefail
cd "$(dirname "$0")"
v="${1:?usage: bump.sh <version>}"
sums="$(curl -fsSL "https://github.com/dzeliks/noonix-tv/releases/download/v$v/SHA256SUMS")"
sum() { awk -v f="Noonix-TV-$v-$1.AppImage" '$2 == f { print $1 }' <<< "$sums"; }
x86="$(sum x86_64)"; arm="$(sum aarch64)"
[[ -n "$x86" && -n "$arm" ]] || { echo "no appimage sums in v$v's SHA256SUMS" >&2; exit 1; }
for p in noonix-tv noonix-tv-bin; do
    sed -i -e "s/^pkgver=.*/pkgver=$v/" -e "s/^pkgrel=.*/pkgrel=1/" "$p/PKGBUILD"
done
sed -i -e "s/^sha256sums_x86_64=.*/sha256sums_x86_64=('$x86')/" \
       -e "s/^sha256sums_aarch64=.*/sha256sums_aarch64=('$arm')/" noonix-tv-bin/PKGBUILD
for p in noonix-tv noonix-tv-bin; do (cd "$p" && makepkg --printsrcinfo > .SRCINFO); done
git -C .. diff --stat -- aur
