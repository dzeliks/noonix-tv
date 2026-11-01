import AppKit
import SwiftUI
import GameController
import MediaPlayer

enum Key { case up, down, left, right, ok, back, menu, playPause, ff, rw, pageUp, pageDown, next, stop, home }

/// the player's own keys, which nothing else uses
extension Key { var media: Bool { [.ff, .rw, .pageUp, .pageDown, .next, .stop].contains(self) } }

/// a real keyboard typing into an on-screen field (qml KeyEntry, ProfileAdd, Search)
enum Typed { case text(String), erase, submit }

/// the mouse is what's in use (observed: the rows' page arrows come and go with it)
@MainActor @Observable
final class PointerMode {
    static let shared = PointerMode()
    var on = false
    /// the mouse is on a card: with the mouse in use the focused card is lifted only then (moving
    /// off lets it down, back on lifts it again)
    private(set) var onCard = false
    @ObservationIgnored private var cards = Set<UUID>()
    func card(_ id: UUID, _ inside: Bool) {
        if inside { cards.insert(id) } else { cards.remove(id) }
        if onCard != !cards.isEmpty { onCard = !cards.isEmpty }
    }
}

/// the wheel on a page (qml PageWheel): pixels, a page moves as one. nil = where the keys have it
@MainActor @Observable
final class PageScroll {
    var y: CGFloat?
    @ObservationIgnored var start: CGFloat = 0
    @ObservationIgnored var end: CGFloat = 0
    @ObservationIgnored var tops: [CGFloat] = []
    @ObservationIgnored private var goal: CGFloat = 0

    func wheel(_ e: NSEvent, u: CGFloat) {
        if y == nil { goal = start; y = start }
        if e.hasPreciseScrollingDeltas {
            goal = max(0, min(end, (y ?? start) - e.scrollingDeltaY))
            y = goal
        } else {
            // the system speeds a quick wheel up on its own
            goal = max(0, min(end, goal - e.scrollingDeltaY * 60 * u))
            withAnimation(.easeOut(duration: 0.26)) { y = goal }
        }
    }
    /// the row at the top of the page, where the keys go on from
    var topRow: Int { max(0, (tops.lastIndex { $0 <= (y ?? 0) + 1 } ?? 0)) }
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
    /// holding back leaves from anywhere (input.cpp holdMs)
    static let holdBack = 0.65
    private static var escDown = Date.distantFuture
    private static var escFired = false

    /// the pointer really moved just now (a list sliding under a resting cursor doesn't count)
    static var pointerLive: Bool { Date().timeIntervalSince(lastMove) < 0.15 }
    /// the mouse moved last (no key since): lists don't scroll for it, the wheel and keys do
    /// (qml Input.pointing); the rows show their page arrows meanwhile
    static var pointing: Bool { PointerMode.shared.on }
    static var pointerHolds: Bool { pointing && pointerLive }
    static func keyed() {
        if PointerMode.shared.on { PointerMode.shared.on = false }
        AppModel.current?.leaveWheel()
    }
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
        let send = { (k: Key) -> Bool in keyed(); return to(k) }
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
            if dy != 0, abs(dy) >= abs(dx), wheel?(e) == true { return nil }
            if e.phase == .began { accX = 0; accY = 0 }
            // a trackpad's coasting after the fingers lift would keep stepping on its own
            if !e.momentumPhase.isEmpty { return nil }
            accY += dy; accX += dx
            let step: CGFloat = 40
            while accY >= step { accY -= step; _ = send(.up) }
            while accY <= -step { accY += step; _ = send(.down) }
            while accX >= step { accX -= step; _ = send(.left) }
            while accX <= -step { accX += step; _ = send(.right) }
            return nil
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
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
                    if !escFired, Date().timeIntervalSince(escDown) >= holdBack { escFired = true; NSApp.terminate(nil) }
                    return nil
                }
            }
            return send(key) ? nil : e
        } as Any)
    }
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
        send = { k in Input.keyed(); return f(k) }
        GCController.shouldMonitorBackgroundEvents = false
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { n in
            guard let c = n.object as? GCController else { return }
            MainActor.assumeIsolated { attach(c) }
        }
        GCController.controllers().forEach(attach)
        GCController.startWirelessControllerDiscovery {}
    }

    private static func attach(_ c: GCController) {
        guard let g = c.extendedGamepad else { return }
        Bindings.shared.padKind = Bindings.kind(c)
        // buttons by position (input.cpp names), through the bindings
        func button(_ b: GCControllerButtonInput?, _ name: String) {
            b?.pressedChangedHandler = { _, _, down in
                MainActor.assumeIsolated {
                    let action = Bindings.shared.action("pad", name)
                    // holding back leaves from anywhere
                    if action == "BACK" {
                        backHold?.cancel()
                        if down {
                            backHold = Task {
                                try? await Task.sleep(for: .seconds(Input.holdBack))
                                if !Task.isCancelled { NSApp.terminate(nil) }
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
                            if let k = names[line] { Input.keyed(); _ = send(k) }
                            else if line.hasPrefix("text:") { _ = typed(.text(String(line.dropFirst(5)))) }
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
