// back at the top of the app: leave noonix tv? (stay is focused, so a stray back is harmless)
import { h, nextFrame } from "./dom"
import { tr } from "../i18n"
import { Action } from "../keys"
import { Screen } from "./home"

export function exitPrompt(leave: () => void, stay: () => void): Screen {
    let choice = 1
    const exitBtn = h("div.button", { text: tr("Exit") })
    const stayBtn = h("div.button", { text: tr("Stay") })
    const el = h("div.prompt", null,
        h("div.box", null, h("div.question", { text: tr("Exit Noonix TV?") }), h("div.buttons", null, exitBtn, stayBtn)))
    const light = function () {
        exitBtn.className = "button" + (choice === 0 ? " lit" : "")
        stayBtn.className = "button" + (choice === 1 ? " lit" : "")
    }
    light()
    nextFrame(function () { el.className = "prompt in" })
    const close = function (then: () => void) {
        el.className = "prompt"
        setTimeout(function () { if (el.parentNode) el.parentNode.removeChild(el) }, 200)
        then()
    }
    return {
        el,
        action(a: Action): boolean {
            if (a === "left") choice = 0
            else if (a === "right") choice = 1
            else if (a === "ok") close(choice === 0 ? leave : stay)
            else if (a === "back") close(stay)
            light()
            return true
        },
    }
}
