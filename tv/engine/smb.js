// an smb2/3 client for network shares on the tv (the desktop core uses the smb crate): negotiate
// 2.0.2 to 3.1.1, ntlmv2 login (a guest when no name is given), signing, 3.1.1 encryption (aes-gcm),
// the server's shares through srvsvc (ndr, which samba answers too), folders and ranged reads.
// written for the tvs' old node (4.4 on samsung): buffers and callbacks, no newer apis
"use strict"
var net = require("net")
var crypto = require("crypto")
var md4 = require("./md4")

var NEGOTIATE = 0, SESSION_SETUP = 1, TREE_CONNECT = 3, CREATE = 5, CLOSE = 6, READ = 8, IOCTL = 0xb, QUERY_DIRECTORY = 0xe

var ST = {
    OK: 0, PENDING: 0x103, MORE: 0xc0000016, NO_MORE_FILES: 0x80000006, BUFFER_OVERFLOW: 0x80000005,
    END_OF_FILE: 0xc0000011, LOGON_FAILURE: 0xc000006d, ACCESS_DENIED: 0xc0000022, BAD_NETWORK_NAME: 0xc00000cc,
    NOT_FOUND: 0xc0000034, PATH_NOT_FOUND: 0xc000003a, ACCOUNT_DISABLED: 0xc0000072, PASSWORD_EXPIRED: 0xc0000071,
    ACCOUNT_RESTRICTION: 0xc000006e, NOT_A_DIRECTORY: 0xc0000103, FILE_IS_A_DIRECTORY: 0xc00000ba,
    SESSION_EXPIRED: 0xc0000203, USER_SESSION_DELETED: 0xc0000203, NETWORK_NAME_DELETED: 0xc00000c9,
}

function ucs2(s) { return Buffer.from(s, "ucs2") }

function u64(buf, off) { return buf.readUInt32LE(off) + buf.readUInt32LE(off + 4) * 0x100000000 }
function put64(buf, n, off) {
    buf.writeUInt32LE(n % 0x100000000 >>> 0, off)
    buf.writeUInt32LE(Math.floor(n / 0x100000000) >>> 0, off + 4)
}

/** an smb error with the status the server gave */
function SmbError(status, what) {
    var e = new Error((what || "smb") + ": 0x" + (status >>> 0).toString(16))
    e.status = status >>> 0
    return e
}

// ---- crypto bits

function hmac(alg, key, parts) {
    var h = crypto.createHmac(alg, key)
    for (var i = 0; i < parts.length; i++) h.update(parts[i])
    return h.digest()
}

/** sp800-108 counter mode, hmac-sha256, 128 bits: smb 3's keys */
function kdf(key, label, context) {
    var one = Buffer.alloc(4); one.writeUInt32BE(1, 0)
    var bits = Buffer.alloc(4); bits.writeUInt32BE(128, 0)
    return hmac("sha256", key, [one, label, Buffer.alloc(1), context, bits]).slice(0, 16)
}

function dbl(b) {
    var out = Buffer.alloc(16)
    for (var i = 0; i < 16; i++) out[i] = ((b[i] << 1) | (i < 15 ? b[i + 1] >>> 7 : 0)) & 0xff
    if (b[0] & 0x80) out[15] ^= 0x87
    return out
}

/** aes-cmac (rfc 4493): smb 3's signatures */
function cmac(key, msg) {
    var ecb = crypto.createCipheriv("aes-128-ecb", key, Buffer.alloc(0))
    ecb.setAutoPadding(false)
    var L = ecb.update(Buffer.alloc(16))
    var k1 = dbl(L), k2 = dbl(k1)
    var n = Math.max(1, Math.ceil(msg.length / 16))
    var whole = msg.length > 0 && msg.length % 16 === 0
    var last = Buffer.alloc(16)
    msg.copy(last, 0, (n - 1) * 16)
    if (!whole) last[msg.length - (n - 1) * 16] = 0x80
    var k = whole ? k1 : k2
    for (var i = 0; i < 16; i++) last[i] ^= k[i]
    var cbc = crypto.createCipheriv("aes-128-cbc", key, Buffer.alloc(16))
    cbc.setAutoPadding(false)
    var out = Buffer.concat([cbc.update(msg.slice(0, (n - 1) * 16)), cbc.update(last)])
    return out.slice(out.length - 16)
}

/** aes-128-ccm (rfc 3610, 16 byte tag): smb 3.0's encryption. by hand: node has it only from 10 */
function ccm(key, nonce, aad, data, tag) {
    var ecb = crypto.createCipheriv("aes-128-ecb", key, Buffer.alloc(0))
    ecb.setAutoPadding(false)
    var L = 15 - nonce.length
    var ctr0 = Buffer.alloc(16)
    ctr0[0] = L - 1
    nonce.copy(ctr0, 1)
    var s0 = ecb.update(ctr0)
    var ctr1 = Buffer.from(ctr0)
    ctr1[15] = 1
    var ctr = crypto.createCipheriv("aes-128-ctr", key, ctr1)
    var out = ctr.update(data)
    var plain = tag ? out : data
    // cbc-mac over b0, the aad (2 byte length) and the message, each padded to 16
    var b0 = Buffer.alloc(16)
    b0[0] = 0x40 | (((16 - 2) / 2) << 3) | (L - 1)
    nonce.copy(b0, 1)
    b0.writeUInt32BE(plain.length, 12)
    var a = Buffer.alloc(2 + aad.length)
    a.writeUInt16BE(aad.length, 0)
    aad.copy(a, 2)
    var pad = function (b) { return b.length % 16 ? Buffer.concat([b, Buffer.alloc(16 - (b.length % 16))]) : b }
    var cbc = crypto.createCipheriv("aes-128-cbc", key, Buffer.alloc(16))
    cbc.setAutoPadding(false)
    var mac = cbc.update(Buffer.concat([b0, pad(a), pad(plain)]))
    var t = mac.slice(mac.length - 16)
    for (var i = 0; i < 16; i++) t[i] ^= s0[i]
    if (tag) {
        var diff = 0
        for (i = 0; i < 16; i++) diff |= t[i] ^ tag[i]
        if (diff) throw new Error("smb: an encrypted answer didn't check out")
        return out
    }
    return { data: out, tag: t }
}

