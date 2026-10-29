#!/usr/bin/env python3
"""puts qt's plugins + qml modules and every shared library the binaries need into an
AppDir, then points each elf at the bundled usr/lib with a relative runpath. no
LD_LIBRARY_PATH: it would leak into the host tools noonix-tv runs (kscreen-doctor & co).

    deploy.py <appdir> <qml source dir> <excludelist>
"""
import json
import os
import re
import shutil
import subprocess
import sys

# arch's qt, or an official build (NOONIX_QT_PREFIX, from deps.sh on the old base)
QT_PREFIX = os.environ.get('NOONIX_QT_PREFIX')
QT_PLUGINS = f'{QT_PREFIX}/plugins' if QT_PREFIX else '/usr/lib/qt6/plugins'
QT_QML = f'{QT_PREFIX}/qml' if QT_PREFIX else '/usr/lib/qt6/qml'
SCANNER = f'{QT_PREFIX}/libexec/qmlimportscanner' if QT_PREFIX else '/usr/lib/qt6/qmlimportscanner'
# libraries deps.sh built from source: their licenses + sources list sit in <deps>/share/licenses
DEPS_PREFIX = os.environ.get('NOONIX_DEPS_PREFIX')
# debian's lib dir for this machine: x86_64-linux-gnu, aarch64-linux-gnu
MULTIARCH = f'{os.uname().machine}-linux-gnu'
# whole plugin dirs, and qt's own plugins by name where kde drops its own next to them
PLUGIN_DIRS = ['wayland-shell-integration', 'wayland-graphics-integration-client',
               'wayland-decoration-client', 'tls', 'networkinformation']
PICKED = {
    'platforms': re.compile(r'libq(wayland.*|offscreen|minimal)\.so$'),
    'imageformats': re.compile(r'libq(svg|jpeg|webp|gif|ico)\.so$'),
    'iconengines': re.compile(r'libqsvgicon\.so$'),
}
# kde's screencast items: a kwin grant to a fixed exe path, never from an appimage
HOST_QML = ('org.kde.',)
# glibc and the gpu driver stack always come from the host. so does brotli: the host's freetype
# (excludelist) loads the host's libbrotlidec, which breaks next to an older bundled libbrotlicommon
ALWAYS_HOST = re.compile(r'^(ld-linux.*|libc|libm|libdl|libpthread|librt|libresolv|libutil|'
                         r'libGL|libGLX|libEGL|libGLdispatch|libOpenGL|libgbm|libdrm|libbrotli[a-z]*)\.so')


def is_elf(path):
    try:
        with open(path, 'rb') as f:
            return f.read(4) == b'\x7fELF'
    except OSError:
        return False


def copy_tree_files(src, dst):
    """one module dir, not its sub-modules (the scanner lists those itself)"""
    os.makedirs(dst, exist_ok=True)
    for name in os.listdir(src):
        s = os.path.join(src, name)
        if os.path.isfile(s):
            shutil.copy2(s, os.path.join(dst, name), follow_symlinks=True)


def deploy_qt(appdir, qml_src):
    usr = os.path.join(appdir, 'usr')
    plugins = os.path.join(usr, 'plugins')
    for d in PLUGIN_DIRS:
        src = os.path.join(QT_PLUGINS, d)
        if os.path.isdir(src):
            shutil.copytree(src, os.path.join(plugins, d), dirs_exist_ok=True)
    for d, pick in PICKED.items():
        os.makedirs(os.path.join(plugins, d), exist_ok=True)
        for name in os.listdir(os.path.join(QT_PLUGINS, d)):
            if pick.match(name):
                shutil.copy2(os.path.join(QT_PLUGINS, d, name), os.path.join(plugins, d, name))

    out = subprocess.run([SCANNER, '-rootPath', qml_src, '-importPath', QT_QML],
                         check=True, capture_output=True, text=True).stdout
    modules = [m for m in json.loads(out) if m.get('type') == 'module' and m.get('path', '').startswith(QT_QML)
               and not m['name'].startswith(HOST_QML)]
    for m in modules:
        rel = os.path.relpath(m['path'], QT_QML)
        copy_tree_files(m['path'], os.path.join(usr, 'qml', rel))
    print('qml modules:', ' '.join(sorted(m['name'] for m in modules)))
    shipped = {m['name'] for m in modules}
    skipped = sorted({m['name'] for m in json.loads(out) if m.get('type') == 'module' and m['name'] not in shipped})
    print('qml modules left to the host or built in:', ' '.join(skipped))

    with open(os.path.join(usr, 'bin', 'qt.conf'), 'w') as f:
        f.write('[Paths]\nPrefix = ..\nPlugins = plugins\nQmlImports = qml\n')


