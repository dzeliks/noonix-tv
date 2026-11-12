#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

/// hosts the player's metal layer; mpv draws into it on its own threads
#if os(macOS)
struct VideoSurface: NSViewRepresentable {
    let player: MPVPlayer

    func makeNSView(context: Context) -> NSView {
        let v = Surface()
        v.player = player
        v.layer = player.layer
        v.wantsLayer = true
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {}

    final class Surface: NSView {
        weak var player: MPVPlayer?

        // a resize (full screen, dragging the window) doesn't always lay out a view without subviews
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            fit()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            fit()
        }

        override func layout() {
            super.layout()
            fit()
        }

        private func fit() {
            guard let player else { return }
            let scale = window?.backingScaleFactor ?? 2
            player.layer.contentsScale = scale
            player.surface(CGSize(width: bounds.width * scale, height: bounds.height * scale))
        }
    }
}
#else
struct VideoSurface: UIViewRepresentable {
    let player: MPVPlayer

    func makeUIView(context: Context) -> UIView {
        let v = Surface()
        v.video = player.layer
        v.player = player
        v.layer.addSublayer(player.layer)
        v.backgroundColor = .black
        return v
    }

    func updateUIView(_ v: UIView, context: Context) {}

    final class Surface: UIView {
        var video: CAMetalLayer?
        weak var player: MPVPlayer?

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let video else { return }
            let scale = window?.screen.nativeScale ?? 3
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            video.frame = bounds
            video.contentsScale = scale
            CATransaction.commit()
            player?.surface(CGSize(width: bounds.width * scale, height: bounds.height * scale))
        }
    }
}
#endif

/// the osd's state and keys (qml Osd): zones bar / row, a track picker over the left side
@MainActor @Observable
final class Osd {
    static weak var shared: Osd?

    enum Zone { case bar, row, skip, back }
    enum Button: String { case subs, audio, match, rew, play, fwd, next, vol, full }
    /// the way out is the back button top left for everyone (keys reach it going up, back arms it).
    /// the mouse also gets volume bottom right (refresh matching lives in settings)
    var mouse: Bool { Theme.mouse }
    /// full screen bottom right wherever the window can be something else: the mac, any input, title bar or not
    var fullButton: Bool { !Platform.ios }
    var buttons: [Button] {
        // phones: play and the jumps lead the row on the left, the rest follow
        (Platform.phone ? [.rew, .play, .fwd, .subs, .audio, .match] : [.subs, .audio, .match, .rew, .play, .fwd])
            + (player.next != nil && player.state != .ended ? [.next] : [])
            + (mouse ? [.vol] : []) + (fullButton ? [.full] : [])
    }
    /// "how's this one?" and the subtitle timing, over the left of the row
    var match: MatchModel?
    var timing: Double?        // the delay before the timing sheet opened

    let player: MPVPlayer
    weak var app: AppModel?
    var shown = true { didSet { player.positionShown = shown } }
    var zone: Zone = .bar
    var rowIndex = 4
    var picker: String?          // "sub" | "audio"
    /// the picker's line by its track, so tracks arriving keep the focus on the same one
    var pickerKey = ""
    var pickerIndex: Int {
        get { pickerLines.firstIndex { !$0.header && "\($0.kind):\($0.id)" == pickerKey } ?? 1 }
        set { if let l = pickerLines[safe: newValue] { pickerKey = "\(l.kind):\(l.id)" } }
    }
    /// back once more exits
    var exitArmed = false
    /// what the mouse is on (qml Theme.lit: with the mouse in use only that one is lit)
    var hover: Button?
    var hoverPill = false
    /// a row button's focus look: the keys' focus, or the mouse on it (a finger: the button's own press)
    func lit(_ b: Button) -> Bool {
        Input.pointing ? Theme.mouse && hover == b : zone == .row && buttons[safe: rowIndex] == b
    }
    /// a held left / right's jump so far, riding above the thumb
    var bubble = ""
    @ObservationIgnored private var hide: Task<Void, Never>?
    @ObservationIgnored private var bubbleClear: Task<Void, Never>?
    @ObservationIgnored private var holdDir = 0
    @ObservationIgnored private var holdStart = Date.distantPast
    @ObservationIgnored private var holdLast = Date.distantPast
    @ObservationIgnored private var holdTotal: Double = 0

    init(player: MPVPlayer, app: AppModel) {
        self.player = player
        self.app = app
        Osd.shared = self
        player.positionShown = true
        player.onTime = { [weak self] in self?.pillCheck() }
        show()
    }

    /// the controls always come up on the row's play (qml show): seeking asks for the bar.
    /// left alone while playing they go down after secs, wherever the focus is
    func show(_ secs: Double = 5, _ z: Zone? = nil) {
        if !shown {
            zone = z ?? .row
            rowIndex = buttons.firstIndex(of: .play) ?? 4
            shown = true
        }
        hide?.cancel()
        guard !player.paused, picker == nil else { return }
        hide = Task {
            try? await Task.sleep(for: .seconds(secs))
            if !Task.isCancelled && !player.paused && picker == nil && match == nil && timing == nil { hideNow() }
        }
    }

    /// the mouse on a row button: the focus goes there
    func point(_ b: Button) {
        let i = buttons.firstIndex(of: b) ?? 0
        if zone != .row { zone = .row }
        if rowIndex != i { rowIndex = i }
        show()
    }

    // only what changes is written: the mouse calls show() with every move, and a write is a layout
    func hideNow() {
        if shown { shown = false }
        if zone != .bar { zone = .bar }
        if exitArmed { exitArmed = false }
    }

    /// left / right: 10 s a tap, held = faster and faster (gamepad.lua's curve)
    func heldSeek(_ dir: Int) {
        let now = Date()
        if dir != holdDir || now.timeIntervalSince(holdLast) > 0.45 {
            holdDir = dir; holdStart = now; holdLast = now; holdTotal = 10
            player.seek(by: Double(dir) * 10)
        } else {
            if now.timeIntervalSince(holdLast) < 0.18 { return }
            holdLast = now
            let held = now.timeIntervalSince(holdStart)
            let amount = min(max(10, 3 + held * held * 14), 60)
            holdTotal += amount
            player.seek(by: Double(dir) * amount)
        }
        bubble = (dir > 0 ? "+" : "−") + Theme.time(holdTotal)
        bubbleClear?.cancel()
        bubbleClear = Task {
            try? await Task.sleep(for: .milliseconds(1200))
            if !Task.isCancelled { bubble = ""; holdDir = 0 }
        }
        show(2, .bar)
    }

    // ---- fast-forward / rewind scrubbing (like remote.lua): x8 doubling to x1024, the other
    // button slows down then turns round; paused while the thumb moves, previews from the cache;
    // ok / play / an arrow jumps there, back cancels
    static let scrubRates: [Double] = [8, 16, 32, 64, 128, 256, 512, 1024]
    var scrubLevel = 0
    var scrubDir = 0
    var scrubT: Double = 0
    @ObservationIgnored private var scrubStart: Double = 0
    @ObservationIgnored private var scrubCacheEnd: Double = 0
    @ObservationIgnored private var scrubShown: Double = -1
    @ObservationIgnored private var scrubWasPaused = false
    @ObservationIgnored private var scrubTick: Task<Void, Never>?
    var scrubRate: Double { scrubLevel > 0 ? Self.scrubRates[scrubLevel - 1] : 0 }
    /// where the bar and the times are: the scrub's point while it runs
    var pos: Double { scrubLevel > 0 ? scrubT : player.position }