// ---- ntlm (ms-nlmp), wrapped in spnego

var NTLM_FLAGS = 0x00000001 | 0x00000004 | 0x00000010 | 0x00000200 | 0x00008000 | 0x00080000 | 0x00800000 | 0x02000000 | 0x20000000 | 0x80000000

function ntlmNegotiate() {
    var b = Buffer.alloc(40)
    b.write("NTLMSSP\0", 0, "binary")
    b.writeUInt32LE(1, 8)
    b.writeUInt32LE(NTLM_FLAGS >>> 0, 12)
    // version 10.0 build 19041, ntlm revision 15
    b[32] = 10; b[33] = 0; b.writeUInt16LE(19041, 34); b[39] = 15
    return b
}

function field(buf, off) {
    var len = buf.readUInt16LE(off), at = buf.readUInt32LE(off + 4)
    return buf.slice(at, at + len)
}

function ntlmChallenge(b) {
    if (b.toString("binary", 0, 8) !== "NTLMSSP\0" || b.readUInt32LE(8) !== 2) throw new Error("not an ntlm challenge")
    return { flags: b.readUInt32LE(20), challenge: b.slice(24, 32), info: field(b, 40), raw: b }
}

/** av pairs of the target info: { id: value } */
function avPairs(info) {
    var out = {}, list = []
    for (var at = 0; at + 4 <= info.length;) {
        var id = info.readUInt16LE(at), len = info.readUInt16LE(at + 2)
        if (id === 0) break
        out[id] = info.slice(at + 4, at + 4 + len)
        list.push(id)
        at += 4 + len
    }
    return { map: out, order: list }
}

function filetime() {
    var t = (Date.now() + 11644473600000) * 10000
    var b = Buffer.alloc(8)
    put64(b, t, 0)
    return b
}

/** the authenticate message and the session key; user "" = anonymous */
function ntlmAuthenticate(neg, ch, user, password, domain) {
    var anon = !user
    var lm, nt, sessionKey
    var info = avPairs(ch.info)
    if (anon) {
        lm = Buffer.alloc(1)
        nt = Buffer.alloc(0)
        sessionKey = Buffer.alloc(16)
    } else {
        var ntHash = md4(ucs2(password || ""))
        var ntowf = hmac("md5", ntHash, [ucs2(user.toUpperCase() + domain)])
        var client = crypto.randomBytes(8)
        var stamp = info.map[7] || filetime()
        // the target info as sent, with msvavflags saying a mic follows
        var pairs = []
        var flagsSet = false
        info.order.forEach(function (id) {
            var v = info.map[id]
            if (id === 6) { v = Buffer.from(v); v.writeUInt32LE(v.readUInt32LE(0) | 2, 0); flagsSet = true }
            var head = Buffer.alloc(4); head.writeUInt16LE(id, 0); head.writeUInt16LE(v.length, 2)
            pairs.push(head, v)
        })
        if (!flagsSet) { var fh = Buffer.alloc(8); fh.writeUInt16LE(6, 0); fh.writeUInt16LE(4, 2); fh.writeUInt32LE(2, 4); pairs.push(fh) }
        pairs.push(Buffer.alloc(4))
        var temp = Buffer.concat([Buffer.from([1, 1, 0, 0, 0, 0, 0, 0]), stamp, client, Buffer.alloc(4), Buffer.concat(pairs), Buffer.alloc(4)])
        var proof = hmac("md5", ntowf, [ch.challenge, temp])
        nt = Buffer.concat([proof, temp])
        lm = info.map[7] ? Buffer.alloc(24) : Buffer.concat([hmac("md5", ntowf, [ch.challenge, client]), client])
        sessionKey = hmac("md5", ntowf, [proof])
    }
    var dom = ucs2(anon ? "" : domain), usr = ucs2(user || ""), ws = ucs2("NOONIXTV")
    var flags = (ch.flags & NTLM_FLAGS) | 0x00000001
    if (anon) flags |= 0x00000800
    var payload = [lm, nt, dom, usr, ws, Buffer.alloc(0)]
    var head = Buffer.alloc(88)
    head.write("NTLMSSP\0", 0, "binary")
    head.writeUInt32LE(3, 8)
    var at = 88
    var spots = [12, 20, 28, 36, 44, 52]
    for (var i = 0; i < spots.length; i++) {
        head.writeUInt16LE(payload[i].length, spots[i])
        head.writeUInt16LE(payload[i].length, spots[i] + 2)
        head.writeUInt32LE(at, spots[i] + 4)
        at += payload[i].length
    }
    head.writeUInt32LE(flags >>> 0, 60)
    head[64] = 10; head[65] = 0; head.writeUInt16LE(19041, 66); head[71] = 15
    var msg = Buffer.concat([head].concat(payload))
    if (!anon) hmac("md5", sessionKey, [neg, ch.raw, msg]).copy(msg, 72)
    return { msg: msg, key: sessionKey, anon: anon }
}

