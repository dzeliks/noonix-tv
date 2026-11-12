#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI
import GameController
import MediaPlayer

enum Key { case up, down, left, right, ok, back, menu, playPause, ff, rw, pageUp, pageDown, next, stop, home }

/// the player's own keys, which nothing else uses
extension Key { var media: Bool { [.ff, .rw, .pageUp, .pageDown, .next, .stop].contains(self) } }
/// a key that moves or picks: the first of these after the mouse may only bring the selection back
extension Key { var picks: Bool { [.up, .down, .left, .right, .ok].contains(self) } }

/// a real keyboard typing into an on-screen field (qml KeyEntry, ProfileAdd, Search)
enum Typed { case text(String), erase, submit }

/// the mouse is what's in use (observed: the rows' page arrows come and go with it)
/// a finger resting on the screen (ios): what's under it shows pressed. no gesture, so the views'
/// own taps stay free; a finger that moves (a scroll) presses nothing
@MainActor @Observable
final class FingerDown {
    static let shared = FingerDown()
    var at: CGPoint?
    static func on(_ r: CGRect) -> Bool { shared.at.map { r.contains($0) } ?? false }
}

extension View {
    /// keeps `box` on the view's place on screen (FingerDown.on(box) = pressed)
    func pressBox(_ box: Binding<CGRect>) -> some View {
        #if os(iOS)
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { box.wrappedValue = $0 }
        #else
        self
        #endif
    }
}

@MainActor @Observable
final class PointerMode {
    static let shared = PointerMode()
    var on = false
    /// what pressed the last key: keyboard | pad | remote (the dev fifo stands in for a remote)
    var kind = Platform.tv ? "remote" : "keyboard"
    func pressed(_ k: String) { if kind != k { kind = k } }
    /// the mouse is on a card: with the mouse in use only that card is lifted (moving off lets it down)
    private(set) var onCard = false
    @ObservationIgnored private var cards = Set<UUID>()
    func card(_ id: UUID, _ inside: Bool) {
        if inside { cards.insert(id) } else { cards.remove(id) }
        if onCard != !cards.isEmpty { onCard = !cards.isEmpty }
    }
}

/// the wheel on a page, a grid or a row (qml PageWheel): pixels, it moves as one, the focus stays
/// with the mouse. nil = where the keys have it
@MainActor @Observable
final class PageScroll {
    var y: CGFloat?
    @ObservationIgnored var start: CGFloat = 0
    @ObservationIgnored var end: CGFloat = 0
    @ObservationIgnored var tops: [CGFloat] = []
    /// where the rows start in the window, what the bar and its fade cover, the window's height
    @ObservationIgnored var rowsTop: CGFloat = 0
    @ObservationIgnored var clearY: CGFloat = 0
    @ObservationIgnored var height: CGFloat = 0
    @ObservationIgnored private var goal: CGFloat = 0
    /// a row pulled on past either end (the episodes: the next or the previous season)
    @ObservationIgnored var past: ((Int) -> Void)?
    @ObservationIgnored private var pull: CGFloat = 0
    @ObservationIgnored private var quiet = Date.distantPast

