// which tv this is: lg webOS, samsung tizen, or a desktop browser (development)

export type Os = "webos" | "tizen" | "browser"

export interface Platform {
    os: Os
    /** the tv os version: webOS 4.5 -> 4, webOS 24 -> 24, tizen 6.5 -> 6.5; 0 in a browser */
    version: number
    /** the web engine's chromium version (0 when unknown) */
    chrome: number
    /** older tvs have little memory: low memory mode starts on there, without asking */
    lowMemoryDefault: boolean
    label: string
}

// webOS tv versions by their engine (lg's tables): 4.x and 4.5 share chromium 53
const webosByChrome: [number, number][] = [[120, 25], [108, 24], [94, 23], [87, 22], [79, 6], [68, 5], [53, 4], [38, 3]]

declare const tizen: any
declare const webOS: any

function detect(): Platform {
    const ua = navigator.userAgent
    const m = /Chrome\/(\d+)/.exec(ua)
    const chrome = m ? parseInt(m[1], 10) : 0
    if (/Tizen/.test(ua) || typeof tizen !== "undefined") {
        const v = /Tizen (\d+(?:\.\d+)?)/.exec(ua)
        const version = v ? parseFloat(v[1]) : 0
        return { os: "tizen", version, chrome, lowMemoryDefault: version < 7, label: "Tizen " + (version || "?") }
    }
    if (/Web0S|webOS/.test(ua) || typeof webOS !== "undefined") {
        let version = 0
        for (let i = 0; i < webosByChrome.length; i++) {
            if (chrome >= webosByChrome[i][0]) { version = webosByChrome[i][1]; break }
        }
        // a newer engine than the table knows: a newer tv
        if (chrome > webosByChrome[0][0]) version = 26
        return { os: "webos", version, chrome, lowMemoryDefault: version < 23, label: "webOS " + (version || "?") }
    }
    return { os: "browser", version: 0, chrome, lowMemoryDefault: false, label: "browser" }
}

export const platform = detect()

/** asks the tv for the remote's media and colour keys (tizen sends only the arrows, ok and back otherwise) */
export function registerKeys(): void {
    if (platform.os !== "tizen") return
    const keys = ["MediaPlayPause", "MediaPlay", "MediaPause", "MediaStop", "MediaRewind", "MediaFastForward",
        "MediaTrackPrevious", "MediaTrackNext", "ColorF0Red", "ColorF1Green", "ColorF2Yellow", "ColorF3Blue",
        "ChannelUp", "ChannelDown", "Info"]
    try {
        const input = tizen.tvinputdevice
        const have: string[] = input.getSupportedKeys().map(function (k: { name: string }) { return k.name })
        const want = keys.filter(function (k) { return have.indexOf(k) >= 0 })
        if (input.registerKeyBatch) input.registerKeyBatch(want)
        else want.forEach(function (k) { input.registerKey(k) })
    } catch (e) {
        console.warn("keys: " + e)
    }
}

/** leaves the app (the tv's home or last input comes back) */
export function exitApp(): void {
    try {
        if (platform.os === "tizen") { tizen.application.getCurrentApplication().exit(); return }
        if (platform.os === "webos" && typeof webOS !== "undefined" && webOS.platformBack) { webOS.platformBack(); return }
    } catch (e) {
        console.warn("exit: " + e)
    }
    window.close()
}

/** samsung's screensaver stays away while a video plays (lg's player holds it off by itself).
 * webapis.js comes from the tv's runtime, loaded once here */
let webapisAsked = false
export function keepAwake(on: boolean): void {
    if (platform.os !== "tizen") return
    const w = (window as any).webapis
    if (!w && !webapisAsked) {
        webapisAsked = true
        const s = document.createElement("script")
        s.src = "$WEBAPIS/webapis/webapis.js"
        s.onload = function () { keepAwake(on) }
        document.head.appendChild(s)
        return
    }
    try {
        const c = w && w.appcommon
        if (c) c.setScreenSaver(on ? c.AppCommonScreenSaverState.SCREEN_SAVER_OFF : c.AppCommonScreenSaverState.SCREEN_SAVER_ON)
    } catch (e) {
        console.warn("screensaver: " + e)
    }
}