// spnego (rfc 4178) around the ntlm tokens: the der by hand, it's two fixed shapes
function der(tag, body) {
    var len = body.length
    var head = len < 0x80 ? Buffer.from([tag, len]) : len < 0x100 ? Buffer.from([tag, 0x81, len]) : Buffer.from([tag, 0x82, len >> 8, len & 0xff])
    return Buffer.concat([head, body])
}
var NTLM_OID = Buffer.from([0x06, 0x0a, 0x2b, 0x06, 0x01, 0x04, 0x01, 0x82, 0x37, 0x02, 0x02, 0x0a])
var SPNEGO_OID = Buffer.from([0x06, 0x06, 0x2b, 0x06, 0x01, 0x05, 0x05, 0x02])

function spnegoInit(token) {
    var mechs = der(0xa0, der(0x30, NTLM_OID))
    var tok = der(0xa2, der(0x04, token))
    return der(0x60, Buffer.concat([SPNEGO_OID, der(0xa0, der(0x30, Buffer.concat([mechs, tok])))]))
}

/** the authenticate token, with the mechlistmic samba asks for once the ntlm message has a mic */
function spnegoResp(token, key) {
    var parts = [der(0xa2, der(0x04, token))]
    if (key) {
        // ntlm signature (ess, no key exchange) over the mech list as sent, sequence 0
        var signKey = crypto.createHash("md5").update(key).update("session key to client-to-server signing key magic constant\0", "binary").digest()
        var seq = Buffer.alloc(4)
        var sig = Buffer.alloc(16)
        sig.writeUInt32LE(1, 0)
        hmac("md5", signKey, [seq, der(0x30, NTLM_OID)]).copy(sig, 4, 0, 8)
        parts.push(der(0xa3, der(0x04, sig)))
    }
    return der(0xa1, der(0x30, Buffer.concat(parts)))
}

/** the ntlm token inside the server's answer (spnego, or raw) */
function unwrap(b) {
    var at = b.indexOf("NTLMSSP\0")
    return at < 0 ? null : b.slice(at)
}

// ---- the connection

var DIALECTS = [0x0202, 0x0210, 0x0300, 0x0302, 0x0311]

function Conn(host, port) {
    this.host = host
    this.port = port || 445
    this.sock = null
    this.buf = Buffer.alloc(0)
    this.mid = 0
    this.credits = 1
    this.waiting = {}          // message id -> { ok, fail }
    this.queue = []            // sends waiting for credits
    this.session = 0
    this.trees = {}            // share name -> { id, encrypt }
    this.dialect = 0
    this.signKey = null
    this.encKey = null
    this.decKey = null
    this.encrypt = false
    this.preauth = null
    this.maxRead = 65536
    this.dead = null
    this.used = Date.now()
}

Conn.prototype.connect = function () {
    var self = this
    return new Promise(function (ok, fail) {
        var sock = net.connect({ host: self.host, port: self.port })
        var timer = setTimeout(function () { sock.destroy(); fail(new Error("smb: no answer")) }, 10000)
        sock.on("connect", function () { clearTimeout(timer); sock.setNoDelay(true); ok() })
        sock.on("data", function (d) { self.onData(d) })
        sock.on("error", function (e) { clearTimeout(timer); self.close(e); fail(e) })
        sock.on("close", function () { self.close(new Error("smb: connection closed")) })
        self.sock = sock
    })
}

Conn.prototype.close = function (err) {
    if (this.dead) return
    this.dead = err || new Error("smb: closed")
    try { this.sock && this.sock.destroy() } catch (e) { /* gone */ }
    var w = this.waiting
    this.waiting = {}
    for (var k in w) w[k].fail(this.dead)
    var q = this.queue
    this.queue = []
    for (var i = 0; i < q.length; i++) q[i].fail(this.dead)
}

Conn.prototype.onData = function (d) {
    this.buf = this.buf.length ? Buffer.concat([this.buf, d]) : d
    while (this.buf.length >= 4) {
        var len = this.buf.readUInt32BE(0) & 0xffffff
        if (this.buf.length < 4 + len) break
        var msg = this.buf.slice(4, 4 + len)
        this.buf = this.buf.slice(4 + len)
        try { this.onMessage(msg) } catch (e) { this.close(e) }
    }
}

Conn.prototype.onMessage = function (msg) {
    if (msg.readUInt32LE(0) === 0x424d53fd) msg = this.decrypt(msg)
    // compounded answers come one after another in one message
    for (var at = 0; ;) {
        var next = msg.readUInt32LE(at + 20)
        var one = next ? msg.slice(at, at + next) : msg.slice(at)
        this.onReply(one)
        if (!next) break
        at += next
    }
}

Conn.prototype.onReply = function (m) {
    if (m.readUInt32LE(0) !== 0x424d53fe) throw new Error("smb: not an smb2 answer")
    var status = m.readUInt32LE(8) >>> 0
    var flags = m.readUInt32LE(16)
    var mid = u64(m, 24)
    this.credits += m.readUInt16LE(14)
    var w = this.waiting[mid]
    if (status === ST.PENDING && (flags & 2)) { this.pump(); return }   // interim: the real answer follows
    if (w) {
        delete this.waiting[mid]
        w.ok({ status: status, head: m.slice(0, 64), body: m.slice(64), raw: m })
    }
    this.pump()
}

