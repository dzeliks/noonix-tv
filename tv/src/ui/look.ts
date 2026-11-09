// what the tv can draw well: set once at start as classes on <html> (style.css follows them)
import { platform } from "../platform"
import * as settings from "../data/settings"

/** low memory mode: lighter artwork, no blur, fewer cards kept */
export let lowMemory = false

export function apply(): void {
    const mode = settings.all().lowMode
    lowMemory = mode === "on" || (mode === "auto" && platform.lowMemoryDefault)
    const root = document.documentElement
    const blur = !lowMemory && (cssSupports("backdrop-filter", "blur(2px)") || cssSupports("-webkit-backdrop-filter", "blur(2px)"))
    root.className = [platform.os, lowMemory ? "low" : "", blur ? "blur" : ""].filter(function (c) { return !!c }).join(" ")
}

function cssSupports(prop: string, value: string): boolean {
    const css = (window as any).CSS
    return !!(css && css.supports && css.supports(prop, value))
}

/** the size of a poster or backdrop to ask tmdb for: the ui is a 1080p page */
export function poster(url: string | null): string | null {
    return url ? url.replace(/\/t\/p\/w\d+\//, "/t/p/w342/") : null
}

export function backdrop(url: string | null): string | null {
    return url ? url.replace(/\/t\/p\/(w\d+|original)\//, lowMemory ? "/t/p/w780/" : "/t/p/w1280/") : null
}
