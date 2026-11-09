# Noonix TV for LG and Samsung TVs

The web app that runs on LG webOS and Samsung Tizen TVs. It is its own client, written in TypeScript
without a framework, because the oldest supported TVs (webOS 4, Tizen 4, both from 2018) run
Chromium 53 and 56: no WebAssembly, so the Rust core can't run there. The parts of the core a TV
needs are ported to TypeScript in `src/data`.

What it does:

- Home, Movies, Shows and Library pages, details with seasons and episodes, search with an on-screen
  keyboard, a first-run setup (language, terms, an addon, Trakt) and profiles.
- Sources from Stremio addons (http links: a debrid addon plays best), ranked for the TV: what it
  can't play well (above the picture quality, AV1 on older TVs, Dolby Vision only, DTS on
  Samsung) goes last and is marked.
- The player: the TV's own `<video>`, or Samsung AVPlay on Tizen (MKV, 4K HDR). Resume, Continue
  Watching, Up Next, Skip Intro (IntroDB), audio and subtitle tracks, subtitles found online
  (OpenSubtitles and subtitle addons), a source that won't start hands over to the next one.
- Trakt: sign-in by code, scrobbles, paused playbacks from other devices, the watchlist.

Not yet: picture quality from a speed check, webOS 4K/HDR playback hints, debrid services without
an addon.

## Build

```sh
cd tv
npm ci
npm run check            # type check
npm run build            # dist/app: the app folder
npm run package          # + dist/Noonix-TV-<version>-webos.ipk and -tizen-unsigned.wgt
```

`NOONIX_TMDB_API_KEY` (or `NOONIX_TMDB_READ_TOKEN`), `NOONIX_TRAKT_CLIENT_ID` and
`NOONIX_TRAKT_CLIENT_SECRET` in the environment become the built-in keys, as in the other builds. `node tools/build.mjs --dev` keeps
the script readable.

The bundle is ES5: esbuild joins the modules, TypeScript 5.9 lowers them (TypeScript 7 can't emit
ES5), esbuild minifies the result. The `.ipk` and `.wgt` are written by `tools/build.mjs` itself,
so no LG or Samsung SDK is needed to build them.

Releases get both packages from the `tv` job in `.github/workflows/release.yml`.

## Install

**LG (webOS 4.0 or newer):** turn on Developer Mode on the TV (the Developer Mode app from the LG
Content Store, signed in with an LG developer account), then install the `.ipk` with the webOS CLI
(`ares-setup-device`, `ares-install`) or a tool such as webOS Dev Manager.

**Samsung (Tizen 4.0 or newer):** a Tizen app has to be signed for the TV it goes on. Sign
`dist/app` with your own Samsung certificate in Tizen Studio or the `tizen` CLI (`tizen package -t
wgt -s <profile>`), with the TV in Developer Mode, then `tizen install`.

## Develop

- `node tools/cdp.mjs <port> shot|key|eval|reload` drives a page over the DevTools protocol: the
  webOS TV simulators (start them with `--remote-debugging-port`) and old Chromium builds.
- The Samsung TV web simulator (Tizen Studio, `tools/sec-tv-simulator`) takes its arguments as
  `--key=value`: `nwjs --file=<dist/app/index.html> --platform=tizentv --resolution=1920x1080
  --remote-debugging-port=<port> --disableInspector`. It runs a copy it makes at launch, so start
  it again after a build. Focus the app's frame (`document.getElementById("document")`) before
  sending keys.
- Keys: arrows, OK (held: options), Back (held: leave), the media and colour keys. In a desktop
  browser: Escape or Backspace for Back, M for options. In the player, Down with the overlay up
  opens audio and subtitles; the options key opens the sources.
- `NOONIX_HIDE=<tmdb ids>` at build time keeps titles out of test runs and screenshots.
