# Noonix TV for LG and Samsung TVs

The web app that runs on LG webOS and Samsung Tizen TVs. It is its own client, written in TypeScript
without a framework, because the oldest supported TVs (webOS 4, Tizen 4, both from 2018) run
Chromium 53 and 56: no WebAssembly, so the Rust core can't run there. The parts of the core a TV
needs are ported to TypeScript in `src/data`.

Work in progress: home, movies, shows and the details page run; playback, search, settings,
profiles and Trakt are next.

## Build

```sh
cd tv
npm ci
npm run check            # type check
npm run build            # dist/app: the app folder
npm run package          # + dist/Noonix-TV-<version>-webos.ipk and -tizen-unsigned.wgt
```

`NOONIX_TMDB_API_KEY` (or `NOONIX_TMDB_READ_TOKEN`) and `NOONIX_TRAKT_CLIENT_ID` in the
environment become the built-in keys, as in the other builds. `node tools/build.mjs --dev` keeps
the script readable.

The bundle is ES5: esbuild joins the modules, TypeScript 5.9 lowers them (TypeScript 7 can't emit
ES5), esbuild minifies the result. The `.ipk` and `.wgt` are written by `tools/build.mjs` itself,
so no LG or Samsung SDK is needed to build them.

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
  browser: Escape or Backspace for Back, M for options.
