// md4 (rfc 1320) for ntlm's password hash: openssl 3 dropped it, so newer node has none, and a tv's
// old node may not either
"use strict"

function rotl(x, n) { return (x << n) | (x >>> (32 - n)) }

module.exports = function md4(data) {
    var len = data.length
    var words = ((len + 8) >>> 6) + 1
    var m = new Array(words * 16)
    for (var i = 0; i < m.length; i++) m[i] = 0
    for (i = 0; i < len; i++) m[i >> 2] |= data[i] << ((i % 4) * 8)
    m[len >> 2] |= 0x80 << ((len % 4) * 8)
    m[words * 16 - 2] = (len * 8) >>> 0
    m[words * 16 - 1] = Math.floor(len / 0x20000000)
    var a = 0x67452301, b = 0xefcdab89, c = 0x98badcfe, d = 0x10325476
    var F = function (x, y, z) { return (x & y) | (~x & z) }
    var G = function (x, y, z) { return (x & y) | (x & z) | (y & z) }
    var H = function (x, y, z) { return x ^ y ^ z }
    for (var k = 0; k < m.length; k += 16) {
        var aa = a, bb = b, cc = c, dd = d
        var X = m.slice(k, k + 16)
        var r1 = [3, 7, 11, 19]
        for (i = 0; i < 16; i++) {
            var t = (a + F(b, c, d) + X[i]) | 0
            a = d; d = c; c = b; b = rotl(t, r1[i % 4])
        }
        var r2 = [3, 5, 9, 13], o2 = [0, 4, 8, 12, 1, 5, 9, 13, 2, 6, 10, 14, 3, 7, 11, 15]
        for (i = 0; i < 16; i++) {
            t = (a + G(b, c, d) + X[o2[i]] + 0x5a827999) | 0
            a = d; d = c; c = b; b = rotl(t, r2[i % 4])
        }
        var r3 = [3, 9, 11, 15], o3 = [0, 8, 4, 12, 2, 10, 6, 14, 1, 9, 5, 13, 3, 11, 7, 15]
        for (i = 0; i < 16; i++) {
            t = (a + H(b, c, d) + X[o3[i]] + 0x6ed9eba1) | 0
            a = d; d = c; c = b; b = rotl(t, r3[i % 4])
        }
        a = (a + aa) | 0; b = (b + bb) | 0; c = (c + cc) | 0; d = (d + dd) | 0
    }
    var out = Buffer.alloc(16)
    out.writeInt32LE(a, 0); out.writeInt32LE(b, 4); out.writeInt32LE(c, 8); out.writeInt32LE(d, 12)
    return out
}