/** an encrypted answer (3.1.1 aes-gcm) */
Conn.prototype.decrypt = function (m) {
    if (!this.decKey) throw new Error("smb: the server wants encryption this player can't do")
    if (this.cipher === 1) return ccm(this.decKey, m.slice(20, 31), m.slice(20, 52), m.slice(52), m.slice(4, 20))
    var nonce = m.slice(20, 32)
    var d = crypto.createDecipheriv("aes-128-gcm", this.decKey, nonce)
    d.setAAD(m.slice(20, 52))
    d.setAuthTag(m.slice(4, 20))
    return Buffer.concat([d.update(m.slice(52)), d.final()])
}

Conn.prototype.encryptMsg = function (m) {
    var t = Buffer.alloc(52)
    t.writeUInt32LE(0x424d53fd, 0)
    var nonce = crypto.randomBytes(this.cipher === 1 ? 11 : 12)
    nonce.copy(t, 20)
    t.writeUInt32LE(m.length, 36)
    t.writeUInt16LE(1, 42)
    put64(t, this.session, 44)
    if (this.cipher === 1) {
        var r = ccm(this.encKey, nonce, t.slice(20, 52), m)
        r.tag.copy(t, 4)
        return Buffer.concat([t, r.data])
    }
    var c = crypto.createCipheriv("aes-128-gcm", this.encKey, nonce)
    c.setAAD(t.slice(20, 52))
    var body = Buffer.concat([c.update(m), c.final()])
    c.getAuthTag().copy(t, 4)
    return Buffer.concat([t, body])
}

Conn.prototype.pump = function () {
    while (this.queue.length && this.credits >= this.queue[0].charge) {
        var q = this.queue.shift()
        this.write(q)
    }
}

/** sends one command; charge: credits it takes (big reads), resolves with its answer */
Conn.prototype.send = function (cmd, body, o) {
    var self = this
    o = o || {}
    if (this.dead) return Promise.reject(this.dead)
    this.used = Date.now()
    var charge = this.dialect >= 0x0210 ? Math.max(1, o.charge || 1) : 1
    return new Promise(function (ok, fail) {
        var q = { cmd: cmd, body: body, o: o, charge: charge, ok: ok, fail: fail }
        if (self.credits >= charge && !self.queue.length) self.write(q)
        else self.queue.push(q)
    })
}

Conn.prototype.write = function (q) {
    var mid = this.mid
    this.mid += q.charge
    this.credits -= q.charge
    var h = Buffer.alloc(64)
    h.writeUInt32LE(0x424d53fe, 0)
    h.writeUInt16LE(64, 4)
    h.writeUInt16LE(this.dialect >= 0x0210 ? q.charge : 0, 6)
    h.writeUInt16LE(q.cmd, 12)
    // ask for enough to keep a few big reads going
    h.writeUInt16LE(Math.max(q.charge, 64), 14)
    put64(h, mid, 24)
    h.writeUInt32LE(0xfeff, 32)
    h.writeUInt32LE(q.o.tree || 0, 36)
    put64(h, this.session, 40)
    var msg = Buffer.concat([h, q.body])
    var tree = q.o.treeInfo
    var enc = this.encKey && (this.encrypt || q.o.encrypt || (tree && tree.encrypt)) && q.cmd !== SESSION_SETUP && q.cmd !== NEGOTIATE
    if (!enc && this.signKey && q.cmd !== NEGOTIATE && !q.o.noSign) {
        msg.writeUInt32LE(msg.readUInt32LE(16) | 8, 16)
        var sig = this.dialect >= 0x0300 ? cmac(this.signKey, msg) : hmac("sha256", this.signKey, [msg]).slice(0, 16)
        sig.copy(msg, 48)
    }
    if (q.o.onSent) q.o.onSent(msg)
    var out = enc ? this.encryptMsg(msg) : msg
    var len = Buffer.alloc(4)
    len.writeUInt32BE(out.length, 0)
    this.waiting[mid] = { ok: q.ok, fail: q.fail }
    this.sock.write(Buffer.concat([len, out]))
}

Conn.prototype.hash = function (msg) {
    if (this.preauth) this.preauth = crypto.createHash("sha512").update(this.preauth).update(msg).digest()
}

