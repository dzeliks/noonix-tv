// node before 4.5 (samsung 2017-18 tvs): Buffer.from is Uint8Array's, Buffer.alloc missing
"use strict"
if (Buffer.from === Uint8Array.from || !Buffer.alloc) {
    // the inherited from is read only: defined on Buffer itself
    var put = function (name, fn) { Object.defineProperty(Buffer, name, { value: fn, writable: true, configurable: true }) }
    put("from", function (v, a, b) {
        if (v instanceof ArrayBuffer) return new Buffer(new Uint8Array(v, a || 0, b === undefined ? v.byteLength - (a || 0) : b))
        return new Buffer(v, a)
    })
    put("alloc", function (n, fill, enc) { var b = new Buffer(n); b.fill(fill === undefined ? 0 : fill, 0, n, enc); return b })
    put("allocUnsafe", function (n) { return new Buffer(n) })
    put("allocUnsafeSlow", function (n) { return new Buffer(n) })
}
