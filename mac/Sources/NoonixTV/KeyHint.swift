import GameController
import SwiftUI

/// a key hint ("M  Options") in whatever was used last (qml KeyHint): the keyboard's key as a cap,
/// or the pad's own button (playstation shapes, xbox letters, a position for others)
struct KeyHint: View {
    @Environment(AppModel.self) private var app
    /// MENU, OK or BACK
    let key: String
    let label: String
    let u: CGFloat
    var labelSize: CGFloat = 33
    var labelColor = Color.white.opacity(0.62)
    /// touch or a phone (ios): no key to show, this says it instead (empty: no hint at all)
    var pointLabel = ""
    private var pointed: Bool { Platform.ios && (PointerMode.shared.on || Platform.phone) }

    private static let keys = ["MENU": "M", "OK": "Return", "BACK": "Esc"]
    private static let remote = ["MENU": "HOLD OK", "OK": "OK", "BACK": "BACK"]
    private static let positions = ["MENU": "north", "OK": "south", "BACK": "east"]

    var body: some View {
        if pointed {
            if !pointLabel.isEmpty { Text(pointLabel).font(Theme.display(labelSize * u)).foregroundStyle(labelColor) }
        } else {
            keyed
        }
    }

    private var keyed: some View {
        let line = Color.white.opacity(0.45)
        return HStack(spacing: 14 * u) {
            if app.inputKind == "pad" {
                Circle().stroke(line, lineWidth: 1.8 * u)
                    .frame(width: 50 * u, height: 50 * u)
                    .overlay { face }
                    .frame(height: 46 * u)
            } else {
                // the remote's caps as on linux; the siri remote has no menu key: the ok click held
                Text(app.inputKind == "remote" ? Self.remote[key] ?? key : Self.keys[key] ?? key)
                    .font(Theme.display(24 * u, .bold)).tracking(0.8 * u)
                    .foregroundStyle(Color.white.opacity(0.85))
                    .padding(.horizontal, 14 * u)
                    .frame(height: 46 * u)
                    .overlay { RoundedRectangle(cornerRadius: 11 * u).stroke(line, lineWidth: 1.6 * u) }
            }
            Text(label).font(Theme.display(labelSize * u)).foregroundStyle(labelColor)
        }
    }

    /// the pad's button for the action: its shape or letter, or four dots with the one to press filled
    @ViewBuilder private var face: some View {
        let pos = Self.positions[key] ?? "south"
        switch app.padKind {
        case "playstation":
            let shape = ["north": "triangle", "south": "xmark", "east": "circle", "west": "square"][pos] ?? "circle"
            Image(systemName: shape).font(.system(size: 22 * u, weight: .semibold)).foregroundStyle(Color.white.opacity(0.9))
        case "xbox":
            Text(["north": "Y", "south": "A", "east": "B", "west": "X"][pos] ?? "A")
                .font(Theme.rounded(26 * u, .bold)).foregroundStyle(Color.white.opacity(0.9))
        default:
            ZStack {
                ForEach([("north", 0.5, 0.17), ("east", 0.83, 0.5), ("south", 0.5, 0.83), ("west", 0.17, 0.5)], id: \.0) { p, x, y in
                    let on = p == pos
                    Circle()
                        .fill(on ? Color.white.opacity(0.95) : .clear)
                        .overlay { Circle().stroke(Color.white.opacity(on ? 0 : 0.55), lineWidth: 1.4 * u) }
                        .frame(width: 9 * u, height: 9 * u)
                        .position(x: x * 30 * u, y: y * 30 * u)
                }
            }
            .frame(width: 30 * u, height: 30 * u)
        }
    }
}

extension Pads {
    /// playstation, xbox or other: what the hints draw
    static var kind: String {
        guard let g = GCController.current?.extendedGamepad else { return "other" }
        if g is GCDualSenseGamepad || g is GCDualShockGamepad { return "playstation" }
        if g is GCXboxGamepad { return "xbox" }
        return "other"
    }
}
