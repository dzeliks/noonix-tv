// typing a line with the remote (qml TextEntry): an addon link, a key. the phone's keyboard is the
// other way in (settings shows a link) where typing a long url by remote is too much
import { h } from "./dom"
import { tr } from "../i18n"
import { Action } from "../keys"
import { keyboard } from "./keyboard"
import { Screen } from "./app"

export function inputScreen(title: string, hint: string, value: string, done: (text: string) => void, close: () => void): Screen {
    let text = value
    const shown = h("span.text")
    const field = h("div.field.wide", null, shown, h("span.caret"))
    const kb = keyboard(96, tr("Done"), function (s) { set(text + s) }, function (name) {
        if (name === "backspace") set(text.slice(0, -1))
        else if (name === "clear") set("")
        else if (name === "enter") { close(); done(text.trim()) }
    })
    kb.setActive(true)
    const el = h("div.input", null,
        h("div.ibox", null, h("div.ititle", { text: title }), h("div.ihint", { text: hint }), field, kb.el))

    function set(t: string): void {
        text = t
        shown.textContent = t
        // a long line shows its end, where the typing is
        field.scrollLeft = field.scrollWidth
    }
    set(value)

    return {
        el,
        action(a: Action): boolean {
            if (kb.action(a)) return true
            if (a === "back") { close(); return true }
            return true
        },
    }
}
