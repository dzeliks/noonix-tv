// the engine's share protocols: smb's crypto against node's and the rfc vectors, the folder listings
import test from "node:test"
import assert from "node:assert/strict"
import crypto from "node:crypto"
import { createRequire } from "node:module"

const require = createRequire(import.meta.url)
const smb = require("../engine/smb.js")
const dav = require("../engine/dav.js")
const ftp = require("../engine/ftp.js")
const md4 = require("../engine/md4.js")

test("md4 (rfc 1320)", function () {
    assert.equal(md4(Buffer.from("")).toString("hex"), "31d6cfe0d16ae931b73c59d7e0c089c0")
    assert.equal(md4(Buffer.from("abc")).toString("hex"), "a448017aaf21d8525fc10ae87aa6729d")
    assert.equal(md4(Buffer.from("12345678901234567890123456789012345678901234567890123456789012345678901234567890")).toString("hex"), "e33b4ddc9c38f2199c3e7b164fcc0536")
})

test("aes-cmac (rfc 4493)", function () {
    const key = Buffer.from("2b7e151628aed2a6abf7158809cf4f3c", "hex")
    assert.equal(smb._test.cmac(key, Buffer.alloc(0)).toString("hex"), "bb1d6929e95937287fa37d129b756746")
    assert.equal(smb._test.cmac(key, Buffer.from("6bc1bee22e409f96e93d7e117393172a", "hex")).toString("hex"), "070a16b46b4d4144f79bdd9dd04a287c")
})

test("aes-ccm as node's", function () {
    const key = crypto.randomBytes(16), nonce = crypto.randomBytes(11), aad = crypto.randomBytes(52)
    for (const n of [0, 1, 16, 1000, 65537]) {
        const data = crypto.randomBytes(n)
        const c = crypto.createCipheriv("aes-128-ccm", key, nonce, { authTagLength: 16 })
        c.setAAD(aad, { plaintextLength: n })
        const want = Buffer.concat([c.update(data), c.final()])
        const got = smb._test.ccm(key, nonce, aad, data)
        assert.ok(got.data.equals(want) && got.tag.equals(c.getAuthTag()), "ccm " + n)
        assert.ok(smb._test.ccm(key, nonce, aad, got.data, got.tag).equals(data))
    }
})

test("webdav listing", function () {
    const xml = `<?xml version="1.0"?><D:multistatus xmlns:D="DAV:">
      <D:response><D:href>/dav/Movies/</D:href><D:propstat><D:prop><D:resourcetype><D:collection xmlns:D="DAV:"/></D:resourcetype></D:prop></D:propstat></D:response>
      <D:response><D:href>/dav/Movies/Sintel%20(2010)/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response>
      <D:response><D:href>http://h/dav/Movies/a%20b&amp;c.mkv</D:href><D:propstat><D:prop><D:resourcetype/><D:getcontentlength>123</D:getcontentlength>
        <D:getlastmodified>Sat, 07 Nov 2026 10:00:00 GMT</D:getlastmodified></D:prop></D:propstat></D:response></D:multistatus>`
    const r = dav._test.parse(xml)
    assert.equal(r.length, 3)
    assert.deepEqual([r[1].name, r[1].dir], ["Sintel (2010)", true])
    assert.deepEqual([r[2].name, r[2].dir, r[2].size], ["a b&c.mkv", false, 123])
    assert.ok(r[2].mtime > 0)
})

test("ftp listings", function () {
    const m = ftp._test.parseMlsd("type=cdir;modify=20261107100000; .\r\ntype=dir;modify=20261107100000; Movies\r\ntype=file;size=31457280;modify=20261107100000; a b.mkv\r\n")
    assert.deepEqual(m.map(function (e) { return [e.name, e.dir, e.size] }), [["Movies", true, 0], ["a b.mkv", false, 31457280]])
    assert.equal(m[1].mtime, Date.UTC(2026, 10, 7, 10) / 1000)
    const l = ftp._test.parseList("drwxr-xr-x    2 ftp      ftp          4096 Nov  7 10:00 Movies\r\n-rw-r--r--    1 ftp      ftp      31457280 Jan 02  2024 Sintel (2010).mkv\r\n11-07-26  10:00AM       <DIR>          Shows\r\n11-07-26  10:00AM             12345678 x y.mp4\r\n")
    assert.deepEqual(l.map(function (e) { return [e.name, e.dir, e.size] }), [["Movies", true, 4096], ["Sintel (2010).mkv", false, 31457280], ["Shows", true, 0], ["x y.mp4", false, 12345678]])
})
