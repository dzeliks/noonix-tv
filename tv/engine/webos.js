// the lg side: a webOS js service (services.json), the app calls its start method; an activity keeps
// it running while it serves (webOS ends idle services after a few seconds)
"use strict"
require("./shim")
var Service = require("webos-service")
var engine = require("./engine")
var service = new Service(__SERVICE_ID__)
var activity = null

service.register("start", function (message) {
    if (!activity) {
        service.activityManager.create("noonix-engine", function (a) { activity = a })
    }
    engine.start({
        version: __VERSION__,
        // MB to keep in memory (the app's low memory mode asks for less)
        cap: message.payload && message.payload.cap,
        onIdle: function () {
            if (activity) service.activityManager.complete(activity, function () {})
            activity = null
        },
    })
    message.respond({ returnValue: true, port: engine.PORT })
})
