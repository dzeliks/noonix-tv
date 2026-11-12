# Extensions

A Noonix TV extension is one small JSON file, usually named `something.noonix`. It bundles a
setup so others can add it in one step: Stremio addon addresses, whether those sources answer with
torrents, and release patterns that sort or hide releases.

Noonix TV comes with no extensions and no video addons, and it doesn't list, host or review any
(the one thing built in is an optional subtitles lookup). Each user adds the ones they choose, from a file or from an address, in setup or in Settings › Sources.

- [Quick start](#quick-start)
- [Example: an open movies club](#example-an-open-movies-club)
- [Fields](#fields)
- [Addon addresses](#addon-addresses)
- [Release patterns](#release-patterns)
- [Make any addon work well](#make-any-addon-work-well)
- [Your own addon](#your-own-addon)
- [Adding, updating, removing](#adding-updating-removing)

## Quick start

1. Write the file. Only `noonix`, `id` and `name` are needed:

   ```json
   {
     "noonix": 1,
     "id": "me.my-setup",
     "name": "My setup",
     "addons": ["https://addon.example.com/manifest.json"]
   }
   ```

2. Save it as `my-setup.noonix` somewhere Noonix TV can reach, like Downloads.
3. In Noonix TV: Settings › Sources › Open an extension file (or the same line in setup), pick
   the file, check what it adds, then Add.

To share it as a link instead, put the JSON on any https address and use Add an addon or extension.

## Example: an open movies club

A film club streams the open movies its members made, and shares a few of them as torrents too. Its
extension adds both of its addons, says that one of them answers with torrents, and prefers its
lossless copies:

```json
{
  "noonix": 1,
  "id": "org.example.open-movies",
  "name": "Open Movies Club",
  "version": "1.2.0",
  "description": "The club's own open movies, streamed or shared as torrents. Lossless copies first.",
  "author": "Example Film Club",
  "addons": [
    "https://stream.open-movies.example.org/manifest.json",
    "https://torrents.open-movies.example.org/manifest.json"
  ],
  "torrents": true,
  "patterns": {
    "preferred": ["REMUX", "/\\bdirector'?s cut\\b/"],
    "excluded": ["sample"]
  }
}
```

What the user sees when adding it:

- a preview naming both addons, the two patterns and that its sources include torrents;
- since `torrents` is `true`, a question whether to allow torrents (with a What's this), unless they
  already did;
- after Add, both addons in Settings › Sources under the extension, which turns them on and off,
  updates or removes them together.

If the club's streaming addon needed a TorBox account, its address would hold the key:
`https://stream.open-movies.example.org/{torbox}/manifest.json`. Noonix TV then asks for the user's
TorBox key (explaining where to get one), fills it in, and names the host that receives it in the
preview.

## Fields

| Field | Needed | What it is |
|---|---|---|
| `noonix` | yes | The format version. Always `1` for now. A newer number asks the user to update Noonix TV. |
| `id` | yes | Lowercase letters, digits, `.`, `_` and `-`, at most 80 characters. Adding a file with the same id again updates it in place. |
| `name` | yes | What the user sees, at most 80 characters. |
| `version` | no | Shown in the preview and in Settings. |
| `description` | no | One or two sentences for the preview. |
| `author` | no | Who made it. |
| `addons` | no | Up to 20 Stremio addon addresses, or addresses with their settings (see below). |
| `torrents` | no | `true` if these addons answer with torrents. The user is then asked whether to allow torrents. |
| `patterns` | no | `preferred` and `excluded` release patterns, at most 50 in all (see below). |
| `keys` | no | Your own debrid keys for these addresses, like `{"torbox": "…"}`, to set up your own devices in one step. Only for files you keep to yourself (see below). |

## Addon addresses

- Each address points to a Stremio addon. The `/manifest.json` at the end is optional, and
  `stremio://` works in place of `https://`.
- Addresses must use `https`. The one exception is an addon on the same computer
  (`http://127.0.0.1:<port>` or `http://localhost:<port>`).
- An address may hold the user's key from a debrid service: `{torbox}`, `{realdebrid}` or
  `{alldebrid}`. Noonix TV fills it in when the addon is added, and asks the user for the key if it
  doesn't have one yet.
- Before anything is added, the preview names every host that gets a key. The key goes only to
  those addresses.
- An extension may bring the key itself in `keys`. Noonix TV uses it only when it has no key for
  that service yet, checks it with the service first, and asks for one if it's refused. An empty one
  (`"torbox": ""`) is a slot to fill: the user is asked for their key, like with no `keys` at all. The key
  isn't kept in the extension. Anyone with such a file can use the key, so never share it.
- If the user changes or removes the key later, the addons that use it follow. An address whose key
  is gone is taken out until the key is back.

### Addons that keep their settings in the address

Many configurable addons put their settings in the address as base64-encoded JSON. Write those
settings as JSON instead, and put `{config}` where the encoded part goes:

```json
"addons": [
  {
    "url": "https://addon.example.com/{config}/manifest.json",
    "config": { "service": "torbox", "apiKey": "{torbox}", "maxResults": 10 }
  }
]
```

Noonix TV fills in the keys, encodes the settings as standard base64 and puts them in the address.
The encoding never contains `/` or `+`, so it's always safe in the path. Key placeholders work
inside the settings like anywhere else, so the same file works with or without a key.

## Release patterns

A pattern is a word or a few words, or a regular expression between slashes:

- `REMUX` matches the whole word in any case, so `Remux` and `remux` match but `REMUXED` doesn't.
  Spaces also match `.`, `_` and `-`, so `web dl` matches `WEB-DL`.
- `/\bITA\b/` is a regular expression that ignores case. In JSON the backslash is written twice.

Preferred patterns lift a release within its group, without overriding the user's quality level or
languages. Excluded patterns hide a release. The user's own patterns in Settings › Sources apply too.

## Make any addon work well

Noonix TV asks an addon for streams with Stremio's addon protocol: `/stream/movie/<imdb id>.json` for a movie
and `/stream/series/<imdb id>:<season>:<episode>.json` for an episode. Any addon that answers those
works. What it reads from each stream decides how well it's ranked:

| From the stream | Used for |
|---|---|
| `url`, or `infoHash` (+ `fileIdx`) | What plays. Streams with neither (external links) are skipped. |
| `behaviorHints.filename` | The release name: resolution, source, codec, HDR, audio, languages, group. The best single hint. |
| `behaviorHints.videoSize` | Size in bytes. Too big for the user's limit, or too small for its resolution, is hidden. |
| `name`, `title` / `description` | Read like the release name when there's no file name. |
| `👤 120` or `Seeders: 120` in the text | Seeders, for torrents. Few seeders sink with a warning. |
| `⚡` / `⏳` in the text | Ready to play right away / needs a download first. |
| `behaviorHints.bingeGroup` | Keeps the next episode on the same kind of release. |
| `behaviorHints.proxyHeaders.request` | Headers sent with the request. |

An addon can also say exactly what a stream is, so nothing is guessed. Put this line anywhere in the
stream's `description`, with the fields it knows:

```
noonix1|r=2160p|q=BluRay REMUX|e=HEVC|v=DV,HDR10|a=TrueHD Atmos|c=7.1|s=58123456789|l=en,it|t=en|p=42|n=Example.Film.2024.2160p.BluRay.REMUX-GROUP.mkv
```

`r` resolution, `q` source, `e` video codec, `v` HDR formats, `a` audio, `c` channels, `s` size in
bytes, `g` group, `k` ready to play (`1` or `0`), `l` audio languages, `t` subtitle languages, `p`
seeders, and `n` the file name (always last).

## Your own addon

The smallest addon is two kinds of JSON file on a web server. This one serves a home video
collection from the same computer; any language or a folder of static files works.

`manifest.json`:

```json
{
  "id": "me.home-videos",
  "version": "1.0.0",
  "name": "Home Videos",
  "resources": ["stream"],
  "types": ["movie", "series"],
  "idPrefixes": ["tt"],
  "catalogs": []
}
```

`stream/movie/tt1727587.json`:

```json
{
  "streams": [
    {
      "name": "Home",
      "url": "http://127.0.0.1:8080/files/Sintel.2010.1080p.mkv",
      "behaviorHints": { "filename": "Sintel.2010.1080p.mkv", "videoSize": 1234567890 }
    }
  ]
}
```

Serve the folder with `python3 -m http.server 8080` and add `http://127.0.0.1:8080/manifest.json`.
For other devices, put it behind https. For files on the same computer, the built-in library (Your
videos) is simpler: it needs no addon at all.

## Adding, updating, removing

- **From a file**: Open an extension file, in setup or Settings › Sources. Files are at most 256 KB.
- **From an address**: Add an addon or extension, with an https link to the JSON. Noonix TV remembers
  the address, so Update in the extension's settings fetches it again and shows the preview before
  applying it.
- **Removing** an extension removes every addon it added and its patterns. The user's keys stay.
- Turning an extension off keeps it but stops its addons and patterns.

A plain Stremio addon address goes through the same preview, without the extra settings.

## For authors

- Keep examples and defaults neutral, and only point to sources you have the right to share.
- Noonix TV checks the format and the addresses, never the content. Whoever runs an addon answers for
  what it offers.