    func scrubPress(_ dir: Int) {
        if scrubLevel == 0 {
            scrubDir = dir; scrubLevel = 1
            scrubT = player.exactPosition; scrubStart = scrubT; scrubShown = -1
            scrubCacheEnd = player.exactPosition + player.cacheAhead
            scrubWasPaused = player.paused
            player.setPaused(true)
            show(0, .bar)
            zone = .bar
            scrubTick?.cancel()
            scrubTick = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard let self, !Task.isCancelled else { return }
                    self.scrubStep()
                }
            }
        } else if scrubDir == dir {
            scrubLevel = min(Self.scrubRates.count, scrubLevel + 1)
        } else {
            scrubLevel -= 1
            if scrubLevel == 0 { scrubDir = dir; scrubLevel = 1 }
        }
        show()
    }

    @discardableResult func scrubStop(_ commit: Bool) -> Bool {
        guard scrubLevel > 0 else { return false }
        scrubLevel = 0
        scrubTick?.cancel()
        if commit { player.seek(to: scrubT) } else if scrubShown >= 0 { player.seek(to: scrubStart) }
        player.setPaused(scrubWasPaused)
        show(2)
        return true
    }

    private func scrubStep() {
        guard scrubLevel > 0, player.state == .playing else {
            scrubLevel = 0; scrubTick?.cancel(); return
        }
        let dur = player.duration
        let t = scrubT + Double(scrubDir) * scrubRate * 0.25
        scrubT = max(0, dur > 0 ? min(t, dur - 1) : t)
        // the picture follows only where it's already in memory
        let cached = scrubT >= scrubStart - 20 && scrubT <= scrubCacheEnd
        if cached && (scrubShown < 0 || abs(scrubT - scrubShown) >= 1) {
            player.seekPreview(scrubT)
            scrubShown = scrubT
        }
    }

    /// "" | searching | none | added | failed (qml Tracks.search)
    var subSearch = ""
    /// the subtitles + audio buttons' span, which the picker covers
    var leftGroup: (x: CGFloat, w: CGFloat) = (0, 0)
    /// subtitles through the match button, which the match sheet spans
    var matchSpan: (x: CGFloat, w: CGFloat) = (0, 0)
    var buttonFrames: [Button: CGRect] = [:] {
        didSet {
            if let a = buttonFrames[.subs], let b = buttonFrames[.audio] { leftGroup = (a.minX, b.maxX - a.minX) }
            if let a = buttonFrames[.subs], let b = buttonFrames[.match] { matchSpan = (a.minX, b.maxX - a.minX) }
        }
    }

    struct TrackLine { var kind: String; var id: Int; var label: String; var detail = ""; var selected = false; var header = false; var dim = false }

    private static func subKind(_ codec: String?) -> String {
        ["hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle"].contains(codec ?? "") ? L("Image") : ""
    }
    private static func groupOf(_ name: String?) -> String {
        guard let name, let m = name.firstMatch(of: #/-([A-Za-z0-9]{2,})(\.[a-z]{2,4})?$/#) else { return "" }
        return String(m.1)
    }
    private static func audioFormat(_ t: MPVPlayer.Track) -> String {
        let names = ["eac3": "Dolby Digital+", "ac3": "Dolby Digital", "truehd": "Dolby TrueHD", "dts": "DTS", "aac": "AAC",
                     "opus": "Opus", "flac": "FLAC", "mp3": "MP3"]
        let c = names[t.codec ?? ""] ?? (t.codec ?? "").uppercased()
        let ch = t.channels == 8 ? "7.1" : t.channels == 6 ? "5.1" : t.channels == 2 ? L("Stereo") : t.channels == 1 ? L("Mono") : ""
        return [c, ch].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// the picker's lines (qml Tracks.lines): a header, subtitles start with off and end with a search
    var pickerLines: [TrackLine] {
        guard let picker else { return [] }
        var out: [TrackLine] = [], seen: [String: Int] = [:]
        if picker == "audio" {
            out.append(TrackLine(kind: "", id: 0, label: L("Audio"), header: true))
            for t in player.tracks where t.type == "audio" {
                let label = Lang.name(t.lang)
                seen[label, default: 0] += 1
                let n = seen[label]!
                out.append(TrackLine(kind: "audio", id: t.id, label: n > 1 && (t.title ?? "").isEmpty ? "\(label) \(n)" : label,
                                     detail: [t.title ?? "", Self.audioFormat(t)].filter { !$0.isEmpty }.joined(separator: "  ·  "),
                                     selected: t.selected))
            }
            return out
        }
        let subs = player.tracks.filter { $0.type == "sub" }
        out.append(TrackLine(kind: "", id: 0, label: L("Subtitles"), header: true))
        out.append(TrackLine(kind: "sub", id: 0, label: L("Off"), selected: !subs.contains(where: \.selected)))
        for t in subs {
            let label = Lang.name(t.lang) + (t.forced ? " · Forced" : t.sdh ? " · SDH" : "")
            // the same language twice without a title: number them
            seen[label, default: 0] += 1
            let n = seen[label]!
            // an added one: where it's from and the release it was made for, not its file name
            let mine = t.external && (t.file ?? "").firstMatch(of: #/[\\\/]import-[^\\\/]+$/#) != nil
            let made = t.external && !mine ? Self.groupOf(t.title) : ""
            let detail = (mine ? [t.title ?? ""] : t.external ? ["OpenSubtitles", made.isEmpty ? "" : L("made for %1", made)] : [t.title ?? "", Self.subKind(t.codec)])
                .filter { !$0.isEmpty }.joined(separator: "  ·  ")
            out.append(TrackLine(kind: "sub", id: t.id, label: n > 1 && (t.title ?? "").isEmpty ? "\(label) \(n)" : label,
                                 detail: detail, selected: t.selected))
        }
        let say = ["searching": L("Looking on OpenSubtitles…"), "none": L("Nothing new for your languages"),
                   "added": L("Added to the list"), "failed": L("OpenSubtitles isn't answering")]
        out.append(TrackLine(kind: "search", id: -1, label: L("Search Subtitles"), detail: say[subSearch] ?? L("Your languages, from OpenSubtitles"),
                             dim: subSearch == "none"))
        out.append(TrackLine(kind: "file", id: -2, label: L("Add Subtitle File"), detail: L("An .srt or .ass file of your own")))
        return out
    }

    /// a subtitle file of the viewer's own: the core keeps a copy and hands it back as a track
    func addFile() {
        guard let app else { return }
        picker = nil
        hold()
        if SystemFile.available {
            app.systemFile = SystemFile(tag: "sub", max: 8 << 20) { [weak self] r in   // the core's own limit
                guard let self else { return }
                switch r {
                case .file(let path): importSub(path)
                case .tooBig: self.app?.toast(L("That file is too big"))
                case .unreadable: self.app?.toast(L("Couldn't read that file"))
                case .none: break
                }
                release()
                show()
            }
            return
        }
        let p = FolderPickerModel()
        p.files = ["srt", "ass", "ssa", "vtt", "sub"]
        p.caption = L("Add a subtitle file")
        p.picked = { [weak self] path in self?.importSub(path) }
        p.closed = { [weak self] in self?.release() }
        app.folderPicker = p
        p.go("", app: app)
        show()
    }
    private func importSub(_ path: String) {
        Task { [weak app = self.app] in
            if (try? await Core.shared.raw("playback.importSub", ["path": path])) == nil { app?.toast(L("Couldn't read that file")) }
        }
    }

    /// a subtitle search or file pick holds the picture, and plays on after if it was playing
    @ObservationIgnored private var holds = 0
    @ObservationIgnored private var held = false
    private func hold() {
        holds += 1
        if holds == 1 && !player.paused { player.setPaused(true); held = true }
    }
    private func release() {
        guard holds > 0 else { return }
        holds -= 1
        if holds == 0 && held && player.paused && player.state != .ended { player.setPaused(false) }
        if holds == 0 { held = false }
    }

    func searchSubs() {
        if subSearch == "searching" { return }
        // already asked: nothing new until the next title
        if subSearch == "none" { app?.toast(L("No subtitles in your languages for this one"), secs: 5); return }
        subSearch = "searching"
        hold()
        Task {
            defer { release() }
            if let data = try? await Core.shared.raw("playback.searchSubs"),
               let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                subSearch = ((d["count"] as? NSNumber)?.intValue ?? 0) > 0 ? "added" : "none"
                if subSearch == "none" { app?.toast(L("No subtitles in your languages for this one"), secs: 5) }
            } else {
                subSearch = "failed"
                app?.toast(L("OpenSubtitles isn't answering, try again in a bit"), secs: 5)
            }
        }
    }

    /// the segment we're in (intro / recap / outro)
    var segment: MPVPlayer.Segment? {
        player.segments.first { player.exactPosition >= $0.start && player.exactPosition < $0.end - 1 }
    }
    /// the next episode card: the outro, or the last 50 s when the outro starts later (or isn't known)
    var nextUp: Bool {
        guard player.next != nil else { return false }
        return player.state == .ended || (player.duration > 300 && player.exactPosition >= player.duration - 50)
            || segment?.kind == "outro"
    }
    /// kept, not worked out by its readers: they'd follow the position with the controls down
    private(set) var pillShown = false
    func pillCheck() {
        let on = (segment != nil && player.state == .playing) || nextUp
        if on != pillShown { pillShown = on }
    }

    func skipAction() {
        if nextUp { app?.playNext(); return }
        guard let seg = segment else { return }
        player.seek(to: seg.kind == "outro" ? max(0, player.duration - 1) : seg.end)
    }

    /// any picker down (a click beside it, another control)
    func closePickers() { picker = nil; match = nil; show() }

    func act(_ b: Button) {
        // one picker at a time, its own button closes it, anything else takes it down
        let same = (b == .subs && picker == "sub") || (b == .audio && picker == "audio") || (b == .match && match != nil)
        if picker != nil || match != nil { picker = nil; match = nil; if same { show(); return } }
        switch b {
        case .subs, .audio:
            picker = b == .subs ? "sub" : "audio"
            pickerIndex = pickerLines.firstIndex { !$0.header && $0.selected } ?? 1
        case .rew: player.seek(by: -10)
        case .play: player.togglePause()
        case .fwd: player.seek(by: 10)
        case .match: openMatch()
        case .next: app?.playNext(); return
        case .vol: player.setMuted(!player.muted)
        case .full:
            #if os(macOS)
            WindowState.shared.toggle()
            #endif
        }
        show()
    }

    /// ok on a line: that track and the picker goes, or the search
    func pick(_ i: Int) {
        guard let l = pickerLines[safe: i], !l.header else { return }
        if l.kind == "search" { searchSubs(); return }
        if l.kind == "file" { addFile(); return }
        player.select(l.kind, l.id)
        picker = nil
        show()
    }

    func movePicker(_ d: Int) {
        let lines = pickerLines
        var i = pickerIndex + d
        while lines.indices.contains(i), lines[i].header { i += d }
        if lines.indices.contains(i) { pickerIndex = i }
    }

    func openMatch() {
        Task {
            guard let data = try? await Core.shared.raw("match.state"),
                  let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            match = MatchModel(info: info)
            show()
        }
    }

    func key(_ k: Key) -> Bool {
        if k == .ff || k == .rw { if timing == nil && match == nil && picker == nil { scrubPress(k == .ff ? 1 : -1) }; return true }
        if scrubLevel > 0 {
            if k == .back { scrubStop(false) } else if [.playPause, .ok, .left, .right].contains(k) { scrubStop(true) }
            return true
        }
        if k == .stop { app?.stopPlayback(); return true }
        if k == .pageUp || k == .pageDown { player.seek(by: k == .pageUp ? 30 : -30); show(); return true }
        if k == .next { if player.next != nil { app?.playNext() }; return true }
        if let before = timing {
            switch k {
            case .left: nudge(-0.1)
            case .right: nudge(0.1)
            case .up: nudge(1)
            case .down: nudge(-1)
            case .ok: closeTiming(save: true)
            case .back: player.setSubDelay(before); closeTiming(save: false)
            case .playPause: player.togglePause()
            default: break
            }
            return true
        }
        if let m = match {
            switch k {
            case .up: m.index = max(0, m.index - 1)
            case .down: m.index = min(m.lines.count - 1, m.index + 1)
            case .ok: choose(m.lines[m.index].id)
            case .back, .menu, .left, .right: match = nil; show()
            default: break
            }
            return true
        }
        if k == .menu { show(); zone = .row; rowIndex = buttons.firstIndex(of: .match) ?? 2; openMatch(); return true }
        if picker != nil {
            switch k {
            case .up: movePicker(-1)
            case .down: movePicker(1)
            case .ok: pick(pickerIndex)
            case .back: picker = nil; show()
            default: break
            }
            return true
        }
        if k == .back {
            if exitArmed || player.state == .ended { app?.stopPlayback(); return true }
            if shown { hideNow(); return true }
            // first back with the controls down: land on the back button, a second one leaves
            show()
            zone = .back
            exitArmed = true
            return true
        }
        if k == .playPause { player.togglePause(); return true }
        exitArmed = false
        if !shown {
            switch k {
            case .left: heldSeek(-1)
            case .right: heldSeek(1)
            case .ok where pillShown: skipAction()
            default: show()
            }
            return true
        }
        switch zone {
        case .bar:
            switch k {
            case .left: heldSeek(-1); return true
            case .right: heldSeek(1); return true
            case .ok: player.togglePause()
            case .down: zone = .row; rowIndex = buttons.firstIndex(of: .play) ?? 4
            case .up: zone = pillShown ? .skip : .back
            default: break
            }
        case .skip:
            switch k {
            case .down: zone = .bar
            case .up: zone = .back
            case .ok: skipAction()
            default: break
            }
            if !pillShown && zone == .skip { zone = .bar }
        case .back:
            switch k {
            case .down: zone = pillShown ? .skip : .bar
            case .ok: app?.stopPlayback(); return true
            default: break
            }
        case .row:
            switch k {
            case .left: rowIndex = max(0, rowIndex - 1)
            case .right: rowIndex = min(buttons.count - 1, rowIndex + 1)
            case .up: zone = .bar
            case .ok: act(buttons[min(rowIndex, buttons.count - 1)])
            default: break
            }
        }
        show()
        return true
    }
}

extension Osd {
    // ---- the match sheet's fixes (qml Main.matchAction)
    func choose(_ what: String) {
        match = nil
        if what == "timing" { openTiming(); return }
        Task {
            if what == "good" {
                let ok = (try? await Core.shared.raw("match.rate", ["verdict": "good"])) != nil
                app?.toast(ok ? L("Saved · Noonix TV picks these again") : L("Couldn't save that"))
                return
            }
            guard (try? await Core.shared.raw("match.rate", ["verdict": "bad", "reason": what])) != nil else {
                app?.toast(L("Couldn't save that"))
                return
            }
            if what == "av" { await nextSource() } else { await nextSubs(what) }
        }
    }

    private func nextSubs(_ why: String) async {
        app?.toast(L("Finding other subtitles…"))
        let subs = player.tracks.filter { $0.type == "sub" }.map(\.json)
        guard let data = try? await Core.shared.raw("match.nextSub", ["tracks": subs]),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            app?.toast(L("Couldn't look for other subtitles"))
            return
        }
        let left = (d["left"] as? NSNumber)?.intValue ?? 0
        let more = left > 0 ? "  ·  " + Ln("%n more to try", left) : ""
        if let sel = (d["select"] as? NSNumber)?.intValue, sel > 0 {
            player.select("sub", sel)
            app?.toast(L("Subtitles switched") + more)
        } else if d["added"] as? Bool == true || (d["added"] as? NSNumber)?.intValue ?? 0 > 0 {
            app?.toast(L("Subtitles switched") + more)
        } else if why == "sync" {
            app?.toast(L("No other subtitles · set the timing"))
            openTiming()
        } else {
            app?.toast(L("No other subtitles in your languages"))
        }
    }

    /// another source at the same spot; none left = the sources sheet
    private func nextSource() async {
        app?.toast(L("Switching source…"))
        guard let data = try? await Core.shared.raw("match.nextSource", ["position": player.exactPosition, "addon": ""]),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            app?.toast(L("No other source left"))
            return
        }
        guard let stream = d["stream"] as? [String: Any], let t = d["target"] as? [String: Any], let app else {
            app?.toast(L("No other source left"))
            if let t = app?.playTarget { app?.openSources(t) }
            return
        }
        let cur = app.playTarget
        let target = PlayTarget(kind: t["kind"] as? String ?? cur?.kind ?? "movie",
                                tmdb: (t["tmdb"] as? NSNumber)?.intValue ?? cur?.tmdb ?? 0,
                                season: (t["season"] as? NSNumber)?.intValue, episode: (t["episode"] as? NSNumber)?.intValue,
                                title: cur?.title ?? "", episodeTitle: cur?.episodeTitle,
                                start: (d["start"] as? NSNumber)?.doubleValue ?? player.exactPosition)
        app.playTarget = target
        await player.play(target, stream: stream)
    }

    // ---- subtitle timing (qml Timing): left / right 0.1 s, up / down 1 s, ok keeps, back undoes
    func openTiming() {
        hideNow()
        timing = player.subDelay
    }

    func nudge(_ d: Double) {
        player.setSubDelay(max(-60, min(60, ((player.subDelay + d) * 10).rounded() / 10)))
    }

    /// kept only when it moved (qml Timing.finish)
    func closeTiming(save: Bool) {
        let before = timing
        timing = nil
        guard save, player.subDelay != before else { return }
        Task {
            let ok = (try? await Core.shared.raw("match.offset", ["ms": Int((player.subDelay * 1000).rounded())])) != nil
            app?.toast(ok ? L("Timing kept for these subtitles") : L("Couldn't keep the timing"))
        }
    }
}

