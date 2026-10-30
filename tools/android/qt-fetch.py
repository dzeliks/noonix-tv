#!/usr/bin/env python3
# qt for android (one abi) and the host qt its tools come from, straight from qt's online repository
#   qt-fetch.py android <version> <abi> <dest> [module...]   e.g. qt-fetch.py android 6.12.0 arm64_v8a /p/qt-android qtshadertools
#   qt-fetch.py host <version> <dest> [module...]            macos host (universal clang_64)
import os
import subprocess
import sys
import urllib.request
import xml.etree.ElementTree as ET

BASE = "https://download.qt.io/online/qtsdkrepository"
# docs aren't needed to build
SKIP = ("qtdoc-",)


def fetch(repo, want, dest):
    xml = urllib.request.urlopen(f"{repo}/Updates.xml", timeout=60).read()
    os.makedirs(os.path.join(dest, ".dl"), exist_ok=True)
    found = set()
    for p in ET.fromstring(xml).iter("PackageUpdate"):
        name = p.findtext("Name")
        if name not in want:
            continue
        found.add(name)
        for a in (x.strip() for x in (p.findtext("DownloadableArchives") or "").split(",")):
            if not a or a.startswith(SKIP):
                continue
            path = os.path.join(dest, ".dl", a)
            print("qt:", a, flush=True)
            urllib.request.urlretrieve(f"{repo}/{name}/{p.findtext('Version')}{a}", path)
            # bsdtar (macos, libarchive) reads 7z; elsewhere 7z
            cmd = ["tar", "-xf", path, "-C", dest] if sys.platform == "darwin" else ["7z", "x", "-y", "-bso0", f"-o{dest}", path]
            subprocess.run(cmd, check=True)
            os.remove(path)
    missing = want - found
    if missing:
        sys.exit(f"qt packages not found: {', '.join(sorted(missing))}")


def main():
    kind, version = sys.argv[1], sys.argv[2]
    v = version.replace(".", "")
    if kind == "android":
        abi, dest, modules = sys.argv[3], sys.argv[4], sys.argv[5:]
        repo = f"{BASE}/all_os/android/qt6_{v}/qt6_{v}_{abi}"
        suffix = f"android_{abi}"
    else:
        dest, modules = sys.argv[3], sys.argv[4:]
        repo = f"{BASE}/mac_x64/desktop/qt6_{v}/qt6_{v}"
        suffix = "clang_64"
    want = {f"qt.qt6.{v}.{suffix}"} | {f"qt.qt6.{v}.addons.{m}.{suffix}" for m in modules}
    fetch(repo, want, dest)


if __name__ == "__main__":
    main()
