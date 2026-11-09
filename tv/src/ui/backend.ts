// what plays the video: the tv's <video> (lg, browsers), or samsung's avplay, which takes the mkv files
// debrid links mostly are and 4k hdr (tizen's <video> does mp4 and hls only)
import { h } from "./dom"
import { platform } from "../platform"

export interface Track { id: number; label: string; on: boolean }

export interface Events {
    playing(): void
    waiting(): void
    error(why: string): void
    time(): void
    ended(): void
    paused(): void
    /** the length is known: a resume can seek now */
    meta(): void
    /** a subtitle line to draw (avplay hands them over, it doesn't draw them); "" clears */
    subtitle(text: string): void
}

export interface Backend {
    el: HTMLElement
    open(url: string): void
    play(): void
    pause(): void
    paused(): boolean
    seek(secs: number): void
    /** seconds */
    time(): number
    duration(): number
    /** how far ahead of the play head is loaded, in seconds from the start */
    buffered(): number
    audioTracks(): Track[]
    setAudio(id: number): void
    textTracks(): Track[]
    /** -1: off */
    setText(id: number): void
    close(): void
}

declare const webapis: any

/** loads samsung's webapis (avplay) once, at start */
export function prepare(): void {
    if (platform.os !== "tizen" || typeof webapis !== "undefined") return
    const s = document.createElement("script")
    s.src = "$WEBAPIS/webapis/webapis.js"
    document.head.appendChild(s)
}

export function backend(ev: Events): Backend {
    if (platform.os === "tizen" && typeof webapis !== "undefined" && webapis.avplay) return avplay(ev)
    return video(ev)
}

// ---- <video>

function video(ev: Events): Backend {
    const v = h("video.video") as HTMLVideoElement
    v.setAttribute("preload", "auto")
    v.addEventListener("playing", ev.playing)
    v.addEventListener("waiting", ev.waiting)
    v.addEventListener("error", function () { ev.error("error " + (v.error ? v.error.code : "?")) })
    v.addEventListener("timeupdate", ev.time)
    v.addEventListener("progress", ev.time)
    v.addEventListener("ended", ev.ended)
    v.addEventListener("pause", function () { if (!v.ended) ev.paused() })
    v.addEventListener("loadedmetadata", ev.meta)
    // the tracks the engine exposes (webOS has audioTracks; chromium only behind a flag)
    const list = function (l: any, kind: string): Track[] {
        const out: Track[] = []
        if (!l) return out
        for (let i = 0; i < l.length; i++) {
            const t = l[i]
            out.push({ id: i, label: t.label || t.language || kind + " " + (i + 1), on: kind === "audio" ? !!t.enabled : t.mode === "showing" })
        }
        return out
    }
    return {
        el: v,
        open(url: string): void {
            v.src = url
            v.load()
            const p = v.play() as Promise<void> | undefined
            if (p && p.catch) p.catch(function (e) { console.warn("play: " + e) })
        },
        play(): void { v.play() },
        pause(): void { v.pause() },
        paused(): boolean { return v.paused },
        seek(secs: number): void { v.currentTime = secs },
        time(): number { return v.currentTime },
        duration(): number { return isFinite(v.duration) ? v.duration : 0 },
        buffered(): number {
            let b = 0
            const t = v.currentTime
            for (let i = 0; i < v.buffered.length; i++) if (v.buffered.start(i) <= t + 1) b = Math.max(b, v.buffered.end(i))
            return b
        },
        audioTracks(): Track[] { return list((v as any).audioTracks, "audio") },
        setAudio(id: number): void {
            const l = (v as any).audioTracks
            if (l) for (let i = 0; i < l.length; i++) l[i].enabled = i === id
        },
        textTracks(): Track[] { return list(v.textTracks, "text") },
        setText(id: number): void {
            for (let i = 0; i < v.textTracks.length; i++) v.textTracks[i].mode = i === id ? "showing" : "disabled"
        },
        close(): void {
            v.pause()
            v.removeAttribute("src")
            v.load()
        },
    }
}