@MainActor @Observable
final class MatchModel {
    struct Line { var id: String; var icon: String; var label: String; var detail: String }
    let info: [String: Any]
    var index = 0
    init(info: [String: Any]) { self.info = info }

    var sub: [String: Any]? { info["sub"] as? [String: Any] }
    var liked: Bool {
        func good(_ k: String) -> Bool { ((info[k] as? [String: Any])?["verdict"] as? NSNumber)?.intValue == 2 }
        return good("releaseMark") && (sub == nil || good("subMark"))
    }
    var release: String { (info["release"] as? [String: Any])?["label"] as? String ?? L("This source") }
    /// "English · SDH · In the file", "Serbian · OpenSubtitles · made for KILLERS"
    var subLine: String {
        guard let s = sub else { return L("Subtitles off") }
        let lang = Lang.name(s["lang"] as? String)
        var parts = [lang]
        if s["embedded"] as? Bool == true {
            if let n = s["name"] as? String, !n.isEmpty, !n.lowercased().contains(lang.lowercased()) { parts.append(n) }
            parts.append(L("In the file"))
        } else {
            parts.append(s["provider"] as? String == "file" ? L("Added") : "OpenSubtitles")
            if let g = s["group"] as? String, !g.isEmpty { parts.append(L("made for %1", g)) }
        }
        return parts.joined(separator: "  ·  ")
    }

