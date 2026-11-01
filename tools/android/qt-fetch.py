#!/usr/bin/env python3
# qt for android (one abi) and the host qt its tools come from, straight from qt's online repository
#   qt-fetch.py android <version> <abi> <dest> <host dest> [module...]
#       e.g. qt-fetch.py android 6.12.0 arm64_v8a /p/qt-android (or armv7) /p/qt-host qtimageformats qtshadertools
#   qt-fetch.py host <version> <dest> [module...]            this machine's host qt (mac: universal, linux: x64)
import os
import re
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
            # the linux host's icu comes flat: its libraries belong in lib/ (the tools' rpath)
            to = os.path.join(dest, "lib") if a.startswith("icu-") else dest
            os.makedirs(to, exist_ok=True)
            # bsdtar (macos, libarchive) reads 7z; elsewhere 7z (7-zip 25+ wants -snld20 for qt's
            # links to links, the older p7zip doesn't know it: exit 7 = a bad switch)
            if sys.platform == "darwin":
                subprocess.run(["tar", "-xf", path, "-C", to], check=True)
            else:
                r = subprocess.run(["7z", "x", "-y", "-bso0", "-snld20", f"-o{to}", path])
                if r.returncode == 7:
                    subprocess.run(["7z", "x", "-y", "-bso0", f"-o{to}", path], check=True)
                else:
                    r.check_returncode()
            os.remove(path)
    missing = want - found
    if missing:
        sys.exit(f"qt packages not found: {', '.join(sorted(missing))}")


def main():
    kind, version = sys.argv[1], sys.argv[2]
    v = version.replace(".", "")
    if kind == "android":
        abi, dest, host, modules = sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6:]
        repo = f"{BASE}/all_os/android/qt6_{v}/qt6_{v}_{abi}"
        suffix = f"android_{abi}"
    else:
        dest, modules = sys.argv[3], sys.argv[4:]
        plat, suffix = ("mac_x64", "clang_64") if sys.platform == "darwin" else ("linux_x64", "linux_gcc_64")
        repo = f"{BASE}/{plat}/desktop/qt6_{v}/qt6_{v}"
    want = {f"qt.qt6.{v}.{suffix}"} | {f"qt.qt6.{v}.addons.{m}.{suffix}" for m in modules}
    fetch(repo, want, dest)
    if kind == "android":
        link_host(dest, host)


# the android qt's tools are the host qt's: target_qt.conf points there (relative, so the pair
# can move together)
def link_host(dest, host):
    conf = os.path.join(dest, "bin", "target_qt.conf")
    text = open(conf).read()
    keys = {
        "HostPrefix": os.path.relpath(host, os.path.join(dest, "bin")),
        "HostData": os.path.relpath(dest, host),
        "HostSpec": "macx-clang" if sys.platform == "darwin" else "linux-g++",
        # the armv7 archives say bin, windows' place for moc
        "HostLibraryExecutables": "libexec",
    }
    for k, v in keys.items():
        text = re.sub(rf"^{k}=.*$", f"{k}={v}", text, flags=re.M) if re.search(rf"^{k}=", text, re.M) else text + f"{k}={v}\n"
    open(conf, "w").write(text)
    # the armv7 archives are made on windows: their scripts come without the x bit
    for name in os.listdir(os.path.join(dest, "bin")):
        path = os.path.join(dest, "bin", name)
        if os.path.isfile(path) and not name.endswith((".bat", ".so")):
            os.chmod(path, 0o755)
    # its qmake and qtpaths are scripts calling the host's tools by the path qt was built at
    rel = os.path.relpath(os.path.join(host, "bin"), os.path.join(dest, "bin"))
    for name in ("qmake", "qmake6", "qtpaths", "qtpaths6"):
        path = os.path.join(dest, "bin", name)
        if os.path.isfile(path) and not os.path.islink(path):
            text = re.sub(r"^\S*/(qmake6|qtpaths6) -qtconf", rf'"$script_dir_path/{rel}/\1" -qtconf', open(path).read(), flags=re.M)
            open(path, "w").write(text)


if __name__ == "__main__":
    main()
