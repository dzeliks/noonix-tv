#!/usr/bin/env python3
"""THIRD-PARTY.txt for the windows and mac builds (the appimage's comes from appimage/deploy.py,
which takes only the rust crates from here): what ships inside, unchanged, with its license and
where its source lives. versions come from the pins, crates from cargo metadata
  tools/third-party.py windows|mac|crates <rust target> > THIRD-PARTY.txt"""
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def pins(path):
    out = {}
    for line in open(os.path.join(ROOT, path)):
        m = re.match(r'^([A-Z_0-9]+)=(\S+)', line)
        if m:
            out[m[1]] = m[2]
    return out


def crates(target):
    """the rust crates linked into the core for this target (no build or dev dependencies)"""
    meta = json.loads(subprocess.check_output(
        ['cargo', 'metadata', '--format-version', '1', '--locked', '--filter-platform', target,
         '--manifest-path', os.path.join(ROOT, 'core', 'Cargo.toml')]))
    pkgs = {p['id']: p for p in meta['packages']}
    nodes = {n['id']: n for n in meta['resolve']['nodes']}
    root = meta['resolve']['root']
    seen, todo = set(), [root]
    while todo:
        n = nodes[todo.pop()]
        for d in n['deps']:
            if any(k['kind'] is None for k in d['dep_kinds']) and d['pkg'] not in seen:
                seen.add(d['pkg'])
                todo.append(d['pkg'])
    lines = ['Rust crates in the core (each under its own license, source on crates.io):']
    for p in sorted((pkgs[i] for i in seen), key=lambda p: (p['name'], p['version'])):
        lines.append(f'- {p["name"]} {p["version"]}  [{p.get("license") or "see crate"}]  '
                     f'{p.get("repository") or "https://crates.io/crates/" + p["name"]}')
    return lines + ['']


def windows():
    d = pins('tools/windows/deps.sh')
    mpv = d['MPV_DEV'].split('/')[-1].removesuffix('.7z')
    loader = re.search(r'vulkan-loader-([\d.]+)', d['VULKAN_LOADER'])[1]
    return [
        'Noonix TV for Windows: GPL-3.0-or-later (LICENSE). Bundled, unchanged:',
        f'- Qt {d["QT_VERSION"]}  [LGPL-3.0-only]  official build, source: https://download.qt.io/official_releases/qt/',
        f'- libmpv ({mpv})  [GPL-2.0-or-later as built]  https://github.com/shinchiro/mpv-winbuild-cmake',
        '    mpv with FFmpeg, libplacebo, libass, dav1d and their own dependencies linked in;',
        '    sources: https://github.com/mpv-player/mpv and the build recipe above',
        f'- SDL {d["SDL_VERSION"]}  [Zlib]  https://github.com/libsdl-org/SDL',
        f'- Vulkan loader {loader}  [Apache-2.0]  https://github.com/KhronosGroup/Vulkan-Loader',
        f'- llvm-mingw {d["LLVM_MINGW"]} runtime (libc++, libunwind, mingw-w64)  [Apache-2.0 WITH LLVM-exception, ZPL-2.1]',
        '    https://github.com/mstorsjo/llvm-mingw',
        '',
    ]


def mac():
    pkg = open(os.path.join(ROOT, 'mac', 'Package.swift')).read()
    mpvkit = re.search(r'MPVKit\.git", exact: "([^"]+)"', pkg)[1]
    return [
        'Noonix TV for macOS: GPL-3.0-or-later (LICENSE). Bundled, unchanged:',
        f'- MPVKit {mpvkit}  [LGPL-3.0 build]  https://github.com/mpvkit/MPVKit',
        '    mpv, FFmpeg, libplacebo, libass, dav1d, MoltenVK (Apache-2.0) and their own dependencies;',
        '    sources: https://github.com/mpv-player/mpv, https://ffmpeg.org and the recipe above',
        '',
    ]


def main():
    kind, target = sys.argv[1], sys.argv[2]
    if kind == 'crates':
        out = crates(target)
    else:
        out = (windows() if kind == 'windows' else mac()) + crates(target)
    sys.stdout.write('\n'.join(out) + '\n')


main()