    var lines: [Line] {
        let on = sub != nil
        var out = [Line(id: "good", icon: "checkmark.circle", label: liked ? L("Good match · saved") : L("Good match"),
                        detail: on ? L("Remember this source and subtitles") : L("Remember this source"))]
        if on {
            out.append(Line(id: "sync", icon: "arrow.triangle.2.circlepath", label: L("Subtitles out of sync"), detail: L("Try others, then set the timing")))
            out.append(Line(id: "wrong", icon: "captions.bubble", label: L("Wrong subtitles"), detail: L("Another episode, language or cut")))
        }
        out.append(Line(id: "av", icon: "film", label: L("Picture or sound problem"), detail: L("Another source, from the same spot")))
        if on { out.append(Line(id: "timing", icon: "slider.horizontal.3", label: L("Subtitle timing"), detail: L("Move them earlier or later"))) }
        return out
    }
}

struct MatchSheet: View {
    let osd: Osd
    let model: MatchModel
    let u: CGFloat
    /// the line a finger is down on
    @GestureState private var downAt: Int?

    /// the timing line says where it's set now
    private func detail(_ l: MatchModel.Line) -> String {
        let d = osd.player.subDelay
        guard l.id == "timing", d != 0 else { return l.detail }
        return (d > 0 ? "+" : "−") + String(format: "%.1f s", abs(d)) + "  ·  " + (d > 0 ? L("later") : L("earlier"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4 * u) {
                Text(L("How's this one?")).font(Theme.display(30 * u, .bold)).foregroundStyle(Theme.fg)
                Text(model.release).font(Theme.text(21 * u, .medium)).foregroundStyle(Theme.fg2)
                Text(model.subLine).font(Theme.text(20 * u)).foregroundStyle(Theme.fg3)
            }
            .lineLimit(1)
            .padding(.horizontal, 30 * u)
            .padding(.top, 14 * u)
            .padding(.bottom, 18 * u)
            ForEach(Array(model.lines.enumerated()), id: \.offset) { i, l in
                // a finger sees no focus, only the press
                let foc = Theme.touch ? downAt == i : model.index == i
                HStack(spacing: 24 * u) {
                    Image(systemName: l.icon).font(.system(size: 30 * u, weight: .medium))
                        .foregroundStyle(foc ? Theme.focusFg : l.id == "good" && model.liked ? Theme.accent : Theme.fg)
                        .frame(width: 36 * u)
                    VStack(alignment: .leading, spacing: 4 * u) {
                        Text(l.label).font(Theme.text(26 * u, .medium)).foregroundStyle(foc ? Theme.focusFg : Theme.fg)
                        Text(detail(l)).font(Theme.text(20 * u)).foregroundStyle(foc ? Theme.focusFg.opacity(0.6) : Theme.fg3)
                    }
                    .lineLimit(1)
                }
                .padding(.horizontal, 30 * u)
                .frame(maxWidth: .infinity, minHeight: (Theme.touch ? 90 : 108) * u, alignment: .leading)
                .background { RoundedRectangle(cornerRadius: 24 * u).fill(foc ? Color.white : .clear) }
                .contentShape(.rect)
                .onContinuousHover { phase in if case .active = phase, Input.pointerLive, model.index != i { model.index = i } }
                .onTapGesture { osd.choose(l.id) }
                #if os(iOS)
                .simultaneousGesture(DragGesture(minimumDistance: 0).updating($downAt) { _, d, _ in d = i })
                #endif
            }
        }
        .padding(16 * u)
        .panelGlass(40 * u, u: u, lift: -0.35)
    }
}

/// the subtitle timing, big in the middle of the bottom (qml Timing). the mouse or a finger: the arrows
/// and keep / undo are buttons, a tap outside keeps it
struct TimingSheet: View {
    let osd: Osd
    let u: CGFloat

