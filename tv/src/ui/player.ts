// the player (qml Player + its osd): the tv's own <video> plays the link, the osd comes and goes over it.
// a source that won't play hands over to the next one; a show's next episode comes up at the end
import { h, clear } from "./dom"
import { tr } from "../i18n"
import { Action } from "../keys"
import { icon } from "./icons"
import { hhmm } from "./meta"
import * as look from "./look"
import { backend } from "./backend"
import { App, PlayReq, Screen, MenuEntry } from "./app"
import * as tmdb from "../data/tmdb"
import * as sources from "../data/sources"
import * as progress from "../data/progress"
import * as trakt from "../data/trakt"

const osdMs = 4500
const saveEvery = 10000
/** the countdown before the next episode, from the end */
const nextSecs = 10
/** a source that hasn't started in this long is passed over */
const startWait = 25000

function clock(s: number): string {
    s = Math.max(0, Math.floor(s))
    const hh = Math.floor(s / 3600), mm = Math.floor(s / 60) % 60, ss = s % 60
    return (hh ? hh + ":" + (mm < 10 ? "0" : "") : "") + mm + ":" + (ss < 10 ? "0" : "") + ss
}

export function playerScreen(app: App, first: PlayReq): Screen {
    let req = first
    let list: sources.Stream[] = []
    let at = 0
    let alive = true
    let osdTimer = 0
    let saveTimer = 0
    let startTimer = 0
    let started = false
    let seekTo = -1
    let seekTimer = 0
    let seekRun = 0
    let lastSeek = 0
    let nextReq: PlayReq | null = null
    let nextLeft = -1
    let nextTimer = 0
    let nextOff = false

    let ended = false
    const subs = h("div.subs")
    const poster = h("img.pbackdrop", { alt: "" }) as HTMLImageElement
    const status = h("div.pstatus")
    const spinner = h("div.spinner")
    const titleEl = h("div.ptitle")
    const subEl = h("div.psub")
    const fill = h("div.fill")
    const buffered = h("div.buffered")
    const knob = h("div.knob")
    const bar = h("div.bar", null, buffered, fill, knob)
    const posEl = h("span.pos")
    const leftEl = h("span.left")
    const endsEl = h("span.ends")
    const srcEl = h("div.psrc")
    const stateIco = h("div.pstate")
    const clockEl = h("div.pclock")
    const osd = h("div.osd", null, h("div.ograd"), clockEl,
        h("div.obottom", null, titleEl, subEl, bar, h("div.times", null, posEl, endsEl, leftEl), srcEl))
    const nextTitle = h("div.ntitle")
    const nextCount = h("div.ncount")
    const nextCard = h("div.nextcard", null, h("div.nlabel", { text: tr("Up Next") }), nextTitle, nextCount,
        h("div.nhint", { text: tr("OK to play now, Back to stay") }))
    const el = h("div.player", null, poster, spinner, stateIco, status, osd, nextCard)

    // ---- what plays

    function label(): void {
        const it = req.item
        titleEl.textContent = it.title
        subEl.textContent = it.kind === "show" && req.season !== undefined
            ? "S" + req.season + " E" + req.episode + (req.episodeTitle ? "  ·  " + req.episodeTitle : "")
            : it.year ? String(it.year) : ""
        const b = look.backdrop(it.backdrop)
        if (b) poster.src = b
    }

    function target(): trakt.Target {
        return { kind: req.item.kind, tmdb: req.item.id, imdb: req.imdb, season: req.season, episode: req.episode }
    }

    function load(r: PlayReq): void {
        req = r
        started = false
        nextReq = null
        nextOff = false
        hideNext()
        label()
        poster.style.display = ""
        say(tr("Looking for sources…"))
        spinner.style.display = ""
        if (r.stream) {
            list = [r.stream].concat((r.list || []).filter(function (s) { return s !== r.stream }))
            at = 0
            start()
            return
        }
        imdbOf(r).then(function (imdb) {
            if (!alive || req !== r) return
            r.imdb = imdb
            if (!imdb) throw new Error(tr("This title has no imdb id: addons can't look it up"))
            return sources.streams({ kind: r.item.kind, imdb: imdb, season: r.season, episode: r.episode }).then(function (got) {
                if (!alive || req !== r) return
                list = pickOrder(got)
                at = 0
                if (!list.length) {
                    spinner.style.display = "none"
                    say(sources.addons().length ? tr("No sources found") : tr("No addons yet: add one in Settings"))
                    return
                }
                start()
            })
        }).catch(function (e) {
            if (!alive) return
            spinner.style.display = "none"
            say(String(e.message || e))
        })
    }

    function imdbOf(r: PlayReq): Promise<string | null> {
        if (r.imdb) return Promise.resolve(r.imdb)
        return tmdb.details(r.item.kind, r.item.id).then(function (d) { return d.imdb })
    }

    /** the next episode keeps to the last one's release (its binge group) */
    function pickOrder(got: sources.Stream[]): sources.Stream[] {
        const group = first.stream && first.stream.bingeGroup
        if (!group) return got
        return got.filter(function (s) { return s.bingeGroup === group }).concat(got.filter(function (s) { return s.bingeGroup !== group }))
    }

    function start(): void {
        const s = list[at]
        if (!s) {
            spinner.style.display = "none"
            say(tr("None of the sources played here"))
            return
        }
        say(at ? tr("Trying another source…") : "")
        srcEl.textContent = [s.resolution ? (s.resolution >= 2160 ? "4K" : s.resolution + "p") : "", s.hdr.join(" "), s.codec || "",
            s.audio.slice(0, 2).join(" "), s.addon, sources.sizeText(s.size)].filter(function (x) { return !!x }).join("  ·  ")
        spinner.style.display = ""
        ended = false
        subs.textContent = ""
        video.open(s.url)
        clearTimeout(startTimer)
        startTimer = window.setTimeout(function () { if (!started) fail("no start") }, startWait)
    }

    function fail(why: string): void {
        if (!alive) return
        console.warn("source " + (at + 1) + "/" + list.length + " failed: " + why)
        at++
        start()
    }

    function say(text: string): void {
        status.textContent = text
        status.style.display = text ? "" : "none"
    }

    // ---- the video's events

    const video = backend({
        meta(): void {
            const d = video.duration()
            const resume = req.start !== undefined ? req.start : progress.resumeAt(req.item.kind, req.item.id, req.season, req.episode, d)
            if (resume > 0 && resume < d - 30) video.seek(resume)
        },
        playing(): void {
            spinner.style.display = "none"
            stateIco.style.display = "none"
            if (!started) {
                started = true
                clearTimeout(startTimer)
                poster.style.display = "none"
                say("")
                trakt.scrobble("start", target(), share())
                showOsd()
            }
        },
        waiting(): void { if (started) spinner.style.display = "" },
        error(why: string): void {
            if (!started) fail(why)
            else { spinner.style.display = "none"; say(tr("Playback stopped: the source broke off")) }
        },
        time(): void {
            if (seekTo < 0) drawBar()
            const left = video.duration() - video.time()
            if (req.item.kind === "show" && started && !nextOff && left > 0 && left <= nextSecs + 0.5 && nextLeft < 0) upNext()
        },
        ended(): void {
            ended = true
            save(true)
            trakt.scrobble("stop", target(), 1)
            if (nextReq) { playNext(); return }
            app.pop()
        },
        paused(): void {
            if (!started || ended) return
            save(false)
            trakt.scrobble("pause", target(), share())
        },
        subtitle(text: string): void { subs.textContent = text },
    })
    el.insertBefore(video.el, poster.nextSibling)
    el.insertBefore(subs, osd)

    function share(): number { return video.duration() ? video.time() / video.duration() : 0 }

    function save(done: boolean): void {
        if (!started || !video.duration()) return
        progress.save({
            item: req.item, season: req.season, episode: req.episode, episodeTitle: req.episodeTitle,
            position: done ? video.duration() : video.time(), duration: video.duration(), updated: 0, finished: done,
        })
    }
    saveTimer = window.setInterval(function () { if (!video.paused()) save(false) }, saveEvery)

    // ---- the osd

    function drawBar(): void {
        const d = video.duration()
        if (!d) { posEl.textContent = leftEl.textContent = endsEl.textContent = ""; return }
        const t = seekTo >= 0 ? seekTo : video.time()
        const k = Math.max(0, Math.min(1, t / d))
        fill.style.width = k * 100 + "%"
        knob.style.left = k * 100 + "%"
        const b = video.buffered()
        buffered.style.width = Math.min(1, b / d) * 100 + "%"
        posEl.textContent = clock(t)
        leftEl.textContent = "-" + clock(d - t)
        endsEl.textContent = tr("Ends at %1", hhmm(new Date(Date.now() + (d - t) * 1000)))
    }

    function showOsd(): void {
        clockEl.textContent = hhmm(new Date())
        osd.className = "osd on"
        drawBar()
        clearTimeout(osdTimer)
        osdTimer = window.setTimeout(function () { if (!video.paused()) osd.className = "osd" }, osdMs)
    }

    function flash(name: string): void {
        clear(stateIco)
        stateIco.appendChild(icon(name, 96))
        stateIco.style.display = ""
    }

    function toggle(): void {
        if (!started) return
        if (video.paused()) { video.play(); stateIco.style.display = "none" }
        else { video.pause(); flash("pause") }
        showOsd()
    }

    /** presses close together go further each time; the jump lands once they stop */
    function seek(dir: number, base: number): void {
        if (!started || !video.duration()) return
        const now = Date.now()
        seekRun = now - lastSeek < 700 ? seekRun + 1 : 0
        lastSeek = now
        const step = base * (seekRun < 3 ? 1 : seekRun < 8 ? 3 : 6)
        const from = seekTo >= 0 ? seekTo : video.time()
        seekTo = Math.max(0, Math.min(video.duration() - 2, from + dir * step))
        showOsd()
        clearTimeout(seekTimer)
        seekTimer = window.setTimeout(function () {
            video.seek(seekTo)
            seekTo = -1
        }, 550)
    }

    // ---- up next

    function upNext(): void {
        nextLeft = nextSecs
        findNext().then(function (n) {
            if (!alive || !n) { nextLeft = -1; nextOff = true; return }
            nextReq = n
            nextTitle.textContent = "S" + n.season + " E" + n.episode + (n.episodeTitle ? "  ·  " + n.episodeTitle : "")
            nextCard.className = "nextcard on"
            tickNext()
        })
    }

    function tickNext(): void {
        nextCount.textContent = tr("Starts in %1", Math.max(0, Math.round(video.duration() - video.time())))
        nextTimer = window.setTimeout(tickNext, 500)
    }

    function hideNext(): void {
        clearTimeout(nextTimer)
        nextCard.className = "nextcard"
        nextLeft = -1
    }

    function findNext(): Promise<PlayReq | null> {
        const it = req.item
        if (it.kind !== "show" || req.season === undefined || req.episode === undefined) return Promise.resolve(null)
        const s = req.season, e = req.episode
        return tmdb.season(it.id, s).then(function (cur) {
            const n = cur.episodes.filter(function (x) { return x.episode === e + 1 })[0]
            if (n) return n
            return tmdb.season(it.id, s + 1).then(function (nx) { return nx.episodes[0] || null }, function () { return null })
        }).then(function (n: tmdb.Episode | null) {
            // not out yet: nothing to play
            if (!n || (n.airDate && Date.parse(n.airDate) > Date.now())) return null
            return { item: it, imdb: req.imdb, season: n.season, episode: n.episode, episodeTitle: n.episodeTitle, start: 0 }
        }, function () { return null })
    }

    function playNext(): void {
        const n = nextReq
        if (!n) return
        save(true)
        trakt.scrobble("stop", target(), 1)
        hideNext()
        video.pause()
        load(n)
    }

    // ---- keys

    function action(a: Action): boolean {
        if (nextReq && nextCard.className.indexOf("on") >= 0) {
            if (a === "ok" || a === "next") { playNext(); return true }
            if (a === "back") { hideNext(); nextReq = null; nextOff = true; return true }
        }
        if (a === "ok" || a === "playpause") toggle()
        else if (a === "play") { if (video.paused()) toggle() }
        else if (a === "pause") { if (!video.paused()) toggle() }
        else if (a === "left") seek(-1, 10)
        else if (a === "right") seek(1, 10)
        else if (a === "rewind") seek(-1, 30)
        else if (a === "forward") seek(1, 30)
        else if (a === "down" && osd.className === "osd on") tracks()
        else if (a === "up" || a === "down" || a === "info") showOsd()
        else if (a === "next") { upNextNow() }
        else if (a === "menu") { video.pause(); openSources() }
        else if (a === "stop" || a === "back") { app.pop(); return true }
        else return true
        return true
    }

    function openSources(): void {
        app.sources({ item: req.item, imdb: req.imdb, season: req.season, episode: req.episode, episodeTitle: req.episodeTitle,
            start: started ? video.time() : undefined })
    }

    /** audio and subtitle tracks, the ones the file has */
    function tracks(): void {
        const audio = video.audioTracks()
        const text = video.textTracks()
        const entries: MenuEntry[] = []
        audio.forEach(function (t) {
            entries.push({ label: tr("Audio") + ": " + t.label, icon: t.on ? "check" : undefined, run: function () { video.setAudio(t.id) } })
        })
        if (text.length) {
            const any = text.some(function (t) { return t.on })
            entries.push({ label: tr("Subtitles") + ": " + tr("Off"), icon: any ? undefined : "check", run: function () { video.setText(-1); subs.textContent = "" } })
            text.forEach(function (t) {
                entries.push({ label: tr("Subtitles") + ": " + t.label, icon: t.on ? "check" : undefined, run: function () { video.setText(t.id) } })
            })
        }
        if (!entries.length) { app.toast(tr("This file has one audio track and no subtitles")); return }
        app.menu(tr("Audio and subtitles"), entries)
    }

    function upNextNow(): void {
        findNext().then(function (n) { if (alive && n) { nextReq = n; playNext() } })
    }

    load(first)
    return {
        el,
        action,
        shown(): void { showOsd() },
        closed(): void {
            alive = false
            if (started && !ended) {
                save(false)
                trakt.scrobble(share() >= 0.92 ? "stop" : "pause", target(), share())
            }
            clearTimeout(osdTimer); clearInterval(saveTimer); clearTimeout(startTimer); clearTimeout(seekTimer); clearTimeout(nextTimer)
            // the decoder is let go now, not when the element is collected
            video.close()
        },
    }
}
