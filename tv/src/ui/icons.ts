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
    chevronleft: "M15.5 5 L8.5 12 L15.5 19",
    fwd10: "M19.5 12 A7.5 7.5 0 1 1 17 6.4 M17 2.8 V6.6 H13.2",
    subtitles: "M3.5 5.5 H20.5 V18.5 H3.5 Z M6.5 14.5 H11 M13 14.5 H17.5 M6.5 11 H9 M11 11 H17.5",
    audio: "M3.5 9.5 H7 L11.5 5.5 V18.5 L7 14.5 H3.5 Z M15 9.5 A3.6 3.6 0 0 1 15 14.5 M17.5 7.2 A6.8 6.8 0 0 1 17.5 16.8",
    feedback: "M4.5 6.5 A2 2 0 0 1 6.5 4.5 H17.5 A2 2 0 0 1 19.5 6.5 V14.5 A2 2 0 0 1 17.5 16.5 H10.5 L6.5 20 V16.5 A2 2 0 0 1 4.5 14.5 Z M8.5 10.6 L11 13 L15.5 8.4",
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
