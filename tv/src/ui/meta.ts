// the words under a title (qml MetaLine, Theme.runtime/endsAt)
import { h } from "./dom"
import { tr, trn, language } from "../i18n"
import * as tmdb from "../data/tmdb"

/** year, genres, length, rating, "ends at": short of room the genres go first, then the rating */
export function metaLine(el: HTMLElement, it: tmdb.Item, d: tmdb.Details | null): void {
    const owner = el as HTMLElement & { metaFor?: tmdb.Item }
    owner.metaFor = it
    // not laid out yet (a page over it): fitted once it shows
    if (!el.clientWidth) {
        el.textContent = ""
        setTimeout(function () { if (owner.metaFor === it) metaLine(el, it, d) }, 400)
        return
    }
    const runtime = d && d.kind === "movie" ? d.runtime : 0
    for (let level = 0; level < 3; level++) {
        const parts: string[] = []
        if (it.year) parts.push(String(it.year))
        const genres = (d ? d.genres : it.genres).slice(0, 2)
        if (level === 0 && genres.length) parts.push(genres.join(", "))
        if (runtime) parts.push(length(runtime))
        if (d && d.kind === "show" && d.seasons) parts.push(trn("%n season(s)", d.seasons.length))
        if (d && d.certification) parts.push(d.certification)
        if (level < 2 && it.rating) parts.push("★ " + it.rating)
        el.textContent = parts.join("  ·  ")
        if (runtime) el.appendChild(h("b", { text: (parts.length ? "  ·  " : "") + tr("Ends at %1", hhmm(new Date(Date.now() + runtime * 60000))) }))
        if (el.scrollWidth <= el.clientWidth) return
    }
}

export function hhmm(d: Date): string {
    return two(d.getHours()) + ":" + two(d.getMinutes())
}

export function length(min: number): string {
    const hh = Math.floor(min / 60)
    return hh ? hh + "h " + (min % 60) + "m" : min + "m"
}

const months: { [lang: string]: string[] } = {
    en: ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"],
    sr: ["jan", "feb", "mar", "apr", "maj", "jun", "jul", "avg", "sep", "okt", "nov", "dec"],
}

/** "12 Nov 2026" from an iso date (tmdb air dates are plain days: no time zone shift) */
export function day(iso: string | null, withYear: boolean): string {
    const m = iso ? /^(\d{4})-(\d{2})-(\d{2})/.exec(iso) : null
    if (!m) return ""
    const d = parseInt(m[3], 10)
    return (language() === "sr" ? d + ". " : d + " ") + (months[language()] || months.en)[parseInt(m[2], 10) - 1] + (withYear ? " " + m[1] : "")
}

function two(n: number): string { return (n < 10 ? "0" : "") + n }
