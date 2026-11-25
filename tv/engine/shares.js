// network shares on the tv (the desktop core's shares.rs): the app asks the engine for a share's
// folders and plays its files from here. smb, webdav (http/https) and ftp.
//   POST /shares/list   {share, path}  -> {entries: [{name, dir, size, mtime}]}  (smb "": its shares)
//   POST /shares/walk   {share, path}  -> {files: [{path, size, mtime}]}  the videos under a folder
//   POST /shares/open   {share, path}  -> {token, size}
//   GET  /shares/file/<token>/<name>   the file, with ranges
//   POST /shares/forget {share}
// a failure answers {error: login|noshare|notfound|encryption|nolist|notdav|cert|unreachable, detail}.
// the posts are text/plain (no cors preflight on the tvs' old browsers)
"use strict"
var smb = require("./smb")
var dav = require("./dav")
var ftp = require("./ftp")

var VIDEO = /\.(mkv|mp4|m4v|avi|mov|wmv|webm|ts|m2ts|mpg|mpeg|ogv|flv)$/i
var SKIP = ["sample", "samples", "extras", "featurettes", "trailers", "behind the scenes", "deleted scenes", "@eadir", "$recycle.bin"]
var MIN = 20 * 1024 * 1024
var TYPES = { mkv: "video/x-matroska", mp4: "video/mp4", m4v: "video/mp4", webm: "video/webm", avi: "video/x-msvideo",
    mov: "video/quicktime", ts: "video/mp2t", m2ts: "video/mp2t", wmv: "video/x-ms-wmv", mpg: "video/mpeg", mpeg: "video/mpeg" }

var tokens = {}     // token -> { share, path, size, used }
var streams = 0     // files being read now (the engine stays up while one plays)

function proto(share) {
    if (share.kind === "dav" || share.kind === "davs") return dav
    if (share.kind === "ftp") return ftp
    return smb
}

function wanted(lower, size) { return size >= MIN && !(lower.indexOf("sample") >= 0 && size < 300 * 1024 * 1024) }

function list(share, path) {
    return proto(share).list(share, path).then(function (l) {
        return l.filter(function (e) { return e.name && e.name !== "." && e.name !== ".." }).map(function (e) { return { name: e.name, dir: !!e.dir, size: e.size || 0, mtime: e.mtime || 0 } })
    })
}

/** the video files under a folder, 8 deep, as library::walk (folders that don't answer are skipped) */
function walk(share, root) {
    root = (root || "").replace(/\/+$/, "")
    var out = []
    var todo = []
    return list(share, root).then(function (first) {
        todo.push({ dir: root, depth: 0, list: first })
        function step() {
            var job = todo.pop()
            if (!job) return out
            var subs = []
            job.list.forEach(function (e) {
                var lower = e.name.toLowerCase()
                if (lower[0] === ".") return
                var path = (job.dir ? job.dir + "/" : "") + e.name
                if (e.dir) {
                    if (job.depth < 8 && SKIP.indexOf(lower) < 0 && lower.slice(-1) !== "$") subs.push(path)
                } else if (VIDEO.test(lower) && wanted(lower, e.size)) out.push({ path: path, size: e.size, mtime: e.mtime })
            })
            return subs.reduce(function (p, path) {
                return p.then(function () {
                    return list(share, path).then(function (l) { todo.push({ dir: path, depth: job.depth + 1, list: l }) }, function () { /* skipped */ })
                })
            }, Promise.resolve()).then(step)
        }
        return step()
    })
}

function token() {
    var s = ""
    for (var i = 0; i < 4; i++) s += Math.floor(Math.random() * 0x100000000).toString(36)
    return s
}

function open(share, path) {
    // it has to be there (and the login right) before the player gets a url
    return proto(share).open(share, path).then(function (f) {
        f.close()
        var t = token()
        tokens[t] = { share: share, path: path, size: f.size, used: Date.now() }
        return { token: t, size: f.size }
    })
}

// tokens unused for a day go
setInterval(function () {
    var now = Date.now()
    for (var t in tokens) if (now - tokens[t].used > 24 * 3600 * 1000) delete tokens[t]
}, 3600 * 1000).unref()

