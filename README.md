<p align="center">
  <img src="dist/noonix-tv.svg" width="160" alt="Noonix TV">
</p>

<h1 align="center">Noonix TV</h1>

<p align="center">
  A cross-platform media player for the living room and out of it: browse and play your own movies and shows, and the
  sources you connect, with a remote, a controller, a mouse or a touch screen.
</p>

<p align="center">
  <a href="https://github.com/dzeliks/noonix-tv/actions/workflows/ci.yml"><img src="https://github.com/dzeliks/noonix-tv/actions/workflows/ci.yml/badge.svg" alt="ci"></a>
  <a href="https://github.com/dzeliks/noonix-tv/releases/latest"><img src="https://img.shields.io/badge/download-latest-F0559F" alt="download"></a>
</p>

<p align="center">
  <img src="docs/screenshots/home.jpg" alt="Home">
</p>

<table>
  <tr>
    <td><img src="docs/screenshots/player.jpg" alt="The player"></td>
    <td><img src="docs/screenshots/match.jpg" alt="Fixing a source or subtitles while watching"></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/library.jpg" alt="The videos on this computer"></td>
    <td><img src="docs/screenshots/details.jpg" alt="A title's page"></td>
  </tr>
</table>

## Features

- **Your own library first**: point Noonix TV at the folders your movies and shows are in, on
  this device or on a network share (SMB, WebDAV or FTP, from a NAS or another computer). It
  recognizes them by name, adds posters, seasons and episodes from TMDB, and plays them straight
  from where they are.
- **A home screen built for the couch**: your library, Up Next and Continue Watching (synced with
  Trakt if you like), popular and trending titles, and a full-screen preview of whatever is in
  focus.
- **Bring your own sources**: Noonix TV comes with none. Add Stremio addons or Noonix TV
  [extensions](docs/extensions.md) you choose, from an address or a file; each one shows exactly
  what it adds before you confirm.
- **The best source, picked for you**: your own files come first, then releases in your audio and
  subtitle languages. Releases above what your setup can play move to the bottom with a warning,
  mismatched episodes are ranked down, and unsupported HDR formats are filtered out. Your own
  preferred and hidden release patterns sort the rest. The full list is always one press away.
- **Quality that fits your setup**: a built-in benchmark measures your internet speed and your
  PC's playback performance, then recommends the best picture quality both can handle: Light,
  Full HD, 4K or Maximum. Low memory mode keeps phones and older PCs with little memory running
  smoothly, and turns itself on for small Android phones.
- **A setup for everyone**: a guided first run that works with just the remote and sensible
  defaults for beginners, with every folder, language and addon open to fine-tuning for advanced
  users.
- **A real player**: mpv with HDR support, refresh rate matching per video, intro and credits
  skipping, and a next-episode prompt at the end.
- **Fixes in one step**: report a source as out of sync, wrong subtitles or a picture problem and
  Noonix TV finds a better one, resuming at the same spot. The choice carries over to the next
  episodes.
- **Subtitles that just work**: embedded tracks first, then OpenSubtitles or a file of your own,
  with an option to treat Serbian, Croatian and Bosnian as one language. The video pauses while
  you look for them.
- **Any input**: remotes, PlayStation, Xbox and Nintendo controllers with matching button
  glyphs, mouse and keyboard, and touch on phones and tablets. Every button can be remapped.
- **Search the way you type**: a real text field for a keyboard (select, copy, paste), the
  on-screen keyboard for a remote or a controller, and results split into shows and movies.
- **For the whole household**: multiple profiles, each with its own Trakt account and
  history, in English and Serbian.

## Extensions

An extension is one small `.noonix` file that sets up Stremio addons, torrents and release
patterns in one step, to share a setup or move it to another device. The
[extension guide](docs/extensions.md) has the format, a worked example, how to make any addon rank
well, and how to write your own.

## Download

