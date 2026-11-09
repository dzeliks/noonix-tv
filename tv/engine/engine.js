// the torrent engine the lg and samsung apps carry (stremio's tv apps run their streaming server on the
// tv the same way): a node service on 127.0.0.1:11470 with the streaming server's api, as the desktop
// core's tvserver.rs: GET /<infohash>/<file index>[?tr=&f=] plays a file of it (-1: the biggest video).
// download only (no upload slots, no listening port), one torrent at a time, pieces kept in memory
// (a tv has little flash): the ones far behind what plays are dropped and fetched again if needed.
"use strict"
var http = require("http")
var os = require("os")
var torrentStream = require("torrent-stream")

var PORT = 11470
var IDLE = 10 * 60 * 1000
// kept in memory: all of it at most (the app says how much: less on low memory tvs), ahead of the
// reader (most of it) and behind it
var MB = 1024 * 1024
var BEHIND = 8 * MB
var CAP, AHEAD
setCap(+(process.env && process.env.NOONIX_ENGINE_CAP) || 220 * MB)

function setCap(bytes) {
    CAP = Math.max(48 * MB, Math.min(512 * MB, bytes))
    AHEAD = Math.round(CAP * 0.7)
}
var VIDEO = /\.(mkv|mp4|m4v|avi|mov|webm|ts|m2ts|wmv|mpg|mpeg|flv|ogv)$/i
var TYPES = { mkv: "video/x-matroska", mp4: "video/mp4", m4v: "video/mp4", webm: "video/webm", avi: "video/x-msvideo",
    mov: "video/quicktime", ts: "video/mp2t", m2ts: "video/mp2t", wmv: "video/x-ms-wmv", mpg: "video/mpeg", mpeg: "video/mpeg" }

var version = "0"
var server = null
var current = null      // { hash, engine, ready, readers: [], last }
var lastAsk = Date.now()
var idleTimer = null
var onIdle = null

function log() {
    var a = Array.prototype.slice.call(arguments)
    a.unshift("[noonix engine]")
    console.log.apply(console, a)
}

// ---- pieces in memory, the least recently read leave first (never the ones a reader is on or near)

function memoryStore(owner) {
    return function (pieceLength) {
        var pieces = {}
        var order = []
        var bytes = 0
        function touch(i) {
            var at = order.indexOf(i)
            if (at >= 0) order.splice(at, 1)
            order.push(i)
        }
        function keepNear(i) {
            for (var r = 0; r < owner.readers.length; r++) {
                var rd = owner.readers[r]
                if (i >= rd.piece - Math.ceil(BEHIND / pieceLength) && i <= rd.piece + Math.ceil(AHEAD / pieceLength)) return true
            }
            return false
        }
        function trim() {
            for (var k = 0; k < order.length && bytes > CAP; k++) {
                var i = order[k]
                if (keepNear(i)) continue
                order.splice(k, 1)
                k--
                bytes -= pieces[i].length
                delete pieces[i]
                if (owner.engine && owner.engine.forget) owner.engine.forget(i)
            }
        }
        return {
            chunkLength: pieceLength,
            put: function (i, buf, cb) {
                if (pieces[i]) bytes -= pieces[i].length
                pieces[i] = buf
                bytes += buf.length
                touch(i)
                trim()
                if (cb) process.nextTick(cb)
            },
            get: function (i, opts, cb) {
                if (typeof opts === "function") { cb = opts; opts = null }
                var buf = pieces[i]
                if (!buf) return process.nextTick(function () { cb(new Error("piece " + i + " not kept")) })
                touch(i)
                if (opts) buf = buf.slice(opts.offset || 0, opts.length ? (opts.offset || 0) + opts.length : buf.length)
                process.nextTick(function () { cb(null, buf) })
            },
            close: function (cb) { if (cb) process.nextTick(cb) },
            destroy: function (cb) { pieces = {}; order = []; bytes = 0; if (cb) process.nextTick(cb) },
        }
    }
}

// ---- one torrent at a time