def needed(path, clean=False):
    """resolved dependency paths of one elf (ldd = the whole closure). clean = as on the
    user's pc: without the build's LD_LIBRARY_PATH, which would win over our runpath"""
    env = {k: v for k, v in os.environ.items() if not (clean and k == 'LD_LIBRARY_PATH')}
    out = subprocess.run(['ldd', path], capture_output=True, text=True, env=env).stdout
    deps = {}
    for line in out.splitlines():
        m = re.match(r'\s*(\S+) => (/\S+)', line)
        if m:
            deps[m.group(1)] = m.group(2)
        elif 'not found' in line:
            sys.exit(f'{path}: {line.strip()}')
    return deps


def owner(path):
    """(package, version, licenses, url, source) of the distro package a file came from"""
    if shutil.which('pacman'):
        r = subprocess.run(['pacman', '-Qqo', path], capture_output=True, text=True)
        if r.returncode:
            return None
        p = r.stdout.strip()
        info = subprocess.run(['pacman', '-Qi', p], capture_output=True, text=True).stdout
        field = lambda k: next((l.split(':', 1)[1].strip() for l in info.splitlines() if l.startswith(k)), '')
        return (p, field('Version'), field('Licenses'), field('URL'),
                f'https://gitlab.archlinux.org/archlinux/packaging/packages/{p}', f'/usr/share/licenses/{p}')
    r = subprocess.run(['dpkg', '-S', path], capture_output=True, text=True)
    if r.returncode:
        return None
    p = r.stdout.split(':', 1)[0].strip()
    ver, srcpkg, url = subprocess.run(['dpkg-query', '-W', '-f=${Version}\t${source:Package}\t${Homepage}', p],
                                      capture_output=True, text=True).stdout.split('\t')
    return (p, ver, 'see copyright', url, f'https://launchpad.net/ubuntu/+source/{srcpkg}/{ver}', f'/usr/share/doc/{p}')