Get the latest build from [Releases](https://github.com/dzeliks/noonix-tv/releases/latest).

- **Linux**: `Noonix-TV-<version>-x86_64.AppImage` (`-aarch64` for ARM), Ubuntu 22.04, Debian 12, Fedora 36
  or newer. `chmod +x` it and run it.
- **Windows** 10 and 11: `Noonix-TV-<version>-windows-x64-setup.exe`, installs per user without admin rights.
- **macOS** 26 or newer: `noonix-tv-<version>-macos-arm64.zip` (Apple silicon) or `-macos-x86_64.zip` (Intel).
  Not notarised yet: on the first launch click Done, then System Settings › Privacy & Security › Open Anyway.
- **Android** 9 or newer, preview: `Noonix-TV-<version>-android-arm64-preview.apk` for TVs, tablets and phones;
  `-armv7-` for 32-bit TV boxes, `-x86_64-` for Chromebooks.
- **iPhone, iPad and Apple TV** 26 or newer, preview: `-ios.ipa` and `-tvos.ipa`, unsigned: install them with a
  sideloading tool such as AltStore or Sideloadly.
- **LG and Samsung TVs**, preview: `-webos-preview.ipk` (webOS 4.0 or newer) and `-tizen-unsigned-preview.wgt`
  (Tizen 4.0 or newer), installed through the TV's Developer Mode: [tv/README.md](tv/README.md#install).

Linux and Windows update themselves from Settings › About and only install updates signed by the project:
`minisign -Vm SHA256SUMS -P RWTxrm/6vwTDc8vqK2CrSQ1YXbYOr8hE2Y6LBYJNkqZjWg0X5eC2l+59` checks a download by hand.

## Build from source

Linux: Qt 6.8+, libmpv, SDL3, wayland-protocols, CMake, Ninja and Rust:

```sh
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$HOME/.local"
cmake --build build && cmake --install build
```

Windows is cross-built on Linux with llvm-mingw in Docker:

```sh
docker build -t noonix-wincross tools/windows
docker run --rm -v "$PWD:/src:ro" -v "$PWD/build-win:/build" noonix-wincross \
    bash -c '/src/tools/windows/deps.sh /build/prefix && /src/tools/windows/build.sh /build/prefix /build/cmake /build/out'
```

macOS: `mac/build.sh` on a Mac with the command line tools and Rust. iPhone and iPad: `mac/ios.sh`
on a Mac with Xcode (`mac/ios.sh ipa` for an unsigned `.ipa`, `mac/ios.sh tv-ipa` for Apple TV, the
header lists the rest).

Android: the SDK and NDK, JDK 17, Rust's `aarch64-linux-android` target and Qt for Android with its
host Qt (`tools/android/qt-fetch.py` fetches both), then `tools/android/build.sh` (its header lists
the variables).

## Your responsibility

Noonix TV is only a player. It comes with no videos and no sources, and it doesn't host, index or
link to any. It plays the files on your computer and whatever addons or extensions you add
yourself; the people who run those answer for what they offer. Only watch, stream or download
videos you have the right to, and follow the law where you live. The app asks you to agree to the
[terms of use](TERMS.md) on its first run.

## License

Free software under the [GNU GPL v3.0 or later](LICENSE). Builds link GPL builds of mpv and
FFmpeg. Every bundled library is listed with its license in the app's `THIRD-PARTY.txt`.

The screenshots show the Blender open movies Sintel, Tears of Steel, Elephants Dream, Big Buck
Bunny, Caminandes, Cosmos Laundromat, Sprite Fright, Charge and Wing It!, © Blender Foundation |
[blender.org](https://www.blender.org), under [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/)
or [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).

<img src="qml/assets/credits/tmdb.svg" height="18" alt="TMDB">

This product uses TMDB and the TMDB APIs but is not endorsed, certified, or otherwise approved by
TMDB. Watch history comes from [Trakt](https://trakt.tv), extra subtitles from
[OpenSubtitles.com](https://www.opensubtitles.com) and the OpenSubtitles addon run by Stremio, and
skip times from IntroDB. Addons use Stremio's addon format. Noonix TV isn't affiliated with any of
them or with Stremio. LG, webOS, Samsung, Tizen and the other platform names are trademarks of their
owners; Noonix TV isn't made or endorsed by them. Other names shown in the app, such as streaming
services, belong to their owners and only describe where a title is available.

Made with ❤️ by [aleksa.sh](https://aleksa.sh).
