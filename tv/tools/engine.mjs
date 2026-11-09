// bundles the torrent engine (tv/engine) for the tvs' node: one es5 commonjs file
import { build, transform } from "esbuild"
import ts from "typescript"
import fs from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"

const tv = path.dirname(path.dirname(fileURLToPath(import.meta.url)))

// torrent-stream keeps a piece it has for good; the engine's memory store lets go of old ones, so
// it learns to forget one (fetched again when a reader comes back to it). and a critical piece is
// critical only until it's in (it never let go: every piece got asked from every peer)
const forget = {
    name: "torrent-stream-forget",
    setup(b) {
        b.onLoad({ filter: /torrent-stream[\\/]index\.js$/ }, (args) => {
            const src = fs.readFileSync(args.path, "utf8")
            const anchor = "    var reservations = torrent.pieces.map(function () {\n      return []\n    })\n"
            if (!src.includes(anchor)) throw new Error("torrent-stream changed: the forget patch no longer fits")
            const patch = anchor + `
    engine.forget = function (i) {
      if (!engine.bitfield.get(i)) return
      engine.bitfield.set(i, false)
      pieces[i] = piece(i === torrent.pieces.length - 1 ? pieceRemainder : pieceLength)
      reservations[i] = []
      for (var k = 0; k < engine.selection.length; k++) {
        var s = engine.selection[k]
        if (i >= s.from && i < s.from + s.offset) s.offset = i - s.from
      }
      refresh()
    }
`
            // a piece stays critical (asked from every peer at once) only until it's in
            const done = "      pieces[index] = null\n      reservations[index] = null\n"
            if (!src.includes(done)) throw new Error("torrent-stream changed: the critical patch no longer fits")
            // download only: it never tells peers what it has (it uploads nothing, and a peer that looks
            // complete gets dropped by the seeders, so a piece let go of could never come back)
            // and it keeps nothing on disk: the file list it got from peers stays in memory (torrent-stream
            // saved it as <tmp>/<name>/<hash>.torrent for good, one more file each torrent)
            const save = "    mkdirp(path.dirname(torrentPath), function (err) {\n      if (err) return engine.emit('error', err)\n      fs.writeFile(torrentPath, buf, function (err) {\n        if (err) engine.emit('error', err)\n      })\n    })\n"
            if (!src.includes(save)) throw new Error("torrent-stream changed: the no-disk patch no longer fits")
            const have = "      for (var i = 0; i < wires.length; i++) wires[i].have(index)\n"
            const bits = "    if (engine.bitfield) wire.bitfield(engine.bitfield)\n"
            if (!src.includes(have) || !src.includes(bits)) throw new Error("torrent-stream changed: the download-only patch no longer fits")
            return {
                contents: src.replace(anchor, patch).replace(done, done + "      critical[index] = false\n").replace(have, "").replace(bits, "").replace(save, ""),
                loader: "js",
            }
        })
    },
}

// a choked peer still sends what was asked just before (thousands of chokes a minute without
// uploads): giving those up at once fetched every block twice. they're given up after 2 s instead
const choke = {
    name: "peer-wire-choke",
    setup(b) {
        b.onLoad({ filter: /peer-wire-protocol[\\/]index\.js$/ }, (args) => {
            const src = fs.readFileSync(args.path, "utf8")
            const old = "\tthis.emit('choke');\n\twhile (this.requests.length) this._callback(this.requests.shift(), new Error('peer is choking'), null);\n"
            if (!src.includes(old)) throw new Error("peer-wire-protocol changed: the choke patch no longer fits")
            const patch = `\tthis.emit('choke');
\tvar self = this;
\tfor (var c = 0; c < this.requests.length; c++) this.requests[c].choked = true;
\tsetTimeout(function () {
\t\tfor (var k = 0; k < self.requests.length; k++) {
\t\t\tif (!self.requests[k].choked) continue;
\t\t\tself._callback(self.requests.splice(k--, 1)[0], new Error('peer is choking'), null);
\t\t}
\t}, 2000);
`
            return { contents: src.replace(old, patch), loader: "js" }
        })
    },
}

