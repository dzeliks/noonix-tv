// the torrent engine on this tv (tv/engine): a service beside the app, the way stremio runs its
// streaming server on these tvs. started when a torrent source plays; it ends itself once nothing
// has asked it for anything in 10 minutes
import { platform } from "../platform"
import { json } from "./http"
import * as settings from "./settings"
import * as look from "../ui/look"

declare const tizen: any
declare const PalmServiceBridge: any

export const LOCAL = "http://127.0.0.1:11470"
// tools/build.mjs names them
const TIZEN_SERVICE = "Engine"
const WEBOS_SERVICE = "luna://io.github.dzeliks.noonixtv.engine/start"

/** this tv can run the engine itself (a browser can't) */
export function onTv(): boolean {
    return platform.os === "tizen" || platform.os === "webos"
}

/** where torrents play from: the streaming server set in settings, else this tv's engine; "" = nowhere */
export function base(): string {
    return settings.all().server || (onTv() ? LOCAL : "")
}

function answers(): Promise<void> {
    return json({ url: LOCAL + "/settings", timeout: 2, retries: 0 }).then(function () { /* up */ })
}

/** MB the engine keeps in memory: less in low memory mode (older tvs) */
function cap(): number {
    return look.lowMemory ? 96 : 220
}

function launch(): void {
    if (platform.os === "tizen") {
        const pkg = tizen.application.getCurrentApplication().appInfo.packageId
        tizen.application.launchAppControl(new tizen.ApplicationControl("http://tizen.org/appcontrol/operation/service",
            null, null, null, [new tizen.ApplicationControlData("cap", [String(cap())])]),
            pkg + "." + TIZEN_SERVICE, function () { /* started */ }, function (e: any) { console.warn("engine: " + (e && e.message || e)) })
    } else if (platform.os === "webos") {
        const bridge = new PalmServiceBridge()
        bridge.onservicecallback = function (r: string) { if (r.indexOf("\"returnValue\":true") < 0) console.warn("engine: " + r) }
        bridge.call(WEBOS_SERVICE, JSON.stringify({ cap: cap() }))
        // (held: a collected bridge drops the call)
        bridges.push(bridge)
    }
}
const bridges: any[] = []

let starting: Promise<void> | null = null

/** the engine answers before a torrent link of this tv's plays (a server set in settings is the user's to run) */
export function ensure(url: string): Promise<void> {
    if (url.indexOf(LOCAL + "/") !== 0) return Promise.resolve()
    if (starting) return starting
    starting = answers().catch(function () {
        try { launch() } catch (e) { return Promise.reject(new Error("engine can't start: " + e)) }
        // a cold start takes a few seconds on older tvs
        return new Promise<void>(function (ok, fail) {
            let left = 40
            const poll = function () {
                answers().then(ok, function () {
                    if (--left <= 0) fail(new Error("the torrent engine didn't start"))
                    else setTimeout(poll, 500)
                })
            }
            setTimeout(poll, 400)
        })
    })
    const done = function () { starting = null }
    starting.then(done, done)
    return starting
}
