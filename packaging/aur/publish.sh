#!/usr/bin/env bash
# packaging/aur/publish.sh [package...]: pushes the PKGBUILD and .SRCINFO to the aur (needs an aur
# account with this machine's ssh key). a package that isn't on the aur yet is made by the push
set -euo pipefail
cd "$(dirname "$0")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
pkgs=("$@")
[[ ${#pkgs[@]} -gt 0 ]] || pkgs=(noonix-tv noonix-tv-bin)
for p in "${pkgs[@]}"; do
    git clone -q "ssh://aur@aur.archlinux.org/$p.git" "$work/$p"
    cp "$p/PKGBUILD" "$p/.SRCINFO" "$work/$p/"
    v="$(sed -n 's/^\tpkgver = //p' "$p/.SRCINFO")-$(sed -n 's/^\tpkgrel = //p' "$p/.SRCINFO")"
    git -C "$work/$p" add PKGBUILD .SRCINFO
    if git -C "$work/$p" diff --cached --quiet; then echo "$p: up to date"; continue; fi
    git -C "$work/$p" -c user.name=dzeliks -c user.email=127214601+dzeliks@users.noreply.github.com \
        commit -qm "$v"
    git -C "$work/$p" push -q origin HEAD:master
    echo "$p: $v pushed"
done