Conn.prototype.negotiate = function () {
    var self = this
    var b = Buffer.alloc(36 + DIALECTS.length * 2)
    b.writeUInt16LE(36, 0)
    b.writeUInt16LE(DIALECTS.length, 2)
    b.writeUInt16LE(1, 4)
    b.writeUInt32LE(0x40, 8)            // encryption (samba answers the cipher context only then)
    crypto.randomBytes(16).copy(b, 12)
    DIALECTS.forEach(function (d, i) { b.writeUInt16LE(d, 36 + i * 2) })
    // 3.1.1: preauth integrity (sha-512) and encryption (aes-128-gcm) contexts, 8-byte aligned
    var pad = Buffer.alloc((8 - ((64 + b.length) % 8)) % 8)
    var pre = Buffer.alloc(8 + 38)
    pre.writeUInt16LE(1, 0); pre.writeUInt16LE(38, 2)
    pre.writeUInt16LE(1, 8); pre.writeUInt16LE(32, 10); pre.writeUInt16LE(1, 12)
    crypto.randomBytes(32).copy(pre, 14)
    var prePad = Buffer.alloc((8 - (pre.length % 8)) % 8)
    var enc = Buffer.alloc(8 + 6)
    enc.writeUInt16LE(2, 0); enc.writeUInt16LE(6, 2); enc.writeUInt16LE(2, 8); enc.writeUInt16LE(2, 10); enc.writeUInt16LE(1, 12)
    b.writeUInt32LE(64 + b.length + pad.length, 28)
    b.writeUInt16LE(2, 32)
    var body = Buffer.concat([b, pad, pre, prePad, enc])
    this.preauth = Buffer.alloc(64)
    return this.send(NEGOTIATE, body, { onSent: function (m) { self.hash(m) } }).then(function (r) {
        if (r.status !== 0) throw SmbError(r.status, "negotiate")
        var p = r.body
        self.dialect = p.readUInt16LE(4)
        self.signRequired = !!(p.readUInt16LE(2) & 2)
        self.maxRead = Math.min(p.readUInt32LE(32), 1024 * 1024)
        if (self.dialect < 0x0210) self.maxRead = Math.min(self.maxRead, 65536)
        // 3.0 / 3.0.2 encrypt with aes-ccm when the server can
        self.cipher = self.dialect >= 0x0300 && self.dialect < 0x0311 && (p.readUInt32LE(24) & 0x40) ? 1 : 0
        if (self.dialect === 0x0311) {
            self.hash(r.raw)
            var count = p.readUInt16LE(6)
            for (var at = p.readUInt32LE(60) - 64, i = 0; i < count && at + 8 <= p.length; i++) {
                var type = p.readUInt16LE(at), len = p.readUInt16LE(at + 2)
                if (type === 2 && len >= 4) self.cipher = p.readUInt16LE(at + 10) === 2 ? 2 : p.readUInt16LE(at + 10) === 1 ? 1 : 0
                at += 8 + len
                at += (8 - (at % 8)) % 8
            }
        } else {
            self.preauth = null
        }
        var sb = p.readUInt16LE(56) - 64
        return p.slice(sb, sb + p.readUInt16LE(58))
    })
}

Conn.prototype.setup = function (token) {
    var self = this
    var b = Buffer.alloc(24)
    b.writeUInt16LE(25, 0)
    b[3] = 1
    b.writeUInt16LE(64 + 24, 12)
    b.writeUInt16LE(token.length, 14)
    // 3.1.1's keys come from the hash right after the last login request
    var sent = function (m) { self.hash(m); self.preauthAtAuth = self.preauth }
    return this.send(SESSION_SETUP, Buffer.concat([b, token]), { noSign: true, onSent: sent }).then(function (r) {
        if (r.status !== 0 && r.status !== ST.MORE) throw SmbError(r.status, "login")
        if (r.status === ST.MORE) self.hash(r.raw)
        self.session = u64(r.head, 40)
        var off = r.body.readUInt16LE(4) - 64
        return { status: r.status, flags: r.body.readUInt16LE(2), token: r.body.slice(off, off + r.body.readUInt16LE(6)) }
    })
}

/** user "" = a guest login (as the desktop: "Guest" with no password, then anonymous) */
Conn.prototype.login = function (user, password) {
    var self = this
    var domain = ""
    var name = user || ""
    var slash = name.indexOf("\\")
    if (slash > 0) { domain = name.slice(0, slash); name = name.slice(slash + 1) }
    var at = name.indexOf("@")
    if (at > 0 && !domain) { domain = name.slice(at + 1); name = name.slice(0, at) }
    var neg = ntlmNegotiate()
    return this.setup(spnegoInit(neg)).then(function (r) {
        var t = unwrap(r.token)
        if (!t) throw new Error("smb: no ntlm challenge")
        var auth = ntlmAuthenticate(neg, ntlmChallenge(t), name || "Guest", password || "", domain)
        return self.setup(spnegoResp(auth.msg, auth.key)).then(function (r2) {
            self.keys(auth.key, !!(r2.flags & 3), r2.flags)
            return r2
        })
    })
}

Conn.prototype.keys = function (key, guest, flags) {
    this.guest = guest
    this.encrypt = !!(flags & 4)
    if (guest) return
    if (this.dialect >= 0x0300) {
        var ctx = this.dialect === 0x0311 ? this.preauthAtAuth : null
        if (this.dialect === 0x0311) {
            this.signKey = kdf(key, Buffer.from("SMBSigningKey\0", "binary"), ctx)
            if (this.cipher) {
                this.encKey = kdf(key, Buffer.from("SMBC2SCipherKey\0", "binary"), ctx)
                this.decKey = kdf(key, Buffer.from("SMBS2CCipherKey\0", "binary"), ctx)
            }
        } else {
            this.signKey = kdf(key, Buffer.from("SMB2AESCMAC\0", "binary"), Buffer.from("SmbSign\0", "binary"))
            if (this.cipher) {
                this.encKey = kdf(key, Buffer.from("SMB2AESCCM\0", "binary"), Buffer.from("ServerIn \0", "binary"))
                this.decKey = kdf(key, Buffer.from("SMB2AESCCM\0", "binary"), Buffer.from("ServerOut\0", "binary"))
            }
        }
    } else {
        this.signKey = key
    }
    if (this.encrypt && !this.encKey) throw new Error("smb: the server wants encryption this player can't do (ask it for smb 3.1.1)")
}

