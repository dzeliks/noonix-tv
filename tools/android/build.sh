#!/usr/bin/env bash
# the android app on a mac or linux box with the android sdk + ndk, qt for android of that abi
# (tools/android/qt-fetch.py) and rust's target for it. ABI=arm64-v8a (the default: the full app,
# hdr and new rendering go here) or armeabi-v7a (32-bit tv boxes: playback only keeps working)
#   QT_ANDROID=<qt for android> QT_HOST=<host qt> ANDROID_SDK_ROOT=<sdk> [ANDROID_NDK_ROOT=<ndk>] [ABI=<abi>]
#   [KEYSTORE=<file> KEYSTORE_ALIAS=<alias> KEYSTORE_PASS=<pass>] tools/android/build.sh <work dir>
#   -> <work>/Noonix-TV-<version>-android-<arm64|armv7>-preview.apk
# built-in app keys come from the NOONIX_TMDB_* / NOONIX_TRAKT_* environment, like the other builds
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
work="$(mkdir -p "${1:?usage: build.sh <work dir>}" && cd "$1" && pwd)"
: "${QT_ANDROID:?}" "${QT_HOST:?}" "${ANDROID_SDK_ROOT:?}"
ndk="${ANDROID_NDK_ROOT:-$(ls -d "$ANDROID_SDK_ROOT"/ndk/* | sort -V | tail -1)}"
abi="${ABI:-arm64-v8a}"
case "$abi" in
    arm64-v8a) name=arm64 triple=aarch64-linux-android ;;
    armeabi-v7a) name=armv7 triple=armv7-linux-androideabi
        # cc-rs asks clang for plain arm here, which qt refuses (armv5)
        export CFLAGS_armv7_linux_androideabi=--target=armv7a-linux-androideabi28
        export CXXFLAGS_armv7_linux_androideabi=--target=armv7a-linux-androideabi28 ;;
    *) echo "unknown abi: $abi" >&2; exit 1 ;;
esac

"$here/libmpv.sh" "$work/libmpv" "$abi"

"$QT_ANDROID/bin/qt-cmake" -S "$root" -B "$work/build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DQT_HOST_PATH="$QT_HOST" -DANDROID_SDK_ROOT="$ANDROID_SDK_ROOT" -DANDROID_NDK_ROOT="$ndk" \
    -DQT_ANDROID_ABIS="$abi" -DNOONIX_MPV_DIR="$work/libmpv" -DNOONIX_QMAKE="$QT_ANDROID/bin/qmake"
cmake --build "$work/build" --target apk

version=$(sed -n 's/^version = "\(.*\)"/\1/p' "$root/core/Cargo.toml" | head -1)
apk="$(ls -t "$work/build/android-build/build/outputs/apk/release/"*.apk | head -1)"
out="$work/Noonix-TV-$version-android-$name-preview.apk"
tools="$(ls -d "$ANDROID_SDK_ROOT"/build-tools/* | sort -V | tail -1)"
# libmpv's c++ runtime (newer than the ndk's), stored like the other native libs: uncompressed
stage="$work/stage"
rm -rf "$stage" && mkdir -p "$stage/lib/$abi"
cp "$work/libmpv/lib/libc++_shared.so" "$stage/lib/$abi/"
# what ships inside with its license and source, like the other builds
mkdir -p "$stage/assets"
QT_ANDROID="$QT_ANDROID" python3 "$root/tools/third-party.py" android "$triple" > "$stage/assets/THIRD-PARTY.txt"
cp "$root/LICENSE" "$root/fonts/Inter-OFL.txt" "$stage/assets/"
cp "$apk" "$work/unaligned.apk"
(cd "$stage" && zip -q -0 "$work/unaligned.apk" "lib/$abi/libc++_shared.so" && zip -q "$work/unaligned.apk" assets/THIRD-PARTY.txt assets/LICENSE assets/Inter-OFL.txt)
"$tools/zipalign" -f -p 4 "$work/unaligned.apk" "$out.tmp"
if [[ -n "${KEYSTORE:-}" ]]; then
    "$tools/apksigner" sign --ks "$KEYSTORE" --ks-key-alias "${KEYSTORE_ALIAS:?}" \
        --ks-pass env:KEYSTORE_PASS --out "$out" "$out.tmp"
else
    # a dev build: the sdk's debug key
    dbg="$HOME/.android/debug.keystore"
    [[ -f "$dbg" ]] || keytool -genkeypair -keystore "$dbg" -storepass android -keypass android \
        -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=Android Debug,O=Android,C=US" >/dev/null
    "$tools/apksigner" sign --ks "$dbg" --ks-key-alias androiddebugkey --ks-pass pass:android --out "$out" "$out.tmp"
fi
rm -f "$out.tmp" "$work/unaligned.apk"
ls -la "$out"
