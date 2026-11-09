// the app's words: english as written, serbian from the qt translations (i18n/noonix-tv_sr_Latn.ts,
// read into the bundle at build time)
declare const __SR__: { [source: string]: string | string[] }

let lang = "en"

export function setLanguage(l: string): void { lang = l }
export function language(): string { return lang }

/** tr("Ends at %1", "21:40") */
export function tr(source: string, ...args: (string | number)[]): string {
    const t = lang === "sr" ? __SR__[source] : undefined
    let s = typeof t === "string" && t ? t : source
    for (let i = 0; i < args.length; i++) s = s.split("%" + (i + 1)).join(String(args[i]))
    return s
}

/** a plural: trn("%n season(s)", 3) */
export function trn(source: string, n: number, ...args: (string | number)[]): string {
    const t = lang === "sr" ? __SR__[source] : undefined
    let s: string
    if (t && typeof t !== "string") {
        // serbian: one (1, 21, ...), few (2-4, 22-24, ...), many
        const m10 = n % 10, m100 = n % 100
        const form = m10 === 1 && m100 !== 11 ? 0 : m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14) ? 1 : 2
        s = t[Math.min(form, t.length - 1)]
    } else {
        s = source.replace("(s)", n === 1 ? "" : "s")
    }
    s = s.split("%n").join(String(n))
    for (let i = 0; i < args.length; i++) s = s.split("%" + (i + 1)).join(String(args[i]))
    return s
}
