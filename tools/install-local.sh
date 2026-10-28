#!/usr/bin/env bash
# release build of this checkout into ~/.local, with noonix tv's app keys from the keyring
# (item: application=noonix-tv-build, one attribute `key` per NOONIX_* name). missing keys
# are fine: the app then uses what setup stored
#   tools/install-local.sh            build + install
#   tools/install-local.sh --store    put the keys into the keyring (asks for each)
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
build="${NOONIX_BUILD_DIR:-$HOME/noonix-tv-build/cmake-release}"
names=(NOONIX_TMDB_API_KEY NOONIX_TMDB_READ_TOKEN NOONIX_TRAKT_CLIENT_ID NOONIX_TRAKT_CLIENT_SECRET)

if [[ "${1:-}" == "--store" ]]; then
    for n in "${names[@]}"; do
        read -rsp "$n (empty skips): " v; echo
        [[ -n "$v" ]] && printf '%s' "$v" | secret-tool store --label="Noonix TV build: $n" application noonix-tv-build key "$n"
    done
    exit 0
fi

for n in "${names[@]}"; do
    v="$(secret-tool lookup application noonix-tv-build key "$n" 2>/dev/null || true)"
    if [[ -n "$v" ]]; then export "$n=$v"; echo "$n: from the keyring"; else echo "$n: not set"; fi
done
source "$HOME/.cargo/env"
cmake -S "$root" -B "$build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$HOME/.local"
nice cmake --build "$build"
cmake --install "$build"
