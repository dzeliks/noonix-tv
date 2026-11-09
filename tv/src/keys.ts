// the remote's keys as actions, like the other clients: ok held = menu (the lg and samsung remotes
// have no menu key the app gets), back held = leave

export type Action = "up" | "down" | "left" | "right" | "ok" | "back" | "menu" | "leave"
    | "playpause" | "play" | "pause" | "stop" | "rewind" | "forward" | "next" | "previous"
    | "red" | "green" | "yellow" | "blue" | "pageup" | "pagedown" | "info"

export const holdMs = 650

// keyCode -> action: the dom codes, webOS (back 461) and tizen (back 10009, media 10252)
const codes: { [code: number]: Action } = {
    37: "left", 38: "up", 39: "right", 40: "down", 13: "ok",
    461: "back", 10009: "back", 27: "back", 8: "back",
    415: "play", 19: "pause", 10252: "playpause", 413: "stop", 412: "rewind", 417: "forward",
    10232: "previous", 10233: "next",
    403: "red", 404: "green", 405: "yellow", 406: "blue",
    33: "pageup", 34: "pagedown", 427: "pageup", 428: "pagedown",
    457: "info", 77: "menu", 93: "menu", 32: "playpause"
}

type Handler = (action: Action, repeat: boolean) => void

/** listens on the document and calls back with actions; ok and back wait for their release */
export function listen(handler: Handler): void {
    let okTimer = 0
    let okHeld = false
    let okDown = false
    let backTimer = 0
    let backHeld = false
    let backDown = false

    document.addEventListener("keydown", function (e: KeyboardEvent) {
        const action = codes[e.keyCode]
        if (!action) return
        e.preventDefault()
        if (action === "ok") {
            if (okDown) return
            okDown = true
            okHeld = false
            okTimer = window.setTimeout(function () { okHeld = true; handler("menu", false) }, holdMs)
            return
        }
        if (action === "back") {
            if (backDown) return
            backDown = true
            backHeld = false
            backTimer = window.setTimeout(function () { backHeld = true; handler("leave", false) }, holdMs)
            return
        }
        handler(action, e.repeat)
    }, true)

    document.addEventListener("keyup", function (e: KeyboardEvent) {
        const action = codes[e.keyCode]
        if (action === "ok" && okDown) {
            okDown = false
            clearTimeout(okTimer)
            if (!okHeld) handler("ok", false)
        } else if (action === "back" && backDown) {
            backDown = false
            clearTimeout(backTimer)
            if (!backHeld) handler("back", false)
        }
    }, true)

    // the app went to the background mid-press: no release will come
    document.addEventListener("visibilitychange", function () {
        if (!document.hidden) return
        clearTimeout(okTimer)
        clearTimeout(backTimer)
        okDown = backDown = false
    })
}
