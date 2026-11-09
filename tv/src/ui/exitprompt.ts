// a question over everything, two answers: leave noonix tv? allow torrents? (the safe answer is
// focused, so a stray ok or back is harmless)
import { h, nextFrame } from "./dom"
import { tr } from "../i18n"
import { Action } from "../keys"
import { Screen } from "./home"

/** yes/no: the button labels; lines: a few paragraphs under the question */
export function askPrompt(question: string, lines: string[], yes: string, no: string, onYes: () => void, onNo: () => void): Screen {
    let choice = 1
    const yesBtn = h("div.button", { text: yes })
    const noBtn = h("div.button", { text: no })
    const body = lines.map(function (l) { return h("div.pline", { text: l }) })
    const el = h("div.prompt" + (lines.length ? ".long" : ""), null,
        h("div.box", null, h("div.question", { text: question }), h("div.ptext", null, ...body), h("div.buttons", null, yesBtn, noBtn)))
    const light = function () {
        yesBtn.className = "button" + (choice === 0 ? " lit" : "")
        noBtn.className = "button" + (choice === 1 ? " lit" : "")
    }
    light()
    nextFrame(function () { el.className += " in" })
    const close = function (then: () => void) {
        el.className = el.className.replace(" in", "")
        setTimeout(function () { if (el.parentNode) el.parentNode.removeChild(el) }, 200)
        then()
    }
    return {
        el,
        action(a: Action): boolean {
            if (a === "left") choice = 0
            else if (a === "right") choice = 1
            else if (a === "ok") close(choice === 0 ? onYes : onNo)
            else if (a === "back") close(onNo)
            light()
            return true
        },
    }
}

export function exitPrompt(leave: () => void, stay: () => void): Screen {
    return askPrompt(tr("Exit Noonix TV?"), [], tr("Exit"), tr("Stay"), leave, stay)
}
