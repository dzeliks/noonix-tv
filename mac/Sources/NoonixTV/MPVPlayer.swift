#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Libmpv
import Observation
#if os(tvOS)
import AVFoundation
import AVKit
import CoreMedia
#endif

/// moltenvk sets a 1x1 drawable to finish a frame early (flicker), and edr only switches on from
/// the main thread (mpv#13651). handed over async: mpv's vo thread sets it while making the
/// swapchain, and a main thread waiting on mpv (a property read) would never let a sync one in
final class VideoLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set { if newValue.width > 1 && newValue.height > 1 { super.drawableSize = newValue } }
    }

    #if !os(tvOS)
    override var wantsExtendedDynamicRangeContent: Bool {
        get { super.wantsExtendedDynamicRangeContent }
        set {
            if Thread.isMainThread {
                super.wantsExtendedDynamicRangeContent = newValue
            } else {
                DispatchQueue.main.async { self.setEDR(newValue) }
            }
        }
    }

    private func setEDR(_ on: Bool) { super.wantsExtendedDynamicRangeContent = on }
    #endif
}

/// libmpv in the window (gpu-next on moltenvk), with the core's bookkeeping around it like the
/// qt player: playback.open -> loadfile paused -> playback.loaded -> ticks -> playback.stop
@MainActor @Observable
final class MPVPlayer {
    enum State: Equatable { case idle, opening, playing, ended, failed(String) }

    var state: State = .idle
    var title = ""
    var subtitle: String?
    var position: Double = 0
    var duration: Double = 0
    var paused = false
    var logo: String?
    var cacheAhead: Double = 0
    /// the screen's refresh rate follows the video (qml Player.refreshMatch)
    var refreshMatch = false
    var tracks: [Track] = []
    /// intro / recap / outro, from chapters, introdb or the core's guess
    var segments: [Segment] = []
    /// the next episode with its stream, once the core found it (near the end)
    var next: NextUp?
    /// seconds the subtitles are moved by (later +)
    var subDelay: Double = 0
    /// mpv's own volume (the mouse's slider in the player, qml Player.volume / muted)
    var volume: Double = 100
    var muted = false

    struct Segment: Hashable {
        var kind: String
        var start: Double
        var end: Double
    }

    struct NextUp {
        var season: Int
        var episode: Int
        var title: String?
        var still: String?
        var raw: [String: Any]
    }

    struct Track: Identifiable, Hashable {
        var id: Int
        var type: String
        var lang: String?
        var title: String?
        var channels: Int?
        var selected: Bool
        var codec: String?
        var forced = false
        var sdh = false
        var external = false
        var file: String?

        /// the core's shape (playback.loaded tracks, playback.sub)
        var json: [String: Any] {
            var d: [String: Any] = ["id": id, "selected": selected, "forced": forced, "sdh": sdh, "external": external]
            if let lang { d["lang"] = lang }
            if let title { d["title"] = title }
            if let codec { d["codec"] = codec }
            if let channels { d["channels"] = channels }
            if let file { d["file"] = file }
            return d
        }
    }

    @ObservationIgnored let layer = VideoLayer()
    @ObservationIgnored private var mpv: OpaquePointer?
    @ObservationIgnored private var session: Int64 = 0
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var addedSubs: Set<String> = []
    @ObservationIgnored private var subSig = ""

