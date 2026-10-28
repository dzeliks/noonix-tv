#!/usr/bin/env python3
# official qt for windows (llvm-mingw build) from qt's online repository. since 6.11 every
# windows toolchain has its own folder there, which aqt 3.3 doesn't know yet
#   qt-win.py <version> <dest> [module...]     e.g. qt-win.py 6.12.0 /p/qt-win qtshadertools qtimageformats
import os
import subprocess
import sys
import urllib.request
import xml.etree.ElementTree as ET

BASE = "https://download.qt.io/online/qtsdkrepository/windows_x86/desktop"
# what the app needs from the base package (qtdoc is only docs)
SKIP = ("qtdoc-", "debug-symbols")


def main():
    version, dest, modules = sys.argv[1], sys.argv[2], sys.argv[3:]
    v = version.replace(".", "")
    repo = f"{BASE}/qt6_{v}/qt6_{v}_llvm_mingw"
    xml = urllib.request.urlopen(f"{repo}/Updates.xml", timeout=60).read()
    want = {f"qt.qt6.{v}.win64_llvm_mingw"} | {f"qt.qt6.{v}.addons.{m}.win64_llvm_mingw" for m in modules}
    os.makedirs(dest, exist_ok=True)
    found = set()
    for p in ET.fromstring(xml).iter("PackageUpdate"):
        name = p.findtext("Name")
        if name not in want:
            continue
        found.add(name)
        archives = [a.strip() for a in (p.findtext("DownloadableArchives") or "").split(",") if a.strip()]
        for a in archives:
            if a.startswith(SKIP) or any(s in a for s in SKIP):
                continue
            url = f"{repo}/{name}/{p.findtext('Version')}{a}"
            path = os.path.join(dest, ".dl", a)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            print("qt:", a, flush=True)
            urllib.request.urlretrieve(url, path)
            if a.endswith(".zip"):
                subprocess.run(["unzip", "-q", "-o", path, "-d", dest], check=True)
            else:
                subprocess.run(["7z", "x", "-y", "-bso0", "-bsp0", f"-o{dest}", path], check=True)
            os.remove(path)
    missing = want - found
    if missing:
        sys.exit(f"qt packages not found: {', '.join(sorted(missing))}")


if __name__ == "__main__":
    main()
