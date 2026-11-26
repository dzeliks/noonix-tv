// the player (qml Player + its osd): the tv's own <video> plays the link, the osd comes and goes over it.
// a source that won't play hands over to the next one; a show's next episode comes up at the end
import { h, clear } from "./dom"
import { textShade } from "./textshade"
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
import * as subtitles from "../data/subs"
import * as memory from "../data/memory"
import * as skip from "../data/skip"
import * as engine from "../data/engine"
import * as shares from "../data/shares"
import * as platform from "../platform"

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
    // the binge group of the source that played (a switch or a fallback changes it)
    let playedGroup: string | null = first.stream ? first.stream.bingeGroup : null
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
    // subtitles found online: drawn here from their cues, moved by delay (seconds)
    let ext: subtitles.Cue[] | null = null
    let extName = ""
    let extId = ""
    let delay = 0
    let extTimer = 0
    let found: subtitles.Found[] | null = null
    // intro / recap / credits of this episode, and the one the play head is in
    let segs: skip.Segment[] = []
    let inSeg: skip.Segment | null = null
    const skipBtn = h("div.skipbtn")
    const subs = h("div.subs")
    const poster = h("img.pbackdrop", { alt: "" }) as HTMLImageElement
    const status = h("div.pstatus")
    const spinner = h("div.spinner")
    // the osd (qml Osd): back top left, the clock top right, the logo over the bar, a row of buttons under it
    const logoImg = h("img", { alt: "" }) as HTMLImageElement
    const titleEl = h("div.ptitle")
    const subEl = h("div.psub")
    const logoBox = h("div.ologo", null, logoImg, titleEl)
    const fill = h("div.fill")
    const buffered = h("div.buffered")
    const knob = h("div.knob")
    const bar = h("div.bar", null, buffered, fill, knob)
    const posEl = h("div.pos")
    const leftEl = h("div.left")
    const endsEl = h("div.pends")
    const clockEl = h("div.pclock")
    const backBtn = h("div.oback", null, icon("chevronleft", 34))
    const subsText = h("span")
    const audioText = h("span")
    const subsBtn = h("div.ochip", null, icon("subtitles", 34), subsText)
    const audioBtn = h("div.ochip", null, icon("audio", 34), audioText)
    const matchBtn = h("div.oround", null, icon("feedback", 34))
    const rewBtn = h("div.tbtn", null, icon("back10", 38))
    const playBtn = h("div.tbtn.play")
    const fwdBtn = h("div.tbtn", null, icon("fwd10", 38))
    const osd = h("div.osd", null, h("div.ograd"), h("div.ogradtop"), backBtn, h("div.pclockbox", null, clockEl, endsEl),
        logoBox, subEl, bar, posEl, leftEl,
        h("div.orow", null, subsBtn, audioBtn, matchBtn), h("div.transport", null, rewBtn, playBtn, fwdBtn))
    // a soft shade behind the logo (its own shape), the line under it and the clock
    const logoShade = textShade(osd, function () { return [logoImg, titleEl, subEl] }, 0.5)
    logoShade.el.className += " ologoshade"
    const clockShade = textShade(osd, function () { return [clockEl, endsEl] }, 0.3)
    const nextTitle = h("div.ntitle")
    const nextCount = h("div.ncount")
    const nextCard = h("div.nextcard", null, h("div.nlabel", { text: tr("Up Next") }), nextTitle, nextCount,
        h("div.nhint", { text: tr("OK to play now, Back to stay") }))
    const el = h("div.player", null, poster, spinner, status, osd, skipBtn, nextCard)

    // ---- what plays

    function label(): void {
        const it = req.item
        titleEl.textContent = it.title
        subEl.textContent = it.kind === "show" && req.season !== undefined
            ? "S" + req.season + " E" + req.episode + (req.episodeTitle ? "  ·  " + req.episodeTitle : "")
            : ""
        // on the episode line, or down in its place when there's none (a movie)
        logoBox.className = "ologo" + (subEl.textContent ? "" : " low")
        const b = look.backdrop(it.backdrop)
        if (b) poster.src = b
        // the logo over the bar, the title until it's in (or when there's none)
        logoImg.style.display = "none"
        titleEl.style.display = ""
        logoImg.removeAttribute("src")
        logoShade.update()
        tmdb.details(it.kind, it.id).then(function (d) {
            if (!alive || req.item !== it || !d.logo) return
            logoImg.onload = function () { if (req.item === it) { logoImg.style.display = ""; titleEl.style.display = "none"; logoShade.update() } }
            logoImg.src = d.logo
        }, function () { /* the title stays */ })
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
            // no imdb id: only the library's files of it
            return sources.streams({ kind: r.item.kind, imdb: imdb || "", tmdb: r.item.id, season: r.season, episode: r.episode }).then(function (got) {
                if (!alive || req !== r) return
                list = pickOrder(got)
                at = 0
                if (!list.length) {
                    spinner.style.display = "none"
                    say(!imdb ? tr("This title has no imdb id: addons can't look it up")
                        : sources.addons().length ? tr("No sources found") : tr("No addons yet: add one in Settings"))
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

    /** the next episode keeps to the release that played last (its binge group), unless it was reported */
    function pickOrder(got: sources.Stream[]): sources.Stream[] {
        const group = playedGroup
        if (!group) return got
        const same = function (s: sources.Stream): boolean { return s.bingeGroup === group && !memory.isBad(s) }
        return got.filter(same).concat(got.filter(function (s) { return !same(s) }))
    }

    function start(): void {
        const s = list[at]
        if (!s) {
            spinner.style.display = "none"
            say(tr("None of the sources played here"))
            return
        }
        say(at ? tr("Trying another source…") : "")
        spinner.style.display = ""
        ended = false
        subs.textContent = ""
        dropExt()
        found = null
        segs = []
        showSkip(null)
        clearTimeout(startTimer)
        const open = function (url?: string) {
            video.open(url || s.url)
            // a torrent first finds people and its file list on the server
            startTimer = window.setTimeout(function () { if (!started) fail("no start") }, s.torrent ? startWait * 3 : startWait)
        }
        // a file on a network share: the engine opens it and hands a link
        if (s.share) {
            shares.playUrl(s.url).then(function (url) {
                if (alive && list[at] === s) open(url)
            }, function (e) {
                if (!alive || list[at] !== s) return
                // what the server said (the name or password, a share gone), then the next source
                app.toast(String(e.message || e))
                fail(String(e.message || e))
            })
            return
        }
        if (!s.torrent) return open()
        // this tv's own engine is started first (a server set in settings is already running)
        engine.ensure(s.url).then(function () {
            if (alive && list[at] === s) open()
        }, function (e) {
            if (alive && list[at] === s) fail(String(e.message || e))
        })
    }

    // ---- how's this one? (qml Match): what works is remembered for the next episodes, what doesn't gets fixed here

    function rate(): void {
        const s = list[at]
        if (!started || !s) return
        pick()
        app.menu(tr("How's this one?"), [
            { label: tr("Good match"), icon: "check", run: function () {
                memory.like(req.item.kind, req.item.id, s)
                app.toast(tr("Good match · saved"))
            } },
            { label: tr("Picture or sound problem"), run: function () { memory.report(s); playedGroup = null; otherSource() } },
            { label: tr("Wrong subtitles"), run: findMenu },
            { label: tr("Subtitles out of sync"), run: function () { if (ext) timingMenu(); else findMenu() } },
        ], above)
    }

    /** another source, from the same spot */
    function otherSource(): void {
        if (at + 1 >= list.length) { app.toast(tr("No sources found")); return }
        save(false)
        req.start = video.time()
        started = false
        app.toast(tr("Another source, from the same spot"))
        at++
        start()
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
            platform.keepAwake(true)
            spinner.style.display = "none"
            light()
            if (!started) {
                started = true
                clearTimeout(startTimer)
                if (list[at]) playedGroup = list[at].bingeGroup
                poster.style.display = "none"
                say("")
                trakt.scrobble("start", target(), share())
                show()
                autoAudio()
                autoSubs()
                findSegments()
            }
        },
        waiting(): void { if (started) spinner.style.display = "" },
        error(why: string): void {
            platform.keepAwake(false)
            if (!started) fail(why)
            else { spinner.style.display = "none"; say(tr("Playback stopped: the source broke off")) }
        },
        time(): void {
            if (seekTo < 0) drawBar()
            checkSkip()
            const left = video.duration() - video.time()
            if (req.item.kind === "show" && started && !nextOff && left > 0 && left <= nextSecs + 0.5 && nextLeft < 0) upNext()
        },
        ended(): void {
            platform.keepAwake(false)
            ended = true
            save(true)
            trakt.scrobble("stop", target(), 1)
            if (nextReq) { playNext(); return }
            app.pop()
        },
        paused(): void {
            platform.keepAwake(false)
            light()
            if (!started || ended) return
            save(false)
            trakt.scrobble("pause", target(), share())
        },
        subtitle(text: string): void { if (!ext) subs.textContent = text },
    })
    el.insertBefore(video.el, poster.nextSibling)
    // after the osd: it moves up over the title while the osd shows
    el.insertBefore(subs, skipBtn)

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
        const ends = tr("Ends at %1", hhmm(new Date(Date.now() + (d - t) * 1000)))
        if (ends !== endsEl.textContent) { endsEl.textContent = ends; clockShade.update() }
    }

    // zones like the other clients: the bar (left/right seek), the row of buttons, the skip pill, back
    const buttons = ["subs", "audio", "match", "rew", "play", "fwd"]
    let shown = false
    let zone = "bar"
    let rowAt = 4
    let exitArmed = false
    // a picker (subtitles, audio, how's this one) is up over the row: the osd stays
    let picking = false
    let playIcon = ""
    /** where the pickers open: above the left buttons, like the track picker */
    const above = { left: 96, bottom: 142 }

    /** the controls always come up on play / pause; seeking keeps the bar */
    function show(secs?: number, z?: string): void {
        if (!shown) {
            zone = z || "row"
            rowAt = buttons.indexOf("play")
        }
        shown = true
        osd.className = "osd on" + (picking ? " picking" : "")
        const now = hhmm(new Date())
        if (now !== clockEl.textContent) { clockEl.textContent = now; clockShade.update() }
        drawBar()
        light()
        clearTimeout(osdTimer)
        if (!video.paused() && !picking) osdTimer = window.setTimeout(function () { if (!video.paused() && !picking) hide() }, (secs || 5) * 1000)
    }

    /** a picker opens over the row: the osd stays, the logo and the times make room */
    function pick(): void {
        picking = true
        clearTimeout(osdTimer)
        osd.className = "osd on picking"
    }

    function hide(): void {
        shown = false
        zone = "bar"
        exitArmed = false
        osd.className = "osd"
        light()
    }

    /** what's lit, the labels, play or pause */
    function light(): void {
        const foc = function (b: string): string { return shown && zone === "row" && buttons[rowAt] === b ? " lit" : "" }
        subsBtn.className = "ochip" + foc("subs")
        audioBtn.className = "ochip" + foc("audio")
        matchBtn.className = "oround" + foc("match")
        rewBtn.className = "tbtn" + foc("rew")
        playBtn.className = "tbtn play" + foc("play")
        fwdBtn.className = "tbtn" + foc("fwd")
        backBtn.className = "oback" + (shown && (zone === "back" || exitArmed) ? " lit" : "")
        bar.className = "bar" + (shown && zone === "bar" ? " foc" : "")
        skipBtn.className = "skipbtn" + (inSeg ? " on" : "") + (inSeg && (!shown || zone === "skip") ? " lit" : "")
        const want = started && video.paused() ? "play" : "pause"
        if (want !== playIcon) { playIcon = want; clear(playBtn); playBtn.appendChild(icon(want, 46)) }
        subsText.textContent = subLabel()
        audioText.textContent = audioLabel()
    }

    function subLabel(): string {
        if (ext) return extName
        const t = video.textTracks().filter(function (x) { return x.on })[0]
        return t ? t.label : tr("Off")
    }

    function audioLabel(): string {
        const t = video.audioTracks().filter(function (x) { return x.on })[0]
        return t ? t.label : tr("Audio")
    }

    function toggle(): void {
        if (!started) return
        if (video.paused()) { video.play(); show(2) }
        else { video.pause(); show() }
    }

    function act(b: string): void {
        if (b === "play") toggle()
        else if (b === "rew") seek(-1, 10)
        else if (b === "fwd") seek(1, 10)
        else if (b === "subs") subsMenu()
        else if (b === "audio") audioMenu()
        else if (b === "match") rate()
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
        show(5, "bar")
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
        if (a === "playpause") toggle()
        else if (a === "play") { if (video.paused()) toggle() }
        else if (a === "pause") { if (!video.paused()) toggle() }
        else if (a === "rewind") seek(-1, 30)
        else if (a === "forward") seek(1, 30)
        else if (a === "next") upNextNow()
        else if (a === "stop") app.pop()
        else if (a === "menu") options()
        else if (a === "back") {
            // the controls down: the first back lands on the back button, a second one leaves
            if (exitArmed) { app.pop(); return true }
            if (shown) hide()
            else { show(); zone = "back"; exitArmed = true; light() }
        } else move(a)
        return true
    }

    function move(a: Action): void {
        exitArmed = false
        if (!shown) {
            if (a === "left") seek(-1, 10)
            else if (a === "right") seek(1, 10)
            else if (a === "ok" && inSeg) doSkip()
            else show()
            return
        }
        if (zone === "bar") {
            if (a === "left") { seek(-1, 10); return }
            if (a === "right") { seek(1, 10); return }
            if (a === "ok") { toggle(); return }
            if (a === "down") { zone = "row"; rowAt = buttons.indexOf("play") }
            else if (a === "up") zone = inSeg ? "skip" : "back"
        } else if (zone === "row") {
            if (a === "left") rowAt = Math.max(0, rowAt - 1)
            else if (a === "right") rowAt = Math.min(buttons.length - 1, rowAt + 1)
            else if (a === "up") zone = "bar"
            else if (a === "ok") { act(buttons[rowAt]); if (!picking) show(); return }
        } else if (zone === "skip") {
            if (a === "down") zone = "bar"
            else if (a === "up") zone = "back"
            else if (a === "ok") { doSkip(); zone = "bar" }
        } else if (zone === "back") {
            if (a === "down") zone = inSeg ? "skip" : "bar"
            else if (a === "ok") { app.pop(); return }
        }
        show()
    }

    function openSources(): void {
        app.sources({ item: req.item, imdb: req.imdb, season: req.season, episode: req.episode, episodeTitle: req.episodeTitle,
            start: started ? video.time() : undefined })
    }

    /** ok held: what the row doesn't have (qml Osd: the menu key) */
    function options(): void {
        const entries: MenuEntry[] = []
        if (started && list[at]) entries.push({ label: tr("How's this one?"), icon: "feedback", run: rate })
        if (req.item.kind === "show") entries.push({ label: tr("Next Episode"), icon: "next", run: upNextNow })
        entries.push({ label: tr("Start Over"), icon: "restart", run: function () { video.seek(0); show() } })
        entries.push({ label: tr("Sources"), icon: "list", run: function () { video.pause(); openSources() } })
        app.menu(tr("Options"), entries)
    }

    /** the subtitles: the file's own, then the ones found online (qml Tracks) */
    function subsMenu(): void {
        const text = video.textTracks()
        const entries: MenuEntry[] = []
        const any = !!ext || text.some(function (t) { return t.on })
        entries.push({ label: tr("Off"), icon: any ? undefined : "check", run: function () { dropExt(); video.setText(-1); subs.textContent = "" } })
        text.forEach(function (t) {
            entries.push({ label: t.label, icon: t.on && !ext ? "check" : undefined, run: function () { dropExt(); video.setText(t.id) } })
        })
        if (ext) entries.push({ label: extName + "  ·  OpenSubtitles", icon: "check", run: function () { /* on */ } })
        if (req.imdb) entries.push({ label: tr("Search Subtitles"), icon: "search", run: findMenu })
        if (ext) entries.push({ label: tr("Subtitle timing") + (delay ? " (" + (delay > 0 ? "+" : "") + delay.toFixed(1) + " s)" : ""), icon: "clock", run: timingMenu })
        pick()
        app.menu(tr("Subtitles"), entries, above)
    }

    function audioMenu(): void {
        const audio = video.audioTracks()
        const entries: MenuEntry[] = audio.map(function (t): MenuEntry {
            return { label: t.label, icon: t.on ? "check" : undefined, run: function () { video.setAudio(t.id) } }
        })
        // the tv lists no tracks: the one that plays
        if (!entries.length) entries.push({ label: (list[at] && list[at].audio.join(" ")) || tr("Audio"), icon: "check", run: function () { /* on */ } })
        pick()
        app.menu(tr("Audio"), entries, above)
    }

    function subTarget(): sources.Target | null {
        return req.imdb ? { kind: req.item.kind, imdb: req.imdb, season: req.season, episode: req.episode } : null
    }

    function release(): string {
        const s = list[at]
        return s ? (s.filename || s.title) : ""
    }

    function foundList(): Promise<subtitles.Found[]> {
        if (found) return Promise.resolve(found)
        const t = subTarget()
        if (!t) return Promise.resolve([])
        return subtitles.find(t).then(function (f) { found = f; return f })
    }

    /** the preferred language when the file has none of it */
    /** the audio language from settings, when the file has it and doesn't start in it */
    function autoAudio(): void {
        const choice = subtitles.audio()
        if (!choice) return
        const list = video.audioTracks()
        if (list.some(function (t) { return t.on && subtitles.trackIn(choice, t) })) return
        for (let i = 0; i < list.length; i++) if (subtitles.trackIn(choice, list[i])) { video.setAudio(list[i].id); return }
    }

    function autoSubs(): void {
        const order = subtitles.choices()
        if (!order.length || ext) return
        const own = video.textTracks()
        const ownFor = function (choice: string): number {
            for (let i = 0; i < own.length; i++) if (subtitles.trackIn(choice, own[i])) return i
            return -1
        }
        // the first choice the file has wins outright; past that the online ones count too
        const first = ownFor(order[0])
        if (first >= 0) { if (!own[first].on) video.setText(own[first].id); return }
        const r = req
        foundList().then(function (f) {
            if (!alive || req !== r || ext) return
            for (let k = 0; k < order.length; k++) {
                const mine = k ? ownFor(order[k]) : -1
                if (mine >= 0) { if (!own[mine].on) video.setText(own[mine].id); return }
                const pick = subtitles.best(f, order[k], release())[0]
                if (pick) { useExt(pick, false); return }
            }
        })
    }

    function useExt(f: subtitles.Found, say: boolean): void {
        const r = req
        subtitles.load(f.url).then(function (cues) {
            if (!alive || req !== r) return
            video.setText(-1)
            ext = cues
            extId = f.id
            extName = subtitles.languageName(f.lang)
            delay = 0
            clearInterval(extTimer)
            extTimer = window.setInterval(drawExt, 200)
            drawExt()
            if (say) app.toast(tr("Subtitles: %1", extName))
        }, function () { if (say) app.toast(tr("Those subtitles didn't load")) })
    }

    function drawExt(): void { if (ext) subs.textContent = subtitles.at(ext, video.time() - delay) }

    function dropExt(): void {
        clearInterval(extTimer)
        if (ext) subs.textContent = ""
        ext = null
        extId = ""
        delay = 0
    }

    function findMenu(): void {
        app.toast(tr("Looking for subtitles…"))
        foundList().then(function (f) {
            if (!alive) return
            if (!f.length) { app.toast(tr("No subtitles found")); return }
            // the preferred language first (closest releases), then the best of each other one
            const order = subtitles.choices()
            let picks: subtitles.Found[] = []
            order.forEach(function (c, k) { picks = picks.concat(subtitles.best(f, c, release()).slice(0, k ? 3 : 6)) })
            const langs: { [l: string]: boolean } = {}
            f.forEach(function (x) { if (!order.some(function (c) { return subtitles.matches(c, x.lang) })) langs[x.lang] = true })
            Object.keys(langs).forEach(function (l) { const b = subtitles.best(f, l, release())[0]; if (b) picks.push(b) })
            pick()
            app.menu(tr("Search Subtitles"), picks.slice(0, 14).map(function (x): MenuEntry {
                const name = x.name.replace(/\.(srt|vtt|sub|ass)$/i, "")
                return {
                    label: subtitles.languageName(x.lang) + (name ? "  ·  " + (name.length > 42 ? name.slice(0, 41) + "…" : name) : ""),
                    icon: x.id === extId ? "check" : undefined,
                    run: function () { useExt(x, true) },
                }
            }), above)
        })
    }

    /** earlier or later in half seconds; the menu comes back after each step */
    function timingMenu(): void {
        const step = function (d: number): MenuEntry {
            return { label: (d < 0 ? tr("Earlier") : tr("Later")) + " " + Math.abs(d).toFixed(1) + " s", run: function () {
                delay = Math.round((delay + d) * 10) / 10
                drawExt()
                timingMenu()
            } }
        }
        pick()
        app.menu(tr("Subtitle timing") + ": " + (delay > 0 ? "+" : "") + delay.toFixed(1) + " s",
            [step(-0.5), step(0.5), step(-0.1), step(0.1), { label: tr("Reset"), icon: "restart", run: function () { delay = 0; drawExt() } }], above)
    }

    // ---- skip intro (introdb)

    function findSegments(): void {
        const r = req
        if (r.item.kind !== "show" || !r.imdb || r.season === undefined || r.episode === undefined) return
        skip.segments(r.imdb, r.season, r.episode).then(function (s) {
            if (alive && req === r) { segs = s; checkSkip() }
        })
    }

    function checkSkip(): void {
        if (!started || !segs.length) return
        const t = video.time()
        let hit: skip.Segment | null = null
        for (let i = 0; i < segs.length; i++) if (t >= segs[i].start && t < segs[i].end - 1) hit = segs[i]
        // the credits hand over to up next when there's a next episode
        if (hit && hit.kind === "outro" && nextOff) hit = null
        if (hit !== inSeg) showSkip(hit)
    }

    function showSkip(s: skip.Segment | null): void {
        inSeg = s
        if (s) skipBtn.textContent = s.kind === "intro" ? tr("Skip Intro") : s.kind === "recap" ? tr("Skip Recap") : tr("Skip Credits")
        if (!s && zone === "skip") zone = "bar"
        light()
    }

    function doSkip(): void {
        const s = inSeg
        if (!s) return
        showSkip(null)
        if (s.kind === "outro" && req.item.kind === "show") {
            findNext().then(function (n) {
                if (!alive) return
                if (n) { nextReq = n; playNext() } else { nextOff = true; video.seek(Math.max(0, video.duration() - 2)) }
            })
            return
        }
        video.seek(s.end)
    }

    function upNextNow(): void {
        findNext().then(function (n) { if (alive && n) { nextReq = n; playNext() } })
    }

    load(first)
    return {
        el,
        action,
        // a picker or a menu closed over it
        shown(): void { picking = false; show() },
        closed(): void {
            alive = false
            platform.keepAwake(false)
            if (started && !ended) {
                save(false)
                trakt.scrobble(share() >= 0.92 ? "stop" : "pause", target(), share())
            }
            clearTimeout(osdTimer); clearInterval(saveTimer); clearTimeout(startTimer); clearTimeout(seekTimer); clearTimeout(nextTimer); clearInterval(extTimer)
            // the decoder is let go now, not when the element is collected
            video.close()
        },
    }
}
