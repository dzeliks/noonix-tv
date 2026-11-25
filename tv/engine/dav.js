// webdav for network shares on the tv (core shares.rs dav_*): propfind for folders, get with a range
// for playing. http or https, basic login
"use strict"
var http = require("http")
var https = require("https")

function url(share, rest) {
    var path = (rest || "").split("/").filter(function (s) { return !!s }).map(encodeURIComponent).join("/")
    return { secure: share.kind === "davs", host: share.host, port: share.port || (share.kind === "davs" ? 443 : 80), path: "/" + path }
}

function request(share, method, target, headers, body, timeout) {
    return new Promise(function (ok, fail) {
        var h = headers || {}
        h["User-Agent"] = "NoonixTV"
        if (share.user) h.Authorization = "Basic " + Buffer.from(share.user + ":" + (share.password || ""), "utf8").toString("base64")
        if (body) h["Content-Length"] = Buffer.byteLength(body)
        var req = (target.secure ? https : http).request({ host: target.host, port: target.port, path: target.path, method: method, headers: h })
        var timer = setTimeout(function () { req.abort(); fail(new Error("dav: no answer")) }, (timeout || 20) * 1000)
        req.on("response", function (res) { clearTimeout(timer); ok(res) })
        req.on("error", function (e) { clearTimeout(timer); fail(e) })
        req.end(body || undefined)
    })
}

function text(res) {
    return new Promise(function (ok, fail) {
        var parts = []
        res.on("data", function (d) { parts.push(d) })
        res.on("end", function () { ok(Buffer.concat(parts).toString("utf8")) })
        res.on("error", fail)
    })
}

function decodeXml(s) {
    return s.replace(/&(#x[0-9a-f]+|#\d+|amp|lt|gt|quot|apos);/gi, function (m, e) {
        var l = e.toLowerCase()
        if (l[0] === "#") return String.fromCharCode(l[1] === "x" ? parseInt(l.slice(2), 16) : parseInt(l.slice(1), 10))
        return { amp: "&", lt: "<", gt: ">", quot: "\"", apos: "'" }[l]
    })
}

/** a multistatus answer: [{ path (decoded), dir, size, mtime }] (any namespace prefix) */
function parse(xml) {
    var out = []
    var re = /<(?:[\w-]+:)?response[\s>][\s\S]*?<\/(?:[\w-]+:)?response>/gi
    var m
    while ((m = re.exec(xml))) {
        var r = m[0]
        var href = /<(?:[\w-]+:)?href[^>]*>([\s\S]*?)<\/(?:[\w-]+:)?href>/i.exec(r)
        if (!href) continue
        var raw = decodeXml(href[1].trim())
        var path = raw.replace(/^https?:\/\/[^/]+/i, "")
        try { path = decodeURIComponent(path) } catch (e) { /* as it is */ }
        var len = /<(?:[\w-]+:)?getcontentlength[^>]*>\s*(\d+)\s*</i.exec(r)
        var mod = /<(?:[\w-]+:)?getlastmodified[^>]*>([^<]*)</i.exec(r)
        var t = mod ? Date.parse(mod[1].trim()) : NaN
        var name = path.replace(/\/+$/, "").split("/").pop() || ""
        out.push({ path: path, name: decodeXml(name), dir: /<(?:[\w-]+:)?collection\b[^>]*>/i.test(r), size: len ? +len[1] : 0,
            mtime: isNaN(t) ? 0 : Math.floor(t / 1000) })
    }
    return out
}

var BODY = "<?xml version=\"1.0\" encoding=\"utf-8\"?><d:propfind xmlns:d=\"DAV:\"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/></d:prop></d:propfind>"

function DavError(kind, msg) { var e = new Error(msg); e.kind = kind; return e }

function list(share, rest) {
    var t = url(share, rest)
    if (!/\/$/.test(t.path)) t.path += "/"
    return request(share, "PROPFIND", t, { Depth: "1", "Content-Type": "application/xml" }, BODY).then(function (res) {
        if (res.statusCode === 401 || res.statusCode === 403) { res.resume(); throw DavError("login", "dav: " + res.statusCode) }
        if (res.statusCode === 404) { res.resume(); throw DavError("notfound", "dav: 404") }
        if (res.statusCode !== 207) { res.resume(); throw DavError("notdav", "dav: " + res.statusCode) }
        return text(res).then(function (xml) {
            var own = t.path.replace(/\/+$/, "")
            try { own = decodeURIComponent(own) } catch (e) { /* as it is */ }
            return parse(xml).filter(function (e) { return e.path.replace(/\/+$/, "") !== own })
        })
    })
}

function open(share, rest) {
    var t = url(share, rest)
    return request(share, "HEAD", t, {}).then(function (res) {
        res.resume()
        if (res.statusCode === 401 || res.statusCode === 403) throw DavError("login", "dav: " + res.statusCode)
        if (res.statusCode < 200 || res.statusCode >= 300) throw DavError("notfound", "dav: " + res.statusCode)
        var size = +(res.headers["content-length"] || 0)
        return {
            size: size,
            /** a readable of count bytes from start (a server without ranges: skipped up to it) */
            stream: function (start, count, onData, onEnd) {
                var h = { Range: "bytes=" + start + "-" + (start + count - 1) }
                var req = null
                var stopped = false
                request(share, "GET", t, h, null, 30).then(function (res) {
                    if (stopped) { res.destroy(); return }
                    req = res
                    if (res.statusCode !== 206 && res.statusCode !== 200) { res.resume(); return onEnd(new Error("dav: " + res.statusCode)) }
                    var skip = res.statusCode === 206 ? 0 : start
                    var left = count
                    res.on("data", function (d) {
                        if (skip) { var n = Math.min(skip, d.length); d = d.slice(n); skip -= n }
                        if (!d.length) return
                        if (d.length > left) d = d.slice(0, left)
                        left -= d.length
                        if (!onData(d)) res.pause()
                        if (!left) { res.destroy(); onEnd(null) }
                    })
                    res.on("end", function () { if (left) onEnd(left === count ? new Error("dav: empty") : null) })
                    res.on("error", function (e) { onEnd(e) })
                }, function (e) { onEnd(e) })
                return {
                    resume: function () { if (req) req.resume() },
                    stop: function () { stopped = true; if (req) req.destroy() },
                }
            },
            close: function () { /* nothing open */ },
        }
    })
}

function explain(e) {
    if (e && e.kind) return e.kind
    if (e && /CERT|certificate|SSL|TLS/i.test(String(e.code || "") + " " + String(e.message || ""))) return "cert"
    return "unreachable"
}

module.exports = { list: list, open: open, explain: explain, _test: { parse: parse } }
