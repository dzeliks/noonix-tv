// who's watching (qml ProfilePicker): shown at start when the tv has more than one profile
import { h } from "./dom"
import { tr } from "../i18n"
import { Action } from "../keys"
import { Screen } from "./app"
import * as profiles from "../data/profiles"

export function profileName(p: profiles.Profile): string { return p.name || tr("Profile %1", p.id) }

export function pickerScreen(picked: (p: profiles.Profile) => void): Screen {
    const list = profiles.list()
    let at = Math.max(0, list.indexOf(profiles.current()))
    const cards = list.map(function (p) {
        const face = h("div.face", { text: profileName(p).charAt(0).toUpperCase() })
        face.style.backgroundColor = p.color
        return h("div.pcard", null, face, h("div.pname", { text: profileName(p) }))
    })
    const el = h("div.picker", null, h("div.ptitle2", { text: tr("Who's watching?") }), h("div.pcards", null, ...cards))
    function light(): void { for (let i = 0; i < cards.length; i++) cards[i].className = "pcard" + (i === at ? " lit" : "") }
    light()
    return {
        el,
        action(a: Action): boolean {
            if (a === "left" && at > 0) at--
            else if (a === "right" && at < cards.length - 1) at++
            else if (a === "ok") { picked(list[at]); return true }
            // nothing under it to go back to
            else if (a === "back") return true
            light()
            return true
        },
    }
}
