#!/usr/bin/env bash
# what the windows build needs, pinned, into <prefix>: llvm-mingw (the toolchain qt's own windows
# build uses), rust with the gnullvm target, qt for linux (its build tools) and for windows, sdl3
# and libmpv. a finished prefix is reused (the stamp is the pins' hash)
#   tools/windows/deps.sh <prefix>
#   source <prefix>/env.sh
set -euo pipefail

QT_VERSION=6.12.0
RUST_VERSION=1.99.1
# qt 6.12's win64_llvm_mingw is built with this one
LLVM_MINGW=20260602
SDL_VERSION=3.4.18
# shinchiro's libmpv builds (gpl, ffmpeg inside); daily, kept for a few weeks only
MPV_DEV=20261010/mpv-dev-x86_64-20261010-git-b2c255c13e.7z
# libmpv imports vulkan-1.dll, which only gpu drivers install: the khronos loader (msys2's clang64 build)
VULKAN_LOADER=mingw-w64-clang-x86_64-vulkan-loader-1.4.317-2-any.pkg.tar.zst
VULKAN_LOADER_SHA256=e7915b1383b154ce246e6f3593bc5d15c03d85ccf4cb3cee46691cba916dcedd

p="$(mkdir -p "${1:?usage: deps.sh <prefix>}" && cd "$1" && pwd)"
here="$(cd "$(dirname "$0")" && pwd)"
stamp="$( (grep -E '^[A-Z_]+=' "$0"; cat "$here/qt-win.py") | sha256sum | cut -c1-16)"
if [[ -f "$p/.stamp" && "$(cat "$p/.stamp")" == "$stamp" ]]; then
    echo "deps: $p is current"
    exec "$here/env.sh" "$p"
fi
rm -rf "$p/llvm-mingw" "$p/qt" "$p/qt-win" "$p/sdl" "$p/mpv" "$p/vulkan" "$p/tools"
dl="$p/.dl"
mkdir -p "$dl"
get() { curl -fsSL --retry 3 -o "$dl/$2" "$1"; echo "$dl/$2"; }

echo "== tools"
python3 -m venv "$p/tools"
"$p/tools/bin/pip" install -q cmake aqtinstall
export CARGO_HOME="$p/cargo" RUSTUP_HOME="$p/rustup"
if [[ ! -x "$CARGO_HOME/bin/rustup" ]]; then
    curl -fsSL https://sh.rustup.rs | sh -s -- -y -q --no-modify-path --profile minimal --default-toolchain "$RUST_VERSION"
fi
"$CARGO_HOME/bin/rustup" default "$RUST_VERSION"
"$CARGO_HOME/bin/rustup" target add x86_64-pc-windows-gnullvm

echo "== llvm-mingw $LLVM_MINGW"
f="$(get "https://github.com/mstorsjo/llvm-mingw/releases/download/$LLVM_MINGW/llvm-mingw-$LLVM_MINGW-ucrt-ubuntu-22.04-x86_64.tar.xz" llvm-mingw.tar.xz)"
mkdir -p "$p/llvm-mingw" && tar -xf "$f" -C "$p/llvm-mingw" --strip-components=1

echo "== qt $QT_VERSION (linux tools, windows libraries)"
cd "$p"   # aqt writes its log into the current folder
"$p/tools/bin/aqt" install-qt -O "$p/qt" linux desktop "$QT_VERSION" linux_gcc_64 -m qtshadertools > /dev/null
# only the host's tools run: their static libraries (qmlls alone is 600 mb) are dead weight in the ci cache
find "$p/qt" -name '*.a' -delete
python3 "$here/qt-win.py" "$QT_VERSION" "$p/qt-win" qtshadertools qtimageformats

echo "== sdl $SDL_VERSION"
f="$(get "https://github.com/libsdl-org/SDL/releases/download/release-$SDL_VERSION/SDL3-devel-$SDL_VERSION-mingw.tar.gz" sdl.tar.gz)"
mkdir -p "$p/sdl" && tar -xf "$f" -C "$p/sdl" --strip-components=1

echo "== libmpv"
f="$(get "https://github.com/shinchiro/mpv-winbuild-cmake/releases/download/$MPV_DEV" mpv.7z)"
mkdir -p "$p/mpv" && 7z x -y -bso0 -bsp0 "-o$p/mpv" "$f"

echo "== vulkan loader"
f="$(get "https://repo.msys2.org/mingw/clang64/$VULKAN_LOADER" vulkan.pkg.tar.zst)"
echo "$VULKAN_LOADER_SHA256  $f" | sha256sum -c --quiet
mkdir -p "$p/vulkan" && tar --zstd -xf "$f" -C "$p/vulkan" --strip-components=2 clang64/bin/vulkan-1.dll

rm -rf "$dl"
echo "$stamp" > "$p/.stamp"
exec "$here/env.sh" "$p"
