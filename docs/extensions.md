# Extensions

A Noonix TV extension is one small JSON file, usually named `something.noonix`. It bundles a
setup so others can add it in one step: Stremio addon addresses, whether those sources answer with
torrents, and release patterns that sort or hide releases.

Noonix TV comes with no extensions and no addons, and it doesn't list, host or review any. Each user
adds the ones they choose, from a file or from an address, in setup or in Settings › Sources.

## Example

```json
{
  "noonix": 1,
  "id": "example.remux-first",
  "name": "Remux first",
  "version": "1.0.0",
  "description": "Lossless releases first, hardcoded subtitles hidden.",
  "author": "Example",
  "addons": [
    "https://addon.example.com/{torbox}/manifest.json",
    "https://other.example.org/manifest.json"
  ],
  "torrents": false,
  "patterns": {
    "preferred": ["REMUX", "/\\bITA\\b/"],
    "excluded": ["HC"]
  }
}
```

## Fields

| Field | Needed | What it is |
|---|---|---|
| `noonix` | yes | The format version. Always `1` for now. A newer number asks the user to update Noonix TV. |
| `id` | yes | Lowercase letters, digits, `.`, `_` and `-`, at most 80 characters. Adding a file with the same id again updates it in place. |
| `name` | yes | What the user sees, at most 80 characters. |
| `version` | no | Shown in the preview and in Settings. |
| `description` | no | One or two sentences for the preview. |
| `author` | no | Who made it. |
| `addons` | no | Up to 20 Stremio addon addresses (see below). |
| `torrents` | no | `true` if these addons answer with torrents. The user is then asked whether to allow torrents. |
| `patterns` | no | `preferred` and `excluded` release patterns, at most 50 in all (see below). |

## Addon addresses

- Each address points to a Stremio addon. The `/manifest.json` at the end is optional, and
  `stremio://` works in place of `https://`.
- Addresses must use `https`.
- An address may hold the user's key from a debrid service: `{torbox}`, `{realdebrid}` or
  `{alldebrid}`. Noonix TV fills it in when the addon is added, and asks the user for the key if it
  doesn't have one yet.
- Before anything is added, the preview names every host that gets a key. The key goes only to
  those addresses.
- If the user changes or removes the key later, the addons that use it follow. An address whose key
  is gone is taken out until the key is back.

## Release patterns

A pattern is a word or a few words, or a regular expression between slashes:

- `REMUX` matches the whole word in any case, so `Remux` and `remux` match but `REMUXED` doesn't.
  Spaces also match `.`, `_` and `-`, so `web dl` matches `WEB-DL`.
- `/\bITA\b/` is a regular expression that ignores case. In JSON the backslash is written twice.

Preferred patterns lift a release within its group, without overriding the user's quality level or
languages. Excluded patterns hide a release. The user's own patterns in Settings › Sources apply too.

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
