#!/usr/bin/env bash
# libmpv for android (arm64-v8a): libmpv-android's prebuilt libmpv + ffmpeg (mit, built from mpv
# and ffmpeg's own sources) and the matching mpv headers, both pinned. also openssl 3 from kdab's
# android_openssl (apache 2.0): qt's tls backend on android (https artwork)
#   tools/android/libmpv.sh <dest>   -> <dest>/include/mpv/*.h, <dest>/lib/*.so
set -euo pipefail
dest="${1:?usage: libmpv.sh <dest>}"
aar_v=1.0.0     # mpv 0.41.0, ffmpeg 8.1
aar_sum=df146592480fc8418415a06b1f1a1d6318b0088e21f52254b0e9a82b61ca8fa2
mpv_v=0.41.0
mpv_sum=ee21092a5ee427353392360929dc64645c54479aefdb5babc5cfbb5fad626209
ssl_rev=b71f1470962019bd89534a2919f5925f93bc5779
ssl_sums="1e6c12ae0c2dadfe9d178d7f80f0ab248a1877a234066098bf5594e5205e5740  libcrypto_3.so
01d2bd0baac626efd3309f35f99c4b826dd9b885a7e4d14d5b12b3603d3a407f  libssl_3.so"
abi=arm64-v8a

[[ -f "$dest/.stamp" && "$(cat "$dest/.stamp")" == "$aar_v $mpv_v $ssl_rev" ]] && exit 0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/libmpv.aar" "https://repo1.maven.org/maven2/dev/jdtech/mpv/libmpv/$aar_v/libmpv-$aar_v.aar"
curl -fsSL -o "$tmp/mpv.tar.gz" "https://github.com/mpv-player/mpv/archive/refs/tags/v$mpv_v.tar.gz"
echo "$aar_sum  $tmp/libmpv.aar" | shasum -a 256 -c - >/dev/null
echo "$mpv_sum  $tmp/mpv.tar.gz" | shasum -a 256 -c - >/dev/null
rm -rf "$dest"
mkdir -p "$dest/lib" "$dest/include"
(cd "$tmp" && unzip -q libmpv.aar "jni/$abi/*")
# its java glue (libplayer) isn't used. its c++ runtime is newer than the ndk's that qt brings and
# runs qt too: the apk takes this one (tools/android/build.sh)
cp "$tmp/jni/$abi"/lib*.so "$dest/lib/"
rm -f "$dest/lib/libplayer.so"
for f in libcrypto_3.so libssl_3.so; do
    curl -fsSL -o "$dest/lib/$f" "https://raw.githubusercontent.com/KDAB/android_openssl/$ssl_rev/ssl_3/$abi/$f"
done
(cd "$dest/lib" && shasum -a 256 -c - <<< "$ssl_sums" >/dev/null)
tar -xzf "$tmp/mpv.tar.gz" -C "$tmp" "mpv-$mpv_v/include/mpv"
cp -R "$tmp/mpv-$mpv_v/include/mpv" "$dest/include/"
echo "$aar_v $mpv_v $ssl_rev" > "$dest/.stamp"
ls "$dest/lib"
