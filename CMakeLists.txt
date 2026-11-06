cmake_minimum_required(VERSION 3.24)
project(noonix-tv LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE RelWithDebInfo)
endif()

if(ANDROID)
    # android (tools/android/build.sh): video in qt quick's opengl es scene, no d-bus, no sdl (the
    # system hands pads and remotes over as keys)
    find_package(Qt6 6.8 REQUIRED COMPONENTS Core Gui Network Qml Quick OpenGL ShaderTools LinguistTools)
elseif(WIN32)
    # windows (tools/windows/build.sh cross-builds it): video drawn in qt quick's opengl scene
    find_package(Qt6 6.8 REQUIRED COMPONENTS Core Gui Network Qml Quick OpenGL DBus ShaderTools LinguistTools)
else()
    # libGL.so.1, not glvnd's libOpenGL + libGLX: minimal installs (and the appimage's hosts)
    # don't always have libOpenGL.so.0
    set(OpenGL_GL_PREFERENCE LEGACY)
    find_package(Qt6 6.8 REQUIRED COMPONENTS Core Gui GuiPrivate Network Qml Quick DBus ShaderTools LinguistTools)
endif()

# rust core, qml module Noonix.Core. a cross build names the qmake that answers for the target qt
include(FetchContent)
if(WIN32)
    # cxx-qt's corrosion (0.5) doesn't know rust's gnullvm target yet; the first declaration wins
    FetchContent_Declare(Corrosion GIT_REPOSITORY https://github.com/corrosion-rs/corrosion.git GIT_TAG v0.6.1)
endif()
FetchContent_Declare(CxxQt GIT_REPOSITORY https://github.com/kdab/cxx-qt-cmake.git GIT_TAG 0.10.0)
FetchContent_MakeAvailable(CxxQt)
set(NOONIX_QMAKE "" CACHE FILEPATH "qmake for cxx-qt (cross builds)")
set(QMAKE_ARG)
if(NOONIX_QMAKE)
    set(QMAKE_ARG QMAKE ${NOONIX_QMAKE})
endif()
cxx_qt_import_crate(MANIFEST_PATH core/Cargo.toml CRATES noonix_core LOCKED
    QT_MODULES Qt::Core Qt::Gui Qt::Qml ${QMAKE_ARG})
cxx_qt_import_qml_module(noonix_core_qml URI "Noonix.Core" SOURCE_CRATE noonix_core)
if(NOT ANDROID)
    find_package(SDL3 REQUIRED CONFIG COMPONENTS SDL3-shared)
endif()

set(SOURCES
    src/main.cpp
    src/videosurface.h
    src/player.cpp src/player.h
    src/videoglass.cpp src/videoglass.h
    src/videograb.cpp src/videograb.h
    src/remote.cpp src/remote.h
    src/input.cpp src/input.h)

if(ANDROID)
    # libmpv-android's prebuilt libmpv + ffmpeg (tools/android/libmpv.sh): include/ and lib/*.so
    set(NOONIX_MPV_DIR "" CACHE PATH "libmpv for android")
    add_library(noonix_mpv SHARED IMPORTED)
    set_target_properties(noonix_mpv PROPERTIES
        IMPORTED_LOCATION ${NOONIX_MPV_DIR}/lib/libmpv.so
        INTERFACE_INCLUDE_DIRECTORIES ${NOONIX_MPV_DIR}/include)
    file(GLOB NOONIX_MPV_LIBS ${NOONIX_MPV_DIR}/lib/*.so)
    # its newer c++ runtime goes into the apk in place of the ndk's (tools/android/build.sh)
    list(FILTER NOONIX_MPV_LIBS EXCLUDE REGEX "libc\\+\\+_shared")
    list(APPEND SOURCES src/videosurface_scene.cpp src/videosurface_android.cpp src/videoview.cpp src/videoview.h)
    # libavcodec: ffmpeg's mediacodec decoders get the java vm from main()
    find_library(AVCODEC avcodec PATHS ${NOONIX_MPV_DIR}/lib NO_DEFAULT_PATH NO_CMAKE_FIND_ROOT_PATH)
    set(PLATFORM_LIBS Qt6::OpenGL noonix_mpv ${AVCODEC} log android nativewindow EGL GLESv3)
elseif(WIN32)
    # shinchiro's libmpv: NOONIX_MPV_DIR holds include/, libmpv.dll.a and libmpv-2.dll
    set(NOONIX_MPV_DIR "" CACHE PATH "libmpv for windows")
    add_library(noonix_mpv SHARED IMPORTED)
    set_target_properties(noonix_mpv PROPERTIES
        IMPORTED_IMPLIB ${NOONIX_MPV_DIR}/libmpv.dll.a
        IMPORTED_LOCATION ${NOONIX_MPV_DIR}/libmpv-2.dll
        INTERFACE_INCLUDE_DIRECTORIES ${NOONIX_MPV_DIR}/include)
    # icon + version for the exe, the version from the core's Cargo.toml
    file(STRINGS core/Cargo.toml NOONIX_VERSION REGEX "^version = " LIMIT_COUNT 1)
    string(REGEX REPLACE "^version = \"([0-9.]+).*" "\\1" NOONIX_VERSION "${NOONIX_VERSION}")
    string(REPLACE "." "," NOONIX_VERSION_RC "${NOONIX_VERSION},0")
    configure_file(dist/windows/noonix-tv.rc.in noonix-tv.rc @ONLY)
    list(APPEND SOURCES src/videosurface_scene.cpp src/videoview.cpp src/videoview.h ${CMAKE_CURRENT_BINARY_DIR}/noonix-tv.rc)
    # iphlpapi: the torrent client lists the network adapters
    set(PLATFORM_LIBS Qt6::OpenGL noonix_mpv iphlpapi)
else()
    find_package(PkgConfig REQUIRED)
    pkg_check_modules(MPV REQUIRED IMPORTED_TARGET mpv)
    pkg_check_modules(WL REQUIRED IMPORTED_TARGET wayland-client wayland-egl egl)
    pkg_get_variable(WAYLAND_PROTOCOLS wayland-protocols pkgdatadir)
    pkg_get_variable(WAYLAND_SCANNER wayland-scanner wayland_scanner)

    # wp_color_manager_v1 client
    set(CM_XML ${WAYLAND_PROTOCOLS}/staging/color-management/color-management-v1.xml)
    set(CM_GEN ${CMAKE_CURRENT_BINARY_DIR}/color-management-v1-client-protocol)
    add_custom_command(OUTPUT ${CM_GEN}.h ${CM_GEN}.c
        COMMAND ${WAYLAND_SCANNER} client-header ${CM_XML} ${CM_GEN}.h
        COMMAND ${WAYLAND_SCANNER} private-code ${CM_XML} ${CM_GEN}.c
        DEPENDS ${CM_XML})
    list(APPEND SOURCES src/videosurface.cpp ${CM_GEN}.c ${CM_GEN}.h)
    set(PLATFORM_LIBS Qt6::GuiPrivate PkgConfig::MPV PkgConfig::WL)
endif()

qt_add_executable(noonix-tv ${SOURCES})
target_include_directories(noonix-tv PRIVATE ${CMAKE_CURRENT_BINARY_DIR})
if(WIN32)
    set_target_properties(noonix-tv PROPERTIES WIN32_EXECUTABLE ON)
endif()
if(ANDROID)
    file(STRINGS core/Cargo.toml NOONIX_VERSION REGEX "^version = " LIMIT_COUNT 1)
    string(REGEX REPLACE "^version = \"([0-9.]+).*" "\\1" NOONIX_VERSION "${NOONIX_VERSION}")
    # 0.2.3 -> 2003: a newer version always has a higher code
    string(REPLACE "." ";" NOONIX_V "${NOONIX_VERSION}")
    list(GET NOONIX_V 0 V_MAJOR)
    list(GET NOONIX_V 1 V_MINOR)
    list(GET NOONIX_V 2 V_PATCH)
    math(EXPR NOONIX_VERSION_CODE "${V_MAJOR} * 1000000 + ${V_MINOR} * 1000 + ${V_PATCH}")
    set_target_properties(noonix-tv PROPERTIES
        QT_ANDROID_PACKAGE_SOURCE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/android
        QT_ANDROID_MIN_SDK_VERSION 28
        QT_ANDROID_TARGET_SDK_VERSION 36
        QT_ANDROID_VERSION_NAME ${NOONIX_VERSION}
        QT_ANDROID_VERSION_CODE ${NOONIX_VERSION_CODE}
        QT_ANDROID_EXTRA_LIBS "${NOONIX_MPV_LIBS}")
else()
    target_compile_definitions(noonix-tv PRIVATE NOONIX_DBUS NOONIX_SDL)
endif()

file(GLOB_RECURSE QML_FILES RELATIVE ${CMAKE_CURRENT_SOURCE_DIR} CONFIGURE_DEPENDS qml/*.qml qml/*.js qml/qmldir qml/assets/*.svg)
# +scene/ holds the versions of a few files for video inside the scene (windows, android)
if(NOT WIN32 AND NOT ANDROID)
    list(FILTER QML_FILES EXCLUDE REGEX "^qml/\\+scene/")
endif()
qt_add_resources(noonix-tv "qml" PREFIX "/" FILES ${QML_FILES})
qt_add_resources(noonix-tv "icon" PREFIX "/" BASE dist FILES dist/noonix-tv.svg dist/noonix-tv-dark.svg)
# inter (ofl) for pcs without sf pro
qt_add_resources(noonix-tv "fonts" PREFIX "/" FILES fonts/InterVariable.ttf)

# glsl 300 es too for android: es 1.00 has no textureLod without an extension most gpus lack
qt_add_shaders(noonix-tv "shaders"
    PREFIX "/"
    BATCHABLE
    GLSL "100es,300es,120,150"
    FILES qml/shaders/glass.vert qml/shaders/glass.frag qml/shaders/blur.frag qml/shaders/art.frag qml/shaders/ring.frag qml/shaders/edge.frag qml/shaders/fade.frag qml/shaders/vidtone.frag qml/shaders/scrim.frag qml/shaders/splash.frag
    OUTPUTS shaders/glass.vert.qsb shaders/glass.frag.qsb shaders/blur.frag.qsb shaders/art.frag.qsb shaders/ring.frag.qsb shaders/edge.frag.qsb shaders/fade.frag.qsb shaders/vidtone.frag.qsb shaders/scrim.frag.qsb shaders/splash.frag.qsb)

# serbian (latin): i18n/*.ts, refreshed by tools/update-translations.sh, built into :/i18n
# immediate: the deferred call loses the quotes around a build dir with spaces
qt_add_translations(noonix-tv TS_FILES i18n/noonix-tv_sr_Latn.ts RESOURCE_PREFIX "/i18n" IMMEDIATE_CALL)

target_link_libraries(noonix-tv PRIVATE
    noonix_core_qml Qt6::Gui Qt6::Network Qt6::Quick ${PLATFORM_LIBS})
if(NOT ANDROID)
    target_link_libraries(noonix-tv PRIVATE Qt6::DBus SDL3::SDL3)
endif()

# dev builds play muted unless NOONIX_MUTE=0 (house rule: tests are muted)
option(NOONIX_DEFAULT_MUTE "start mpv muted" OFF)
if(NOONIX_DEFAULT_MUTE)
    target_compile_definitions(noonix-tv PRIVATE NOONIX_DEFAULT_MUTE)
endif()

if(ANDROID)
    # the apk: androiddeployqt (tools/android/build.sh)
    return()
endif()

if(WIN32)
    # one folder: the exe and its dlls (tools/windows/deploy.py)
    install(TARGETS noonix-tv RUNTIME DESTINATION .)
    install(PROGRAMS $<TARGET_FILE:noonix-tv-cli> DESTINATION .)
    install(FILES LICENSE fonts/Inter-OFL.txt DESTINATION .)
    return()
endif()

install(TARGETS noonix-tv RUNTIME DESTINATION bin)
install(PROGRAMS $<TARGET_FILE:noonix-tv-cli> DESTINATION bin)
install(FILES dist/noonix-tv.svg dist/noonix-tv-dark.svg DESTINATION share/icons/hicolor/scalable/apps)
install(FILES fonts/Inter-OFL.txt DESTINATION share/doc/noonix-tv)
install(FILES LICENSE DESTINATION share/licenses/noonix-tv)
# kwin grants the wallpaper screencast to the desktop file whose Exec is the real binary
set(NOONIX_EXEC "${CMAKE_INSTALL_PREFIX}/bin/noonix-tv")
configure_file(dist/noonix-tv.desktop.in noonix-tv.desktop @ONLY)
install(FILES ${CMAKE_CURRENT_BINARY_DIR}/noonix-tv.desktop DESTINATION share/applications)
