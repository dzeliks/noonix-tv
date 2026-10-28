#!/usr/bin/env bash
# refreshes i18n/*.ts from the qml, the c++ and the core's strings (qml/CoreStrings.js);
# keeps every translation already there. translate in the .ts (linguist or by hand)
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
lupdate="$(command -v lupdate6 || command -v lupdate || echo /usr/lib/qt6/bin/lupdate)"
cd "$root"
for ts in i18n/*.ts; do
    "$lupdate" -silent -locations none -no-obsolete qml src -ts "$ts"
done
grep -c '<translation type="unfinished"' i18n/*.ts || true
