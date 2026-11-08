#if os(tvOS)
import UIKit
import GameController

/// apple tv: every press and swipe of the remote reaches the app before the system's focus engine
/// (it has nothing to move: the app keeps its own focus, like the tv ui on linux)
final class TVApp: UIApplication {
    /// swiftui makes the plain UIApplication: this turns it into one of these (nothing stored, so
    /// the swap is safe)
    static func take(_ app: UIApplication) { object_setClass(app, TVApp.self) }

    override func sendEvent(_ event: UIEvent) {
        if let e = event as? UIPressesEvent {
            TVRemote.presses(e)
            return
        }
        if event.type == .touches, let t = event.allTouches, t.contains(where: { $0.type == .indirect }) {
            TVRemote.touches(t)
            return
        }
        super.sendEvent(event)
    }
}

/// the siri remote (and any ir remote the apple tv learned) as the tv ui's keys: the ring's clicks
/// are the arrows (held: they repeat), the middle click ok (held: options), back, play / pause.
/// a swipe on the touch surface steps the arrows too. game pads come through Pads (their presses
/// here are the same buttons again: dropped)
@MainActor
enum TVRemote {
    private static var send: ((Key) -> Bool)?
    private static var held: Key?
    private static var repeatTask: Task<Void, Never>?
    private static var selectTask: Task<Void, Never>?
    private static var selectLong = false
    /// a swipe: where it started stepping from
    private static var swipeFrom: CGPoint?
    /// the touch surface: a step every this many points (the surface is about 1920 wide)
    private static let stepX: CGFloat = 260
    private static let stepY: CGFloat = 200

    static func install(_ f: @escaping (Key) -> Bool) {
        send = { k in
            PointerMode.shared.pressed("remote")
            if Input.keyed(), k.picks { return true }
            return f(k)
        }
    }

    /// a game pad's own press, seen here too (a pad's buttons count once, in Pads)
    private static func fromPad(_ p: UIPress) -> Bool {
        GCController.controllers().contains { c in
            guard c.extendedGamepad != nil else { return false }
            return abs(c.physicalInputProfile.lastEventTimestamp - p.timestamp) < 0.08
        }
    }

    static func presses(_ e: UIPressesEvent) {
        for p in e.allPresses {
            // a keyboard: GCKeyboard has it (Input)
            if p.key != nil { continue }
            switch p.phase {
            case .began:
                // the pad's report and its press arrive close together: decide a moment later
                if GCController.controllers().contains(where: { $0.extendedGamepad != nil }) {
                    let type = p.type
                    Task {
                        try? await Task.sleep(for: .milliseconds(30))
                        if !fromPad(p) { began(type) }
                    }
                } else {
                    began(p.type)
                }
            case .ended, .cancelled:
                ended(p.type)
            default:
                break
            }
        }
    }

    private static func began(_ t: UIPress.PressType) {
        switch t {
        case .upArrow: hold(.up)
        case .downArrow: hold(.down)
        case .leftArrow: hold(.left)
        case .rightArrow: hold(.right)
        case .select:
            // ok on letting go; held, the options (the remote has no menu key of its own)
            selectLong = false
            selectTask?.cancel()
            selectTask = Task {
                try? await Task.sleep(for: .milliseconds(550))
                guard !Task.isCancelled else { return }
                selectLong = true
                _ = send?(.menu)
            }
        case .menu: _ = send?(.back)
        case .playPause: _ = send?(.playPause)
        case .pageUp: _ = send?(.pageUp)
        case .pageDown: _ = send?(.pageDown)
        default: break
        }
    }

    private static func ended(_ t: UIPress.PressType) {
        switch t {
        case .upArrow: release(.up)
        case .downArrow: release(.down)
        case .leftArrow: release(.left)
        case .rightArrow: release(.right)
        case .select:
            guard let task = selectTask else { return }
            task.cancel()
            selectTask = nil
            if !selectLong { _ = send?(.ok) }
        default: break
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

    /// a finger on the touch surface: a step each time it travels far enough one way
    static func touches(_ all: Set<UITouch>) {
        guard let t = all.first(where: { $0.type == .indirect }) else { return }
        let p = t.location(in: nil)
        switch t.phase {
        case .began:
            swipeFrom = p
        case .moved:
            guard let from = swipeFrom else { swipeFrom = p; return }
            let dx = p.x - from.x, dy = p.y - from.y
            if abs(dx) >= stepX, abs(dx) > abs(dy) {
                _ = send?(dx > 0 ? .right : .left)
                swipeFrom = CGPoint(x: from.x + (dx > 0 ? stepX : -stepX), y: p.y)
            } else if abs(dy) >= stepY, abs(dy) > abs(dx) {
                _ = send?(dy > 0 ? .down : .up)
                swipeFrom = CGPoint(x: p.x, y: from.y + (dy > 0 ? stepY : -stepY))
            }
        default:
            swipeFrom = nil
        }
    }

    /// leaving: to the apple tv's home screen (apps don't quit themselves; the tv button does this)
    static func home() {
        UIControl().sendAction(NSSelectorFromString("suspend"), to: UIApplication.shared, for: nil)
    }
}
#endif
