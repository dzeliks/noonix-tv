// line icons on the 24 grid (qml Symbol): drawn in the text colour
const paths: { [name: string]: string } = {
    check: "M5.5 12.5 L10 17 L18.5 7.5",
    play: "M8 5.5 V18.5 L18.5 12 Z",
    back10: "M4.5 12 A7.5 7.5 0 1 0 7 6.4 M7 2.8 V6.6 H10.8",
    plus: "M12 5 V19 M5 12 H19",
    list: "M8.5 7 H19.5 M8.5 12 H19.5 M8.5 17 H19.5 M4.5 7 H4.6 M4.5 12 H4.6 M4.5 17 H4.6",
    pause: "M8 5.5 V18.5 M16 5.5 V18.5",
    next: "M6 5.5 V18.5 L15.5 12 Z M18.5 5.5 V18.5",
    restart: "M4.5 12 A7.5 7.5 0 1 0 7 6.4 M7 2.8 V6.6 H10.8",
    minus: "M5 12 H19",
    search: "M10.5 4 A6.5 6.5 0 1 0 10.5 17 A6.5 6.5 0 1 0 10.5 4 M15.3 15.3 L20 20",
    clock: "M12 3.5 A8.5 8.5 0 1 0 12 20.5 A8.5 8.5 0 1 0 12 3.5 M12 7.5 V12 L15 14",
    eye: "M2.5 12 C5 7 8.5 5 12 5 C15.5 5 19 7 21.5 12 C19 17 15.5 19 12 19 C8.5 19 5 17 2.5 12 Z M12 9.5 A2.5 2.5 0 1 0 12 14.5 A2.5 2.5 0 1 0 12 9.5",
}
const filled: { [name: string]: boolean } = { play: true, next: true }

export function icon(name: string, size: number): HTMLElement {
    const el = document.createElement("span")
    el.className = "ico"
    el.innerHTML = "<svg width=\"" + size + "\" height=\"" + size + "\" viewBox=\"0 0 24 24\" fill=\""
        + (filled[name] ? "currentColor" : "none") + "\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\""
        + " stroke-linejoin=\"round\"><path d=\"" + paths[name] + "\"/></svg>"
    return el
}
