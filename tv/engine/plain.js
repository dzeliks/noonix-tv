// the engine on its own (tests on a computer): node engine-plain.js
"use strict"
require("./shim")
// torrent-stream's old new Buffer() calls: fine, but node 10+ says so on every start
process.noDeprecation = true
require("./engine").start({ version: __VERSION__ })
