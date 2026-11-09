// builds the tv web app into tv/dist/app: one es5 script (chromium 38+ parses it), the page, styles,
// icons and the font. --package also writes the lg .ipk and the samsung .wgt (unsigned: samsung tvs
// want it signed for the tv it goes on, see tv/README.md)
//   node tools/build.mjs [--package] [--dev]
import { build, transform } from "esbuild"
import ts from "typescript"
import fs from "node:fs"
import path from "node:path"
import zlib from "node:zlib"
import { fileURLToPath } from "node:url"
import { bundleEngine } from "./engine.mjs"

const here = path.dirname(fileURLToPath(import.meta.url))
const tv = path.dirname(here)
const repo = path.dirname(tv)
const out = path.join(tv, "dist")
const app = path.join(out, "app")
const dev = process.argv.includes("--dev")
const pack = process.argv.includes("--package")

const version = /^version = "(.*)"/m.exec(fs.readFileSync(path.join(repo, "core/Cargo.toml"), "utf8"))[1]
const webosId = "io.github.dzeliks.noonixtv"
const tizenPackage = "NoonixTVap"
// the torrent engine runs beside the app as a service (as stremio's server does on these tvs)
const webosService = `${webosId}.engine`

// serbian: every translated message of the qt app (the first one wins where contexts differ)
const sr = {}
const ts_ = fs.readFileSync(path.join(repo, "i18n/noonix-tv_sr_Latn.ts"), "utf8")
const unxml = (t) => t.replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, "\"").replace(/&apos;/g, "'").replace(/&amp;/g, "&")
for (const m of ts_.matchAll(/<source>([\s\S]*?)<\/source>\s*(?:<comment>[\s\S]*?<\/comment>\s*)?<translation(?: type="[^"]*")?>([\s\S]*?)<\/translation>/g)) {
    const src = unxml(m[1])
    // plurals: the forms in order (serbian: one, few, many)
    const forms = [...m[2].matchAll(/<numerusform>([\s\S]*?)<\/numerusform>/g)].map((f) => unxml(f[1]))
    const tr = forms.length ? forms : unxml(m[2])
    if (tr.length && !(src in sr)) sr[src] = tr
}
// the tv's own words the qt app doesn't have
for (const [src, tr] of Object.entries(JSON.parse(fs.readFileSync(path.join(tv, "src/sr.json"), "utf8")))) if (!(src in sr)) sr[src] = tr

// the bundle: esbuild joins the modules (es2015), typescript lowers it to es5 (esbuild can't)
const bundled = await build({
    entryPoints: [path.join(tv, "src/main.ts")],
    bundle: true,
    write: false,
    format: "iife",
    target: "es2015",
    minify: !dev,
    sourcemap: false,
    legalComments: "none",
    define: {
        __VERSION__: JSON.stringify(version),
        __DEV__: String(dev),
        __SR__: JSON.stringify(sr),
        // the built-in keys, as in the other builds (empty: the user adds their own)
        __TMDB_KEY__: JSON.stringify(process.env.NOONIX_TMDB_API_KEY || ""),
        __TMDB_TOKEN__: JSON.stringify(process.env.NOONIX_TMDB_READ_TOKEN || ""),
        __TRAKT_ID__: JSON.stringify(process.env.NOONIX_TRAKT_CLIENT_ID || ""),
        __TRAKT_SECRET__: JSON.stringify(process.env.NOONIX_TRAKT_CLIENT_SECRET || ""),
        // dev: tmdb ids kept out of tests and screenshots
        __HIDE__: JSON.stringify(dev ? process.env.NOONIX_HIDE || "" : ""),
    },
})
const es2015 = bundled.outputFiles[0].text
const lowered = ts.transpileModule(es2015, {
    fileName: "app.js",
    compilerOptions: {
        target: ts.ScriptTarget.ES5,
        module: ts.ModuleKind.None,
        allowJs: true,
        downlevelIteration: true,
        removeComments: !dev,
    },
}).outputText
// typescript writes it out long: minified again, staying es5
const es5 = dev ? lowered : (await transform(lowered, { minify: true, target: "es5", legalComments: "none" })).code

fs.rmSync(out, { recursive: true, force: true })
fs.mkdirSync(path.join(app, "fonts"), { recursive: true })
fs.writeFileSync(path.join(app, "app.js"), es5)
copyDir(path.join(tv, "static"), app, (rel) => !rel.startsWith("webos") && !rel.startsWith("tizen"))
fs.copyFileSync(path.join(repo, "fonts/InterVariable.ttf"), path.join(app, "fonts/InterVariable.ttf"))
fs.copyFileSync(path.join(repo, "fonts/Inter-OFL.txt"), path.join(app, "fonts/Inter-OFL.txt"))
fs.copyFileSync(path.join(repo, "LICENSE"), path.join(app, "LICENSE"))
fs.copyFileSync(path.join(repo, "qml/assets/credits/tmdb.svg"), path.join(app, "icons/tmdb.svg"))
const fill = (s) => s.replaceAll("@VERSION@", version).replaceAll("@WEBOS_ID@", webosId).replaceAll("@TIZEN_PACKAGE@", tizenPackage)
fs.writeFileSync(path.join(app, "appinfo.json"), fill(fs.readFileSync(path.join(tv, "static/webos/appinfo.json"), "utf8")))
fs.writeFileSync(path.join(app, "config.xml"), fill(fs.readFileSync(path.join(tv, "static/tizen/config.xml"), "utf8")))
console.log(`app ${version}: ${path.relative(repo, app)} (app.js ${(es5.length / 1024).toFixed(0)} kb)`)

// the engine: samsung's in the app folder (config.xml points at it), lg's as its own service folder
const tizenEngine = await bundleEngine("tizen.js", { __VERSION__: version })
fs.mkdirSync(path.join(app, "engine"), { recursive: true })
fs.writeFileSync(path.join(app, "engine/service.js"), tizenEngine.code)
fs.writeFileSync(path.join(app, "engine/NOTICES.txt"), tizenEngine.notices)
const webosEngine = await bundleEngine("webos.js", { __VERSION__: version, __SERVICE_ID__: webosService })
console.log(`engine: ${(tizenEngine.code.length / 1024).toFixed(0)} kb`)

if (pack) {
    const ipk = path.join(out, `Noonix-TV-${version}-webos-preview.ipk`)
    fs.writeFileSync(ipk, makeIpk())
    const wgt = path.join(out, `Noonix-TV-${version}-tizen-unsigned-preview.wgt`)
    fs.writeFileSync(wgt, makeZip(listFiles(app).filter((f) => f !== "appinfo.json")))
    console.log(`packages: ${path.relative(repo, ipk)}, ${path.relative(repo, wgt)}`)
}

function copyDir(from, to, keep) {
    for (const rel of listFiles(from)) {
        if (!keep(rel)) continue
        fs.mkdirSync(path.dirname(path.join(to, rel)), { recursive: true })
        fs.copyFileSync(path.join(from, rel), path.join(to, rel))
    }
}

/** every file under dir, relative, sorted (the packages come out the same each build) */
function listFiles(dir, rel = "") {
    const files = []
    for (const e of fs.readdirSync(path.join(dir, rel), { withFileTypes: true })) {
        const r = rel ? `${rel}/${e.name}` : e.name
        if (e.isDirectory()) files.push(...listFiles(dir, r))
        else files.push(r)
    }
    return files.sort()
}

// ---- the webOS .ipk: a debian ar of debian-binary, control.tar.gz and data.tar.gz (as ares-package makes it)

function makeIpk() {
    const appDir = `usr/palm/applications/${webosId}`
    const pkgDir = `usr/palm/packages/${webosId}`
    const data = []
    const dirs = new Set(["usr", "usr/palm", "usr/palm/applications", appDir, "usr/palm/packages", pkgDir])
    let bytes = 0
    for (const rel of listFiles(app)) {
        if (rel === "config.xml" || rel.startsWith("engine/")) continue
        const parts = rel.split("/")
        for (let i = 1; i < parts.length; i++) dirs.add(`${appDir}/${parts.slice(0, i).join("/")}`)
        const body = fs.readFileSync(path.join(app, rel))
        bytes += body.length
        data.push({ name: `${appDir}/${rel}`, body })
    }
    const info = JSON.stringify({ id: webosId, version, app: webosId, services: [webosService] }, null, 2) + "\n"
    data.push({ name: `${pkgDir}/packageinfo.json`, body: Buffer.from(info) })
    // the engine service: usr/palm/services/<id>, a node package the system runs on demand
    const svcDir = `usr/palm/services/${webosService}`
    dirs.add("usr/palm/services").add(svcDir)
    const about = "Noonix TV's torrent engine: plays torrent sources on this TV"
    const svc = {
        "services.json": JSON.stringify({ id: webosService, description: about, services: [{ name: webosService, description: about }] }, null, 2) + "\n",
        "package.json": JSON.stringify({ name: webosService, version, description: about, main: "index.js", license: "GPL-3.0-or-later" }, null, 2) + "\n",
        "index.js": webosEngine.code,
        "NOTICES.txt": webosEngine.notices,
        "LICENSE": fs.readFileSync(path.join(repo, "LICENSE"), "utf8"),
    }
    for (const [name, body] of Object.entries(svc)) {
        const b = Buffer.from(body)
        bytes += b.length
        data.push({ name: `${svcDir}/${name}`, body: b })
    }
    const entries = [...dirs].sort().map((name) => ({ name, dir: true })).concat(data.sort((a, b) => a.name < b.name ? -1 : 1))
    const control = [
        `Package: ${webosId}`,
        `Version: ${version}`,
        "Section: misc",
        "Priority: optional",
        "Architecture: all",
        // in bytes, as ares-package writes it
        `Installed-Size: ${bytes}`,
        "Maintainer: dzeliks <127214601+dzeliks@users.noreply.github.com>",
        "Description: Noonix TV",
        "webOS-Package-Format-Version: 2",
        "webOS-Packager-Version: 3.2.6",
        "",
    ].join("\n")
    const gz = (b) => zlib.gzipSync(b, { level: 9 })
    return makeAr([
        { name: "debian-binary", body: Buffer.from("2.0\n") },
        { name: "control.tar.gz", body: gz(makeTar([{ name: "control", body: Buffer.from(control) }])) },
        { name: "data.tar.gz", body: gz(makeTar(entries)) },
    ])
}

function makeAr(files) {
    const parts = [Buffer.from("!<arch>\n")]
    const mtime = Math.floor(Date.now() / 1000)
    for (const f of files) {
        const head = f.name.padEnd(16) + String(mtime).padEnd(12) + "0".padEnd(6) + "0".padEnd(6)
            + "100644".padEnd(8) + String(f.body.length).padEnd(10) + "`\n"
        parts.push(Buffer.from(head, "ascii"), f.body)
        if (f.body.length % 2) parts.push(Buffer.from("\n"))
    }
    return Buffer.concat(parts)
}

// a ustar tar (names as ares-package writes them, no "./"), long ones split into prefix + name
function makeTar(entries) {
    const blocks = []
    const mtime = Math.floor(Date.now() / 1000)
    for (const e of entries) {
        const full = `${e.name}${e.dir ? "/" : ""}`
        let name = full
        let prefix = ""
        if (Buffer.byteLength(name) > 100) {
            const cut = full.lastIndexOf("/", full.length - 2)
            prefix = full.slice(0, cut)
            name = full.slice(cut + 1)
            if (Buffer.byteLength(name) > 100 || Buffer.byteLength(prefix) > 155) throw new Error(`path too long for tar: ${full}`)
        }
        const size = e.dir ? 0 : e.body.length
        const h = Buffer.alloc(512)
        h.write(name, 0, 100, "utf8")
        h.write((e.dir ? "0000755" : "0000644") + "\0", 100, "ascii")
        h.write("0000000\0", 108, "ascii")
        h.write("0000000\0", 116, "ascii")
        h.write(size.toString(8).padStart(11, "0") + "\0", 124, "ascii")
        h.write(mtime.toString(8).padStart(11, "0") + "\0", 136, "ascii")
        h.write("        ", 148, "ascii")
        h.write(e.dir ? "5" : "0", 156, "ascii")
        h.write("ustar\0" + "00", 257, "ascii")
        h.write("root", 265, "ascii")
        h.write("root", 297, "ascii")
        h.write(prefix, 345, 155, "utf8")
        let sum = 0
        for (let i = 0; i < 512; i++) sum += h[i]
        h.write(sum.toString(8).padStart(6, "0") + "\0 ", 148, "ascii")
        blocks.push(h)
        if (!e.dir) {
            blocks.push(e.body)
            if (size % 512) blocks.push(Buffer.alloc(512 - (size % 512)))
        }
    }
    blocks.push(Buffer.alloc(1024))
    return Buffer.concat(blocks)
}

// ---- the tizen .wgt: a zip of the app folder (config.xml at the root)

function makeZip(files) {
    const locals = []
    const central = []
    let offset = 0
    // dos time: 1980-01-01, so the zip doesn't change between builds of the same files
    const time = 0, date = (1 << 5) | 1
    for (const rel of files) {
        const body = fs.readFileSync(path.join(app, rel))
        const deflated = zlib.deflateRawSync(body, { level: 9 })
        const stored = deflated.length >= body.length
        const data = stored ? body : deflated
        const crc = zlib.crc32(body)
        const name = Buffer.from(rel, "utf8")
        const local = Buffer.alloc(30)
        local.writeUInt32LE(0x04034b50, 0)
        local.writeUInt16LE(20, 4)
        local.writeUInt16LE(0x0800, 6)
        local.writeUInt16LE(stored ? 0 : 8, 8)
        local.writeUInt16LE(time, 10)
        local.writeUInt16LE(date, 12)
        local.writeUInt32LE(crc, 14)
        local.writeUInt32LE(data.length, 18)
        local.writeUInt32LE(body.length, 22)
        local.writeUInt16LE(name.length, 26)
        locals.push(local, name, data)
        const c = Buffer.alloc(46)
        c.writeUInt32LE(0x02014b50, 0)
        c.writeUInt16LE(0x031e, 4)
        c.writeUInt16LE(20, 6)
        c.writeUInt16LE(0x0800, 8)
        c.writeUInt16LE(stored ? 0 : 8, 10)
        c.writeUInt16LE(time, 12)
        c.writeUInt16LE(date, 14)
        c.writeUInt32LE(crc, 16)
        c.writeUInt32LE(data.length, 20)
        c.writeUInt32LE(body.length, 24)
        c.writeUInt16LE(name.length, 28)
        c.writeUInt32LE((0o100644 << 16) >>> 0, 38)
        c.writeUInt32LE(offset, 42)
        central.push(c, name)
        offset += 30 + name.length + data.length
    }
    const dir = Buffer.concat(central)
    const end = Buffer.alloc(22)
    end.writeUInt32LE(0x06054b50, 0)
    end.writeUInt16LE(files.length, 8)
    end.writeUInt16LE(files.length, 10)
    end.writeUInt32LE(dir.length, 12)
    end.writeUInt32LE(offset, 16)
    return Buffer.concat([...locals, dir, end])
}
