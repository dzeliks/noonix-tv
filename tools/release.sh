#!/usr/bin/env bash
# tools/release.sh 0.2.0 - sets the version, commits, tags v0.2.0 and pushes; the release
# workflow builds, checks and publishes the appimage and the windows setup from the tag
set -euo pipefail
cd "$(dirname "$0")/.."
v="${1:?usage: release.sh <version, e.g. 0.2.0>}"
[[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || { echo "not a version: $v" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "commit or stash first" >&2; exit 1; }
[[ "$(git branch --show-current)" == main ]] || { echo "releases come from main" >&2; exit 1; }
git rev-parse -q --verify "refs/tags/v$v" >/dev/null && { echo "v$v exists" >&2; exit 1; }

python3 - "$v" <<'PY'
import re, sys
v = sys.argv[1]
p = 'core/Cargo.toml'
s = open(p).read()
s = re.sub(r'(?m)^version = ".*"', f'version = "{v}"', s, count=1)
open(p, 'w').write(s)
p = 'core/Cargo.lock'
s = open(p).read()
s = re.sub(r'(name = "noonix_core"\nversion = )".*"', rf'\1"{v}"', s)
open(p, 'w').write(s)
PY
git diff --quiet || git commit -qam "release $v"
git tag -a "v$v" -m "Noonix TV $v"
git push -q origin main "v$v"
echo "v$v pushed: gh run watch \$(gh run list -w release -L1 --json databaseId -q '.[0].databaseId')"
