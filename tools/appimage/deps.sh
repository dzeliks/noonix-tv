#!/usr/bin/env bash
# what the appimage bundles, built from pinned sources on the old base (base.sh first):
# qt (official build), wayland headers, libva, dav1d, ffmpeg, libass, libplacebo, mpv, sdl3,
# plus the build tools (meson, cmake, uv, rust). everything lands in <prefix>; a finished
# prefix is reused (the stamp is this file's hash, comments left out)
#   tools/appimage/deps.sh <prefix>
#   source <prefix>/env.sh   (paths for the app build)
set -euo pipefail

QT_VERSION=6.12.0
RUST_VERSION=1.99.1
# headers only: the host's libwayland-client runs (1.21 is what mpv asks for, 22.04 has 1.20)
WAYLAND_VERSION=1.21.0
WAYLAND_PROTOCOLS_VERSION=1.49
LIBVA_VERSION=2.24.1
NVCODEC_VERSION=n12.1.14.0
DAV1D_VERSION=1.5.4
FFMPEG_VERSION=n9.0.2
LIBASS_VERSION=0.17.5
LIBPLACEBO_VERSION=v7.360.1
MPV_VERSION=v0.41.0
SDL_VERSION=release-3.4.18
# every distro's va driver dir (libva tries them in order): debian/ubuntu, fedora + rpmfusion,
# arch, nixos
# qt's own build per arch: x86_64 or aarch64 (arm64)
if [[ $(uname -m) == aarch64 ]]; then qt_host=linux_arm64 qt_arch=linux_gcc_arm64 qt_dir=gcc_arm64
else qt_host=linux qt_arch=linux_gcc_64 qt_dir=gcc_64; fi
VA_DRIVERS=/usr/lib/$(uname -m)-linux-gnu/dri:/usr/lib64/dri:/usr/lib64/dri-freeworld:/usr/lib/dri:/run/opengl-driver/lib/dri

p="$(mkdir -p "${1:?usage: deps.sh <prefix>}" && cd "$1" && pwd)"
stamp="$(grep -Ev '^[[:space:]]*(#|$)' "$0" | sha256sum | cut -c1-16)"
if [[ -f "$p/.stamp" && "$(cat "$p/.stamp")" == "$stamp" ]]; then
    echo "deps: $p is current"
    exit 0
fi
usr="$p/usr"
src="$p/src"
rm -rf "$usr" "$src" "$p/tools" "$p/qt"
mkdir -p "$usr" "$src"
jobs="$(nproc)"

echo "== tools"
python3 -m venv "$p/tools"
"$p/tools/bin/pip" install -q meson ninja cmake aqtinstall uv jinja2 markupsafe
export CARGO_HOME="$p/cargo" RUSTUP_HOME="$p/rustup"
if [[ ! -x "$CARGO_HOME/bin/rustup" ]]; then
    curl -fsSL https://sh.rustup.rs | sh -s -- -y -q --no-modify-path --profile minimal --default-toolchain "$RUST_VERSION"
fi
"$CARGO_HOME/bin/rustup" default "$RUST_VERSION"

cat > "$p/env.sh" <<ENV
export PATH="$p/tools/bin:$CARGO_HOME/bin:$p/qt/$QT_VERSION/$qt_dir/bin:$usr/bin:\$PATH"
export CARGO_HOME="$CARGO_HOME" RUSTUP_HOME="$RUSTUP_HOME"
export PKG_CONFIG_PATH="$usr/lib/pkgconfig:$usr/share/pkgconfig"
export CMAKE_PREFIX_PATH="$p/qt/$QT_VERSION/$qt_dir:$usr"
export QMAKE="$p/qt/$QT_VERSION/$qt_dir/bin/qmake"
export LD_LIBRARY_PATH="$usr/lib:$p/qt/$QT_VERSION/$qt_dir/lib"
export NOONIX_QT_PREFIX="$p/qt/$QT_VERSION/$qt_dir" NOONIX_DEPS_PREFIX="$usr"
ENV
# shellcheck source=/dev/null
source "$p/env.sh"