// the "bitfield" package (0.1.0) states no license: engine/bitfield.js stands in
const ownBitfield = {
    name: "own-bitfield",
    setup(b) {
        b.onResolve({ filter: /^bitfield$/ }, () => ({ path: path.join(tv, "engine/bitfield.js") }))
    },
}

// every bundled package's license, for the notices file shipped next to the engine
function notices(metafile) {
    const mods = path.join(tv, "engine/node_modules")
    const seen = new Map()
    for (const input of Object.keys(metafile.inputs)) {
        const m = /node_modules[\\/]((?:@[^\\/]+[\\/])?[^\\/]+)/.exec(input)
        if (m) seen.set(m[1], true)
    }
    const parts = [
        "Noonix TV's torrent engine (GPL-3.0-or-later, see LICENSE) is built with these packages.",
        "Their licenses follow, as each states it.",
        "",
    ]
    for (const name of [...seen.keys()].sort()) {
        const dir = path.join(mods, name)
        const pkg = JSON.parse(fs.readFileSync(path.join(dir, "package.json"), "utf8"))
        const file = fs.readdirSync(dir).find((f) => /^(licen[cs]e|copying)(\.(md|txt))?$/i.test(f))
        let text = file ? fs.readFileSync(path.join(dir, file), "utf8").trim() : ""
        if (!text) {
            // no license file: what its package.json or readme says
            const readme = fs.readdirSync(dir).find((f) => /^readme/i.test(f))
            const said = readme && /#+\s*licen[cs]e:?\s*\n+([^\n#]+)/i.exec(fs.readFileSync(path.join(dir, readme), "utf8"))
            const id = typeof pkg.license === "string" ? pkg.license : said ? said[1].trim() : ""
            if (!/^MIT/i.test(id) && !/^ISC/i.test(id)) throw new Error(`engine: ${name} has no license we can ship`)
            const author = typeof pkg.author === "string" ? pkg.author : pkg.author && pkg.author.name || "its authors"
            text = `${id} license, copyright ${author}.\n\n${MIT}`
        }
        parts.push("=".repeat(72), `${name} ${pkg.version}`, "", text, "")
    }
    return parts.join("\n")
}

const MIT = `Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
associated documentation files (the "Software"), to deal in the Software without restriction,
including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense,
and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial
portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT
LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN
NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.`

/** entry: engine/<name>.js; define: build-time constants. gives { code, notices } */
export async function bundleEngine(entry, define, minify = true) {
    if (!fs.existsSync(path.join(tv, "engine/node_modules/torrent-stream"))) {
        throw new Error("engine: run npm ci in tv/engine first")
    }
    const r = await build({
        entryPoints: [path.join(tv, "engine", entry)],
        bundle: true,
        write: false,
        platform: "node",
        format: "cjs",
        target: "es2015",
        external: ["webos-service"],
        legalComments: "none",
        metafile: true,
        define: Object.fromEntries(Object.entries(define).map(([k, v]) => [k, JSON.stringify(v)])),
        plugins: [forget, choke, ownBitfield],
        logLevel: "warning",
    })
    const es5 = ts.transpileModule(r.outputFiles[0].text, {
        fileName: "engine.js",
        compilerOptions: { target: ts.ScriptTarget.ES5, module: ts.ModuleKind.None, allowJs: true, downlevelIteration: true },
    }).outputText
    const code = minify ? (await transform(es5, { minify: true, target: "es5", legalComments: "none" })).code : es5
    return { code, notices: notices(r.metafile) }
}

// node tools/engine.mjs <out.js>: a plain build that starts at once (tests on a computer)
if (process.argv[1] === fileURLToPath(import.meta.url)) {
    const out = process.argv[2] || path.join(tv, "dist/engine-plain.js")
    fs.mkdirSync(path.dirname(out), { recursive: true })
    const e = await bundleEngine("plain.js", { __VERSION__: "dev" }, false)
    fs.writeFileSync(out, e.code)
    fs.writeFileSync(out.replace(/\.js$/, "") + "-NOTICES.txt", e.notices)
    console.log("engine: " + out + " (" + (fs.statSync(out).size / 1024).toFixed(0) + " kb)")
}
