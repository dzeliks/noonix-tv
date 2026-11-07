#if os(macOS)
import AppKit
#else
import UIKit
#endif
import GameController

/// pad buttons and keyboard keys -> the remote's actions (input.cpp bindings): the defaults with the
/// changes settings made on top, kept in the app setting "controls" like the tv app (same names, so
/// a home moved between the two keeps them)
@MainActor @Observable
final class Bindings {
    static let shared = Bindings()

    static let actions = ["OK", "BACK", "MENU", "PLAYPAUSE", "RW", "FF", "CH_DOWN", "CH_UP", "HOME"]

    /// playstation, xbox, nintendo or generic: the last pad that showed up
    var padKind = "generic"
    /// side ("pad" / "keys") -> action -> the buttons or keys, only what settings changed
    var custom: [String: [String: [String]]] = [:]
    /// "pad:OK" / "keys:BACK" while the next button or key is taken for it
    var capturing = ""
    @ObservationIgnored private var timeout: Task<Void, Never>?
    @ObservationIgnored private var waitingSlot = 0
    @ObservationIgnored private var finished: (() -> Void)?

    var defaults: [String: [String: [String]]] {
        // nintendo confirms with a on the right, everyone else with the bottom button
        let nin = padKind == "nintendo"
        return [
            "pad": ["OK": [nin ? "east" : "south"], "BACK": [nin ? "south" : "east"], "MENU": ["north", "back"],
                    "PLAYPAUSE": ["west", "start"], "RW": ["lb"], "FF": ["rb"], "CH_DOWN": ["lt"], "CH_UP": ["rt"], "HOME": ["guide"]],
            // youtube's keys where the keyboard has no remote keys
            "keys": ["OK": ["Return"], "BACK": ["Esc", "Backspace"], "MENU": ["M"], "PLAYPAUSE": ["Space", "K"], "RW": ["J"],
                     "FF": ["L"], "CH_DOWN": ["PgDown"], "CH_UP": ["PgUp"], "HOME": ["H"]],
        ]
    }

    var all: [String: [String: [String]]] {
        var out = defaults
        for (side, m) in custom { out[side, default: [:]].merge(m) { _, new in new } }
        return out
    }

    func action(_ side: String, _ name: String) -> String? {
        all[side]?.first { $0.value.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }?.key
    }

    static func key(_ action: String) -> Key? {
        switch action {
        case "OK": .ok
        case "BACK": .back
        case "MENU": .menu
        case "PLAYPAUSE": .playPause
        case "RW": .rw
        case "FF": .ff
        case "CH_DOWN": .pageDown
        case "CH_UP": .pageUp
        case "HOME": .home
        default: nil
        }
    }

    func load(_ controls: Any?) {
        guard let c = controls as? [String: Any] else { return }
        custom = c.compactMapValues { ($0 as? [String: Any])?.compactMapValues { $0 as? [String] } }
    }

    /// waits for the next button or key for this slot of the action; the press that asked isn't it
    func capture(_ side: String, _ action: String, slot: Int, done: @escaping () -> Void) {
        timeout?.cancel()
        waitingSlot = slot
        finished = done
        DispatchQueue.main.async { self.capturing = side + ":" + action }
        timeout = Task {
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { stopCapture() }
        }
    }

    func stopCapture() {
        timeout?.cancel()
        capturing = ""
        finished?()
        finished = nil
    }

    func clear(_ side: String, _ action: String, slot: Int) {
        var l = all[side]?[action] ?? []
        guard l.indices.contains(slot) else { return }
        l.remove(at: slot)
        custom[side, default: [:]][action] = l
        save()
    }

    /// a button or key came in while capturing: one button, one action (it leaves whatever had it)
    /// true = taken
    func captured(_ side: String, _ name: String) -> Bool {
        let parts = capturing.split(separator: ":").map(String.init)
        guard parts.count == 2, parts[0] == side else { return false }
        stopCapture()
        let action = parts[1]
        var mine = (all[side]?[action] ?? []).filter { $0 != name }
        let had = all[side]?[action]?.count ?? 0
        mine.insert(name, at: min(waitingSlot, mine.count))
        if waitingSlot < had, mine.count > waitingSlot + 1 { mine.remove(at: waitingSlot + 1) }
        var c = custom
        for (a, l) in all[side] ?? [:] where a != action && l.contains(name) {
            c[side, default: [:]][a] = l.filter { $0 != name }
        }
        c[side, default: [:]][action] = Array(mine.prefix(3))
        custom = c
        save()
        return true
    }

    func reset() {
        custom = [:]
        save()
    }

    private func save() {
        let v = custom
        Task { _ = try? await Core.shared.raw("settings.setApp", ["key": "controls", "value": v]) }
    }