echo "== qt $QT_VERSION"
aqt install-qt -O "$p/qt" "$qt_host" desktop "$QT_VERSION" "$qt_arch" -m qtshadertools qtimageformats > /dev/null
test -f "$NOONIX_QT_PREFIX/lib/libQt6WaylandClient.so.6"

# a step's output only when it fails
quiet() { "$@" > "$src/step.log" 2>&1 || { tail -n 40 "$src/step.log"; return 1; }; }
fetch() {   # <name> <git url> <tag>
    git -c advice.detachedHead=false clone -q --depth 1 --recurse-submodules --shallow-submodules \
        --branch "$3" "$2" "$src/$1"
}
mesonbuild() {   # <name> [meson options...]
    local d="$src/$1"; shift
    quiet meson setup "$d/build" "$d" --prefix="$usr" --libdir=lib --buildtype=release -Ddefault_library=shared "$@"
    quiet ninja -C "$d/build" -j "$jobs"
    quiet ninja -C "$d/build" install
}

echo "== wayland $WAYLAND_VERSION"
fetch wayland https://gitlab.freedesktop.org/wayland/wayland.git "$WAYLAND_VERSION"
mesonbuild wayland -Ddocumentation=false -Dtests=false -Ddtd_validation=false

echo "== wayland-protocols $WAYLAND_PROTOCOLS_VERSION"
fetch wayland-protocols https://gitlab.freedesktop.org/wayland/wayland-protocols.git "$WAYLAND_PROTOCOLS_VERSION"
mesonbuild wayland-protocols -Dtests=false

echo "== libva $LIBVA_VERSION"
fetch libva https://github.com/intel/libva.git "$LIBVA_VERSION"
mesonbuild libva -Ddriverdir="$VA_DRIVERS" -Dwith_x11=no -Dwith_glx=no -Dwith_wayland=yes -Denable_docs=false

echo "== nv-codec-headers $NVCODEC_VERSION"
fetch nv-codec-headers https://github.com/FFmpeg/nv-codec-headers.git "$NVCODEC_VERSION"
quiet make -C "$src/nv-codec-headers" PREFIX="$usr" install

echo "== dav1d $DAV1D_VERSION"
fetch dav1d https://code.videolan.org/videolan/dav1d.git "$DAV1D_VERSION"
mesonbuild dav1d -Denable_tools=false -Denable_tests=false -Denable_examples=false

echo "== ffmpeg $FFMPEG_VERSION"
fetch ffmpeg https://github.com/FFmpeg/FFmpeg.git "$FFMPEG_VERSION"
(
    cd "$src/ffmpeg"
    quiet ./configure --prefix="$usr" --libdir="$usr/lib" --enable-shared --disable-static --enable-pic \
        --enable-gpl --enable-version3 --disable-programs --disable-doc --disable-avdevice \
        --disable-debug --enable-openssl --enable-libdav1d --enable-libdrm --enable-vaapi \
        --enable-ffnvcodec --enable-nvdec --enable-cuvid --disable-vulkan --disable-xlib \
        --disable-libxcb --disable-sdl2 --disable-encoders --enable-encoder=png,mjpeg
    quiet make -j "$jobs"
    quiet make install
)

echo "== libass $LIBASS_VERSION"
fetch libass https://github.com/libass/libass.git "$LIBASS_VERSION"
mesonbuild libass -Dfontconfig=enabled -Dlibunibreak=disabled -Dtest=disabled -Dcompare=disabled -Dprofile=disabled -Dfuzz=disabled -Dcheckasm=disabled

echo "== libplacebo $LIBPLACEBO_VERSION"
fetch libplacebo https://code.videolan.org/videolan/libplacebo.git "$LIBPLACEBO_VERSION"
mesonbuild libplacebo -Dvulkan=disabled -Dopengl=enabled -Dshaderc=disabled -Dglslang=disabled \
    -Dlcms=enabled -Ddemos=false -Dtests=false -Dd3d11=disabled -Dxxhash=disabled -Dunwind=disabled

