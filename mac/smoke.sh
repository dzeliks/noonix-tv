#!/usr/bin/env bash
# starts the built mac app and checks it stays up (a crash at launch fails), muted, then a shot of the screen
#   mac/smoke.sh "mac/dist/Noonix TV.app" [shot.png]
set -euo pipefail
app="${1:?usage: smoke.sh <Noonix TV.app> [shot.png]}"
shot="${2:-}"
bin="$app/Contents/MacOS/$(ls "$app/Contents/MacOS" | head -1)"
log="$(mktemp)"
NOONIX_MUTE=1 "$bin" > "$log" 2>&1 &
pid=$!
for i in $(seq 25); do
    sleep 1
    if ! kill -0 "$pid" 2> /dev/null; then
        echo "::error::the app quit after $i s"
        cat "$log"
        exit 1
    fi
done
[[ -z "$shot" ]] || screencapture -x "$shot" || true
kill "$pid"
wait "$pid" 2> /dev/null || true
echo "up for 25 s"