    func wheel(_ delta: CGFloat, precise: Bool, u: CGFloat, coasting: Bool = false) {
        // the rest of the swipe that switched (and its coasting) doesn't scroll the new cards: a pause first
        if Date() < quiet { quiet = Date().addingTimeInterval(0.35); return }
        if let past, !coasting {
            let at = y == nil ? start : precise ? y! : goal
            if precise {
                let want = at - delta
                pull = want > end ? pull + want - end : want < 0 ? pull + want : 0
            } else {
                // a notch once the row is at that end already
                pull = at >= end - 1 && delta < 0 ? 1e6 : at <= 1 && delta > 0 ? -1e6 : 0
            }
            if abs(pull) > 140 * u {
                let dir = pull > 0 ? 1 : -1
                pull = 0
                quiet = Date().addingTimeInterval(0.35)
                past(dir)
                return
            }
        }
        if y == nil { goal = start; y = start }
        if precise {
            goal = max(0, min(end, (y ?? start) - delta))
            y = goal
        } else {
            // the system speeds a quick wheel up on its own; a spring keeps its speed on a new goal
            goal = max(0, min(end, goal - delta * 200 * u))
            withAnimation(.smooth(duration: 0.28)) { y = goal }
        }
    }
    /// a finger let go at v points a second: the page coasts on and settles
    func fling(_ v: CGFloat) {
        guard let now = y else { return }
        goal = max(0, min(end, now - v * 0.32))
        withAnimation(.timingCurve(0.15, 0.75, 0.3, 1, duration: 0.7)) { y = goal }
    }
    /// the keys on the scrolled page: row i comes in whole, the top row ends it
    func reveal(_ i: Int) {
        guard let now = y, tops.indices.contains(i) else { return }
        if i == 0 { withAnimation(Theme.slide) { y = nil }; return }
        let top = rowsTop + tops[i], bottom = rowsTop + (i + 1 < tops.count ? tops[i + 1] : end + height - rowsTop)
        var to = now
        if top - to < clearY { to = top - clearY } else if bottom - to > height { to = bottom - height }
        goal = max(0, min(end, to))
        withAnimation(Theme.slide) { y = goal }
    }
    /// a key after the mouse: the row kept if at least half of it is in view, else the first such row
    func rowInView(_ current: Int) -> Int {
        let at = y ?? start
        func half(_ i: Int) -> Bool {
            guard tops.indices.contains(i) else { return false }
            let top = rowsTop + tops[i] - at, h = (i + 1 < tops.count ? tops[i + 1] : end + height - rowsTop) - tops[i]
            return min(top + h, height) - max(top, clearY) >= h / 2
        }
        return half(current) ? current : tops.indices.first(where: half) ?? current
    }
}

/// the tv app's input everywhere (Main.qml): arrows / return / escape, the wheel scrolls a page (the
/// arrows elsewhere), right click is back or a card's options, the mouse focuses what it moves over
/// (only real movement counts)
@MainActor
enum Input {
    private static var monitors: [Any] = []
    private static var lastMove = Date.distantPast
    private static var accY: CGFloat = 0
    private static var accX: CGFloat = 0
    /// a trackpad gesture's axis, kept through its coasting: two fingers never go straight, and
    /// event by event the drift kept handing a sideways swipe to the page and back
    private static var axis: (x: Bool, decided: Bool, gx: CGFloat, gy: CGFloat) = (false, false, 0, 0)
    /// holding back leaves from anywhere (input.cpp holdMs)
    static let holdBack = 0.65
    private static var escDown = Date.distantFuture
    private static var escFired = false

    /// the pointer really moved just now (a list sliding under a resting cursor doesn't count, unless
    /// the wheel slid it: then the hover is the mouse's)
    static var pointerLive: Bool { Date().timeIntervalSince(lastMove) < 0.15 || Date().timeIntervalSince(lastWheel) < 0.4 }
    private static var lastWheel = Date.distantPast
    /// the row of cards under the mouse: sideways, the wheel moves it
    static var row: PageScroll?
    #if os(macOS)
    /// the page moved under a resting mouse: a move of nothing, so what's under it now takes the hover
    private static var rehoverTask: Task<Void, Never>?
    private static func rehover() {
        lastWheel = Date()
        rehoverTask?.cancel()
        rehoverTask = Task {
            // once as it moves, once when the glide has landed
            for wait in [40, 300] {
                try? await Task.sleep(for: .milliseconds(wait))
                guard !Task.isCancelled, let w = NSApp.keyWindow,
                      let e = NSEvent.mouseEvent(with: .mouseMoved, location: w.mouseLocationOutsideOfEventStream, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                                 context: nil, eventNumber: 0, clickCount: 0, pressure: 0) else { return }
                NSApp.postEvent(e, atStart: false)
            }
        }
    }
    #else
    private static func rehover() { lastWheel = Date() }
    #endif

