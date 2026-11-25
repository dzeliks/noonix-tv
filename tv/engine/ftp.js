// ftp for network shares on the tv (core shares.rs ftp_*): a login per folder or play, passive data
// connections, mlsd with a list fallback, rest + retr for a range
"use strict"
var net = require("net")

function FtpError(kind, msg) { var e = new Error(msg); e.kind = kind; return e }

/** the control connection: send(cmd) -> { code, text } (multi-line answers joined) */
function connect(share) {
    return new Promise(function (ok, fail) {
        var sock = net.connect({ host: share.host, port: share.port || 21 })
        var buf = ""
        var waiters = []
        var early = []      // answers nobody waits on yet (a 226 can come before the data's end)
        var lines = []
        var done = false
        var timer = setTimeout(function () { sock.destroy(); fail(FtpError("unreachable", "ftp: no answer")) }, 10000)
        sock.setEncoding("utf8")
        sock.on("data", function (d) {
            buf += d
            var at
            while ((at = buf.indexOf("\n")) >= 0) {
                var line = buf.slice(0, at).replace(/\r$/, "")
                buf = buf.slice(at + 1)
                lines.push(line)
                // the end of an answer: "123 text" (a multi-line one starts "123-")
                if (/^\d{3} /.test(line) && (lines.length === 1 || lines[0].slice(0, 3) === line.slice(0, 3))) {
                    var r = { code: +line.slice(0, 3), text: lines.join("\n") }
                    lines = []
                    var w = waiters.shift()
                    if (w) w.ok(r)
                    else early.push(r)
                }
            }
        })
        sock.on("error", function (e) { var w; while ((w = waiters.shift())) w.fail(e); if (!done) { clearTimeout(timer); fail(e) } })
        sock.on("close", function () { var w; while ((w = waiters.shift())) w.fail(new Error("ftp: closed")) })
        var c = {
            sock: sock,
            next: function () {
                if (early.length) return Promise.resolve(early.shift())
                return new Promise(function (y, n) { waiters.push({ ok: y, fail: n }) })
            },
            send: function (cmd) { var p = c.next(); sock.write(cmd + "\r\n"); return p },
            quit: function () { try { sock.write("QUIT\r\n"); sock.end() } catch (e) { /* gone */ } },
        }
        c.next().then(function (hello) {
            clearTimeout(timer)
            done = true
            if (hello.code !== 220) throw FtpError("unreachable", "ftp: " + hello.text)
            var user = share.user || "anonymous"
            var pass = share.user || share.password ? share.password || "" : "noonix@"
            return c.send("USER " + user).then(function (r) {
                if (r.code === 230) return r
                if (r.code !== 331) throw FtpError("login", "ftp: " + r.text)
                return c.send("PASS " + pass)
            }).then(function (r) {
                if (r.code !== 230 && r.code !== 202) throw FtpError("login", "ftp: " + r.text)
                return c.send("TYPE I")
            }).then(function () { ok(c) })
        }).catch(function (e) { sock.destroy(); fail(e) })
    })
}

/** a passive data connection's address */
function passive(c, share) {
    return c.send("EPSV").then(function (r) {
        var m = /\(\|\|\|(\d+)\|\)/.exec(r.text)
        if (r.code === 229 && m) return { host: share.host, port: +m[1] }
        return c.send("PASV").then(function (p) {
            var n = /(\d+),(\d+),(\d+),(\d+),(\d+),(\d+)/.exec(p.text)
            if (p.code !== 227 || !n) throw FtpError("unreachable", "ftp: " + p.text)
            // the address it names may be its own private one: the one we reached it by is used
            return { host: share.host, port: +n[5] * 256 + +n[6] }
        })
    })
}

function dataConn(at) {
    return new Promise(function (ok, fail) {
        var s = net.connect({ host: at.host, port: at.port })
        var timer = setTimeout(function () { s.destroy(); fail(new Error("ftp: data didn't connect")) }, 10000)
        s.on("connect", function () { clearTimeout(timer); ok(s) })
        s.on("error", function (e) { clearTimeout(timer); fail(e) })
    })
}

function readAll(s) {
    return new Promise(function (ok, fail) {
        var parts = []
        s.on("data", function (d) { parts.push(d) })
        s.on("end", function () { ok(Buffer.concat(parts).toString("utf8")) })
        s.on("error", fail)
    })
}

function path(rest) { return (rest || "").replace(/^\/+|\/+$/g, "") }

/** mlsd lines: "type=dir;size=0;modify=20261107100000; name" */
function parseMlsd(text) {
    return text.split(/\r?\n/).filter(function (l) { return !!l.trim() }).map(function (l) {
        var sp = l.indexOf(" ")
        var facts = {}
        l.slice(0, sp).split(";").forEach(function (f) { var eq = f.indexOf("="); if (eq > 0) facts[f.slice(0, eq).toLowerCase()] = f.slice(eq + 1) })
        var name = l.slice(sp + 1)
        var t = facts.modify || ""
        var mtime = t.length >= 14 ? Math.floor(Date.UTC(+t.slice(0, 4), +t.slice(4, 6) - 1, +t.slice(6, 8), +t.slice(8, 10), +t.slice(10, 12), +t.slice(12, 14)) / 1000) : 0
        var type = (facts.type || "").toLowerCase()
        return { name: name, dir: type === "dir" || type === "cdir" || type === "pdir", size: +(facts.size || 0), mtime: mtime, skip: type === "cdir" || type === "pdir" }
    }).filter(function (e) { return !e.skip })
}

