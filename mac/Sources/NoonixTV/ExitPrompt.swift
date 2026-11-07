#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

/// back at the top of the app: leave noonix tv? (qml ExitPrompt: stay is focused, so a stray
/// back is harmless). choice 0 = exit, 1 = stay
struct ExitPromptView: View {
    @Environment(AppModel.self) private var app
    let choice: Int
    @State private var shown = false

    var body: some View {
        let u = app.u
        ZStack {
            Rectangle().fill(.ultraThinMaterial).overlay { Color.black.opacity(0.74) }
                .ignoresSafeArea()
                .onTapGesture { app.exitChoice = nil }
            VStack(spacing: 56 * u) {
                Text(L("Exit Noonix TV?"))
                    .font(Theme.display(64 * u, .bold))
                    .foregroundStyle(Theme.fg)
                HStack(spacing: 28 * u) {
                    ForEach(Array([L("Exit"), L("Stay")].enumerated()), id: \.offset) { i, t in
                        GlassButton(text: t, focused: choice == i, u: u, flat: true, width: 300 * u)
                            .onContinuousHover { phase in if case .active = phase, Input.pointerLive { app.exitChoice = i } }
                            .onTapGesture { i == 0 ? Platform.quit() : (app.exitChoice = nil) }
                    }
                }
            }
            .scaleEffect(shown ? 1 : 0.96)
        }
        .onAppear { withAnimation(.timingCurve(0.33, 1, 0.68, 1, duration: 0.22)) { shown = true } }
    }
}

extension AppModel {
    func exitKey(_ k: Key) {
        switch k {
        case .left: exitChoice = 0
        case .right: exitChoice = 1
        case .ok: if exitChoice == 0 { Platform.quit() } else { exitChoice = nil }
        case .back: exitChoice = nil
        default: break
        }
    }
}
