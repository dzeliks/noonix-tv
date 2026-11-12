// the launch lockup: the icon and the name, then a fade into the app. a key, a button or a click
// lifts it early; settings › fast intro only flashes it
import { h, nextFrame } from "./dom"

export function showSplash(stage: HTMLElement, version: string, fast: boolean): Promise<void> {
    const el = h("div.splash",
        null,
        h("div.lockup", null,
            h("img.icon", { src: "icons/icon-512.png", alt: "" }),
            h("div.name", { text: "Noonix TV" })),
        h("div.version", { text: version }))
    stage.appendChild(el)
    return new Promise<void>(function (resolve) {
        let left = false
        function leave(): void {
            if (left) return
            left = true
            document.removeEventListener("keydown", leave, true)
            document.removeEventListener("click", leave, true)
            el.className += " out"
            setTimeout(function () {
                if (el.parentNode) el.parentNode.removeChild(el)
                resolve()
            }, 450)
        }
        document.addEventListener("keydown", leave, true)
        document.addEventListener("click", leave, true)
        nextFrame(function () { el.className += " in" })
        setTimeout(leave, fast ? 300 : 1400)
    })
}
