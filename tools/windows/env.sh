#!/usr/bin/env bash
# writes <prefix>/env.sh (paths for the build) and the cross qmake that cxx-qt asks for qt's
# folders: windows qt's headers and libraries, the linux host's moc / rcc / qmlcachegen
#   tools/windows/env.sh <prefix>
set -euo pipefail
p="$(cd "$1" && pwd)"
host="$(dirname "$(dirname "$(find "$p/qt" -maxdepth 4 -path '*/gcc_64/bin/qmake' -print -quit)")")"
win="$p/qt-win"
[[ -x "$host/bin/qmake" && -f "$win/lib/cmake/Qt6/Qt6Config.cmake" ]] || { echo "deps: qt missing in $p" >&2; exit 1; }

mkdir -p "$p/cross"
printf '[Paths]\nPrefix=%s\n' "$win" > "$p/cross/qt.conf"
cat > "$p/cross/qmake" <<SH
#!/bin/sh
case "\$*" in
    *QT_INSTALL_BINS*|*QT_INSTALL_LIBEXECS*) exec "$host/bin/qmake" "\$@" ;;
esac
exec "$host/bin/qmake" -qtconf "$p/cross/qt.conf" "\$@"
SH
chmod +x "$p/cross/qmake"

cat > "$p/env.sh" <<ENV
export PATH="$p/tools/bin:$p/cargo/bin:$p/llvm-mingw/bin:\$PATH"
export CARGO_HOME="$p/cargo" RUSTUP_HOME="$p/rustup"
export NOONIX_WIN_PREFIX="$p" NOONIX_QT_HOST="$host" NOONIX_QT_WIN="$win"
# cargo: the cc crate and the linker for the windows target
export CC_x86_64_pc_windows_gnullvm=x86_64-w64-mingw32-clang CXX_x86_64_pc_windows_gnullvm=x86_64-w64-mingw32-clang++
export AR_x86_64_pc_windows_gnullvm=llvm-ar CARGO_TARGET_X86_64_PC_WINDOWS_GNULLVM_LINKER=x86_64-w64-mingw32-clang
ENV
echo "deps: ready in $p"