    var body: some View {
        let player = osd.player
        let d = player.subDelay
        let pointing = Theme.mouse || Theme.touch
        ZStack(alignment: .top) {
            HStack {
                if pointing {
                    RoundButton(icon: "chevron.left", u: u) { osd.nudge(-0.1) }
                    Spacer()
                    RoundButton(icon: "chevron.right", u: u) { osd.nudge(0.1) }
                } else {
                    Image(systemName: "chevron.left").frame(width: 64 * u)
                    Spacer()
                    Image(systemName: "chevron.right").frame(width: 64 * u)
                }
            }
            .font(.system(size: 30 * u, weight: .semibold)).foregroundStyle(Theme.fg2)
            .frame(height: 64 * u)
            .padding(.horizontal, 28 * u).padding(.top, 28 * u)
            VStack(spacing: 2 * u) {
                Text((d > 0 ? "+" : d < 0 ? "−" : "") + String(format: "%.1f s", abs(d)))
                    .font(Theme.rounded(50 * u, .bold)).monospacedDigit().foregroundStyle(Theme.fg)
                Text(d > 0 ? L("Subtitles later") : d < 0 ? L("Subtitles earlier") : L("Subtitle timing"))
                    .font(Theme.text(23 * u, .medium)).foregroundStyle(Theme.fg2)
            }
            .padding(.top, 22 * u)
            if pointing {
                HStack(spacing: 20 * u) {
                    GlassButton(text: L("Undo"), focused: false, u: u * 0.85, flat: true)
                        .onTapGesture { osd.closeTiming(save: false) }
                    GlassButton(text: L("Keep"), primary: true, focused: false, u: u * 0.85, flat: true)
                        .onTapGesture { osd.closeTiming(save: true) }
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 28 * u)
            } else {
                Text("◀ ▶  0.1 s     ▲ ▼  1 s     Return  keep     Esc  undo")
                    .font(Theme.text(19 * u, .medium)).foregroundStyle(Theme.fg3)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 20 * u)
            }
        }
        .frame(width: 720 * u, height: (pointing ? 262 : 168) * u)
        .panelGlass(44 * u, u: u, lift: -0.25)
    }
}

/// the video full window with the tv osd over it
struct PlayerView: View {
    @Environment(AppModel.self) private var app
    let player: MPVPlayer
    @State private var osd: Osd?
    /// the last tap on the picture: two on one side jump
    @State private var lastTap: (at: Date, side: Int)?

    var body: some View {
        ZStack {
            Color.black
            VideoSurface(player: player)

            if case .failed(let why) = player.state {
                VStack(spacing: 18 * app.u) {
                    Text("Can't play this one").font(Theme.display(34 * app.u, .semibold))
                    Text(why).font(Theme.text(24 * app.u)).foregroundStyle(Theme.fg2)
                }
            }
            if let osd {
                // gone, not just see-through, while hidden: glass over a moving picture is redrawn by the
                // system every frame (cpu, battery) even at opacity 0, and nothing follows the position
                if osd.shown || player.state == .ended {
                    OsdView(osd: osd, u: app.u, size: app.size)
                        .transition(.opacity.animation(.easeOut(duration: 0.26)))
                }
                PillHost(osd: osd, u: app.u, size: app.size)
                // the timing capsule stays up with the controls down
                if osd.timing != nil {
                    Color.clear.contentShape(.rect).onTapGesture { osd.closeTiming(save: true) }
                    TimingSheet(osd: osd, u: app.u)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, 64 * app.u)
                }
            }
            if let c = app.tipChoice {
                MatchTipView(choice: c)
                    .transition(.opacity.animation(.timingCurve(0.33, 1, 0.68, 1, duration: 0.22)))
            }
        }
        .contentShape(.rect)
        .onContinuousHover { _ in if Input.pointerLive { osd?.show() } }
        #if os(iOS)
        // a finger: a tap shows or hides them (like phone players), a double tap on a side jumps 10 s
        .onTapGesture(coordinateSpace: .local) { at in
            if osd?.picker != nil || osd?.match != nil { osd?.closePickers(); return }
            let W = app.size.width
            let side = at.x < W / 3 ? -1 : at.x > W * 2 / 3 ? 1 : 0
            let now = Date()
            if let last = lastTap, side != 0, last.side == side, now.timeIntervalSince(last.at) < 0.35 {
                // the first tap of the pair toggled the controls: keep them up while jumping
                player.seek(by: Double(side * 10))
                osd?.show()
                lastTap = (now, side)
                return
            }
            lastTap = (now, side)
            if osd?.shown == true { osd?.hideNow() } else { osd?.show() }
        }
        #else
        .onTapGesture {
            #if os(macOS)
            // the second click of a pair: full screen, and the first one's pause taken back. counted here, not
            // with a count: 2 gesture: swiftui then holds every click, the buttons' too, until a second can't come
            if let last = lastTap, Date().timeIntervalSince(last.at) < NSEvent.doubleClickInterval {
                lastTap = nil
                if last.side == 1 { player.togglePause() }
                NSApp.keyWindow?.toggleFullScreen(nil)
                return
            }
            let pauses = osd?.picker == nil && osd?.match == nil && osd?.shown == true
            lastTap = (Date(), pauses ? 1 : 0)
            #endif
            if osd?.picker != nil || osd?.match != nil { osd?.closePickers() }
            else if osd?.shown == true { player.togglePause() } else { osd?.show() }
        }
        #endif
        .onAppear { osd = Osd(player: player, app: app) }
        // paused: up for good; playing again: down soon
        .onChange(of: player.paused) {
            MediaKeys.playing(true, paused: player.paused)
            if osd?.scrubLevel == 0 { osd?.show(player.paused ? 5 : 2) }
        }
        // the end: the next episode card takes the focus, otherwise back to where we were
        .onChange(of: player.state) {
            // a new title: its subtitles haven't been looked for yet
            if player.state == .opening { osd?.subSearch = "" }
            osd?.pillCheck()
            if player.state == .playing { osd?.show(5); app.scheduleTip(); player.setSubtitleLift(true) }
            guard player.state == .ended else { return }
            if player.next != nil { osd?.show(); osd?.zone = .skip } else { app.stopPlayback() }
        }
        .onChange(of: (osd?.shown ?? true) || player.state == .ended, initial: true) { _, up in player.setSubtitleLift(up) }
        #if os(macOS)
        // the cursor goes with the controls, until the mouse moves again
        .onHover { inside in NSCursor.setHiddenUntilMouseMoves(inside && !(osd?.shown ?? true)) }
        .onChange(of: osd?.shown ?? true) { _, up in if !up { NSCursor.setHiddenUntilMouseMoves(true) } }
        #endif
    }
}

struct OsdView: View {
    let osd: Osd
    let u: CGFloat
    let size: CGSize
    @State private var leftW: CGFloat = 0
    @State private var fullLeftW: CGFloat = 0
    @State private var rightW: CGFloat = 0
    @State private var transportW: CGFloat = 0

