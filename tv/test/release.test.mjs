// the release-name parser against the cases the core passes too (core/fixtures/release-names.json)
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync, mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join, dirname } from "node:path"
import { fileURLToPath, pathToFileURL } from "node:url"
import { build } from "esbuild"

const here = dirname(fileURLToPath(import.meta.url))
const out = mkdtempSync(join(tmpdir(), "noonix-tv-test-"))
await build({ entryPoints: [join(here, "../src/data/release.ts")], bundle: true, format: "esm", platform: "node", outfile: join(out, "release.mjs"), logLevel: "silent" })
const release = await import(pathToFileURL(join(out, "release.mjs")).href)
rmSync(out, { recursive: true, force: true })
const cases = JSON.parse(readFileSync(join(here, "../../core/fixtures/release-names.json"), "utf8"))

test("release names", function () {
    for (const c of cases.releases) {
        const s = release.parseRelease(c.text)
        const got = { resolution: s.resolution, hdr: s.hdr, codec: s.codec, audio: s.audio, source: s.source }
        const want = { resolution: c.resolution, hdr: c.hdr, codec: c.codec, audio: c.audio, source: c.source }
        assert.deepEqual(got, want, c.text)
    }
})

test("sizes", function () {
    for (const c of cases.sizes) assert.equal(release.parseSize(c.text), c.bytes, c.text)
})

test("release patterns", function () {
    for (const c of cases.patterns) {
        const re = release.pattern(c.pattern)
        assert.equal(!!re && re.test(c.text), c.match, JSON.stringify(c.pattern) + " on " + JSON.stringify(c.text))
    }
})

test("pasted addon addresses", function () {
    for (const c of cases.addresses) assert.equal(release.address(c.pasted), c.address, JSON.stringify(c.pasted))
})
