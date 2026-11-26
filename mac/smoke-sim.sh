#!/usr/bin/env bash
# installs a simulator build in a fresh simulator (the newest runtime), starts it and checks it stays up,
# then a shot of its screen. the simulator is deleted after
#   mac/smoke-sim.sh ios|duo|tv <Noonix TV.app> [shot.png]   (the app from mac/ios.sh or mac/ios.sh tv;
#   duo: the foldable iphone, closed, shot of its outer screen)
set -euo pipefail
kind="${1:?usage: smoke-sim.sh ios|duo|tv <app> [shot.png]}"
app="${2:?usage: smoke-sim.sh ios|duo|tv <app> [shot.png]}"
shot="${3:-}"
case $kind in
    ios) platform=iOS; model="iPad Pro 13-inch";;
    duo) platform=iOS; model="iPhone Duo";;
    tv) platform=tvOS; model="Apple TV 4K";;
    *) echo "ios or tv" >&2; exit 1;;
esac
id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Info.plist")"

# the newest runtime of the platform and the first device of that model it runs
read -r runtime devtype < <(xcrun simctl list runtimes available -j | python3 -c '
import json, sys
platform, model = sys.argv[1], sys.argv[2]
rs = [r for r in json.load(sys.stdin)["runtimes"] if r.get("platform") == platform]
rs.sort(key=lambda r: [int(x) for x in r["version"].split(".")])
for r in reversed(rs):
    for d in r.get("supportedDeviceTypes", []):
        if d["name"].startswith(model):
            print(r["identifier"], d["identifier"]); sys.exit(0)
sys.exit("no " + platform + " runtime with a " + model)
' "$platform" "$model")
echo "$runtime / $devtype"

udid="$(xcrun simctl create noonix-smoke "$devtype" "$runtime")"
trap 'xcrun simctl shutdown "$udid" > /dev/null 2>&1 || true; xcrun simctl delete "$udid" > /dev/null 2>&1 || true' EXIT
xcrun simctl boot "$udid"
xcrun simctl bootstatus "$udid" -b > /dev/null
xcrun simctl install "$udid" "$app"
pid="$(SIMCTL_CHILD_NOONIX_MUTE=1 xcrun simctl launch "$udid" "$id" | awk '{print $NF}')"
for i in $(seq 25); do
    sleep 1
    if ! kill -0 "$pid" 2> /dev/null; then
        echo "::error::the app quit after $i s"
        xcrun simctl spawn "$udid" log show --last 2m --predicate "process == \"Noonix TV\"" 2> /dev/null | tail -40 || true
        exit 1
    fi
done
# two screens: the outer one (the one in use while closed) by its width
display=()
if [[ $kind == duo ]]; then
    d=$(xcrun simctl io "$udid" enumerate | awk '/UUID:/{u=$2} /Default width:/{if ($3==1398) {print u; exit}}')
    [[ -n $d ]] && display=(--display="$d")
fi
[[ -z "$shot" ]] || xcrun simctl io "$udid" screenshot "${display[@]}" "$shot" > /dev/null || true
echo "up for 25 s"
