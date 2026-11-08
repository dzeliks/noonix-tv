#!/usr/bin/env bash
# builds mac/dist-ios/Noonix TV.app for iphone + ipad on a mac: the rust core (no qt, c interface),
# then the swiftui app (the mac client's sources), bundled by hand (swiftpm makes no ios apps).
# built-in app keys come from the NOONIX_TMDB_* / NOONIX_TRAKT_* environment, like the other builds
#   mac/ios.sh            the simulator (apple silicon)
#   mac/ios.sh device     an iphone / ipad (needs CODESIGN_ID and PROFILE, a .mobileprovision)
#   mac/ios.sh ipa        an unsigned .ipa for sideloading (altstore, sideloadly sign it with your apple id)
#   CORE=0 mac/ios.sh     the app only (the core as last built)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$here")
kind=${1:-sim}
if [[ $kind == device || $kind == ipa ]]; then
    t=aarch64-apple-ios; dest="generic/platform=iOS"; sdk=iphoneos; plat=iPhoneOS
else
    t=aarch64-apple-ios-sim; dest="generic/platform=iOS Simulator"; sdk=iphonesimulator; plat=iPhoneSimulator
fi
export IPHONEOS_DEPLOYMENT_TARGET=26.0
conf=${CONF:-Release}

if [[ ${CORE:-1} != 0 ]]; then
    rustup target add "$t" >/dev/null 2>&1 || true
    cargo build --release --no-default-features --target "$t" --manifest-path "$repo/core/Cargo.toml" \
        --target-dir "${CARGO_TARGET_DIR:-$here/.build/cargo}"
fi
mkdir -p "$here/.build/core-ios"
cp "${CARGO_TARGET_DIR:-$here/.build/cargo}/$t/release/libnoonix_core.a" "$here/.build/core-ios/libnoonix_core.a"

cd "$here"
xcodebuild -scheme NoonixTV -destination "$dest" -configuration "$conf" -derivedDataPath "$here/.build/xc-$kind" \
    -skipMacroValidation -skipPackagePluginValidation ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO -quiet build
bin="$here/.build/xc-$kind/Build/Products/$conf-$sdk/NoonixTV"

version=$(sed -n 's/^version = "\(.*\)"/\1/p' "$repo/core/Cargo.toml" | head -1)
app="$here/dist-ios/$kind/Noonix TV.app"
rm -rf "$app"
mkdir -p "$app"
cp "$bin" "$app/Noonix TV"
cp "$repo/i18n/noonix-tv_sr_Latn.ts" "$repo/LICENSE" "$app/"
python3 "$repo/tools/third-party.py" mac "$t" > "$app/THIRD-PARTY.txt" 2>/dev/null || true

# the asset catalog: the icon, the splash kitty and the tmdb logo (ios reads svg / pdf only from here)
cat_dir=$(mktemp -d)/Assets.xcassets
mkdir -p "$cat_dir"
echo '{"info":{"version":1,"author":"xcode"}}' > "$cat_dir/Contents.json"
# the launch screen's colour: black, like the app
mkdir -p "$cat_dir/Launch.colorset"
echo '{"colors":[{"color":{"color-space":"srgb","components":{"red":"0","green":"0","blue":"0","alpha":"1"}},"idiom":"universal"}],"info":{"version":1,"author":"xcode"}}' \
    > "$cat_dir/Launch.colorset/Contents.json"
for f in "$repo"/qml/assets/kitty/*.svg "$here/Resources/tmdb.pdf"; do
    n=$(basename "${f%.*}"); e=${f##*.}
    mkdir -p "$cat_dir/$n.imageset"
    cp "$f" "$cat_dir/$n.imageset/$n.$e"
    printf '{"images":[{"filename":"%s","idiom":"universal"}],"info":{"version":1,"author":"xcode"},"properties":{"preserves-vector-representation":true}}\n' \
        "$n.$e" > "$cat_dir/$n.imageset/Contents.json"
done
icon_plist=$(mktemp)
xcrun actool "$cat_dir" "$here/Resources/AppIcon.icon" --compile "$app" --app-icon AppIcon --platform "$sdk" \
    --target-device iphone --target-device ipad --minimum-deployment-target 26.0 \
    --output-partial-info-plist "$icon_plist" >/dev/null

cat > "$app/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Noonix TV</string>
    <key>CFBundleDisplayName</key><string>Noonix TV</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID:-io.github.dzeliks.noonix-tv}</string>
    <key>CFBundleExecutable</key><string>Noonix TV</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleVersion</key><string>$version</string>
    <key>CFBundleSupportedPlatforms</key><array><string>$plat</string></array>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>sr-Latn</string></array>
    <key>LSRequiresIPhoneOS</key><true/>
    <key>MinimumOSVersion</key><string>26.0</string>
    <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
    <key>UILaunchScreen</key><dict><key>UIColorName</key><string>Launch</string></dict>
    <key>UIRequiresFullScreen</key><true/>
    <key>UIStatusBarHidden</key><true/>
    <key>UIViewControllerBasedStatusBarAppearance</key><false/>
    <key>UIUserInterfaceStyle</key><string>Dark</string>
    <key>UISupportedInterfaceOrientations</key>
    <array><string>UIInterfaceOrientationLandscapeLeft</string><string>UIInterfaceOrientationLandscapeRight</string></array>
    <key>UISupportedInterfaceOrientations~ipad</key>
    <array><string>UIInterfaceOrientationLandscapeLeft</string><string>UIInterfaceOrientationLandscapeRight</string></array>
    <key>UIApplicationSupportsIndirectInputEvents</key><true/>
    <key>UIBackgroundModes</key><array><string>audio</string></array>
    <!-- the library: videos copied into the app's folder in the files app -->
    <key>UIFileSharingEnabled</key><true/>
    <key>LSSupportsOpeningDocumentsInPlace</key><true/>
    <key>NSLocalNetworkUsageDescription</key><string>Plays from media servers and addons on your network.</string>
    <key>LSApplicationQueriesSchemes</key><array><string>vlc-x-callback</string><string>infuse</string><string>outplayer</string></array>
</dict>
</plist>
PLIST
/usr/libexec/PlistBuddy -c "Merge $icon_plist" "$app/Info.plist" >/dev/null 2>&1 || true

if [[ $kind == ipa ]]; then
    codesign --force --sign - "$app" >/dev/null 2>&1
    pay=$(mktemp -d)
    mkdir "$pay/Payload"
    cp -R "$app" "$pay/Payload/"
    ipa="$here/dist-ios/Noonix-TV-$version-ios.ipa"
    rm -f "$ipa"
    (cd "$pay" && zip -qry "$ipa" Payload)
    rm -rf "$pay"
    echo "$ipa"
    exit 0
elif [[ $kind == device ]]; then
    cp "${PROFILE:?a .mobileprovision}" "$app/embedded.mobileprovision"
    codesign --force --sign "${CODESIGN_ID:?a signing identity}" --entitlements "${ENTITLEMENTS:-/dev/null}" "$app"
else
    codesign --force --sign - "$app" >/dev/null 2>&1
fi
echo "$app"
