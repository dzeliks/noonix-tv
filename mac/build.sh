#!/usr/bin/env bash
# builds mac/dist/Noonix TV.app on a mac: the rust core (no qt, c interface) for each arch, then
# the swiftui app. needs the command line tools and rustup. built-in app keys come from the
# NOONIX_TMDB_* / NOONIX_TRAKT_* environment, like the other builds
#   mac/build.sh            universal (arm64 + x86_64)
#   ARCHS=arm64 mac/build.sh  one arch
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$here")
archs=${ARCHS:-"arm64 x86_64"}
export MACOSX_DEPLOYMENT_TARGET=26.0

libs=()
for a in $archs; do
    t=$([[ $a == arm64 ]] && echo aarch64-apple-darwin || echo x86_64-apple-darwin)
    rustup target add "$t" >/dev/null 2>&1 || true
    cargo build --release --no-default-features --target "$t" --manifest-path "$repo/core/Cargo.toml" \
        --target-dir "${CARGO_TARGET_DIR:-$here/.build/cargo}"
    libs+=("${CARGO_TARGET_DIR:-$here/.build/cargo}/$t/release/libnoonix_core.a")
done
mkdir -p "$here/.build/core"
lipo -create "${libs[@]}" -output "$here/.build/core/libnoonix_core.a"

# the package checkout sometimes comes back half made on ci runners, and github's downloads of
# the prebuilt frameworks answer 500 now and then: again from clean, waiting longer each time
for i in 1 2 3 4 5; do
    swift package resolve --package-path "$here" && break
    rm -rf "$here/.build/repositories" "$HOME/Library/Caches/org.swift.swiftpm/repositories"
    sleep $((i * 15))
done

swift_archs=()
for a in $archs; do swift_archs+=(--arch "$a"); done
swift build -c release --package-path "$here" "${swift_archs[@]}"
bin_dir="$(swift build -c release --package-path "$here" "${swift_archs[@]}" --show-bin-path)"
bin="$bin_dir/NoonixTV"

version=$(sed -n 's/^version = "\(.*\)"/\1/p' "$repo/core/Cargo.toml" | head -1)
app="$here/dist/Noonix TV.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/Noonix TV"
# what ships inside with its license (both arches link the same crates)
python3 "$repo/tools/third-party.py" mac "$t" > "$app/Contents/Resources/THIRD-PARTY.txt"
cp "$repo/LICENSE" "$app/Contents/Resources/"

# icon: the icon composer document (light, dark, clear and tinted) -> Assets.car + an icns for
# older finders
icon_tmp=$(mktemp -d)
xcrun actool "$here/Resources/AppIcon.icon" --compile "$app/Contents/Resources" --app-icon AppIcon \
    --platform macosx --target-device mac --minimum-deployment-target 26.0 \
    --output-partial-info-plist "$icon_tmp/icon.plist" --output-format human-readable-text >/dev/null
# the tmdb logo the credits must show (vector, from qml/assets/credits/tmdb.svg)
cp "$here/Resources/tmdb.pdf" "$app/Contents/Resources/"
# the launch splash's kitty, in parts (qml Splash)
cp -R "$repo/qml/assets/kitty" "$app/Contents/Resources/"
# serbian, from the same translations the tv app uses
cp "$repo/i18n/noonix-tv_sr_Latn.ts" "$app/Contents/Resources/"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Noonix TV</string>
    <key>CFBundleDisplayName</key><string>Noonix TV</string>
    <key>CFBundleIdentifier</key><string>io.github.dzeliks.noonix-tv</string>
    <key>CFBundleExecutable</key><string>Noonix TV</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleVersion</key><string>$version</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.entertainment</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# ad-hoc: runs on this mac; another mac needs right click > open (or xattr -cr) once
codesign --force --sign - "$app"
echo "$app"
