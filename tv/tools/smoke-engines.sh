#!/usr/bin/env bash
# runs the built app (dist/app) in the oldest engines the tvs have: chromium 53 (webOS 4) and 56 (tizen 4),
# snapshot builds in an ubuntu 16.04 container, driven over devtools (tools/cdp.mjs). checks the first run
# screen, then home with its rows and a title page, and leaves a shot of each.
# needs docker, node 22+ and the network (tmdb); build first (npm run build, with the tmdb keys)
#   tools/smoke-engines.sh [shots dir]
#   ENGINES=<dir> keeps the downloaded engines there (default ~/.cache/noonix-tv-engines)
set -euo pipefail
cd "$(dirname "$0")/.."
out="$(mkdir -p "${1:-smoke}" && cd "${1:-smoke}" && pwd)"
engines="${ENGINES:-$HOME/.cache/noonix-tv-engines}"
[[ -f dist/app/index.html ]] || { echo "no dist/app: npm run build first" >&2; exit 1; }
mkdir -p "$engines"

docker build -q -t noonix-tv-engines -f tools/engines.Dockerfile tools > /dev/null

fail=0
run() {
    local name=$1 rev=$2 port=$3 ua=$4
    local c="noonix-smoke-$name" prof
    if [[ ! -x "$engines/c$rev/chrome-linux/chrome" ]]; then
        curl -fsSL --retry 4 -o "$engines/c$rev.zip" \
            "https://storage.googleapis.com/chromium-browser-snapshots/Linux_x64/$rev/chrome-linux.zip"
        rm -rf "$engines/c$rev" && mkdir -p "$engines/c$rev"
        unzip -q "$engines/c$rev.zip" -d "$engines/c$rev" && rm "$engines/c$rev.zip"
    fi
    prof="$(mktemp -d)"
    docker rm -f "$c" > /dev/null 2>&1 || true
    docker run -d --rm --shm-size=1g --name "$c" --network host --user "$(id -u):$(id -g)" \
        -v "$engines/c$rev:/engine:ro" -v "$PWD/dist/app:/app:ro" -v "$prof:/prof" noonix-tv-engines \
        sh -c "Xvfb :9$port -screen 0 1920x1080x24 > /dev/null 2>&1 & sleep 1; HOME=/prof DISPLAY=:9$port \
            /engine/chrome-linux/chrome --no-sandbox --test-type --disable-infobars --mute-audio --user-agent='$ua' \
            --remote-debugging-port=$port --window-size=1920,1080 --window-position=0,0 --user-data-dir=/prof/p \
            --kiosk file:///app/index.html" > /dev/null
    local cdp="node tools/cdp.mjs $port"
    # waits for a js condition (true) up to $2 seconds
    until_true() {
        local i
        for ((i = 0; i < $2 * 2; i++)); do
            [[ "$($cdp eval "$1" 2> /dev/null)" == true ]] && return 0
            sleep 0.5
        done
        return 1
    }
    step() {
        if until_true "$2" "$3"; then
            echo "$name: $1 ok"
        else
            echo "::error::$name (chromium $rev): $1 didn't show up" >&2
            fail=1
        fi
        $cdp shot "$out/$name-$4.png" > /dev/null 2>&1 || true
    }
    for ((i = 0; i < 60; i++)); do curl -fs "localhost:$port/json/list" | grep -q '"page"' && break; sleep 0.5; done

    step "first run screen" '!!document.querySelector(".setup")' 30 setup
    # past the first run: home under it
    $cdp eval 'localStorage.setItem("noonix:setup", "1"); localStorage.removeItem("noonix:setupStep"); true' > /dev/null
    $cdp reload > /dev/null
    step "home rows" '!document.querySelector(".splash") && document.querySelectorAll(".rowtitle").length > 0' 60 home
    # down to the first row: its title's backdrop from tmdb
    $cdp key down > /dev/null
    step "a title on home" 'Array.prototype.some.call(document.querySelectorAll("img.backdrop"), function (i) { return i.naturalWidth > 0 })' 30 hero
    $cdp key ok > /dev/null
    step "title page" '!!document.querySelector(".details .gbutton")' 30 details
    $cdp key back wait:900 > /dev/null
    step "back home" '!document.querySelector(".details") || !document.querySelector(".details").offsetParent' 15 back

    docker rm -f "$c" > /dev/null 2>&1 || true
    rm -rf "$prof"
}

run webos 403380 9333 "Mozilla/5.0 (Web0S; Linux/SmartTV) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/53.0.2785.34 Safari/537.36 WebAppManager"
run tizen 433017 9334 "Mozilla/5.0 (SMART-TV; LINUX; Tizen 4.0) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/2.1 Chrome/56.0.2924.0 TV Safari/537.36"
exit $fail