echo "== mpv $MPV_VERSION"
# drm=auto: libdrm found = the gl dmabuf interop vaapi needs; no libdisplay-info = no vo=drm (unused)
fetch mpv https://github.com/mpv-player/mpv.git "$MPV_VERSION"
mesonbuild mpv -Dlibmpv=true -Dcplayer=false -Dlua=disabled -Djavascript=disabled \
    -Dpipewire=disabled -Dpulse=enabled -Dalsa=enabled -Dx11=disabled -Dvulkan=disabled \
    -Dwayland=enabled -Degl=enabled -Degl-wayland=enabled -Dgl=enabled -Dvaapi=enabled \
    -Dvaapi-wayland=enabled -Dvaapi-drm=disabled -Ddrm=auto -Duchardet=enabled -Dlcms2=enabled \
    -Dzimg=enabled -Dlibarchive=disabled -Dlibbluray=disabled -Ddvdnav=disabled -Dcdda=disabled \
    -Drubberband=disabled -Dsdl2-audio=disabled -Dsdl2-video=disabled -Djack=disabled \
    -Dopenal=disabled -Dlibavdevice=disabled -Dvapoursynth=disabled -Dmanpage-build=disabled \
    -Dhtml-build=disabled

echo "== sdl $SDL_VERSION"
fetch sdl https://github.com/libsdl-org/SDL.git "$SDL_VERSION"
# gamepads only: video and audio are qt's and mpv's
quiet cmake -S "$src/sdl" -B "$src/sdl/build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$usr" \
    -DCMAKE_INSTALL_LIBDIR=lib -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF \
    -DSDL_VIDEO=OFF -DSDL_AUDIO=OFF -DSDL_RENDER=OFF -DSDL_GPU=OFF -DSDL_CAMERA=OFF -DSDL_UNIX_CONSOLE_BUILD=ON
quiet cmake --build "$src/sdl/build"
quiet cmake --install "$src/sdl/build"

# license texts + exact sources, for the appimage's notices (deploy.py copies them)
lic="$usr/share/licenses"
for d in wayland libva dav1d ffmpeg libass libplacebo mpv sdl; do
    mkdir -p "$lic/$d"
    find "$src/$d" -maxdepth 1 -type f \( -iname 'COPYING*' -o -iname 'LICENSE*' -o -iname 'LGPL*' \) \
        -exec cp {} "$lic/$d/" \;
done
cat > "$usr/share/licenses/SOURCES.txt" <<SRC
wayland $WAYLAND_VERSION  https://gitlab.freedesktop.org/wayland/wayland/-/tree/$WAYLAND_VERSION
libva $LIBVA_VERSION  https://github.com/intel/libva/tree/$LIBVA_VERSION
dav1d $DAV1D_VERSION  https://code.videolan.org/videolan/dav1d/-/tree/$DAV1D_VERSION
ffmpeg $FFMPEG_VERSION (gpl, version3)  https://github.com/FFmpeg/FFmpeg/tree/$FFMPEG_VERSION
libass $LIBASS_VERSION  https://github.com/libass/libass/tree/$LIBASS_VERSION
libplacebo $LIBPLACEBO_VERSION  https://code.videolan.org/videolan/libplacebo/-/tree/$LIBPLACEBO_VERSION
mpv $MPV_VERSION  https://github.com/mpv-player/mpv/tree/$MPV_VERSION
sdl $SDL_VERSION  https://github.com/libsdl-org/SDL/tree/$SDL_VERSION
qt $QT_VERSION (official build)  https://download.qt.io/official_releases/qt/${QT_VERSION%.*}/$QT_VERSION/single/
SRC
rm -rf "$src"
echo "$stamp" > "$p/.stamp"
du -sh "$p"/* | sort -h