    // ---- names as the settings list shows them (qml Pads.js)

    private static let names: [String: [String: String]] = [
        "playstation": ["lb": "L1", "rb": "R1", "lt": "L2", "rt": "R2", "back": "Create", "start": "Options", "guide": "PS", "ls": "L3", "rs": "R3",
                        "touchpad": "Touchpad", "misc1": "Mute"],
        "xbox": ["lb": "LB", "rb": "RB", "lt": "LT", "rt": "RT", "back": "View", "start": "Menu", "guide": "Xbox", "ls": "LS", "rs": "RS", "misc1": "Share"],
        "nintendo": ["lb": "L", "rb": "R", "lt": "ZL", "rt": "ZR", "back": "−", "start": "+", "guide": "Home", "ls": "L3", "rs": "R3", "misc1": "Capture"],
        "generic": ["lb": "LB", "rb": "RB", "lt": "LT", "rt": "RT", "back": "Select", "start": "Start", "guide": "Home", "ls": "L3", "rs": "R3",
                    "touchpad": "Touchpad", "misc1": "Misc"],
    ]
    private static let faces: [String: [String: String]] = [
        "playstation": ["south": "Cross", "east": "Circle", "west": "Square", "north": "Triangle"],
        "xbox": ["south": "A", "east": "B", "west": "X", "north": "Y"],
        "nintendo": ["south": "B", "east": "A", "west": "Y", "north": "X"],
    ]

    func padText(_ button: String) -> String {
        if ["south", "east", "west", "north"].contains(button) {
            if let f = Self.faces[padKind]?[button] { return f }
            return [ "south": L("Button 1"), "east": L("Button 2"), "west": L("Button 3"), "north": L("Button 4")][button] ?? button
        }
        return (Self.names[padKind] ?? Self.names["generic"]!)[button] ?? Self.names["generic"]![button] ?? button
    }

    static func keyText(_ k: String) -> String {
        k == "Return" ? "Enter" : k == "PgUp" ? "Page Up" : k == "PgDown" ? "Page Down" : k
    }

    #if os(macOS)
    /// a key as qt's portable text spells it (what the setting holds); nil for the arrows, which
    /// always move
    static func keyName(_ e: NSEvent) -> String? {
        switch e.keyCode {
        case 123, 124, 125, 126: return nil
        case 36, 76: return "Return"
        case 53: return "Esc"
        case 51: return "Backspace"
        case 117: return "Del"
        case 49: return "Space"
        case 48: return "Tab"
        case 116: return "PgUp"
        case 121: return "PgDown"
        case 115: return "Home"
        case 119: return "End"
        default:
            guard let c = e.charactersIgnoringModifiers?.uppercased(), c.count == 1,
                  let s = c.unicodeScalars.first, s.value > 32, s.value < 127 else { return nil }
            return c
        }
    }
    #else
    /// a key as qt's portable text spells it (what the setting holds); nil for the arrows, which
    /// always move. a hardware keyboard's hid usage
    static func keyName(_ c: GCKeyCode) -> String? {
        switch c {
        case .returnOrEnter, .keypadEnter: return "Return"
        case .escape: return "Esc"
        case .deleteOrBackspace: return "Backspace"
        case .deleteForward: return "Del"
        case .spacebar: return "Space"
        case .tab: return "Tab"
        case .pageUp: return "PgUp"
        case .pageDown: return "PgDown"
        case .home: return "Home"
        case .end: return "End"
        default:
            let v = c.rawValue
            if (0x04...0x1D).contains(v) { return String(UnicodeScalar(UInt8(65 + v - 0x04))) }
            if (0x1E...0x26).contains(v) { return String(v - 0x1D) }
            if v == 0x27 { return "0" }
            return nil
        }
    }

    /// what a hardware key types into an on-screen keyboard that's up (nil: a normal key)
    static func typed(_ c: GCKeyCode, shift: Bool) -> Typed? {
        switch c {
        case .returnOrEnter, .keypadEnter: return .submit
        case .deleteOrBackspace: return .erase
        case .spacebar: return .text(" ")
        default:
            guard let n = keyName(c), n.count == 1 else { return nil }
            return .text(shift ? n : n.lowercased())
        }
    }

    #endif

    /// the pad family from the controller's own name (input.cpp padKind)
    static func kind(_ c: GCController) -> String {
        let n = (c.productCategory + " " + (c.vendorName ?? "")).lowercased()
        if n.contains("dualsense") || n.contains("dualshock") || n.contains("playstation") { return "playstation" }
        if n.contains("xbox") { return "xbox" }
        if n.contains("switch") || n.contains("joy-con") || n.contains("nintendo") { return "nintendo" }
        return "generic"
    }
}
