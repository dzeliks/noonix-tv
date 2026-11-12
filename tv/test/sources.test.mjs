// the source list's pure parts: the viewers' memory, the torrent link, the ranking
import test from "node:test"
import assert from "node:assert/strict"
import { mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join, dirname } from "node:path"
import { fileURLToPath, pathToFileURL } from "node:url"
import { build } from "esbuild"

// the tv's storage, in memory
const kept = new Map()
globalThis.localStorage = {
    getItem: function (k) { return kept.has(k) ? kept.get(k) : null },
    setItem: function (k, v) { kept.set(k, String(v)) },
    removeItem: function (k) { kept.delete(k) },
    key: function (i) { return Array.from(kept.keys())[i] ?? null },
    get length() { return kept.size },
    clear: function () { kept.clear() },
}

const here = dirname(fileURLToPath(import.meta.url))
const out = mkdtempSync(join(tmpdir(), "noonix-tv-test-"))
const entry = join(out, "entry.ts")
writeFileSync(entry, `export * as memory from ${JSON.stringify(join(here, "../src/data/memory.ts"))}
export * as sources from ${JSON.stringify(join(here, "../src/data/sources.ts"))}
`)
await build({ entryPoints: [entry], bundle: true, format: "esm", platform: "node", outfile: join(out, "t.mjs"), logLevel: "silent" })
const { memory, sources } = await import(pathToFileURL(join(out, "t.mjs")).href)
rmSync(out, { recursive: true, force: true })

function stream(name, more) {
    return Object.assign({ title: name + "\n👤 12 💾 2 GB", filename: name, resolution: 1080, hdr: [], codec: "", audio: [], source: "WEB-DL",
        size: 2 * 1073741824, cached: null, torrent: false, seeders: null, warn: null }, more || {})
}

test("file keys and release groups", function () {
    assert.equal(memory.fileKey(stream("Show.S01E01.1080p.WEB-DL-GRP.mkv")), "show.s01e01.1080p.web-dl-grp.mkv")
    assert.equal(memory.fileKey({ title: "  Some Title \nsecond line", filename: "" }), "some title")
    assert.equal(memory.groupOf(stream("Show.S01E01.1080p.WEB-DL-GRP.mkv")), "grp")
    assert.equal(memory.groupOf(stream("Show.S01E01.2160p.x265-NTb[rartv].mkv")), "ntb")
    assert.equal(memory.groupOf(stream("Movie 2020 1080p")), null)
})

test("liked first, reported last, the rest as ranked", function () {
    const a = stream("A.S01E01-ONE.mkv"), b = stream("B.S01E01-TWO.mkv"), c = stream("C.S01E01-THREE.mkv"), d = stream("D.S01E02-TWO.mkv")
    assert.deepEqual(memory.order("show", 1, [a, b, c]), [a, b, c])
    memory.report(a)
    memory.like("show", 1, c)
    assert.deepEqual(memory.order("show", 1, [a, b, c]), [c, b, a])
    // the liked group lifts another episode of the same show, not another show
    memory.like("show", 1, b)
    assert.deepEqual(memory.order("show", 1, [c, a, d]).map(memory.fileKey), [c, d, a].map(memory.fileKey))
    assert.equal(memory.isBad(a), true)
    memory.like("show", 1, a)
    assert.equal(memory.isBad(a), false)
})

test("torrent links the way stremio builds them", function () {
    const h = "0123456789abcdef0123456789abcdef01234567"
    assert.equal(sources.torrentUrl("http://pc:11470", {}, h), "http://pc:11470/" + h + "/-1")
    assert.equal(sources.torrentUrl("http://pc:11470", { fileIdx: 3, sources: ["tracker:udp://t.example:1337", 5] }, h),
        "http://pc:11470/" + h + "/3?tr=" + encodeURIComponent("tracker:udp://t.example:1337"))
    assert.equal(sources.torrentUrl("http://pc:11470", { url: "magnet:?xt=urn:btih:" + h + "&tr=udp%3A%2F%2Fa.example%3A80", fileMustInclude: ["e01"] }, h),
        "http://pc:11470/" + h + "/-1?tr=" + encodeURIComponent("tracker:udp://a.example:80") + "&f=e01")
})

test("ranking: ready links first, then sharper, a cam never", function () {
    const cam = stream("Cam", { source: "CAM" })
    const sd = stream("Sd", { resolution: 720, cached: true })
    const hd = stream("Hd", { resolution: 1080, cached: true })
    const hdr = stream("Hdr", { resolution: 1080, cached: true, hdr: ["HDR10"] })
    const lonely = stream("Lonely", { resolution: 2160, torrent: true, seeders: 1, cached: undefined })
    const shared = stream("Shared", { resolution: 1080, torrent: true, seeders: 80, cached: undefined })
    const got = sources.rank([lonely, shared, cam, sd, hd, hdr, stream("Hd", { resolution: 1080, cached: true })]).map(function (s) { return s.title.split("\n")[0] })
    assert.deepEqual(got, ["Hdr", "Hd", "Sd", "Shared", "Lonely"])
})