// ---- samsung avplay: draws under the page, through a transparent <object>

function avplay(ev: Events): Backend {
    const av = webapis.avplay
    const el = h("object.video", { type: "application/avplayer" })
    let paused = false
    let dur = 0
    let now = 0
    let ahead = 0
    let done = false

    function trackList(kind: string): Track[] {
        try {
            const cur = av.getCurrentStreamInfo().filter(function (t: any) { return t.type === kind })
                .map(function (t: any) { return t.index })
            return av.getTotalTrackInfo().filter(function (t: any) { return t.type === kind }).map(function (t: any) {
                let info: any = {}
                try { info = JSON.parse(t.extra_info) } catch (e) { /* no extra */ }
                const lang = info.language || info.track_lang || ""
                const label = [lang.toUpperCase(), info.channels ? info.channels + "ch" : "", info.fourCC || ""].filter(function (x) { return !!x }).join(" ")
                return { id: t.index, label: label || kind.toLowerCase() + " " + (t.index + 1), on: cur.indexOf(t.index) >= 0 }
            })
        } catch (e) {
            return []
        }
    }

    return {
        el,
        open(url: string): void {
            done = false
            dur = now = ahead = 0
            // the video is drawn under the page: the page goes see-through while it plays
            document.documentElement.className += " av"
            try {
                av.stop()
                av.close()
            } catch (e) { /* nothing open */ }
            try {
                av.open(url)
                av.setDisplayRect(0, 0, window.innerWidth, window.innerHeight)
                av.setDisplayMethod("PLAYER_DISPLAY_MODE_LETTER_BOX")
                // 4k streams need it asked for before prepare
                if (!platform.lowMemoryDefault) try { av.setStreamingProperty("SET_MODE_4K", "TRUE") } catch (e) { /* hd tv */ }
                av.setListener({
                    onbufferingstart: function () { ev.waiting() },
                    onbufferingcomplete: function () { if (!paused) ev.playing() },
                    oncurrentplaytime: function (ms: number) { now = ms / 1000; ahead = Math.max(ahead, now); ev.time() },
                    onstreamcompleted: function () { done = true; ev.ended() },
                    onerror: function (e: string) { ev.error(String(e)) },
                    onsubtitlechange: function (_ms: number, text: string) { ev.subtitle(text || "") },
                })
                av.prepareAsync(function () {
                    dur = av.getDuration() / 1000
                    ev.meta()
                    av.play()
                    paused = false
                    ev.playing()
                }, function (e: any) { ev.error("prepare " + (e && e.name || e)) })
            } catch (e) {
                ev.error("open " + e)
            }
        },
        play(): void { try { av.play(); paused = false; ev.playing() } catch (e) { /* not ready */ } },
        pause(): void { try { av.pause(); paused = true; ev.paused() } catch (e) { /* not ready */ } },
        paused(): boolean { return paused || done },
        seek(secs: number): void {
            try { av.seekTo(Math.floor(secs * 1000), function () { now = secs; ev.time() }, function () { /* kept */ }) } catch (e) { /* not ready */ }
        },
        time(): number { return now },
        duration(): number { return dur },
        buffered(): number { return ahead },
        audioTracks(): Track[] { return trackList("AUDIO") },
        setAudio(id: number): void { try { av.setSelectTrack("AUDIO", id) } catch (e) { console.warn("audio track: " + e) } },
        textTracks(): Track[] { return trackList("TEXT") },
        setText(id: number): void {
            try {
                if (id < 0) av.setSilentSubtitle(true)
                else { av.setSilentSubtitle(false); av.setSelectTrack("TEXT", id) }
            } catch (e) { console.warn("text track: " + e) }
        },
        close(): void {
            try { av.stop(); av.close() } catch (e) { /* closed */ }
            document.documentElement.className = document.documentElement.className.replace(/ av\b/g, "")
        },
    }
}