function trackersOf(query) {
    var tr = query.tr || []
    if (typeof tr === "string") tr = [tr]
    var out = []
    for (var i = 0; i < tr.length; i++) {
        var t = String(tr[i]).replace(/^tracker:/, "")
        if (/^(udp|https?|wss?):\/\//.test(t)) out.push(t)
    }
    return out
}

function drop() {
    if (!current) return
    var c = current
    current = null
    for (var i = 0; i < c.readers.length; i++) c.readers[i].stop()
    log("dropped " + c.hash)
    try { c.engine.destroy(function () { c.engine.remove(function () {}) }) } catch (e) { log("destroy: " + e) }
}

function open(hash, trackers) {
    if (current && current.hash === hash) return current
    drop()
    var owner = { hash: hash, engine: null, readers: [], ready: false, last: Date.now(), waiting: [] }
    var engine = torrentStream("magnet:?xt=urn:btih:" + hash, {
        uploads: 0,
        trackers: trackers.length ? trackers : undefined,
        storage: memoryStore(owner),
        tmp: os.tmpdir(),
        name: "noonix-engine",
        verify: false,
    })
    owner.engine = engine
    engine.on("error", function (e) { log(hash + ": " + (e && e.message || e)) })
    owner.verified = 0
    owner.invalid = 0
    owner.hotswaps = 0
    engine.on("verify", function () { owner.verified++ })
    engine.on("invalid-piece", function () { owner.invalid++ })
    engine.on("hotswap", function () { owner.hotswaps++ })
    engine.on("ready", function () {
        owner.ready = true
        log("ready " + hash + ": " + engine.files.length + " files")
        var w = owner.waiting
        owner.waiting = []
        for (var i = 0; i < w.length; i++) w[i]()
    })
    current = owner
    log("opened " + hash + " (" + trackers.length + " trackers)")
    return owner
}

function whenReady(owner, ms, cb) {
    if (owner.ready) return cb(null)
    var done = false
    var t = setTimeout(function () { if (!done) { done = true; cb(new Error("no metadata yet")) } }, ms)
    owner.waiting.push(function () { if (!done) { done = true; clearTimeout(t); cb(null) } })
}

function pickFile(engine, idx, must) {
    var files = engine.files
    if (idx >= 0 && idx < files.length) return files[idx]
    var best = null
    for (var i = 0; i < files.length; i++) {
        var f = files[i]
        if (must && f.path.toLowerCase().indexOf(must.toLowerCase()) < 0) continue
        if (!VIDEO.test(f.name)) continue
        if (!best || f.length > best.length) best = f
    }
    return best
}

// ---- a file's bytes as they arrive: a window of pieces asked for ahead of where it reads

function reader(owner, file, start, end, res) {
    var engine = owner.engine
    var plen = engine.torrent.pieceLength
    var pos = start
    var stopped = false
    var sel = null
    var waitingFor = -1
    var rd = { piece: Math.floor((file.offset + start) / plen), stop: stop }
    owner.readers.push(rd)

    function select() {
        var from = rd.piece
        var to = Math.min(Math.floor((file.offset + end) / plen), from + Math.ceil(AHEAD / plen))
        if (sel && sel.from === from && sel.to === to) return
        if (sel) engine.deselect(sel.from, sel.to, true)
        sel = { from: from, to: to }
        engine.select(from, to, true)
    }
    function stop() {
        if (stopped) return
        stopped = true
        engine.removeListener("verify", onverify)
        if (sel) engine.deselect(sel.from, sel.to, true)
        var at = owner.readers.indexOf(rd)
        if (at >= 0) owner.readers.splice(at, 1)
        owner.last = Date.now()
        try { res.end() } catch (e) { /* gone */ }
    }
    // verify comes before the piece is stored: read it on the next turn
    function onverify(i) { if (i === waitingFor) { waitingFor = -1; setImmediate(next) } }
    function next() {
        if (stopped) return
        if (pos > end) return stop()
        rd.piece = Math.floor((file.offset + pos) / plen)
        owner.last = Date.now()
        select()
        // the one it waits on (and the next): asked from every peer that has it
        if (!engine.bitfield.get(rd.piece)) { waitingFor = rd.piece; engine.critical(rd.piece, 2); return }
        engine.store.get(rd.piece, function (err, buf) {
            if (stopped) return
            // dropped from memory meanwhile: asked for again
            if (err) return setTimeout(next, 250)
            var off = file.offset + pos - rd.piece * plen
            var chunk = buf.slice(off, Math.min(buf.length, off + (end - pos + 1)))
            pos += chunk.length
            if (res.write(chunk)) next()
            else res.once("drain", next)
        })
    }
    engine.on("verify", onverify)
    res.on("close", stop)
    next()
}

// ---- http

function reply(res, code, type, body) {
    res.writeHead(code, { "Content-Type": type, "Access-Control-Allow-Origin": "*", "Content-Length": Buffer.byteLength(body) })
    res.end(body)
}

function parseQuery(q) {
    var out = {}
    if (!q) return out
    q.split("&").forEach(function (kv) {
        if (!kv) return
        var at = kv.indexOf("=")
        var k = decodeURIComponent((at < 0 ? kv : kv.slice(0, at)).replace(/\+/g, " "))
        var v = at < 0 ? "" : decodeURIComponent(kv.slice(at + 1).replace(/\+/g, " "))
        if (out[k] === undefined) out[k] = v
        else if (typeof out[k] === "string") out[k] = [out[k], v]
        else out[k].push(v)
    })
    return out
}

function handle(req, res) {
    lastAsk = Date.now()
    var q = req.url.indexOf("?")
    var p = q < 0 ? req.url : req.url.slice(0, q)
    var query = parseQuery(q < 0 ? "" : req.url.slice(q + 1))
    if (req.method === "OPTIONS") {
        res.writeHead(204, { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "*", "Access-Control-Allow-Methods": "GET, HEAD, OPTIONS" })
        return res.end()
    }
    if (p === "/settings") return reply(res, 200, "application/json", JSON.stringify({ options: [], values: { serverVersion: "noonix-tv-engine " + version, cacheSize: CAP } }))
    if (p === "/heartbeat" || p === "/stats.json") return reply(res, 200, "application/json", "{}")
    var m = /^\/([0-9a-fA-F]{40})\/(-?\d+)(?:\/.*)?$/.exec(p)
    var s = /^\/([0-9a-fA-F]{40})\/stats\.json$/.exec(p)
    if (s) {
        var o = current && current.hash === s[1].toLowerCase() ? current : null
        var c = o && o.engine
        return reply(res, 200, "application/json", JSON.stringify(c ? { peers: c.swarm.wires.length, downloadSpeed: c.swarm.downloadSpeed(),
            downloaded: c.swarm.downloaded, pieces: o.verified, invalid: o.invalid, hotswaps: o.hotswaps,
            pieceLength: c.torrent ? c.torrent.pieceLength : 0 } : {}))
    }
    if (!m || (req.method !== "GET" && req.method !== "HEAD")) return reply(res, 404, "text/plain", "not found")
    var owner = open(m[1].toLowerCase(), trackersOf(query))
    whenReady(owner, 60000, function (err) {
        if (err) return reply(res, 504, "text/plain", "no metadata: nobody sharing it answered")
        if (owner !== current) return reply(res, 410, "text/plain", "replaced")
        var file = pickFile(owner.engine, parseInt(m[2], 10), typeof query.f === "string" ? query.f : "")
        if (!file) return reply(res, 404, "text/plain", "no video in it")
        var size = file.length
        var start = 0
        var end = size - 1
        var range = /bytes=(\d*)-(\d*)/.exec(req.headers.range || "")
        if (range) {
            if (range[1]) start = parseInt(range[1], 10)
            else if (range[2]) start = Math.max(0, size - parseInt(range[2], 10))
            if (range[1] && range[2]) end = Math.min(end, parseInt(range[2], 10))
            if (start >= size) {
                res.writeHead(416, { "Content-Range": "bytes */" + size, "Access-Control-Allow-Origin": "*" })
                return res.end()
            }
        }
        var ext = (file.name.split(".").pop() || "").toLowerCase()
        var head = { "Content-Type": TYPES[ext] || "application/octet-stream", "Accept-Ranges": "bytes",
            "Content-Length": end - start + 1, "Access-Control-Allow-Origin": "*" }
        if (range) head["Content-Range"] = "bytes " + start + "-" + end + "/" + size
        res.writeHead(range ? 206 : 200, head)
        if (req.method === "HEAD") return res.end()
        reader(owner, file, start, end, res)
    })
}

function tick() {
    var now = Date.now()
    if (current && !current.readers.length && now - current.last > IDLE) drop()
    if (!current && now - lastAsk > IDLE && onIdle) {
        log("idle: stopping")
        stop()
        onIdle()
    }
}

/** starts it once; opts.version, opts.cap (MB kept in memory), opts.onIdle: nothing asked for a while
 *  (the service may end) */
function start(opts) {
    opts = opts || {}
    if (opts.version) version = opts.version
    if (+opts.cap > 0 && !(process.env && process.env.NOONIX_ENGINE_CAP)) setCap(+opts.cap * MB)
    if (opts.onIdle) onIdle = opts.onIdle
    lastAsk = Date.now()
    if (server) return
    server = http.createServer(handle)
    // a stream waits on peers as long as it takes (node ends a quiet socket after 2 min)
    server.timeout = 0
    server.on("error", function (e) { log("server: " + (e && e.message || e)) })
    server.listen(PORT, "127.0.0.1", function () { log("listening on 127.0.0.1:" + PORT) })
    idleTimer = setInterval(tick, 30000)
}

function stop() {
    drop()
    if (idleTimer) clearInterval(idleTimer)
    idleTimer = null
    if (server) try { server.close() } catch (e) { /* closed */ }
    server = null
}

module.exports = { start: start, stop: stop, PORT: PORT }