    init() {
        layer.framebufferOnly = true
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    private func create() -> Bool {
        if mpv != nil { return true }
        guard let m = mpv_create() else { return false }
        var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
        mpv_set_option(m, "wid", MPV_FORMAT_INT64, &wid)
        for (k, v) in [
            ("vo", "gpu-next"), ("gpu-api", "vulkan"), ("gpu-context", "moltenvk"), ("hwdec", "videotoolbox"),
            ("target-colorspace-hint", "yes"), ("ytdl", "no"), ("keep-open", "yes"), ("input-default-bindings", "no"),
            // mpv keeps its packets for reuse after a stop: the cache size is also what stays
            ("cache", "yes"), ("demuxer-max-bytes", Platform.ios ? "128MiB" : "200MiB"), ("demuxer-max-back-bytes", "32MiB"), ("sub-auto", "fuzzy"),
            ("osd-level", "0"), ("ao", ProcessInfo.processInfo.environment["NOONIX_MUTE"] == "1" ? "null" : Platform.ios ? "audiounit" : "coreaudio"),
        ] {
            mpv_set_option_string(m, k, v)
        }
        // NOONIX_MPV_LOG=<file>: mpv's own log (dev)
        if let f = ProcessInfo.processInfo.environment["NOONIX_MPV_LOG"] { mpv_set_option_string(m, "log-file", f) }
        guard mpv_initialize(m) >= 0 else { mpv_terminate_destroy(m); return false }
        mpv_observe_property(m, 1, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(m, 2, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(m, 3, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(m, 4, "eof-reached", MPV_FORMAT_FLAG)
        mpv_observe_property(m, 5, "demuxer-cache-duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(m, 6, "track-list", MPV_FORMAT_NONE)
        mpv_observe_property(m, 7, "volume", MPV_FORMAT_DOUBLE)
        mpv_observe_property(m, 8, "mute", MPV_FORMAT_FLAG)
        mpv_set_wakeup_callback(m, { ctx in
            guard let ctx else { return }
            // any mpv thread: the events are read on the main thread
            let me = Unmanaged<MPVPlayer>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { me.drain() } }
        }, Unmanaged.passUnretained(self).toOpaque())
        mpv = m
        Core.shared.on("playback.skip", key: "player") { [weak self] d in self?.pushed(d) }
        Core.shared.on("playback.next", key: "player") { [weak self] d in self?.pushed(d) }
        Core.shared.on("playback.subs", key: "player") { [weak self] d in self?.subsPushed(d) }
        return true
    }

    /// asks the core for the session (start point, languages) and loads the file paused
    func play(_ target: PlayTarget, stream: [String: Any]) async {
        guard create() else { state = .failed(L("The player could not start.")); return }
        stopTicks()
        state = .opening
        title = target.title
        subtitle = target.season.map { "S\($0) · E\(target.episode ?? 0)" + (target.episodeTitle.map { "  " + $0 } ?? "") }
        logo = nil
        tracks = []
        segments = []
        next = nil
        addedSubs = []
        subSig = ""
        subDelay = 0
        position = 0
        duration = 0
        var args: [String: Any] = ["kind": target.kind, "tmdb": target.tmdb, "stream": stream]
        if let s = target.season, let e = target.episode { args["season"] = s; args["episode"] = e }
        if let start = target.start { args["start"] = start }
        do {
            let data = try await Core.shared.raw("playback.open", args)
            guard let r = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let url = r["url"] as? String else { throw CoreError(message: "no address") }
            session = (r["session"] as? NSNumber)?.int64Value ?? 0
            if let item = r["item"] as? [String: Any] {
                if let t = item["title"] as? String { title = t }
                if let sub = item["subtitle"] as? String { subtitle = sub }
                logo = item["logo"] as? String
            }
            let headers = (r["headers"] as? [String] ?? []).map { $0.replacingOccurrences(of: ",", with: "\\,") }
            set("http-header-fields", headers.joined(separator: ","))
            set("alang", r["alang"] as? String ?? "")
            set("slang", r["slang"] as? String ?? "")
            set("force-media-title", title)
            set("pause", "yes")
            let start = (r["start"] as? NSNumber)?.doubleValue ?? 0
            command(["loadfile", url, "replace", "-1", start > 0 ? "start=\(Int(start))" : ""].filter { !$0.isEmpty })
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func setSubDelay(_ s: Double) {
        subDelay = s
        set("sub-delay", String(s))
    }

    func togglePause() { set("pause", paused ? "no" : "yes") }
    func setVolume(_ v: Double) {
        let v = min(100, max(0, v.rounded()))
        set("volume", String(Int(v)))
        // dragging up from nothing: sound again
        if muted && v > 0 { setMuted(false) }
    }
    func setMuted(_ on: Bool) { set("mute", on ? "yes" : "no") }
    /// the app went to the background (ios): the video waits
    func background() { if mpv != nil, !paused { set("pause", "yes") } }
    /// the player's hz button: on / off now and from now on
    func setRefreshMatch(_ on: Bool) {
        refreshMatch = on
        guard session != 0 else { return }
        let mine = session
        Task {
            guard let data = try? await Core.shared.raw("playback.refresh", ["on": on]), mine == session,
                  let r = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            if let d = r["sync"] as? String { set("video-sync", d) }
        }
    }
    func setPaused(_ on: Bool) { set("pause", on ? "yes" : "no") }
    /// subtitles above the osd while it's up (qml Osd chromeShown)
    func setSubtitleLift(_ on: Bool) { set("sub-pos", on ? "77" : "100") }
    /// a quick look while scrubbing: the nearest keyframe
    func seekPreview(_ s: Double) { command(["seek", String(s), "absolute+keyframes"]) }
    func seek(by s: Double) { command(["seek", String(s), "relative"]) }
    func seek(to s: Double) { command(["seek", String(s), "absolute"]) }

    /// leaves the video: saves the point (and scrobbles) like the tv app
    func stop(reason: String = "user") {
        stopTicks()
        #if os(tvOS)
        TVDisplay.reset()
        #endif
        command(["stop"])
        if session != 0 {
            let args: [String: Any] = ["position": position, "duration": duration, "reason": reason]
            session = 0
            // detached: on quit the main thread waits and a main-actor task would never run
            Task.detached { _ = try? await Core.shared.raw("playback.stop", args) }
        }
        state = .idle
    }

    // ---- mpv side

    #if os(tvOS)
    /// the decoded picture's size and colours, once the first frame is out (up to a second)
    private func videoParams() async -> TVDisplay.Video? {
        for _ in 0..<20 {
            guard let mpv else { return nil }
            var w: Int64 = 0, h: Int64 = 0
            mpv_get_property(mpv, "video-params/w", MPV_FORMAT_INT64, &w)
            mpv_get_property(mpv, "video-params/h", MPV_FORMAT_INT64, &h)
            if w > 0 && h > 0 {
                let str = { (n: String) -> String in
                    guard let c = mpv_get_property_string(mpv, n) else { return "" }
                    defer { mpv_free(c) }
                    return String(cString: c)
                }
                return TVDisplay.Video(width: Int32(w), height: Int32(h), gamma: str("video-params/gamma"),
                                       primaries: str("video-params/primaries"), codec: str("video-format"))
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }
    #endif

    private func set(_ name: String, _ value: String) {
        guard let mpv else { return }
        mpv_set_property_string(mpv, name, value)
    }

    private func command(_ args: [String]) {
        guard let mpv else { return }
        var c = args.map { strdup($0) }
        c.append(nil)
        defer { c.forEach { free($0) } }
        c.withUnsafeMutableBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buf.count) { p in
                _ = mpv_command_async(mpv, 0, p)
            }
        }
    }

    private func drain() {
        while let mpv, let e = mpv_wait_event(mpv, 0)?.pointee, e.event_id != MPV_EVENT_NONE {
            switch e.event_id {
            case MPV_EVENT_PROPERTY_CHANGE:
                guard let p = e.data?.assumingMemoryBound(to: mpv_event_property.self).pointee else { break }
                if String(cString: p.name) == "track-list" {
                    if state == .playing { readTracks(); subChanged() }
                    break
                }
                guard let data = p.data else { break }
                switch (String(cString: p.name), p.format) {
                case ("time-pos", MPV_FORMAT_DOUBLE): position = data.assumingMemoryBound(to: Double.self).pointee
                case ("duration", MPV_FORMAT_DOUBLE): duration = data.assumingMemoryBound(to: Double.self).pointee
                case ("pause", MPV_FORMAT_FLAG): paused = data.assumingMemoryBound(to: Int32.self).pointee != 0
                case ("demuxer-cache-duration", MPV_FORMAT_DOUBLE): cacheAhead = data.assumingMemoryBound(to: Double.self).pointee
                case ("volume", MPV_FORMAT_DOUBLE): volume = data.assumingMemoryBound(to: Double.self).pointee
                case ("mute", MPV_FORMAT_FLAG): muted = data.assumingMemoryBound(to: Int32.self).pointee != 0
                case ("eof-reached", MPV_FORMAT_FLAG):
                    if data.assumingMemoryBound(to: Int32.self).pointee != 0, state == .playing {
                        state = .ended
                        stop(reason: "eof")
                        state = .ended
                    }
                default: break
                }
            case MPV_EVENT_FILE_LOADED:
                readTracks()
                loaded()
            case MPV_EVENT_END_FILE:
                if let end = e.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee, end.reason == MPV_END_FILE_REASON_ERROR {
                    state = .failed(String(cString: mpv_error_string(end.error)))
                }
            default:
                break
            }
        }
    }

    /// the file is open (paused): the core picks subtitles and starts scrobbling, then it plays
    private func loaded() {
        guard let mpv else { return }
        var fps = 0.0
        mpv_get_property(mpv, "container-fps", MPV_FORMAT_DOUBLE, &fps)
        // the screen under the window, matched only when it's ours (full screen)
        #if os(macOS)
        let window = NSApp.keyWindow ?? NSApp.windows.first
        let output = (window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? ""
        let full = window?.styleMask.contains(.fullScreen) ?? false
        #else
        // a phone or tablet doesn't switch its refresh rate for us
        let output = "", full = false
        #endif
        let args: [String: Any] = ["duration": duration, "fps": fps, "output": output, "refresh": full,
                                   "chapters": chapters(), "tracks": tracks.filter { $0.type == "sub" && !$0.external }.map(\.json),
                                   "dvProfile": 0]
        let mine = session
        #if os(tvOS)
        let rate = fps
        #endif
        Task {
            let data = try? await Core.shared.raw("playback.loaded", args)
            guard mine == session else { return }
            if let r = data.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) {
                segments = Self.segments(r["segments"])
                if let d = r["sync"] as? String { set("video-sync", d) }
                refreshMatch = r["refresh"] as? Bool ?? false
                // the core's pick among the file's subtitles: a track, or -1 = off
                let pick = (r["subPick"] as? NSNumber)?.intValue ?? 0
                if pick > 0 { set("sid", String(pick)) } else if pick == -1 { set("sid", "no") }
            }
            #if os(tvOS)
            // the tv to the video's frame rate and hdr first, then it plays
            await TVDisplay.match(fps: rate, video: videoParams())
            guard mine == session else { return }
            #endif
            set("pause", "no")
            state = .playing
            tick("start")
            readTracks()
            subChanged()
            ticker = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick("tick") }
            }
        }
    }

    /// the core's pushes for this session: segments, the next episode
    private func pushed(_ data: Data) {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (o["session"] as? NSNumber)?.int64Value == session, session != 0 else { return }
        if o["segments"] != nil { segments = Self.segments(o["segments"]) }
        if let n = o["next"] as? [String: Any], n["stream"] != nil,
           let se = (n["season"] as? NSNumber)?.intValue, let ep = (n["episode"] as? NSNumber)?.intValue {
            next = NextUp(season: se, episode: ep, title: n["title"] as? String, still: n["still"] as? String, raw: n)
        }
    }

    /// subtitles the core found (opensubtitles, the folder): added, the best one on only when the
    /// file had nothing for the preferences or the core says so
    private func subsPushed(_ data: Data) {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (o["session"] as? NSNumber)?.int64Value == session, session != 0 else { return }
        let take = o["take"] as? Bool ?? false
        let on = tracks.contains { $0.type == "sub" && $0.selected }
        var first = true
        for sub in o["subs"] as? [[String: Any]] ?? [] {
            guard let path = sub["path"] as? String, !addedSubs.contains(path) else { continue }
            addedSubs.insert(path)
            command(["sub-add", path, (take || !on) && first ? "select" : "auto", sub["title"] as? String ?? "", sub["lang"] as? String ?? ""])
            first = false
        }
    }

    /// the subtitle on screen changed: the core remembers it and answers with its timing
    private func subChanged() {
        guard session != 0, state == .playing else { return }
        let on = tracks.first { $0.type == "sub" && $0.selected }
        let sig = on.map { "\($0.id)|\($0.file ?? "")" } ?? "off"
        guard sig != subSig else { return }
        subSig = sig
        let mine = session
        let args: [String: Any] = ["track": on?.json ?? NSNull()]
        Task {
            guard let data = try? await Core.shared.raw("playback.sub", args), mine == session, sig == subSig,
                  let r = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            setSubDelay(((r["delayMs"] as? NSNumber)?.doubleValue ?? 0) / 1000)
        }
    }

    private static func segments(_ v: Any?) -> [Segment] {
        (v as? [[String: Any]] ?? []).compactMap { d in
            guard let k = d["kind"] as? String, let a = (d["start"] as? NSNumber)?.doubleValue,
                  let b = (d["end"] as? NSNumber)?.doubleValue else { return nil }
            return Segment(kind: k, start: a, end: b)
        }
    }

    /// the file's chapters (title + time): intros and credits are often marked there
    private func chapters() -> [[String: Any]] {
        guard let mpv else { return [] }
        var count: Int64 = 0
        mpv_get_property(mpv, "chapter-list/count", MPV_FORMAT_INT64, &count)
        return (0..<Int(max(0, count))).map { i in
            var t = 0.0
            mpv_get_property(mpv, "chapter-list/\(i)/time", MPV_FORMAT_DOUBLE, &t)
            var title = ""
            if let c = mpv_get_property_string(mpv, "chapter-list/\(i)/title") { title = String(cString: c); mpv_free(c) }
            return ["title": title, "time": t]
        }
    }

    /// the file's audio and subtitle tracks
    func readTracks() {
        guard let mpv else { return }
        func str(_ n: String) -> String? {
            guard let c = mpv_get_property_string(mpv, n) else { return nil }
            defer { mpv_free(c) }
            return String(cString: c)
        }
        var count: Int64 = 0
        mpv_get_property(mpv, "track-list/count", MPV_FORMAT_INT64, &count)
        tracks = (0..<Int(max(0, count))).compactMap { i in
            let p = "track-list/\(i)/"
            guard let type = str(p + "type"), type != "video", let id = str(p + "id").flatMap(Int.init) else { return nil }
            return Track(id: id, type: type, lang: str(p + "lang"), title: str(p + "title"),
                         channels: str(p + "demux-channel-count").flatMap(Int.init), selected: str(p + "selected") == "yes",
                         codec: str(p + "codec"), forced: str(p + "forced") == "yes", sdh: str(p + "hearing-impaired") == "yes",
                         external: str(p + "external") == "yes", file: str(p + "external-filename"))
        }
    }

    /// a track by id, or 0 = off (subtitles)
    func select(_ type: String, _ id: Int) {
        set(type == "sub" ? "sid" : "aid", id == 0 ? "no" : String(id))
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            readTracks()
        }
    }

    private func tick(_ reason: String) {
        guard session != 0 else { return }
        let args: [String: Any] = ["position": position, "duration": duration, "paused": paused, "reason": reason]
        Task { _ = try? await Core.shared.raw("playback.tick", args) }
    }

    private func stopTicks() {
        ticker?.invalidate()
        ticker = nil
    }
}

/// the speed check: decodes the clip the way playback does (videotoolbox, copied back) on a second,
/// silent mpv and counts frames. `progress(fps, done)` on the main thread, fps 0 = failed
enum DecodeBench {
    static func run(_ path: String, progress: @escaping @MainActor (Double, Bool) -> Void) {
        Thread.detachNewThread {
            let report = { (fps: Double, done: Bool) in Task { @MainActor in progress(fps, done) } }
            guard let m = mpv_create() else { report(0, true); return }
            for (k, v) in [("config", "no"), ("terminal", "no"), ("load-scripts", "no"), ("ytdl", "no"), ("vo", "null"),
                           ("ao", "null"), ("audio", "no"), ("untimed", "yes"), ("loop-file", "inf"), ("hwdec", "videotoolbox-copy")] {
                mpv_set_option_string(m, k, v)
            }
            func get(_ p: String) -> Double {
                var v = -1.0
                return mpv_get_property(m, p, MPV_FORMAT_DOUBLE, &v) >= 0 ? v : -1
            }
            var fps = 0.0
            var load: [UnsafePointer<CChar>?] = [UnsafePointer(strdup("loadfile")), UnsafePointer(strdup(path)), nil]
            defer { load.compactMap { $0 }.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
            if mpv_initialize(m) >= 0, mpv_command(m, &load) >= 0 {
                // the first frame (the decoder takes a moment to open), then a short warm-up
                var t0 = Date()
                while get("time-pos") < 0.2, Date().timeIntervalSince(t0) < 10 { usleep(20_000) }
                let rate = get("container-fps") > 0 ? get("container-fps") : 24
                let length = get("duration") > 0 ? get("duration") : 1
                var last = get("time-pos"), played = 0.0
                if last >= 0 {
                    t0 = Date()
                    var shown = t0
                    while Date().timeIntervalSince(t0) < 2.5 {
                        usleep(50_000)
                        let t = get("time-pos")
                        if t < 0 { continue }
                        played += t >= last ? t - last : length - last + t   // looped
                        last = t
                        fps = played * rate / Date().timeIntervalSince(t0)
                        if Date().timeIntervalSince(shown) > 0.2 { shown = Date(); report(fps, false) }
                    }
                }
            }
            mpv_terminate_destroy(m)
            report(fps, true)
        }
    }
}

#if os(tvOS)
/// apple tv: the tv's mode follows the video (frame rate, hdr10 / hlg). tvos only switches when
/// match content is on in its settings (video and audio), like for every other app
@MainActor
enum TVDisplay {
    struct Video {
        var width: Int32
        var height: Int32
        var gamma: String
        var primaries: String
        var codec: String
    }

    /// nil where the system has none (the simulator)
    private static var manager: AVDisplayManager? {
        guard let w = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.windows.first }).first,
              w.responds(to: NSSelectorFromString("avDisplayManager")) else { return nil }
        return w.avDisplayManager
    }

    /// the tv can show hdr (whether it's in an hdr mode right now or not)
    static var hdr: Bool { AVPlayer.eligibleForHDRPlayback }

    static func match(fps: Double, video: Video?) async {
        guard let manager, manager.isDisplayCriteriaMatchingEnabled, let video else { return }
        var ext: [CFString: Any] = [:]
        switch video.gamma {
        case "pq":
            ext[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
        case "hlg":
            ext[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
        default:
            ext[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_ITU_R_709_2
        }
        let wide = video.primaries == "bt.2020"
        ext[kCMFormatDescriptionExtension_ColorPrimaries] = wide ? kCMFormatDescriptionColorPrimaries_ITU_R_2020 : kCMFormatDescriptionColorPrimaries_ITU_R_709_2
        ext[kCMFormatDescriptionExtension_YCbCrMatrix] = wide ? kCMFormatDescriptionYCbCrMatrix_ITU_R_2020 : kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
        let codec = video.codec.contains("hevc") ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        var desc: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreate(allocator: nil, codecType: codec, width: video.width, height: video.height,
                                             extensions: ext as CFDictionary, formatDescriptionOut: &desc) == noErr,
              let desc else { return }
        manager.preferredDisplayCriteria = AVDisplayCriteria(refreshRate: Float(fps > 0 ? fps : 0), formatDescription: desc)
        // the tv goes dark while it switches: the video waits for it (never longer than 8 s)
        try? await Task.sleep(for: .milliseconds(250))
        let start = Date()
        while manager.isDisplayModeSwitchInProgress, Date().timeIntervalSince(start) < 8 {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// back to the mode the tv had for the menus
    static func reset() { manager?.preferredDisplayCriteria = nil }
}
#endif
