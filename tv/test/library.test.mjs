// the library's name reading and share addresses against the core's cases (library.rs, shares.rs)
import test from "node:test"
import assert from "node:assert/strict"
import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join, dirname } from "node:path"
import { fileURLToPath, pathToFileURL } from "node:url"
import { build } from "esbuild"

const here = dirname(fileURLToPath(import.meta.url))
const out = mkdtempSync(join(tmpdir(), "noonix-tv-test-"))
const define = { __SR__: "{}", __TMDB_KEY__: "\"\"", __TMDB_TOKEN__: "\"\"", __HIDE__: "\"\"", __VERSION__: "\"test\"" }
const load = async function (name) {
    await build({ entryPoints: [join(here, "../src/data/" + name + ".ts")], bundle: true, format: "esm", platform: "node", define, outfile: join(out, name + ".mjs"), logLevel: "silent" })
    return import(pathToFileURL(join(out, name + ".mjs")).href)
}
const library = await load("library")
const shares = await load("shares")
rmSync(out, { recursive: true, force: true })

const g = function (p) {
    const r = library.guess("/lib/" + p, "/lib")
    return { kind: r.kind, name: r.name, year: r.year, season: r.season, episode: r.episode }
}
const movie = function (name, year) { return { kind: "movie", name, year, season: null, episode: null } }

test("reads names", function () {
    assert.deepEqual(g("Sintel.2010.1080p.mkv"), movie("Sintel", 2010))
    assert.deepEqual(g("Big Buck Bunny (2008)/bbb_sunflower_1080p_60fps_normal.mp4"), movie("Big Buck Bunny", 2008))
    assert.equal(g("Tears of Steel.mkv").name, "Tears of Steel")
    assert.deepEqual(g("Shows/The Office/Season 2/The.Office.US.S02E03.720p.mkv"), { kind: "episode", name: "The Office US", year: null, season: 2, episode: 3 })
    assert.deepEqual(g("Some Show (2019)/Season 01/03 - Pilot.mkv"), { kind: "episode", name: "Some Show", year: 2019, season: 1, episode: 3 })
    assert.deepEqual(g("Some Show/S02/Episode 4.mkv"), { kind: "episode", name: "Some Show", year: null, season: 2, episode: 4 })
    assert.deepEqual(g("show/1x05.mkv"), { kind: "episode", name: "show", year: null, season: 1, episode: 5 })
    assert.deepEqual(g("2001 A Space Odyssey 1968.mkv"), movie("2001 A Space Odyssey", 1968))
})

test("share paths", function () {
    const s = shares.parse("smb", "nas.local/Media", "")
    assert.deepEqual([s.kind, s.host, s.port, s.base], ["smb", "nas.local", null, "Media"])
    assert.equal(shares.root(s), "smb://nas.local/Media")
    const w = shares.parse("smb", "\\\\192.168.1.5\\Movies", "me")
    assert.deepEqual([w.host, w.base, w.user], ["192.168.1.5", "Movies", "me"])
    const d = shares.parse("smb", "https://cloud.example.com/remote.php/dav/files/me", "")
    assert.deepEqual([d.kind, d.base], ["davs", "remote.php/dav/files/me"])
    const f = shares.parse("ftp", "me@10.0.0.2:2121", "")
    assert.deepEqual([f.host, f.port, f.user, shares.root(f)], ["10.0.0.2", 2121, "me", "ftp://10.0.0.2:2121"])
    assert.throws(function () { shares.parse("smb", "", "") })
    assert.ok(shares.isShare("smb://nas/x") && shares.isShare("davs://h/x") && !shares.isShare("/home/x") && !shares.isShare("http://x"))
    assert.equal(shares.label("smb://nas/Media/Movies"), "SMB  ·  nas/Media/Movies")
})
