#!/usr/bin/env bash
# the release appimage built here, the way ci does it: old base in docker, deps prefix and the
# image all kept in <work> (reused on the next run)
#   tools/appimage/docker.sh <work dir>   -> <work>/out/Noonix-TV-<version>-<arch>.AppImage
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mkdir -p "${1:?usage: docker.sh <work dir>}" && cd "$1" && pwd)"
image=noonix-oldbase:22.04

# noonix tv's app keys, from the keyring like install-local.sh (not set = setup asks for them)
for n in NOONIX_TMDB_API_KEY NOONIX_TMDB_READ_TOKEN NOONIX_TRAKT_CLIENT_ID NOONIX_TRAKT_CLIENT_SECRET; do
    [[ -n "${!n:-}" ]] && continue
    v="$(secret-tool lookup application noonix-tv-build key "$n" 2>/dev/null || true)"
    if [[ -n "$v" ]]; then export "$n=$v"; fi
done

docker build -q -t "$image" "$root/tools/appimage" > /dev/null
# as you, not root: the work dir stays yours
run() {
    docker run --rm --user "$(id -u):$(id -g)" -e HOME=/build/home -w /build -v "$root:/src:ro" -v "$work:/build" \
        -e NOONIX_TMDB_API_KEY -e NOONIX_TMDB_READ_TOKEN -e NOONIX_TRAKT_CLIENT_ID -e NOONIX_TRAKT_CLIENT_SECRET -e NOONIX_UPDATE_REPO -e NOONIX_RELEASE \
        "$image" bash -euo pipefail -c "$1"
}
mkdir -p "$work/home"
run '/src/tools/appimage/deps.sh /build/prefix'
run '. /build/prefix/env.sh && NOONIX_GLIBC_MAX=2.35 /src/tools/build-appimage.sh /build/out'
ls -lh "$work"/out/*.AppImage
