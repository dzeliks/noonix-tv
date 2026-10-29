#!/usr/bin/env bash
# builds Noonix-TV-<version>-<x86_64|aarch64>.AppImage (the build machine's arch). releases come from the old base (ubuntu 22.04:
# tools/appimage/base.sh + deps.sh, then `source <prefix>/env.sh`): qt, mpv & co from the
# deps prefix get bundled, glibc, libstdc++ and the gpu drivers stay the host's. on arch
# (no env.sh) it bundles the system's qt + mpv instead, and the image needs a host as new
#   tools/build-appimage.sh [out dir]
# needs: cmake, ninja, rust, qt6 (base, declarative, shadertools, wayland), mpv, sdl3,
# wayland-protocols, patchelf, curl
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
out="$(mkdir -p "${1:-$root/build/appimage}" && cd "${1:-$root/build/appimage}" && pwd)"
version="$(sed -n 's/^version = "\(.*\)"/\1/p' "$root/core/Cargo.toml" | head -1)"
work="$out/work"
appdir="$work/AppDir"
# pinned tools
appimagetool_ver=1.9.1
excludelist_rev=19e30b276ffedf4d3b4b56bc6320f463625a74f8

rm -rf "$appdir"
mkdir -p "$work"

echo "== build $version"
cmake -S "$root" -B "$work/cmake" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr
cmake --build "$work/cmake"
DESTDIR="$appdir" cmake --install "$work/cmake"
strip --strip-unneeded "$appdir/usr/bin/noonix-tv" "$appdir/usr/bin/noonix-tv-cli"

# AppRun --version reads it
mkdir -p "$appdir/usr/share/noonix-tv"
printf '%s\n' "$version" > "$appdir/usr/share/noonix-tv/version"

echo "== qt + libraries"
curl -fsSL -o "$work/excludelist" \
    "https://raw.githubusercontent.com/AppImageCommunity/pkg2appimage/$excludelist_rev/excludelist"
python3 "$root/tools/appimage/deploy.py" "$appdir" "$root/qml" "$work/excludelist"
{ echo; python3 "$root/tools/third-party.py" crates "$(uname -m)-unknown-linux-gnu"; } >> "$appdir/usr/share/doc/noonix-tv/THIRD-PARTY.txt"

# the newest glibc / libstdc++ any shipped elf asks for = the oldest host it runs on
elves() { find "$appdir" -type f -print0 | xargs -0 file -N | sed -n 's/: *ELF .*//p'; }
newest() { elves | xargs -d '\n' objdump -T 2>/dev/null | grep -oE "$1_[0-9.]+" | sort -uV | tail -1 || true; }
glibc="$(newest GLIBC)"
echo "needs $glibc, $(newest GLIBCXX)"
if [[ -n "${NOONIX_GLIBC_MAX:-}" && "$(printf '%s\n' "GLIBC_$NOONIX_GLIBC_MAX" "$glibc" | sort -V | tail -1)" != "GLIBC_$NOONIX_GLIBC_MAX" ]]; then
    echo "needs $glibc, newer than the base's $NOONIX_GLIBC_MAX:" >&2
    elves | while read -r f; do objdump -T "$f" 2>/dev/null | grep -q "$glibc" && echo "  ${f#"$appdir"/}" >&2; done
    exit 1
fi

echo "== appdir"
install -m755 "$root/tools/appimage/AppRun" "$appdir/AppRun"
cp "$root/dist/noonix-tv.svg" "$appdir/noonix-tv.svg"
cat > "$appdir/noonix-tv.desktop" <<DESK
[Desktop Entry]
Type=Application
Name=Noonix TV
Comment=Movies and shows on the TV
Exec=noonix-tv
Icon=noonix-tv
Categories=AudioVideo;Video;Player;TV;
X-AppImage-Version=$version
DESK
rm -f "$appdir/usr/share/applications/noonix-tv.desktop"

tool="$work/appimagetool-$appimagetool_ver-$(uname -m)"
[[ -x "$tool" ]] || {
    curl -fsSL -o "$tool" "https://github.com/AppImage/appimagetool/releases/download/$appimagetool_ver/appimagetool-$(uname -m).AppImage"
    chmod +x "$tool"
}
name="Noonix-TV-$version-$(uname -m).AppImage"
rm -f "$out/$name"
APPIMAGE_EXTRACT_AND_RUN=1 ARCH="$(uname -m)" VERSION="$version" "$tool" --comp zstd --no-appstream "$appdir" "$out/$name"
(cd "$out" && sha256sum "$name" > "$name.sha256")
ls -lh "$out/$name"
