# cross build for windows x64 with llvm-mingw, qt for windows + the linux host's qt tools.
# needs <prefix>/env.sh sourced (tools/windows/deps.sh)
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR x86_64)
set(CMAKE_C_COMPILER x86_64-w64-mingw32-clang)
set(CMAKE_CXX_COMPILER x86_64-w64-mingw32-clang++)
set(CMAKE_RC_COMPILER x86_64-w64-mingw32-windres)

set(prefix $ENV{NOONIX_WIN_PREFIX})
set(QT_HOST_PATH $ENV{NOONIX_QT_HOST})
set(CMAKE_FIND_ROOT_PATH $ENV{NOONIX_QT_WIN} ${prefix}/sdl/x86_64-w64-mingw32 ${prefix}/llvm-mingw/x86_64-w64-mingw32)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

set(SDL3_DIR ${prefix}/sdl/cmake)
set(NOONIX_MPV_DIR ${prefix}/mpv)
set(NOONIX_QMAKE ${prefix}/cross/qmake)

# rust: corrosion builds for this target (env.sh names the compilers and linker for cargo)
set(Rust_CARGO_TARGET x86_64-pc-windows-gnullvm)
