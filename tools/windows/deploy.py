#!/usr/bin/env python3
# fills an installed windows build with what it loads: the qml modules the app imports (host
# qmlimportscanner), the qt plugins it uses, and every dll the exes and plugins import, found
# in the prefix (qt, libmpv, sdl, the vulkan loader, the llvm-mingw runtime). windows' own dlls
# stay out. the exes lose their debug info (190 MB of it)
#   deploy.py <app dir> <qml source dir>     (with <prefix>/env.sh sourced)
import json
import os
import re
import shutil
import subprocess
import sys

PLUGINS = {
    "platforms": ["qwindows"],
    "imageformats": ["qjpeg", "qsvg", "qwebp", "qgif", "qico"],
    "iconengines": ["qsvgicon"],
    "tls": ["qschannelbackend", "qcertonlybackend"],
    "networkinformation": ["qnetworklistmanager"],
}


def main():
    app, qml_src = os.path.abspath(sys.argv[1]), sys.argv[2]
    prefix = os.environ["NOONIX_WIN_PREFIX"]
    qt_win, qt_host = os.environ["NOONIX_QT_WIN"], os.environ["NOONIX_QT_HOST"]
    search = [
        os.path.join(qt_win, "bin"),
        os.path.join(prefix, "mpv"),
        os.path.join(prefix, "sdl/x86_64-w64-mingw32/bin"),
        os.path.join(prefix, "vulkan"),
        os.path.join(prefix, "llvm-mingw/x86_64-w64-mingw32/bin"),
    ]

    # qml modules, each without the submodules inside it (those come on their own if imported)
    scan = subprocess.run(
        [os.path.join(qt_host, "libexec/qmlimportscanner"), "-rootPath", qml_src, "-importPath", os.path.join(qt_win, "qml")],
        check=True, capture_output=True, text=True,
    )
    qml_root = os.path.join(qt_win, "qml")
    modules = 0
    for imp in json.loads(scan.stdout):
        path = imp.get("path")
        if imp.get("type") != "module" or not path or not os.path.abspath(path).startswith(qml_root + os.sep):
            continue
        copy_module(path, os.path.join(app, "qml", os.path.relpath(path, qml_root)))
        modules += 1

    for kind, names in PLUGINS.items():
        os.makedirs(os.path.join(app, kind), exist_ok=True)
        for n in names:
            shutil.copy2(os.path.join(qt_win, "plugins", kind, n + ".dll"), os.path.join(app, kind))

    # without a working opengl driver (vms, remote desktop) qt falls back to mesa's
    shutil.copy2(os.path.join(qt_win, "opengl32sw.dll"), app)

    for exe in ("noonix-tv.exe", "noonix-tv-cli.exe"):
        subprocess.run(["llvm-strip", os.path.join(app, exe)], check=True)

    # every dll the exes, plugins and qml plugins import, transitively
    todo = [os.path.join(r, f) for r, _, fs in os.walk(app) for f in fs if f.lower().endswith((".exe", ".dll"))]
    seen, missing = set(), set()
    while todo:
        for dll in imports(todo.pop()):
            key = dll.lower()
            if key in seen:
                continue
            seen.add(key)
            src = next((os.path.join(d, dll) for d in search if os.path.isfile(os.path.join(d, dll))), None)
            if not src:
                missing.add(dll)
                continue
            dst = os.path.join(app, dll)
            if not os.path.exists(dst):
                shutil.copy2(src, dst)
                todo.append(dst)
    system = sorted(d for d in missing if not re.match(r"(?i)(api-ms-|ext-ms-)", d))
    print(f"deploy: {modules} qml modules, {len(seen) - len(missing)} dlls; from windows: {', '.join(system)}")


def copy_module(src, dst):
    for root, dirs, files in os.walk(src):
        # a folder with its own qmldir is another module
        dirs[:] = [d for d in dirs if not os.path.isfile(os.path.join(root, d, "qmldir"))]
        out = os.path.join(dst, os.path.relpath(root, src))
        os.makedirs(out, exist_ok=True)
        for f in files:
            if f.endswith((".qmltypes", ".debug", ".pdb")):   # tooling only
                continue
            shutil.copy2(os.path.join(root, f), out)


def imports(path):
    out = subprocess.run(["llvm-objdump", "-p", path], capture_output=True, text=True).stdout
    return re.findall(r"DLL Name: (\S+)", out)


if __name__ == "__main__":
    main()
