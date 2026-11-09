// the samsung side: a tizen web service (config.xml <tizen:service>), started by the app on demand
"use strict"
require("./shim")
var engine = require("./engine")
var started = false

// what the app sent with the launch: cap = MB to keep in memory
function asked(key) {
    try {
        var data = tizen.application.getCurrentApplication().getRequestedAppControl().appControl.data
        for (var i = 0; i < data.length; i++) if (data[i].key === key) return data[i].value[0]
    } catch (e) { /* started without */ }
    return undefined
}

function go() {
    var cap = asked("cap")
    if (started) return engine.start({ cap: cap, version: __VERSION__ })
    started = true
    engine.start({
        version: __VERSION__,
        cap: cap,
        // nothing asked for a while: the service ends (the app starts it again when it needs it)
        onIdle: function () {
            try { tizen.application.getCurrentApplication().exit() } catch (e) { process.exit(0) }
        },
    })
}

module.exports.onStart = go
module.exports.onRequest = go
module.exports.onExit = function () { engine.stop() }