/** an smb file read in blocks, a few asked at once (each one waits for the network otherwise) */
function smbStream(f, start, count, onData, onEnd) {
    var block = f.block || 65536
    var next = start
    var end = start + count
    var queue = []
    var stopped = false
    var paused = false
    function fill() {
        while (!stopped && queue.length < 4 && next < end) {
            var len = Math.min(block, end - next)
            queue.push(f.read(next, len))
            next += len
        }
    }
    function pump() {
        if (stopped || paused) return
        if (!queue.length) { stopped = true; return onEnd(null) }
        fill()
        queue[0].then(function (buf) {
            if (stopped) return
            queue.shift()
            if (!buf.length) { stopped = true; return onEnd(new Error("smb: short")) }
            fill()
            if (onData(buf)) pump()
            else paused = true
        }, function (e) { if (!stopped) { stopped = true; onEnd(e) } })
    }
    fill()
    pump()
    return {
        resume: function () { if (paused) { paused = false; pump() } },
        stop: function () { stopped = true },
    }
}

function serve(t, req, res) {
    var entry = tokens[t]
    if (!entry) return send(res, 404, { error: "notfound", detail: "that file isn't open" })
    entry.used = Date.now()
    var size = entry.size
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
    var ext = (entry.path.split(".").pop() || "").toLowerCase()
    var head = { "Content-Type": TYPES[ext] || "application/octet-stream", "Accept-Ranges": "bytes",
        "Content-Length": end - start + 1, "Access-Control-Allow-Origin": "*" }
    if (range) head["Content-Range"] = "bytes " + start + "-" + end + "/" + size
    if (req.method === "HEAD") { res.writeHead(range ? 206 : 200, head); return res.end() }
    var p = proto(entry.share)
    p.open(entry.share, entry.path).then(function (f) {
        var done = false
        var s = null
        streams++
        function finish(e) {
            if (done) return
            done = true
            streams--
            if (s) s.stop()
            f.close()
            if (e) console.log("[noonix engine] share read: " + (e.message || e))
            try { res.end() } catch (x) { /* gone */ }
        }
        res.writeHead(range ? 206 : 200, head)
        var onData = function (buf) { return res.write(buf) }
        s = p === smb ? smbStream(f, start, end - start + 1, onData, finish) : f.stream(start, end - start + 1, onData, finish)
        res.on("drain", function () { if (!done) s.resume() })
        res.on("close", function () { finish(null) })
    }, function (e) {
        send(res, 502, { error: p.explain(e), detail: String(e && e.message || e) })
    })
}

function send(res, code, obj) {
    var body = JSON.stringify(obj)
    res.writeHead(code, { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*", "Content-Length": Buffer.byteLength(body) })
    res.end(body)
}

function body(req) {
    return new Promise(function (ok, fail) {
        var parts = []
        var n = 0
        req.on("data", function (d) { n += d.length; if (n > 65536) { req.destroy(); fail(new Error("too big")) } else parts.push(d) })
        req.on("end", function () {
            try { ok(JSON.parse(Buffer.concat(parts).toString("utf8") || "{}")) } catch (e) { fail(e) }
        })
        req.on("error", fail)
    })
}

/** a share as the app sends it: { kind, host, port, user, password, id } */
function clean(s) {
    s = s || {}
    var kind = ["smb", "dav", "davs", "ftp"].indexOf(s.kind) >= 0 ? s.kind : "smb"
    return { kind: kind, id: s.id ? String(s.id) : "", host: String(s.host || ""), port: +s.port || 0, user: String(s.user || ""), password: String(s.password || "") }
}

/** true when it took the request */
function handle(req, res, path) {
    if (path.indexOf("/shares/") !== 0) return false
    var file = /^\/shares\/file\/([0-9a-z]+)(?:\/.*)?$/.exec(path)
    if (file) {
        if (req.method !== "GET" && req.method !== "HEAD") return send(res, 405, { error: "method" }), true
        serve(file[1], req, res)
        return true
    }
    if (req.method !== "POST") return send(res, 405, { error: "method" }), true
    var what = path.slice(8)
    body(req).then(function (b) {
        var share = clean(b.share)
        if (!share.host) throw new Error("no host")
        var p = proto(share)
        var job = what === "list" ? list(share, b.path).then(function (l) { return { entries: l } })
            : what === "walk" ? walk(share, b.path).then(function (l) { return { files: l } })
                : what === "open" ? open(share, b.path)
                    : what === "forget" ? Promise.resolve(p.forget ? p.forget(share) : null).then(function () { return {} })
                        : null
        if (!job) return send(res, 404, { error: "notfound", detail: "no such call" })
        return job.then(function (r) { send(res, 200, r) }, function (e) {
            send(res, 200, { error: p.explain(e), detail: String(e && e.message || e) })
        })
    }).catch(function (e) { send(res, 400, { error: "bad", detail: String(e && e.message || e) }) })
    return true
}

module.exports = { handle: handle, busy: function () { return streams > 0 }, _test: { walk: walk } }