    var body: some View {
        let p = osd.player
        let W = size.width, H = size.height, margin = Theme.margin(u)
        let pos = osd.pos, dur = p.duration
        let picking = osd.picker != nil || osd.match != nil
        // the scrub / held-seek chip rides above the thumb: the title steps aside for it
        let chip = !osd.bubble.isEmpty || osd.scrubLevel > 0
        ZStack(alignment: .topLeading) {
            LinearGradient(stops: [.init(color: .black.opacity(0), location: 0),
                                   .init(color: .black.opacity(0.42), location: 0.55),
                                   .init(color: .black.opacity(0.7), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(width: W, height: 560 * u)
                .offset(y: H - 560 * u)
            LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                .frame(width: W, height: 220 * u)

            // clock + ends at, top right
            VStack(alignment: .trailing, spacing: 2 * u) {
                TimelineView(.everyMinute) { ctx in
                    // sf rounded's tabular digits stop short of their advance: the ink lines up with "ends at" under it
                    Text(Theme.clock(ctx.date))
                        .font(Theme.rounded(46 * u, .bold)).foregroundStyle(Theme.fg).monospacedDigit()
                        .offset(x: 12 * u)
                    if dur - pos > 1 {
                        Text(L("Ends at %1", Theme.endsAt(dur - pos))).font(Theme.text(25 * u, .medium)).foregroundStyle(Theme.fg2)
                    }
                }
            }
            .frame(width: W - margin, alignment: .trailing)
            .padding(.top, 56 * u)

            // the way out, top left like every page's back (a key reaches it going up, back arms it)
            RoundButton(icon: "chevron.left", u: u, size: 76, lit: osd.exitArmed || (osd.zone == .back && !Input.pointing)) {
                osd.app?.stopPlayback()
            }
            .offset(x: margin, y: WindowState.shared.belowLights(56 * u))

            // logo / title in a fixed box, bottom edge at H-336, the episode line under it
            LogoBox(url: p.logo, title: p.title, titleSize: 54 * u, leading: true)
                .frame(width: 520 * u, height: 150 * u)
                .offset(x: margin, y: H - 336 * u - 150 * u)
                .opacity(picking || chip ? 0 : 1)
                .animation(.easeInOut(duration: 0.16), value: picking || chip)
            if let sub = p.subtitle {
                Text(sub).font(Theme.display(30 * u, .semibold)).foregroundStyle(Theme.fg)
                    .offset(x: margin, y: H - 298 * u)
                    .opacity(picking || chip ? 0 : 1)
                    .animation(.easeInOut(duration: 0.16), value: picking || chip)
            }

            SeekBar(osd: osd, u: u)
                .frame(width: W - 2 * margin, height: 8 * u)
                .offset(x: margin, y: H - 214 * u)

            Text(Theme.time(pos)).font(Theme.text(25 * u, .medium)).monospacedDigit().foregroundStyle(Theme.fg2)
                .offset(x: margin, y: H - 170 * u)
                .opacity(picking ? 0 : 1)
            Text("-" + Theme.time(dur - pos)).font(Theme.text(25 * u, .medium)).monospacedDigit().foregroundStyle(Theme.fg2)
                .frame(width: W - margin, alignment: .trailing)
                .offset(y: H - 170 * u)

            buttonRow(W: W, H: H, margin: margin)

            if osd.picker != nil {
                TrackPicker(osd: osd, u: u, size: size)
            }
            if let m = osd.match {
                // spans the left group (subtitles, audio, match), its bottom just above the row
                let w = max(osd.matchSpan.w, 540 * u)
                MatchSheet(osd: osd, model: m, u: u)
                    .frame(width: w)
                    .offset(x: min(osd.matchSpan.w > 0 ? osd.matchSpan.x : margin, W - w - margin))
                    .frame(width: W, height: H - 140 * u, alignment: .bottomLeading)
            }
        }
        .frame(width: W, height: H, alignment: .topLeading)
        .coordinateSpace(.named("osd"))
    }

    private func buttonRow(W: CGFloat, H: CGFloat, margin: CGFloat) -> some View {
        let p = osd.player
        let focusOf: (Osd.Button) -> Bool = { b in osd.lit(b) }
        let subLabel = p.tracks.first { $0.type == "sub" && $0.selected }.map { Lang.name($0.lang) } ?? L("Off")
        let audioLabel: String = {
            guard let t = p.tracks.first(where: { $0.type == "audio" && $0.selected }) else { return L("Audio") }
            let ch = t.channels == 6 ? "5.1" : t.channels == 8 ? "7.1" : t.channels == 2 ? L("Stereo") : ""
            // a track without a language says what it is, not "unknown"
            let known = !(t.lang ?? "").isEmpty && t.lang != "und"
            return (known ? Lang.name(t.lang) : L("Audio")) + (ch.isEmpty ? "" : "  ·  " + ch)
        }()
        // a narrow screen: where the row runs into the right buttons, subtitles and audio go without
        // their labels. phones: the capsule leads on the left, the rest follow it
        let compact = margin + fullLeftW + 18 * u + transportW + 18 * u > W - margin - rightW
        let phone = Platform.phone
        let left = HStack(spacing: 18 * u) {
            rowButton(.subs, text: compact ? "" : subLabel, icon: "tv.subtitles", focused: focusOf(.subs))
            rowButton(.audio, text: compact ? "" : audioLabel, icon: "speaker.wave.2", focused: focusOf(.audio))
            rowButton(.match, text: "", icon: "text.bubble", focused: focusOf(.match))
        }
        return ZStack(alignment: .topLeading) {
            GlassEffectContainer(spacing: 18 * u) {
                HStack(spacing: 18 * u) {
                    left
                        .padding(.leading, phone ? transportW + 18 * u : 0)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { leftW = $0 }
                        // the width with the labels, to know when they don't fit
                        .background(alignment: .leading) {
                            HStack(spacing: 18 * u) {
                                GlassButton(text: subLabel, icon: "tv.subtitles", focused: false, u: u)
                                GlassButton(text: audioLabel, icon: "speaker.wave.2", focused: false, u: u)
                                GlassButton(text: "", icon: "text.bubble", focused: false, u: u)
                            }
                            .fixedSize()
                            .hidden()
                            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { fullLeftW = $0 }
                        }
                    Spacer(minLength: 0)
                    HStack(spacing: 18 * u) {
                        if osd.buttons.contains(.next) {
                            rowButton(.next, text: L("Next Episode"), icon: "forward.end.fill", focused: focusOf(.next))
                        }
                        if osd.buttons.contains(.vol) {
                            VolumeControl(osd: osd, u: u)
                        }
                        if osd.buttons.contains(.full) {
                            rowButton(.full, text: "", icon: WindowState.shared.fullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                      focused: focusOf(.full))
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rightW = $0 }
                }
            }
            .padding(.horizontal, margin)
            .frame(width: W, height: 104 * u)

            // transport in one glass capsule: 14 round the 76 circles, 10 round play. ios: as tall as
            // the other buttons (76), 6 round its 64 play
            let small = Platform.ios
            HStack(spacing: (small ? 4 : 10) * u) {
                ForEach([Osd.Button.rew, .play, .fwd], id: \.self) { b in
                    TransportKey(osd: osd, b: b, focused: focusOf(b), small: small, u: u)
                }
            }
            .padding(.horizontal, (small ? 6 : 14) * u)
            .frame(height: (small ? 76 : 104) * u)
            .glassEffect(.regular, in: .capsule)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { transportW = $0 }
            .frame(height: 104 * u)
            .offset(x: phone ? margin : max((W - transportW) / 2, margin + leftW + 18 * u))
        }
        .frame(width: W, height: 104 * u, alignment: .topLeading)
        .offset(y: H - 86 * u - 52 * u)
    }

    private func rowButton(_ b: Osd.Button, text: String, icon: String, focused: Bool) -> some View {
        GlassButton(text: text, icon: icon, focused: focused, u: u)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("osd")) } action: { osd.buttonFrames[b] = $0 }
            .onContinuousHover { phase in
                if case .active = phase {
                    if osd.hover != b { osd.hover = b }
                    if Input.pointerLive { osd.point(b) }
                } else if osd.hover == b { osd.hover = nil }
            }
            .onTapGesture { osd.act(b) }
    }
}

/// rewind / play / forward in the transport capsule
private struct TransportKey: View {
    let osd: Osd
    let b: Osd.Button
    let focused: Bool
    var small = false
    let u: CGFloat
    @State private var box = CGRect.zero
    private var down: Bool { FingerDown.on(box) }

    var body: some View {
        // touch: play is the white one, the others light while pressed
        let foc = Theme.touch ? b == .play || down : focused
        let d = (small ? (b == .play ? 64 : 58) : (b == .play ? 84 : 76)) * u
        Image(systemName: b == .play ? (osd.player.paused ? "play.fill" : "pause.fill") : b == .rew ? "arrow.counterclockwise" : "arrow.clockwise")
            .font(.system(size: (b == .play ? 34 : 28) * (small ? 0.76 : 1) * u, weight: .semibold))
            .contentTransition(.symbolEffect(.replace, options: .speed(2.5)))
            .foregroundStyle(foc ? Theme.focusFg : Theme.fg)
            .frame(width: d, height: d)
            .background { Circle().fill(foc ? Color.white : .clear).scaleEffect(foc ? 1.1 : 1) }
            .animation(Theme.lift, value: foc)
            .contentShape(.circle)
            .onContinuousHover { phase in
                if case .active = phase {
                    if osd.hover != b { osd.hover = b }
                    if Input.pointerLive { osd.point(b) }
                } else if osd.hover == b { osd.hover = nil }
            }
            .onTapGesture { osd.act(b) }
            #if !os(macOS)
            .pressBox($box)
            #endif
    }
}

/// skip intro / recap / credits, or the next episode card near the end (no countdown, house
/// rule); white while it has the focus, which it has whenever the controls are down
/// the pill only while it shows
struct PillHost: View {
    let osd: Osd
    let u: CGFloat
    let size: CGSize

    var body: some View {
        if osd.pillShown {
            SkipPill(osd: osd, u: u, size: size)
                .transition(.opacity.animation(.easeOut(duration: 0.3)))
        }
    }
}

struct SkipPill: View {
    let osd: Osd
    let u: CGFloat
    let size: CGSize

    var body: some View {
        let p = osd.player
        let next = osd.nextUp
        // alone on screen it's the white one; with the controls up, the mouse lights it by being on it
        let foc = !osd.shown || (Input.pointing ? Theme.mouse && osd.hoverPill : osd.zone == .skip)
        let label = osd.segment.map { $0.kind == "intro" ? L("Skip Intro") : $0.kind == "recap" ? L("Skip Recap") : L("Skip Credits") } ?? ""
        let cardW = 340 * u
        ZStack {
            if next, let n = p.next {
                VStack(alignment: .leading, spacing: 0) {
                    Art(url: n.still, radius: 18 * u, px: 700, u: u)
                        .frame(width: cardW - 24 * u, height: (cardW - 24 * u) * 9 / 16)
                    Spacer(minLength: 0)
                    Text(L("Next Episode"))
                        .font(Theme.text(16 * u, .semibold))
                        .foregroundStyle(foc ? Theme.focusFg.opacity(0.6) : Theme.fg2)
                    Text("S\(n.season) · E\(n.episode)" + (n.title.map { "  " + $0 } ?? ""))
                        .font(Theme.display(21 * u, .semibold)).lineLimit(1)
                        .foregroundStyle(foc ? Theme.focusFg : Theme.fg)
                }
                .padding(12 * u)
                .padding(.bottom, 6 * u)
                .frame(width: cardW, height: (cardW - 24 * u) * 9 / 16 + 88 * u, alignment: .topLeading)
                .background { RoundedRectangle(cornerRadius: 30 * u).fill(Color.white).opacity(foc ? 1 : 0) }
                .glassEffect(.regular, in: .rect(cornerRadius: 30 * u))
            } else {
                Text(label)
                    .font(Theme.display(29 * u, .semibold))
                    .foregroundStyle(foc ? Theme.focusFg : Theme.fg)
                    .padding(.horizontal, 40 * u)
                    .frame(height: 84 * u)
                    .background { Capsule().fill(Color.white).opacity(foc ? 1 : 0) }
                    .glassEffect(.regular, in: .capsule)
            }
        }
        .shadow(color: .black.opacity(foc ? 0.55 : 0.28), radius: 22 * u, y: 16 * u)
        .animation(.easeOut(duration: 0.14), value: foc)
        .contentShape(.rect)
        .hover { osd.hoverPill = $0 }
        .onTapGesture { osd.skipAction() }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, Theme.margin(u))
        .padding(.bottom, (osd.shown ? 300 : 150) * u)
        .animation(.easeOut(duration: 0.26), value: osd.shown)
    }
}

/// the seek bar: buffered ahead, played, the thumb (purple fill while it has the focus)
struct SeekBar: View {
    let osd: Osd
    let u: CGFloat