def notices(appdir, files):
    """license texts of everything we took files from + a list with versions and where their
    source lives (gpl/lgpl: the source has to stay reachable for whoever gets the appimage)"""
    usr = os.path.join(appdir, 'usr')
    lic = os.path.join(usr, 'share', 'licenses')
    pkgs, built, qt = {}, False, False
    for f in files:
        name = os.path.basename(f)
        if DEPS_PREFIX and os.path.exists(os.path.join(DEPS_PREFIX, 'lib', name)):
            built = True
            continue
        if QT_PREFIX and (os.path.exists(os.path.join(QT_PREFIX, 'lib', name))
                          or os.path.relpath(f, usr).split(os.sep)[0] in ('plugins', 'qml')):
            qt = True
            continue
        rel = os.path.relpath(f, usr)
        for cand in (f'/usr/{rel}', f'/usr/lib/{name}', f'/usr/lib/{MULTIARCH}/{name}',
                     f'/lib/{MULTIARCH}/{name}', f'/usr/lib/qt6/{rel}'):
            if os.path.exists(cand) and (o := owner(cand)):
                pkgs[o[0]] = o
                break
    pkgs.pop('noonix-tv', None)
    lines = []
    for p, ver, lics, url, source, texts in sorted(pkgs.values()):
        lines.append(f'{p} {ver}  [{lics}]\n    {url}\n    source: {source}')
        if os.path.isdir(texts):
            dst = os.path.join(lic, p)
            os.makedirs(dst, exist_ok=True)
            for n in os.listdir(texts):
                s = os.path.join(texts, n)
                # debian's doc dirs hold changelogs too: only the license texts
                if os.path.isfile(s) and (not texts.startswith('/usr/share/doc') or n == 'copyright'):
                    shutil.copy2(s, os.path.join(dst, n))
    head = ['Libraries in this AppImage (license texts in usr/share/licenses).', '']
    if built:
        shutil.copytree(os.path.join(DEPS_PREFIX, 'share', 'licenses'), lic, dirs_exist_ok=True)
        head += ['Built unchanged from these upstream releases:',
                 open(os.path.join(DEPS_PREFIX, 'share', 'licenses', 'SOURCES.txt')).read()]
    if qt:
        for t in ('/usr/share/common-licenses/LGPL-3', '/usr/share/licenses/spdx/LGPL-3.0-only.txt'):
            if os.path.exists(t):
                os.makedirs(os.path.join(lic, 'qt'), exist_ok=True)
                shutil.copy2(t, os.path.join(lic, 'qt', 'LGPL-3.0-only.txt'))
                break
        head +=['Qt (official build, LGPL-3.0-only): https://www.qt.io/download-open-source', '']
    if pkgs:
        head += ['Unchanged from distribution packages:']
    doc = os.path.join(usr, 'share', 'doc', 'noonix-tv')
    os.makedirs(doc, exist_ok=True)
    with open(os.path.join(doc, 'THIRD-PARTY.txt'), 'w') as f:
        f.write('\n'.join(head) + '\n' + '\n'.join(lines) + '\n')
    print(f'notices for {len(pkgs)} packages' + (' + the built deps' if built else '') + (' + qt' if qt else ''))


def main():
    appdir, qml_src, excludelist = sys.argv[1:4]
    appdir = os.path.abspath(appdir)
    usr = os.path.join(appdir, 'usr')
    lib = os.path.join(usr, 'lib')
    os.makedirs(lib, exist_ok=True)
    excluded = set()
    for line in open(excludelist):
        line = line.split('#', 1)[0].strip()
        if line:
            excluded.add(line)

    deploy_qt(appdir, qml_src)

    # every elf we ship ourselves
    elves = []
    for top in ('bin', 'plugins', 'qml'):
        for dp, _, files in os.walk(os.path.join(usr, top)):
            elves += [os.path.join(dp, f) for f in files if is_elf(os.path.join(dp, f))]

    bundled = {}
    for e in elves:
        for soname, path in needed(e).items():
            # the loader shows up by its absolute path
            if '/' in soname or soname in excluded or ALWAYS_HOST.match(soname) or soname in bundled:
                continue
            dst = os.path.join(lib, soname)
            shutil.copy2(path, dst, follow_symlinks=True)
            os.chmod(dst, 0o755)
            bundled[soname] = path
    print(f'bundled {len(bundled)} libraries')

    def runpath(f, target):
        rel = os.path.relpath(target, os.path.dirname(f))
        subprocess.run(['patchelf', '--set-rpath', '$ORIGIN' if rel == '.' else f'$ORIGIN/{rel}', f], check=True)

    for e in elves:
        runpath(e, lib)
    for soname in bundled:
        runpath(os.path.join(lib, soname), lib)

    notices(appdir, [os.path.join(lib, so) for so in bundled] + elves)

    # our own files must find what we bundle in usr/lib (host libs we leave out, like
    # harfbuzz, still load their own deps from the host: that's fine)
    missing = []
    for f in elves + [os.path.join(lib, so) for so in bundled]:
        direct = subprocess.run(['patchelf', '--print-needed', f], check=True, capture_output=True, text=True).stdout.split()
        resolved = needed(f, clean=True)
        for soname in direct:
            path = os.path.normpath(resolved.get(soname, ''))
            if soname in bundled and not path.startswith(lib + os.sep):
                missing.append(f'{os.path.relpath(f, appdir)}: {soname} -> {path}')
    if missing:
        sys.exit('resolves outside the appdir:\n' + '\n'.join(missing))


if __name__ == '__main__':
    main()
