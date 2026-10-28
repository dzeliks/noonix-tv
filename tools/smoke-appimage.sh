#!/usr/bin/env bash
# checks a built appimage end to end in a throwaway home: version, the core (library,
# extensions), and the ui under a headless weston. never run this on a pc where noonix tv is
# open (same d-bus name)
#   tools/smoke-appimage.sh <file.AppImage> [--no-ui]
set -euo pipefail

img="$(readlink -f "${1:?usage: smoke-appimage.sh <file.AppImage> [--no-ui]}")"
ui=1; [[ "${2:-}" == "--no-ui" ]] && ui=0
tmp="$(mktemp -d)"
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$tmp"' EXIT
export HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/config" XDG_DATA_HOME="$tmp/data" \
       XDG_CACHE_HOME="$tmp/cache" XDG_STATE_HOME="$tmp/state" APPIMAGE_EXTRACT_AND_RUN=1
mkdir -p "$HOME" "$XDG_CONFIG_HOME/noonix-tv"

echo "== version"
"$img" --version

# the rest runs from one unpacked copy: extract-and-run unpacks the whole image on every call
(cd "$tmp" && "$img" --appimage-extract > /dev/null)
app="$tmp/squashfs-root/AppRun"
export APPIMAGE="$img"

echo "== core"
"$app" --cli ping
mkdir -p "$tmp/videos"
"$app" --cli library.addFolder "{\"path\":\"$tmp/videos\"}" library.status extensions.list > "$tmp/core.json"
python3 - "$tmp/core.json" <<'PY'
import json, sys
text = open(sys.argv[1]).read()
# noonix-tv-cli prints one json document per call
docs, dec, i = [], json.JSONDecoder(), 0
while i < len(text):
    if text[i].isspace():
        i += 1
        continue
    d, i = dec.raw_decode(text, i)
    docs.append(d)
st, ext = docs[-2], docs[-1]
assert len(st["folders"]) == 1, st
assert ext == [], ext
print("library + extensions ok")
PY

[[ $ui == 1 ]] || exit 0
echo "== ui (headless weston)"
export XDG_RUNTIME_DIR="$tmp/run"; mkdir -m 700 -p "$XDG_RUNTIME_DIR"
# weston < 10 (ubuntu 22.04) names its backends by module file
backend=headless; weston --help 2>&1 | grep -q 'headless-backend.so' && backend=headless-backend.so
weston --backend=$backend --socket=wl-smoke --width=1920 --height=1080 --idle-time=0 > "$tmp/weston.log" 2>&1 &
for _ in $(seq 50); do [[ -S "$XDG_RUNTIME_DIR/wl-smoke" ]] && break; sleep 0.1; done
export WAYLAND_DISPLAY=wl-smoke QT_QPA_PLATFORM=wayland NOONIX_WINDOWED=1 NOONIX_MUTE=1 NOONIX_TEST=1 QT_FORCE_STDERR_LOGGING=1
dbus-run-session -- "$app" > "$tmp/ui.log" 2>&1 &
pid=$!
sleep 20
alive=0; kill -0 $pid 2>/dev/null && alive=1
kill $pid 2>/dev/null || true; wait $pid 2>/dev/null || true
cat "$tmp/ui.log" | tail -40
if grep -E "is not installed|is not a type|Could not load the Qt platform plugin|module .* not found|Cannot assign to non-existent|failed to load component" "$tmp/ui.log" | grep -v "org.kde"; then
    echo "qml errors" >&2; exit 1
fi
[[ $alive == 1 ]] || { echo "the app exited within 20 s" >&2; exit 1; }
echo "ui ok"