    /// the mouse moved last (no key since): lists don't scroll for it, the wheel and keys do
    /// (qml Input.pointing); the rows show their page arrows meanwhile
    static var pointing: Bool { PointerMode.shared.on }
    static var pointerHolds: Bool { pointing && pointerLive }
    /// true: this first key after the mouse only brought the selection back
    static func keyed() -> Bool {
        #if os(macOS)
        // keys in use: the cursor goes until the mouse moves again
        NSCursor.setHiddenUntilMouseMoves(true)
        #endif
        guard PointerMode.shared.on else { return false }
        PointerMode.shared.on = false
        return AppModel.current?.leaveMouse() ?? false
    }
    #if os(macOS)
    /// a page that scrolls in pixels takes the wheel (true: it did)
    static var wheel: ((NSEvent) -> Bool)?

    /// what a key typed while an on-screen keyboard is up means (nil: a normal key)
    private static func typing(_ e: NSEvent) -> Typed? {
        let cmd = e.modifierFlags.contains(.command), ctrl = e.modifierFlags.contains(.control)
        switch e.keyCode {
        case 36, 76: return .submit
        case 51: return .erase
        default: break
        }
        if cmd, e.charactersIgnoringModifiers == "v" {
            return NSPasteboard.general.string(forType: .string).map { .text($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        guard !cmd, !ctrl, let c = e.characters, c.count == 1, let s = c.unicodeScalars.first,
              s.value >= 32, s.value != 127, !(0xF700...0xF8FF).contains(s.value) else { return nil }
        return .text(c)
    }

    static func install(_ to: @escaping (Key) -> Bool, typed: @escaping (Typed) -> Bool) {
        guard monitors.isEmpty else { return }
        let send = { (k: Key) -> Bool in
            if keyed(), k.picks { return true }
            return to(k)
        }
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { e in
            lastMove = Date()
            if !PointerMode.shared.on { PointerMode.shared.on = true }
            return e
        } as Any)
        // not a key: the mouse stays in charge, the page doesn't jump to the focus
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { e in
            _ = to(PointerMode.shared.onCard ? .menu : .back)
            return nil
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { e in
            // a notch is 120 in qt; a trackpad sends small precise deltas
            let scale: CGFloat = e.hasPreciseScrollingDeltas ? 1 : 40
            var dx = e.scrollingDeltaX * scale, dy = e.scrollingDeltaY * scale
            if e.modifierFlags.contains(.shift) { dx = dy; dy = 0 }
            if PointerMode.shared.on == false { PointerMode.shared.on = true }
            if e.hasPreciseScrollingDeltas {
                if e.phase == .began || e.phase == .mayBegin { axis = (false, false, 0, 0) }
                if !axis.decided {
                    // the first few points of the swipe pick the way
                    axis.gx += dx; axis.gy += dy
                    if max(abs(axis.gx), abs(axis.gy)) < 3 { return nil }
                    axis = (abs(axis.gx) > abs(axis.gy), true, 0, 0)
                }
                if axis.x { dy = 0 } else { dx = 0 }
            }
            if dy != 0, abs(dy) >= abs(dx), wheel?(e) == true { rehover(); return nil }
            if dx != 0, abs(dx) > abs(dy), let r = row {
                r.wheel(e.hasPreciseScrollingDeltas || e.scrollingDeltaX != 0 ? e.scrollingDeltaX : e.scrollingDeltaY,
                        precise: e.hasPreciseScrollingDeltas, u: AppModel.current?.u ?? 1, coasting: !e.momentumPhase.isEmpty)
                rehover()
                return nil
            }
            // only over the video it's the arrows. elsewhere the lists scroll by themselves
            guard AppModel.current?.wheelSteps == true else { rehover(); return e }
            if e.phase == .began { accX = 0; accY = 0 }
            // a trackpad's coasting after the fingers lift would keep stepping on its own
            if !e.momentumPhase.isEmpty { return nil }
            accY += dy; accX += dx
            // over the video the mouse stays the mouse: up and down turn the volume (like its slider),
            // sideways seeks 10 s
            let step: CGFloat = 40
            var vol = 0.0, seek = 0.0
            while accY >= step { accY -= step; vol += 5 }
            while accY <= -step { accY += step; vol -= 5 }
            while accX >= step { accX -= step; seek -= 10 }
            while accX <= -step { accX += step; seek += 10 }
            if let p = AppModel.current?.player, vol != 0 || seek != 0 {
                if vol != 0 { p.setVolume((p.muted ? 0 : p.volume) + vol) }
                if seek != 0 { p.seek(by: seek) }
                Osd.shared?.show()
            }
            return nil
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            PointerMode.shared.pressed("keyboard")
            let typing = NSApp.keyWindow?.firstResponder is NSTextView
            // an on-screen keyboard is up: letters, delete, return and cmd+v type into it
            if !typing, let t = Input.typing(e), typed(t) { return nil }
            let name = Bindings.keyName(e)
            // settings waiting for a key: this one, not what it does
            if !typing, let name, !e.isARepeat, Bindings.shared.captured("keys", name) { return nil }
            let key: Key?
            switch e.keyCode {
            case 126: key = .up
            case 125: key = .down
            case 123: key = typing ? nil : .left
            case 124: key = typing ? nil : .right
            // a text field keeps its keys, all but escape
            case _ where typing: key = e.keyCode == 53 ? .back : nil
            default: key = name.flatMap { Bindings.shared.action("keys", $0) }.flatMap(Bindings.key)
            }
            guard let key else { return e }
            // a held back only counts the time; the first press is back as usual
            if key == .back {
                if !e.isARepeat { escDown = Date(); escFired = false }
                else {
                    if !escFired, Date().timeIntervalSince(escDown) >= holdBack { escFired = true; Platform.quit() }
                    return nil
                }
            }
            return send(key) ? nil : e
        } as Any)
    }
    #else
    /// a page that scrolls in pixels takes a finger's drag (true: it did)
    static var wheel: ((CGFloat) -> Bool)?
    /// a hardware keyboard (ipad): arrows, return, escape and the bound keys; letters type into an
    /// on-screen keyboard that's up
    private static var keyboardOn = false
    private static var shift = false
    /// a touch: the pointer is what's in use (no focus marks, lists don't follow the focus)
    static func touched() {
        lastMove = Date()
        if !PointerMode.shared.on { PointerMode.shared.on = true }
    }
    static func install(_ to: @escaping (Key) -> Bool, typed: @escaping (Typed) -> Bool) {
        guard !keyboardOn else { return }
        keyboardOn = true
        let send = { (k: Key) -> Bool in
            if keyed(), k.picks { return true }
            return to(k)
        }
        func attach(_ kb: GCKeyboard?) {
            kb?.keyboardInput?.keyChangedHandler = { _, _, code, down in
                MainActor.assumeIsolated {
                    if code == .leftShift || code == .rightShift { shift = down; return }
                    guard down else { return }
                    PointerMode.shared.pressed("keyboard")
                    let name = Bindings.keyName(code)
                    if let t = Bindings.typed(code, shift: shift), typed(t) { return }
                    if let name, Bindings.shared.captured("keys", name) { return }
                    let key: Key?
                    switch code {
                    case .upArrow: key = .up
                    case .downArrow: key = .down
                    case .leftArrow: key = .left
                    case .rightArrow: key = .right
                    default: key = name.flatMap { Bindings.shared.action("keys", $0) }.flatMap(Bindings.key)
                    }
                    if let key { _ = send(key) }
                }
            }
        }
        attach(GCKeyboard.coalesced)
        NotificationCenter.default.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { n in
            MainActor.assumeIsolated { attach(n.object as? GCKeyboard) }
        }
    }
    #endif
}


/// game pads (input.cpp): the buttons by position through the bindings (Controls.swift); the d-pad
/// and the left stick repeat like held arrows (380 ms, then 110)
@MainActor
enum Pads {
    private static var send: ((Key) -> Bool)?
    private static var held: Key?
    private static var repeatTask: Task<Void, Never>?
    private static var stick: Key?
    private static var backHold: Task<Void, Never>?

    static func install(_ f: @escaping (Key) -> Bool) {
        send = { k in
            PointerMode.shared.pressed("pad")
            if Input.keyed(), k.picks { return true }
            return f(k)
        }
        GCController.shouldMonitorBackgroundEvents = false
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { n in
            guard let c = n.object as? GCController else { return }
            MainActor.assumeIsolated { attach(c) }
        }
        GCController.controllers().forEach(attach)
        GCController.startWirelessControllerDiscovery {}
    }

    /// the pad's ok is down (held backspace keeps deleting)
    static var okHeld = false

    private static func attach(_ c: GCController) {
        guard let g = c.extendedGamepad else { return }
        Bindings.shared.padKind = Bindings.kind(c)
        // buttons by position (input.cpp names), through the bindings
        func button(_ b: GCControllerButtonInput?, _ name: String) {
            b?.pressedChangedHandler = { _, _, down in
                MainActor.assumeIsolated {
                    let action = Bindings.shared.action("pad", name)
                    if action.flatMap(Bindings.key) == .ok { okHeld = down }
                    // holding back leaves from anywhere
                    if action == "BACK" {
                        backHold?.cancel()
                        if down {
                            backHold = Task {
                                try? await Task.sleep(for: .seconds(Input.holdBack))
                                if !Task.isCancelled { Platform.quit() }
                            }
                        }
                    }
                    guard down else { return }
                    if Bindings.shared.captured("pad", name) { return }
                    if let k = action.flatMap(Bindings.key) { _ = send?(k) }
                }
            }
        }
        button(g.buttonA, "south")
        button(g.buttonB, "east")
        button(g.buttonX, "west")
        button(g.buttonY, "north")
        button(g.leftShoulder, "lb")
        button(g.rightShoulder, "rb")
        button(g.leftTrigger, "lt")
        button(g.rightTrigger, "rt")
        button(g.buttonOptions, "back")
        button(g.buttonMenu, "start")
        button(g.buttonHome, "guide")
        button(g.leftThumbstickButton, "ls")
        button(g.rightThumbstickButton, "rs")
        if let ds = g as? GCDualSenseGamepad { button(ds.touchpadButton, "touchpad") } else if let d4 = g as? GCDualShockGamepad { button(d4.touchpadButton, "touchpad") }
        func arrow(_ b: GCControllerButtonInput, _ k: Key) {
            b.pressedChangedHandler = { _, _, down in
                MainActor.assumeIsolated { down ? hold(k) : release(k) }
            }
        }
        arrow(g.dpad.up, .up)
        arrow(g.dpad.down, .down)
        arrow(g.dpad.left, .left)
        arrow(g.dpad.right, .right)
        g.leftThumbstick.valueChangedHandler = { _, x, y in
            MainActor.assumeIsolated {
                // past half way on one axis counts as that arrow
                let k: Key? = abs(x) < 0.5 && abs(y) < 0.5 ? nil
                    : abs(x) > abs(y) ? (x > 0 ? .right : .left) : (y > 0 ? .up : .down)
                guard k != stick else { return }
                if let s = stick { release(s) }
                stick = k
                if let k { hold(k) }
            }
        }
    }

    private static func hold(_ k: Key) {
        held = k
        _ = send?(k)
        repeatTask?.cancel()
        repeatTask = Task {
            try? await Task.sleep(for: .milliseconds(380))
            while !Task.isCancelled, held == k {
                _ = send?(k)
                try? await Task.sleep(for: .milliseconds(110))
            }
        }
    }

    private static func release(_ k: Key) {
        guard held == k else { return }
        held = nil
        repeatTask?.cancel()
    }
}

/// the mac's media keys and the now playing controls (qml: the remote's play / ff / rw / next / stop)
@MainActor
enum MediaKeys {
    static func install(_ send: @escaping (Key) -> Bool) {
        let c = MPRemoteCommandCenter.shared()
        func on(_ cmd: MPRemoteCommand, _ k: Key) {
            cmd.addTarget { _ in MainActor.assumeIsolated { send(k) } ? .success : .commandFailed }
        }
        on(c.togglePlayPauseCommand, .playPause)
        on(c.nextTrackCommand, .next)
        on(c.stopCommand, .stop)
        // held ff / rw: each press steps the scrub speed, like the remote
        for (cmd, k) in [(c.seekForwardCommand, Key.ff), (c.seekBackwardCommand, Key.rw)] {
            cmd.addTarget { e in
                guard (e as? MPSeekCommandEvent)?.type != .endSeeking else { return .success }
                return MainActor.assumeIsolated { send(k) } ? .success : .commandFailed
            }
        }
    }

    /// the keys only reach the app while it says it's playing
    static func playing(_ on: Bool, paused: Bool = false) {
        MPNowPlayingInfoCenter.default().playbackState = !on ? .stopped : paused ? .paused : .playing
    }
}

/// dev: NOONIX_KEYS=<fifo> takes a key name a line (up, ok, back, menu, play, ff, rw, pageup,
/// pagedown, next, stop) or text:<abc> / erase / submit, so tests can drive the app over ssh.
/// shot:<png path> draws the window into a file (no screen recording permission over ssh; the
/// system's glass and the video don't show in it)
enum DevKeys {
    #if os(macOS)
    @MainActor static func shot(_ path: String) {
        guard let w = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { return }
        // the app's own window as the screen shows it (the sdk hides the call, the system still has it)
        typealias Grab = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"),
           let img = unsafeBitCast(sym, to: Grab.self)(.null, 1 << 3, UInt32(w.windowNumber), 1 << 0 | 1 << 3)?.takeRetainedValue() {
            try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            return
        }
        guard let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
    #else
    /// the simulator is shot from outside (simctl io)
    @MainActor static func shot(_ path: String) {}
    #endif

    static func install(_ send: @escaping @MainActor (Key) -> Bool, typed: @escaping @MainActor (Typed) -> Bool) {
        guard let path = ProcessInfo.processInfo.environment["NOONIX_KEYS"] else { return }
        let names: [String: Key] = ["up": .up, "down": .down, "left": .left, "right": .right, "ok": .ok, "back": .back,
                                    "menu": .menu, "play": .playPause, "ff": .ff, "rw": .rw, "pageup": .pageUp,
                                    "pagedown": .pageDown, "next": .next, "stop": .stop]
        Thread.detachNewThread {
            while true {
                guard let f = fopen(path, "r") else { sleep(1); continue }
                var buf: UnsafeMutablePointer<CChar>?
                var cap = 0
                while getline(&buf, &cap, f) > 0, let buf {
                    let line = String(cString: buf).trimmingCharacters(in: .whitespacesAndNewlines)
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            #if os(iOS)
                            // a finger, without one: touch mode, a page drag, letting go at a speed
                            if line == "touch" { Input.touched(); return }
                            if line.hasPrefix("drag:"), let d = Double(line.dropFirst(5)) { Input.touched(); _ = Input.wheel?(d); return }
                            if line.hasPrefix("fling:"), let v = Double(line.dropFirst(6)) { AppModel.current?.fling(v); return }
                            if line.hasPrefix("kind:") { withAnimation(.easeOut(duration: 0.24)) { AppModel.current?.search.kind = String(line.dropFirst(5)) }; return }
                            if line.hasPrefix("page:"), let p = Page(rawValue: String(line.dropFirst(5))) { Input.touched(); AppModel.current?.choose(p); AppModel.current?.navFocused = false; return }
                            #endif
                            if let k = names[line] { PointerMode.shared.pressed("remote"); if !(Input.keyed() && k.picks) { _ = send(k) } }
                            else if line.hasPrefix("text:") { PointerMode.shared.pressed("keyboard"); _ = typed(.text(String(line.dropFirst(5)))) }
                            else if line == "erase" { _ = typed(.erase) }
                            else if line == "submit" { _ = typed(.submit) }
                            else if line.hasPrefix("shot:") { shot(String(line.dropFirst(5))) }

                        }
                    }
                }
                fclose(f)
            }
        }
    }
}
