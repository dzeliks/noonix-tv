// the pieces a peer has, one bit each, highest bit first (as the protocol sends them). stands in for
// the "bitfield" package torrent-stream asks for, whose 0.1.0 states no license
"use strict"

function Bitfield(data) {
    if (!(this instanceof Bitfield)) return new Bitfield(data)
    if (typeof data === "number") {
        // (shim.js gives old node its Buffer.alloc)
        data = Buffer.alloc(Math.ceil(data / 8))
    }
    this.buffer = data
}

Bitfield.prototype.get = function (i) {
    return !!(this.buffer[i >> 3] & (128 >> (i & 7)))
}

Bitfield.prototype.set = function (i, on) {
    if (on || arguments.length === 1) this.buffer[i >> 3] |= 128 >> (i & 7)
    else this.buffer[i >> 3] &= ~(128 >> (i & 7))
}

module.exports = Bitfield
