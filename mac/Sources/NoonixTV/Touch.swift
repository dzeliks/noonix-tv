#if os(iOS)
import UIKit
import SwiftUI

/// fingers on the window (android: the qml flickables): a drag up or down moves the page, sideways
/// the row of cards under it; a swipe in from the left edge is back. taps stay with the views
@MainActor
enum Touch {
    static var back: (() -> Void)?
    /// the row of cards the finger went down on (the top one there: the views hit-test it)
    static var claimed: PageScroll?

    private static var installed = false
    private static let handler = Handler()

    /// on the key window once there is one
    static func install() {
        guard !installed else { return }
        guard let w = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow) else {
            Task { try? await Task.sleep(for: .milliseconds(200)); install() }
            return
        }
        installed = true
        let pan = UIPanGestureRecognizer(target: handler, action: #selector(Handler.pan(_:)))
        pan.cancelsTouchesInView = false
        pan.delaysTouchesBegan = false
        pan.delegate = handler
        w.addGestureRecognizer(pan)
        let edge = UIScreenEdgePanGestureRecognizer(target: handler, action: #selector(Handler.edge(_:)))
        edge.edges = .left
        edge.delegate = handler
        w.addGestureRecognizer(edge)
        // a docked keyboard: what's typed into moves up above it
        let kb = { (n: Notification) in
            let f = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .null
            let top = f.isNull || f.height < 1 || f.minY >= w.bounds.height ? CGFloat.infinity : f.minY
            MainActor.assumeIsolated { withAnimation(.easeOut(duration: 0.22)) { AppModel.current?.keyboardTop = top } }
        }
        NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main, using: kb)
        NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { withAnimation(.easeOut(duration: 0.22)) { AppModel.current?.keyboardTop = .infinity } }
        }
        let down = Down(target: nil, action: nil)
        down.cancelsTouchesInView = false
        down.delaysTouchesBegan = false
        down.delaysTouchesEnded = false
        down.delegate = handler
        w.addGestureRecognizer(down)
    }

    enum Axis { case none, vertical, horizontal }

    final class Handler: NSObject, UIGestureRecognizerDelegate {
        private var axis = Axis.none
        private var row: PageScroll?
        private var last = CGPoint.zero
        private var fromEdge = false

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool { true }

        @objc func pan(_ g: UIPanGestureRecognizer) {
            MainActor.assumeIsolated {
                let v = g.view, t = g.translation(in: v)
                switch g.state {
                case .began:
                    axis = .none; row = nil; last = .zero
                    fromEdge = g.location(in: v).x - t.x < 24
                    Input.touched()
                case .changed:
                    if fromEdge { return }
                    if axis == .none {
                        guard hypot(t.x, t.y) > 10 else { return }
                        let start = CGPoint(x: g.location(in: v).x - t.x, y: g.location(in: v).y - t.y)
                        if abs(t.x) > abs(t.y) {
                            axis = .horizontal
                            row = Touch.claimed
                        } else {
                            axis = .vertical
                            AppModel.current?.touchX = start.x
                        }
                    }
                    let d = CGPoint(x: t.x - last.x, y: t.y - last.y)
                    last = t
                    Input.touched()
                    switch axis {
                    case .vertical: _ = Input.wheel?(d.y)
                    case .horizontal: if let row, let u = AppModel.current?.u { row.wheel(d.x, precise: true, u: u) }
                    case .none: break
                    }
                case .ended:
                    let vel = g.velocity(in: v)
                    switch axis {
                    case .vertical: AppModel.current?.fling(vel.y)
                    case .horizontal: row?.fling(vel.x)
                    case .none: break
                    }
                    axis = .none; row = nil; Touch.claimed = nil
                default:
                    axis = .none; row = nil; Touch.claimed = nil
                }
            }
        }

        @objc func edge(_ g: UIScreenEdgePanGestureRecognizer) {
            MainActor.assumeIsolated {
                guard g.state == .ended else { return }
                let t = g.translation(in: g.view), vel = g.velocity(in: g.view)
                if t.x > 80 || vel.x > 600 { Touch.back?() }
            }
        }
    }

    /// any finger down: the pointer takes over (before a tap lands); where it rests is pressed
    /// (FingerDown) until it lifts or moves. never recognizes, so it takes nothing from the views
    final class Down: UIGestureRecognizer {
        private var start = CGPoint.zero
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            let all = event.allTouches ?? touches
            let p = touches.first?.location(in: nil) ?? .zero
            start = p
            MainActor.assumeIsolated {
                Input.touched()
                FingerDown.shared.at = all.count == 1 ? p : nil
            }
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            guard let p = touches.first?.location(in: nil), hypot(p.x - start.x, p.y - start.y) > 10 else { return }
            MainActor.assumeIsolated { if FingerDown.shared.at != nil { FingerDown.shared.at = nil } }
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { lift() }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { lift() }
        private func lift() {
            MainActor.assumeIsolated { FingerDown.shared.at = nil }
            state = .failed
        }
    }
}

/// the phone's own keyboard typing into a field, unseen (qml ImeInput): the field's line shows what's
/// typed. `open` changing brings the keyboard up; return is done
struct ImeField: UIViewRepresentable {
    let text: String
    var secret = false
    var limit = 400
    var open = 0
    var words = false
    /// the return key says search
    var search = false
    /// the field itself shows (select, copy, paste): no drawn line over it
    var shown = false
    var size: CGFloat = 26
    var placeholder = ""
    let edited: (String) -> Void
    let done: () -> Void

    func makeUIView(context: Context) -> UITextField {
        let f = UITextField()
        f.alpha = shown ? 1 : 0.02
        f.tintColor = shown ? .white : .clear
        f.textColor = shown ? .white : .clear
        if shown {
            f.font = .systemFont(ofSize: size, weight: .medium)
            f.attributedPlaceholder = NSAttributedString(string: placeholder, attributes: [.foregroundColor: UIColor.white.withAlphaComponent(0.42)])
        }
        f.setContentHuggingPriority(.defaultLow, for: .horizontal)
        f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        f.autocorrectionType = .no
        f.spellCheckingType = .no
        f.autocapitalizationType = words ? .words : .none
        f.returnKeyType = search ? .search : .done
        f.keyboardAppearance = .dark
        f.delegate = context.coordinator
        f.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        return f
    }

    func updateUIView(_ f: UITextField, context: Context) {
        context.coordinator.owner = self
        f.isSecureTextEntry = secret
        if f.text != text { f.text = text }
        if context.coordinator.opened != open {
            context.coordinator.opened = open
            DispatchQueue.main.async { f.becomeFirstResponder() }
        }
    }

    static func dismantleUIView(_ f: UITextField, coordinator: Coordinator) { f.resignFirstResponder() }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var owner: ImeField
        var opened = 0
        init(_ o: ImeField) { owner = o }
        @objc func changed(_ f: UITextField) {
            var t = f.text ?? ""
            if t.count > owner.limit { t = String(t.prefix(owner.limit)); f.text = t }
            MainActor.assumeIsolated { owner.edited(t) }
        }
        func textFieldShouldReturn(_ f: UITextField) -> Bool {
            MainActor.assumeIsolated { owner.done() }
            return false
        }
    }
}
#else
import SwiftUI
/// (ios only: the phone's own keyboard)
struct ImeField: View {
    let text: String
    var secret = false
    var limit = 400
    var open = 0
    var words = false
    var search = false
    var shown = false
    var size: CGFloat = 26
    var placeholder = ""
    let edited: (String) -> Void
    let done: () -> Void
    var body: some View { EmptyView() }
}
#endif