    var body: some View {
        let p = osd.player
        let foc = osd.zone == .bar && osd.shown
        GeometryReader { g in
            let w = g.size.width
            let frac = p.duration > 0 ? min(1, osd.pos / p.duration) : 0
            let ahead = p.duration > 0 ? min(1, (p.position + p.cacheAhead) / p.duration) : 0
            // never narrower than it is tall: a shorter capsule loses its round ends
            let fill = { (f: CGFloat) in f > 0 ? max(g.size.height, w * f) : 0 }
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.25))
                Capsule().fill(Color.white.opacity(0.22)).frame(width: fill(ahead))
                Capsule().fill(foc ? Theme.accent : .white).frame(width: fill(frac))
            }
            .frame(height: g.size.height)
            // the knob only while the bar has focus: the fill says where it is otherwise. an
            // overlay: inside the stack it stretched the whole bar to its own height
            .overlay(alignment: .leading) {
                Circle().fill(.white)
                    .frame(width: 26 * u, height: 26 * u)
                    .shadow(color: .black.opacity(0.35), radius: 6 * u, y: 2 * u)
                    .scaleEffect(foc ? 1 : 0.2)
                    .opacity(foc ? 1 : 0)
                    .offset(x: w * frac - 13 * u)
                    .animation(.easeOut(duration: 0.16), value: foc)
            }
            .overlay(alignment: .topLeading) { chip(w: w, frac: frac) }
            .contentShape(.rect.inset(by: -24 * u))
            #if !os(tvOS)
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                if osd.picker != nil || osd.match != nil { osd.closePickers() }
                if p.duration > 0 { p.seek(to: max(0, min(1, v.location.x / w)) * p.duration) }
                osd.show(5, .bar)
            })
            #endif
        }
    }
}

extension SeekBar {
    /// the scrub speed or held-seek jump above the thumb, kept a little inside the screen edges
    fileprivate func chip(w: CGFloat, frac: CGFloat) -> some View {
        let margin = Theme.margin(u)
        let on = osd.scrubLevel > 0 || !osd.bubble.isEmpty
        return HStack(spacing: 10 * u) {
            if osd.scrubLevel > 0 {
                Image(systemName: osd.scrubDir > 0 ? "forward.fill" : "backward.fill")
                    .font(.system(size: 18 * u, weight: .semibold))
                    .frame(width: 26 * u, height: 26 * u)
            }
            Text(osd.scrubLevel > 0 ? "×\(Int(osd.scrubRate))   " + Theme.time(osd.scrubT) : osd.bubble)
                .font(Theme.text(24 * u, .semibold)).monospacedDigit()
        }
            .foregroundStyle(Theme.fg)
            .padding(.horizontal, 20 * u)
            .frame(height: 56 * u)
            .glassEffect(.regular, in: .capsule)
            .fixedSize()
            .alignmentGuide(.leading) { d in
                let x = max(-margin + 24 * u, min(w - d.width + margin - 24 * u, frac * w - d.width / 2))
                return -x
            }
            .alignmentGuide(.top) { d in d.height + 26 * u }
            .opacity(on ? 1 : 0)
            .animation(.easeInOut(duration: 0.16), value: on)
    }
}

/// the subtitle or audio picker: a glass popover over the subtitles + audio buttons, its bottom
/// just above the row (qml Tracks)
struct TrackPicker: View {
    let osd: Osd
    let u: CGFloat
    let size: CGSize

