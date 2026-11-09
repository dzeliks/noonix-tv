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
import * as subtitles from "../data/subs"
import * as memory from "../data/memory"
import * as skip from "../data/skip"
import * as engine from "../data/engine"
import * as platform from "../platform"

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
    const el = h("div.player", null, poster, spinner, stateIco, status, osd, skipBtn, nextCard)

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
            return sources.streams({ kind: r.item.kind, imdb: imdb, tmdb: r.item.id, season: r.season, episode: r.episode }).then(function (got) {
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
        srcEl.textContent = [s.resolution ? (s.resolution >= 2160 ? "4K" : s.resolution + "p") : "", s.hdr.join(" "), s.codec || "",
            s.audio.slice(0, 2).join(" "), s.addon, sources.sizeText(s.size)].filter(function (x) { return !!x }).join("  ·  ")
        spinner.style.display = ""
        ended = false
        subs.textContent = ""
        dropExt()
        found = null
        segs = []
        showSkip(null)
        clearTimeout(startTimer)
        const open = function () {
            video.open(s.url)
            // a torrent first finds people and its file list on the server
            startTimer = window.setTimeout(function () { if (!started) fail("no start") }, s.torrent ? startWait * 3 : startWait)
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
        app.menu(tr("How's this one?"), [
            { label: tr("Good match"), icon: "check", run: function () {
                memory.like(req.item.kind, req.item.id, s)
                app.toast(tr("Good match · saved"))
            } },
            { label: tr("Picture or sound problem"), run: function () { memory.report(s); playedGroup = null; otherSource() } },
            { label: tr("Wrong subtitles"), run: findMenu },
            { label: tr("Subtitles out of sync"), run: function () { if (ext) timingMenu(); else findMenu() } },
        ])
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
            stateIco.style.display = "none"
            if (!started) {
                started = true
                clearTimeout(startTimer)
                if (list[at]) playedGroup = list[at].bingeGroup
                poster.style.display = "none"
                say("")
                trakt.scrobble("start", target(), share())
                showOsd()
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
        if (a === "ok" && inSeg && !video.paused()) { doSkip(); return true }
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

    /** audio and subtitle tracks: the file's own, then the ones found online */
    function tracks(): void {
        const audio = video.audioTracks()
        const text = video.textTracks()
        const entries: MenuEntry[] = []
        audio.forEach(function (t) {
            entries.push({ label: tr("Audio") + ": " + t.label, icon: t.on ? "check" : undefined, run: function () { video.setAudio(t.id) } })
        })
        const any = !!ext || text.some(function (t) { return t.on })
        entries.push({ label: tr("Subtitles") + ": " + tr("Off"), icon: any ? undefined : "check", run: function () { dropExt(); video.setText(-1); subs.textContent = "" } })
        text.forEach(function (t) {
            entries.push({ label: tr("Subtitles") + ": " + t.label, icon: t.on && !ext ? "check" : undefined, run: function () { dropExt(); video.setText(t.id) } })
        })
        if (ext) entries.push({ label: tr("Subtitles") + ": " + extName, icon: "check", run: function () { /* on */ } })
        if (req.imdb) entries.push({ label: tr("Find subtitles"), icon: "search", run: findMenu })
        if (ext) entries.push({ label: tr("Subtitle timing") + (delay ? " (" + (delay > 0 ? "+" : "") + delay.toFixed(1) + " s)" : ""), icon: "clock", run: timingMenu })
        if (started && list[at]) entries.push({ label: tr("How's this one?"), icon: "eye", run: rate })
        // the osd's other buttons (qml Osd): for remotes without media keys
        if (req.item.kind === "show") entries.push({ label: tr("Next Episode"), icon: "next", run: upNextNow })
        entries.push({ label: tr("Start Over"), icon: "restart", run: function () { video.seek(0); showOsd() } })
        entries.push({ label: tr("Sources"), icon: "list", run: function () { video.pause(); openSources() } })
        app.menu(tr("Options"), entries)
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
            app.menu(tr("Find subtitles"), picks.slice(0, 14).map(function (x): MenuEntry {
                const name = x.name.replace(/\.(srt|vtt|sub|ass)$/i, "")
                return {
                    label: subtitles.languageName(x.lang) + (name ? "  ·  " + (name.length > 42 ? name.slice(0, 41) + "…" : name) : ""),
                    icon: x.id === extId ? "check" : undefined,
                    run: function () { useExt(x, true) },
                }
            }))
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
        app.menu(tr("Subtitle timing") + ": " + (delay > 0 ? "+" : "") + delay.toFixed(1) + " s",
            [step(-0.5), step(0.5), step(-0.1), step(0.1), { label: tr("Reset"), icon: "restart", run: function () { delay = 0; drawExt() } }])
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
        skipBtn.className = "skipbtn" + (s ? " on" : "")
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
        shown(): void { showOsd() },
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
