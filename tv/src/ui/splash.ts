// the launch lockup: the icon and the name, then a fade into the app
import { h, nextFrame } from "./dom"

export function showSplash(stage: HTMLElement, version: string): Promise<void> {
    const el = h("div.splash",
        null,
        h("div.lockup", null,
            h("img.icon", { src: "icons/icon-512.png", alt: "" }),
            h("div.name", { text: "Noonix TV" })),
        h("div.version", { text: version }))
    stage.appendChild(el)
    return new Promise<void>(function (resolve) {
        nextFrame(function () { el.className += " in" })
        setTimeout(function () {
            el.className += " out"
            setTimeout(function () {
                if (el.parentNode) el.parentNode.removeChild(el)
                resolve()
            }, 450)
        }, 1400)
    })
}