var MONTHS = "jan feb mar apr may jun jul aug sep oct nov dec".split(" ")

/** unix ls lines ("drwxr-xr-x 2 u g 4096 Nov  7 10:00 name") and dos ones ("11-07-26 10:00AM <DIR> name") */
function parseList(text) {
    var out = []
    text.split(/\r?\n/).forEach(function (l) {
        var u = /^([\-dlbcps])[rwxsStT\-]{9}\S*\s+\d+\s+\S+\s+\S+\s+(\d+)\s+(\w{3})\s+(\d{1,2})\s+(\d{1,2}:\d{2}|\d{4})\s+(.+)$/.exec(l)
        if (u) {
            var name = u[6]
            if (u[1] === "l") name = name.replace(/ -> .*$/, "")
            var mon = MONTHS.indexOf(u[3].toLowerCase())
            var year = /:/.test(u[5]) ? new Date().getUTCFullYear() : +u[5]
            var hm = /:/.test(u[5]) ? u[5].split(":") : ["0", "0"]
            out.push({ name: name, dir: u[1] === "d" || u[1] === "l", size: +u[2], mtime: Math.floor(Date.UTC(year, mon, +u[4], +hm[0], +hm[1]) / 1000) })
            return
        }
        var d = /^(\d{2})-(\d{2})-(\d{2,4})\s+(\d{1,2}):(\d{2})(AM|PM)\s+(<DIR>|\d+)\s+(.+)$/i.exec(l)
        if (d) out.push({ name: d[8], dir: d[7].toUpperCase() === "<DIR>", size: d[7].toUpperCase() === "<DIR>" ? 0 : +d[7], mtime: 0 })
    })
    return out.filter(function (e) { return e.name !== "." && e.name !== ".." })
}

function list(share, rest) {
    return connect(share).then(function (c) {
        var p = path(rest)
        var cmd = function (verb, parse) {
            return passive(c, share).then(function (at) {
                return dataConn(at).then(function (d) {
                    var data = readAll(d)
                    return c.send(verb + (p ? " /" + p : "")).then(function (r) {
                        if (r.code >= 400) { d.destroy(); throw FtpError(r.code === 550 ? "notfound" : "unreachable", "ftp: " + r.text) }
                        return data.then(function (t) { return c.next().then(function () { return parse(t) }) })
                    })
                })
            })
        }
        return cmd("MLSD", parseMlsd).catch(function (e) {
            if (e.kind === "notfound") throw e
            return cmd("LIST", parseList)
        }).then(function (l) { c.quit(); return l }, function (e) { c.quit(); throw e })
    })
}

function open(share, rest) {
    var p = path(rest)
    return connect(share).then(function (c) {
        return c.send("SIZE /" + p).then(function (r) {
            c.quit()
            if (r.code !== 213) throw FtpError("notfound", "ftp: " + r.text)
            return {
                size: +r.text.slice(4).trim(),
                stream: function (start, count, onData, onEnd) {
                    var sock = null
                    var ctl = null
                    var stopped = false
                    var left = count
                    var finish = function (e) {
                        if (stopped) return
                        stopped = true
                        if (sock) sock.destroy()
                        if (ctl) { ctl.sock.destroy() }
                        onEnd(e)
                    }
                    connect(share).then(function (cc) {
                        ctl = cc
                        if (stopped) return finish(null)
                        return passive(cc, share).then(function (at) {
                            return (start ? cc.send("REST " + start) : Promise.resolve({ code: 350 })).then(function (r) {
                                if (r.code !== 350) throw FtpError("unreachable", "ftp: no resume: " + r.text)
                                return dataConn(at)
                            })
                        }).then(function (d) {
                            sock = d
                            cc.send("RETR /" + p).then(function (r) { if (r.code >= 400) finish(new Error("ftp: " + r.text)) }, function () { /* closed on purpose */ })
                            d.on("data", function (b) {
                                if (b.length > left) b = b.slice(0, left)
                                left -= b.length
                                if (!onData(b)) d.pause()
                                // the rest isn't wanted: the connection just goes
                                if (!left) finish(null)
                            })
                            d.on("end", function () { finish(left ? new Error("ftp: short") : null) })
                            d.on("error", function (e) { finish(e) })
                        })
                    }).catch(function (e) { finish(e) })
                    return { resume: function () { if (sock) sock.resume() }, stop: function () { finish(null) } }
                },
                close: function () { /* each read logs in itself */ },
            }
        })
    })
}

function explain(e) { return (e && e.kind) || "unreachable" }

module.exports = { list: list, open: open, explain: explain, _test: { parseMlsd: parseMlsd, parseList: parseList } }