Conn.prototype.tree = function (share) {
    var self = this
    var have = this.trees[share.toLowerCase()]
    if (have) return Promise.resolve(have)
    var path = ucs2("\\\\" + this.host + "\\" + share)
    var b = Buffer.alloc(8)
    b.writeUInt16LE(9, 0)
    b.writeUInt16LE(72, 4)
    b.writeUInt16LE(path.length, 6)
    var ask = function (encrypt) {
        return self.send(TREE_CONNECT, Buffer.concat([b, path]), { encrypt: encrypt }).then(function (r) {
            // a share that wants encryption may refuse a plain connect (or say nothing, below)
            if (r.status === ST.ACCESS_DENIED && !encrypt && self.encKey) return ask(true)
            return r
        })
    }
    return ask(false).then(function (r) {
        if (r.status !== 0) throw SmbError(r.status, "share " + share)
        var t = { id: r.head.readUInt32LE(36), encrypt: !!(r.body.readUInt32LE(4) & 0x8) }
        if (t.encrypt && !self.encKey) throw new Error("smb: the share wants encryption this player can't do (ask it for smb 3.1.1)")
        self.trees[share.toLowerCase()] = t
        return t
    })
}

/** opens a file, folder or pipe: { id (16 bytes), size, dir } */
Conn.prototype.create = function (tree, name, kind) {
    var self = this
    var n = ucs2(name.replace(/\//g, "\\"))
    var b = Buffer.alloc(56)
    b.writeUInt16LE(57, 0)
    b.writeUInt32LE(2, 4)
    b.writeUInt32LE(kind === "dir" ? 0x00100081 : kind === "pipe" ? 0x0012019f : 0x00120089, 24)
    b.writeUInt32LE(7, 32)
    b.writeUInt32LE(1, 36)
    b.writeUInt32LE(kind === "dir" ? 0x1 : kind === "file" ? 0x40 : 0, 40)
    b.writeUInt16LE(120, 44)
    b.writeUInt16LE(n.length, 46)
    var name0 = n.length ? n : Buffer.alloc(1)
    return this.send(CREATE, Buffer.concat([b, name0]), { tree: tree.id, treeInfo: tree }).then(function (r) {
        // samba's "smb encrypt = required" share: no flag on the connect, plain requests refused
        if (r.status === ST.ACCESS_DENIED && self.encKey && !tree.encrypt && !self.encrypt) {
            tree.encrypt = true
            return self.create(tree, name, kind)
        }
        if (r.status !== 0) throw SmbError(r.status, "open " + name)
        var p = r.body
        return { id: p.slice(64, 80), size: u64(p, 48), dir: !!(p.readUInt32LE(56) & 0x10), mtime: u64(p, 24) }
    })
}

Conn.prototype.closeFile = function (tree, id) {
    var b = Buffer.alloc(24)
    b.writeUInt16LE(24, 0)
    id.copy(b, 8)
    return this.send(CLOSE, b, { tree: tree.id, treeInfo: tree }).then(function () { /* closed */ }, function () { /* gone */ })
}

Conn.prototype.read = function (tree, id, offset, length) {
    var b = Buffer.alloc(49)
    b.writeUInt16LE(49, 0)
    b[2] = 0x50
    b.writeUInt32LE(length, 4)
    put64(b, offset, 8)
    id.copy(b, 16)
    return this.send(READ, b, { tree: tree.id, treeInfo: tree, charge: Math.ceil(length / 65536) }).then(function (r) {
        if (r.status === ST.END_OF_FILE) return Buffer.alloc(0)
        if (r.status !== 0) throw SmbError(r.status, "read")
        var off = r.body[2] - 64
        return r.body.slice(off, off + r.body.readUInt32LE(4))
    })
}

/** a folder's entries: { name, dir, size, mtime (unix s) } */
Conn.prototype.list = function (tree, id) {
    var self = this
    var out = []
    var first = true
    function more() {
        var pattern = ucs2("*")
        var b = Buffer.alloc(32)
        b.writeUInt16LE(33, 0)
        b[2] = 0x01                    // file directory information
        b[3] = first ? 0x01 : 0        // restart
        first = false
        id.copy(b, 8)
        b.writeUInt16LE(96, 24)
        b.writeUInt16LE(pattern.length, 26)
        b.writeUInt32LE(65536, 28)
        return self.send(QUERY_DIRECTORY, Buffer.concat([b, pattern]), { tree: tree.id, treeInfo: tree }).then(function (r) {
            if (r.status === ST.NO_MORE_FILES) return out
            if (r.status !== 0) throw SmbError(r.status, "list")
            var off = r.body.readUInt16LE(2) - 64
            var data = r.body.slice(off, off + r.body.readUInt32LE(4))
            for (var at = 0; at < data.length;) {
                var next = data.readUInt32LE(at)
                var nlen = data.readUInt32LE(at + 60)
                var name = data.toString("ucs2", at + 64, at + 64 + nlen)
                var t = u64(data, at + 24)
                out.push({ name: name, dir: !!(data.readUInt32LE(at + 56) & 0x10), size: u64(data, at + 40),
                    mtime: t ? Math.floor(t / 10000000 - 11644473600) : 0 })
                if (!next) break
                at += next
            }
            return more()
        })
    }
    return more()
}

/** fsctl pipe transceive: one rpc message in, the answer out (with what's left read after) */
Conn.prototype.transceive = function (tree, id, data) {
    var self = this
    var b = Buffer.alloc(56)
    b.writeUInt16LE(57, 0)
    b.writeUInt32LE(0x0011c017, 4)
    id.copy(b, 8)
    b.writeUInt32LE(120, 24)
    b.writeUInt32LE(data.length, 28)
    b.writeUInt32LE(65536, 44)
    b.writeUInt32LE(1, 48)
    return this.send(IOCTL, Buffer.concat([b, data]), { tree: tree.id, treeInfo: tree, charge: 1 }).then(function (r) {
        if (r.status !== 0 && r.status !== ST.BUFFER_OVERFLOW) throw SmbError(r.status, "rpc")
        var off = r.body.readUInt32LE(32) - 64
        var out = r.body.slice(off, off + r.body.readUInt32LE(36))
        if (r.status !== ST.BUFFER_OVERFLOW) return out
        // the rest of a long answer: read from the pipe
        var parts = [out]
        function rest() {
            return self.read(tree, id, 0, 65536).then(function (more) {
                parts.push(more)
                var all = Buffer.concat(parts)
                var want = all.length >= 10 ? all.readUInt16LE(8) : Infinity
                return more.length && all.length < want ? rest() : all
            })
        }
        return rest()
    })
}

// ---- srvsvc: the server's shares (ndr 2.0, not ndr64: samba answers this one)

function uuid(s) {
    var h = s.replace(/-/g, "")
    var b = Buffer.from(h, "hex")
    var out = Buffer.alloc(16)
    out.writeUInt32LE(b.readUInt32BE(0), 0)
    out.writeUInt16LE(b.readUInt16BE(4), 4)
    out.writeUInt16LE(b.readUInt16BE(6), 6)
    b.copy(out, 8, 8)
    return out
}

function rpcHead(type, callId, body) {
    var h = Buffer.alloc(16)
    h[0] = 5; h[1] = 0; h[2] = type; h[3] = 3
    h[4] = 0x10
    h.writeUInt16LE(16 + body.length, 8)
    h.writeUInt32LE(callId, 12)
    return Buffer.concat([h, body])
}

function rpcBind() {
    var b = Buffer.alloc(12 + 44)
    b.writeUInt16LE(4280, 0); b.writeUInt16LE(4280, 2)
    b[8] = 1
    b.writeUInt16LE(0, 12); b[14] = 1
    uuid("4b324fc8-1670-01d3-1278-5a47bf6ee188").copy(b, 16)
    b.writeUInt16LE(3, 32)
    uuid("8a885d04-1ceb-11c9-9fe8-08002b104860").copy(b, 36)
    b.writeUInt32LE(2, 52)
    return rpcHead(11, 1, b)
}

function ndrString(s) {
    var chars = ucs2(s + "\0")
    var n = chars.length / 2
    var h = Buffer.alloc(12)
    h.writeUInt32LE(n, 0); h.writeUInt32LE(0, 4); h.writeUInt32LE(n, 8)
    var pad = Buffer.alloc((4 - (chars.length % 4)) % 4)
    return Buffer.concat([h, chars, pad])
}

function rpcShareEnum(host) {
    var ref = Buffer.alloc(4); ref.writeUInt32LE(0x20000, 0)
    var name = ndrString(host)
    var rest = Buffer.alloc(28)
    rest.writeUInt32LE(1, 0)            // level
    rest.writeUInt32LE(1, 4)            // union switch
    rest.writeUInt32LE(0x20004, 8)      // container
    rest.writeUInt32LE(0, 12)           // entries read
    rest.writeUInt32LE(0, 16)           // buffer: null
    rest.writeUInt32LE(0xffffffff, 20)  // preferred max length
    rest.writeUInt32LE(0x20008, 24)     // resume handle pointer
    var stub = Buffer.concat([ref, name, rest, Buffer.alloc(4)])
    var r = Buffer.alloc(8)
    r.writeUInt32LE(stub.length, 0)
    r.writeUInt16LE(0, 4)
    r.writeUInt16LE(15, 6)              // NetrShareEnum
    return rpcHead(0, 2, Buffer.concat([r, stub]))
}

function parseShares(resp) {
    if (resp[2] !== 2) throw new Error("smb: share list refused")
    var s = resp.slice(24)
    var at = 0
    function u32() { var v = s.readUInt32LE(at); at += 4; return v }
    function str() {
        var max = u32(); u32(); var n = u32()
        void max
        var t = s.toString("ucs2", at, at + n * 2).replace(/\0+$/, "")
        at += n * 2
        at += (4 - (at % 4)) % 4
        return t
    }
    u32(); u32()                        // level, switch
    if (!u32()) return []               // container pointer
    var count = u32()
    if (!u32()) return []               // array pointer
    u32()                               // max count
    var entries = []
    for (var i = 0; i < count; i++) entries.push({ name: u32(), type: u32(), remark: u32() })
    var out = []
    entries.forEach(function (e) {
        var name = e.name ? str() : ""
        if (e.remark) str()
        if ((e.type & 0xff) === 0 && !(e.type & 0x80000000) && name && name.slice(-1) !== "$") out.push(name)
    })
    return out
}

Conn.prototype.shares = function () {
    var self = this
    return this.tree("IPC$").then(function (t) {
        return self.create(t, "srvsvc", "pipe").then(function (f) {
            return self.transceive(t, f.id, rpcBind()).then(function (ack) {
                if (ack[2] !== 12) throw new Error("smb: share list refused")
                return self.transceive(t, f.id, rpcShareEnum(self.host))
            }).then(function (r) {
                self.closeFile(t, f.id)
                return parseShares(r)
            }, function (e) { self.closeFile(t, f.id); throw e })
        })
    })
}

// ---- the clients, one per share (login), let go after a minute unused

var clients = {}

// the password is part of it: one that changed logs in again
function key(share) {
    var pw = crypto.createHash("sha256").update(share.password || "").digest("hex").slice(0, 16)
    return (share.id || share.host + ":" + (share.port || 445) + ":" + share.user) + ":" + pw
}

function client(share) {
    var k = key(share)
    var c = clients[k]
    if (c && !c.conn.dead) return c.ready
    var conn = new Conn(share.host, share.port)
    var ready = conn.connect().then(function () { return conn.negotiate() }).then(function () {
        var user = share.user || ""
        return conn.login(user, share.password || "").catch(function (e) {
            // a guest that's refused: anonymous
            if (user || e.status !== ST.LOGON_FAILURE) throw e
            conn.close()
            return null
        })
    }).then(function (r) {
        if (r === null) return anonymous(share)
        return conn
    })
    clients[k] = { conn: conn, ready: ready }
    ready.catch(function () { if (clients[k] && clients[k].conn === conn) delete clients[k] })
    return ready
}

function anonymous(share) {
    var conn = new Conn(share.host, share.port)
    return conn.connect().then(function () { return conn.negotiate() }).then(function () {
        var neg = ntlmNegotiate()
        return conn.setup(spnegoInit(neg)).then(function (r) {
            var ch = ntlmChallenge(unwrap(r.token))
            return conn.setup(spnegoResp(ntlmAuthenticate(neg, ch, "", "", "").msg))
        })
    }).then(function (r) {
        conn.keys(Buffer.alloc(16), true, r.flags)
        clients[key(share)] = { conn: conn, ready: Promise.resolve(conn) }
        return conn
    })
}

setInterval(function () {
    var now = Date.now()
    for (var k in clients) {
        var c = clients[k].conn
        if (c.dead || (now - c.used > 60000 && !Object.keys(c.waiting).length)) { c.close(); delete clients[k] }
    }
}, 30000).unref()

function forget(share) {
    var k = key(share)
    if (clients[k]) { clients[k].conn.close(); delete clients[k] }
}

/** "Media/Movies/x.mkv" -> share "Media", path "Movies\x.mkv" */
function parts(rest) {
    var r = (rest || "").replace(/^\/+|\/+$/g, "")
    var at = r.indexOf("/")
    if (!r) return { share: "", path: "" }
    return at < 0 ? { share: r, path: "" } : { share: r.slice(0, at), path: r.slice(at + 1) }
}

/** with one retry on a dropped or expired session */
function withConn(share, fn) {
    return client(share).then(fn).catch(function (e) {
        var again = !e.status || e.status === ST.SESSION_EXPIRED || e.status === ST.NETWORK_NAME_DELETED
        if (!again || /no answer|ECONNREFUSED|EHOSTUNREACH|ENOTFOUND/.test(String(e.message))) throw e
        forget(share)
        return client(share).then(fn)
    })
}

/** a folder of the share, or the server's shares for "" */
function list(share, rest) {
    var p = parts(rest)
    return withConn(share, function (c) {
        if (!p.share) return c.shares().then(function (names) { return names.map(function (n) { return { name: n, dir: true, size: 0, mtime: 0 } }) })
        return c.tree(p.share).then(function (t) {
            return c.create(t, p.path, "dir").then(function (f) {
                return c.list(t, f.id).then(function (l) { c.closeFile(t, f.id); return l }, function (e) { c.closeFile(t, f.id); throw e })
            })
        })
    })
}

/** an open file: { size, read(offset, length) -> Promise<Buffer>, block, close() } */
function open(share, rest) {
    var p = parts(rest)
    if (!p.share || !p.path) return Promise.reject(SmbError(ST.NOT_FOUND, "open"))
    return withConn(share, function (c) {
        return c.tree(p.share).then(function (t) {
            return c.create(t, p.path, "file").then(function (f) {
                if (f.dir) { c.closeFile(t, f.id); throw SmbError(ST.FILE_IS_A_DIRECTORY, "open") }
                return {
                    size: f.size, block: c.maxRead,
                    read: function (offset, length) { return c.read(t, f.id, offset, length) },
                    close: function () { c.closeFile(t, f.id) },
                }
            })
        })
    })
}

/** what to tell the user about an error */
function explain(e) {
    var s = e && e.status
    if (s === ST.LOGON_FAILURE || s === ST.ACCESS_DENIED || s === ST.ACCOUNT_DISABLED || s === ST.ACCOUNT_RESTRICTION || s === ST.PASSWORD_EXPIRED) return "login"
    if (s === ST.BAD_NETWORK_NAME) return "noshare"
    if (s === ST.NOT_FOUND || s === ST.PATH_NOT_FOUND || s === ST.NOT_A_DIRECTORY) return "notfound"
    if (e && /encryption/.test(String(e.message))) return "encryption"
    if (e && /share list refused/.test(String(e.message))) return "nolist"
    return "unreachable"
}

module.exports = { _Conn: Conn, list: list, open: open, forget: forget, explain: explain, _test: { ccm: ccm, cmac: cmac, kdf: kdf, parseShares: parseShares, md4: md4, ntlmAuthenticate: ntlmAuthenticate } }
