// line icons on the 24 grid (qml Symbol): drawn in the text colour
const paths: { [name: string]: string } = {
    check: "M5.5 12.5 L10 17 L18.5 7.5",
    play: "M8 5.5 V18.5 L18.5 12 Z",
    back10: "M4.5 12 A7.5 7.5 0 1 0 7 6.4 M7 2.8 V6.6 H10.8",
    plus: "M12 5 V19 M5 12 H19",
    list: "M8.5 7 H19.5 M8.5 12 H19.5 M8.5 17 H19.5 M4.5 7 H4.6 M4.5 12 H4.6 M4.5 17 H4.6",
}
const filled: { [name: string]: boolean } = { play: true }

export function icon(name: string, size: number): HTMLElement {
    const el = document.createElement("span")
    el.className = "ico"
    el.innerHTML = "<svg width=\"" + size + "\" height=\"" + size + "\" viewBox=\"0 0 24 24\" fill=\""
        + (filled[name] ? "currentColor" : "none") + "\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\""
        + " stroke-linejoin=\"round\"><path d=\"" + paths[name] + "\"/></svg>"
    return el
}