    var body: some View {
        let lines = osd.pickerLines
        let linesH = lines.reduce(0) { $0 + ($1.header ? 84 : $1.detail.isEmpty ? 84 : 108) } * u
        let h = min(size.height - 200 * u, linesH + 32 * u)
        let g = osd.leftGroup
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                        if l.header {
                            Text(l.label)
                                .font(Theme.display(28 * u, .bold)).foregroundStyle(Theme.fg2)
                                .padding(.leading, 30 * u).padding(.bottom, 22 * u)
                                .frame(maxWidth: .infinity, minHeight: 84 * u, alignment: .bottomLeading)
                        } else {
                            let value = l.kind == "search" ? (osd.subSearch == "searching" ? "…" : osd.subSearch == "none" ? "" : "›") : l.kind == "file" ? "›" : l.selected ? "✓" : ""
                            // no lift: it would eat the inset and crowd the corners
                            SettingsRow(line: SettingsModel.Line(label: l.label, detail: l.detail, value: value, dim: l.dim),
                                        focused: osd.pickerIndex == i, u: u, grow: 1)
                                .id(i)
                                .onContinuousHover { phase in if case .active = phase, Input.pointerLive, osd.pickerIndex != i { osd.pickerIndex = i } }
                                .onTapGesture { osd.pickerIndex = i; osd.pick(i) }
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .scrollDisabled(linesH + 32 * u <= h)
            // keys only: under the mouse a list stays where it is (the wheel moves it)
            .onChange(of: osd.pickerIndex) { _, i in if !Input.pointerHolds { withAnimation(.easeOut(duration: 0.16)) { proxy.scrollTo(i) } } }
        }
        // 16 all round: the rows' 24 radius + 16 = the panel's 40, corners stay concentric
        .padding(16 * u)
        .frame(width: g.w > 0 ? g.w : 470 * u, height: h)
        .panelGlass(40 * u, u: u, lift: -0.35)
        .offset(x: g.w > 0 ? g.x : Theme.margin(u), y: size.height - 140 * u - h)
    }
}

/// track language tags (iso 639-1/2, with or without a region: en-US, es-419) as names (qml Theme.langName)
enum Lang {
    private static let regional = ["es-419": "Spanish (Latin America)", "pt-BR": "Portuguese (Brazil)", "fr-CA": "French (Canada)",
                                   "zh-HANT": "Chinese (Traditional)", "zh-TW": "Chinese (Traditional)", "zh-HK": "Chinese (Hong Kong)"]
    private static let names = [
        "eng": "English", "en": "English", "srp": "Serbian", "sr": "Serbian", "scc": "Serbian", "hrv": "Croatian",
        "hr": "Croatian", "scr": "Croatian", "bos": "Bosnian", "bs": "Bosnian", "ger": "German", "deu": "German",
        "de": "German", "fre": "French", "fra": "French", "fr": "French", "spa": "Spanish", "es": "Spanish",
        "ita": "Italian", "it": "Italian", "rus": "Russian", "ru": "Russian", "jpn": "Japanese", "ja": "Japanese",
        "kor": "Korean", "ko": "Korean", "por": "Portuguese", "pt": "Portuguese", "slv": "Slovenian", "sl": "Slovenian",
        "mac": "Macedonian", "mkd": "Macedonian", "pol": "Polish", "pl": "Polish", "dut": "Dutch", "nld": "Dutch",
        "nl": "Dutch", "tur": "Turkish", "tr": "Turkish", "chi": "Chinese", "zho": "Chinese", "zh": "Chinese",
        "bul": "Bulgarian", "bg": "Bulgarian", "gre": "Greek", "ell": "Greek", "el": "Greek", "cze": "Czech", "ces": "Czech",
        "cs": "Czech", "slo": "Slovak", "slk": "Slovak", "sk": "Slovak", "hun": "Hungarian", "hu": "Hungarian",
        "rum": "Romanian", "ron": "Romanian", "ro": "Romanian", "swe": "Swedish", "sv": "Swedish", "dan": "Danish",
        "da": "Danish", "nor": "Norwegian", "nob": "Norwegian", "no": "Norwegian", "nb": "Norwegian", "fin": "Finnish",
        "fi": "Finnish", "ice": "Icelandic", "isl": "Icelandic", "est": "Estonian", "et": "Estonian", "lav": "Latvian",
        "lv": "Latvian", "lit": "Lithuanian", "lt": "Lithuanian", "ukr": "Ukrainian", "uk": "Ukrainian", "ara": "Arabic",
        "ar": "Arabic", "heb": "Hebrew", "he": "Hebrew", "hin": "Hindi", "hi": "Hindi", "tha": "Thai", "th": "Thai",
        "vie": "Vietnamese", "vi": "Vietnamese", "ind": "Indonesian", "id": "Indonesian", "may": "Malay", "msa": "Malay",
        "ms": "Malay", "fil": "Filipino", "tgl": "Filipino", "cat": "Catalan", "ca": "Catalan", "baq": "Basque",
        "eus": "Basque", "glg": "Galician", "gl": "Galician", "per": "Persian", "fas": "Persian", "fa": "Persian",
        "alb": "Albanian", "sqi": "Albanian", "sq": "Albanian", "tam": "Tamil", "ta": "Tamil", "tel": "Telugu",
        "te": "Telugu", "is": "Icelandic", "mk": "Macedonian", "mon": "Mongolian", "mn": "Mongolian", "kaz": "Kazakh",
        "kk": "Kazakh", "geo": "Georgian", "kat": "Georgian", "ka": "Georgian", "arm": "Armenian", "hye": "Armenian",
        "hy": "Armenian", "ben": "Bengali", "bn": "Bengali", "urd": "Urdu", "ur": "Urdu", "kan": "Kannada", "kn": "Kannada",
        "mal": "Malayalam", "ml": "Malayalam", "mar": "Marathi", "mr": "Marathi", "lat": "Latin", "la": "Latin",
        "wel": "Welsh", "cym": "Welsh", "cy": "Welsh", "gle": "Irish", "ga": "Irish", "swa": "Swahili", "sw": "Swahili",
        "afr": "Afrikaans", "af": "Afrikaans", "zul": "Zulu", "zu": "Zulu", "yue": "Cantonese", "nno": "Norwegian",
    ]

    static func name(_ tag: String?) -> String {
        let parts = (tag ?? "").split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
        guard let first = parts.first, !first.isEmpty else { return L("Unknown") }
        let l = first.lowercased(), region = parts.count > 1 ? parts[1] : ""
        if let r = regional[l + "-" + region.uppercased()] ?? regional[l + "-" + region] { return Lc(r) }
        if let n = names[l] { return Lc(n) }
        return l.uppercased()
    }
}

/// the mouse's volume (mac): a speaker (mute) and a slider in one capsule, the wheel turns it too
private struct VolumeControl: View {
    let osd: Osd
    let u: CGFloat
    @State private var onSpeaker = false
    @State private var onTrack = false
    @State private var dragging = false

    var body: some View {
        let p = osd.player
        let frac = p.muted ? 0 : max(0, min(1, p.volume / 100))
        let speaker = onSpeaker && Theme.mouse
        let live = (onTrack && Theme.mouse) || dragging
        HStack(spacing: 6 * u) {
            Image(systemName: p.muted || p.volume <= 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 26 * u, weight: .semibold))
                .foregroundStyle(speaker ? Theme.focusFg : Theme.fg)
                .frame(width: 68 * u, height: 68 * u)
                .background { Circle().fill(Color.white).opacity(speaker ? 1 : 0) }
                .animation(.easeOut(duration: 0.14), value: speaker)
                .contentShape(.circle)
                .hover { onSpeaker = $0 }
                .onTapGesture { osd.act(.vol); osd.show() }
                .padding(.leading, 4 * u)
            GeometryReader { g in
                let w = g.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.25)).frame(height: 8 * u)
                    Capsule().fill(live ? Theme.accent : Color.white).frame(width: frac * w, height: 8 * u)
                    Circle().fill(Color.white).frame(width: 22 * u, height: 22 * u)
                        .scaleEffect(live ? 1 : 0.5)
                        .animation(.easeOut(duration: 0.14), value: live)
                        .offset(x: frac * w - 11 * u)
                }
                .frame(width: w, height: g.size.height)
                .contentShape(.rect)
                .hover { onTrack = $0 }
                #if !os(tvOS)
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in dragging = true; p.setVolume(v.location.x / max(1, w) * 100); osd.show() }
                    .onEnded { _ in dragging = false })
                #endif
            }
            .padding(.trailing, 30 * u)
        }
        .frame(width: 300 * u, height: 76 * u)
        .glassEffect(.regular.tint(.white.opacity(0.06)), in: .capsule)
    }
}
