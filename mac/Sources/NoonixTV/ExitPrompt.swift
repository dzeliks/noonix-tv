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

/// the db file didn't open (qml DataError): the core runs on an empty one in memory and keeps
/// nothing, so this instead of everything else
struct DataErrorView: View {
    @Environment(AppModel.self) private var app
    let error: String

    var body: some View {
        let u = app.u
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                Text(L("Noonix TV can't open its data"))
                    .font(Theme.display(64 * u, .bold))
                    .foregroundStyle(Theme.fg)
                    .multilineTextAlignment(.center)
                Text(L("Your profiles and settings are still on this device, they just couldn't be read. Close Noonix TV and open it again. If this comes back, the storage may be full or the file damaged."))
                    .font(Theme.text(28 * u))
                    .foregroundStyle(Theme.fg2)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4 * u)
                    .frame(maxWidth: 900 * u)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 26 * u)
                Text(error)
                    .font(Theme.text(22 * u))
                    .foregroundStyle(Theme.fg3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 900 * u)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 22 * u)
                // ios apps don't quit themselves
                if Platform.canQuit {
                    GlassButton(text: L("Close"), primary: true, focused: true, u: u, flat: true, width: 300 * u)
                        .onTapGesture { Platform.quit() }
                        .padding(.top, 56 * u)
                }
            }
            .padding(.horizontal, Theme.margin(u))
        }
    }
}

/// a yes / no question over everything (qml Confirm): title, a line on what happens, two buttons.
/// cancel has the focus, so a stray ok or back is harmless
@MainActor @Observable
final class ConfirmModel {
    let title: String
    let detail: String
    let ok: String
    let cancel: String
    let yes: () -> Void
    /// cancel, back or a tap outside
    let no: (() -> Void)?
    var answered = false
    var choice = 1          // 0 yes, 1 cancel

    init(title: String, detail: String, ok: String, cancel: String = L("Cancel"), yes: @escaping () -> Void, no: (() -> Void)? = nil) {
        self.title = title
        self.detail = detail
        self.ok = ok
        self.cancel = cancel
        self.yes = yes
        self.no = no
    }
}

struct ConfirmView: View {
    @Environment(AppModel.self) private var app
    let model: ConfirmModel
    @State private var shown = false

    var body: some View {
        let u = app.u
        // one width for both buttons: the longer label decides
        let bw = max(300 * u, (CGFloat(max(model.ok.count, model.cancel.count)) * 15 + 120) * u)
        ZStack {
            Rectangle().fill(.ultraThinMaterial).overlay { Color.black.opacity(0.74) }
                .ignoresSafeArea()
                .onTapGesture { app.confirm = nil }
            VStack(spacing: 0) {
                Text(model.title)
                    .font(Theme.display(64 * u, .bold))
                    .foregroundStyle(Theme.fg)
                    .multilineTextAlignment(.center)
                if !model.detail.isEmpty {
                    Text(model.detail)
                        .font(Theme.text(28 * u))
                        .foregroundStyle(Theme.fg2)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4 * u)
                        .frame(maxWidth: 900 * u)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 26 * u)
                }
                HStack(spacing: 28 * u) {
                    ForEach(Array([model.ok, model.cancel].enumerated()), id: \.offset) { i, t in
                        GlassButton(text: t, focused: model.choice == i, u: u, flat: true, width: bw)
                            .onContinuousHover { phase in if case .active = phase, Input.pointerLive { model.choice = i } }
                            .onTapGesture { i == 0 ? app.confirmYes() : (app.confirm = nil) }
                    }
                }
                .padding(.top, 56 * u)
            }
            .padding(.horizontal, Theme.margin(u))
            .scaleEffect(shown ? 1 : 0.96)
        }
        .onAppear { withAnimation(.timingCurve(0.33, 1, 0.68, 1, duration: 0.22)) { shown = true } }
    }
}

extension AppModel {
    func confirmKey(_ k: Key) {
        guard let c = confirm else { return }
        switch k {
        case .left: c.choice = 0
        case .right: c.choice = 1
        case .ok: if c.choice == 0 { confirmYes() } else { confirm = nil }
        case .back: confirm = nil
        default: break
        }
    }

    func confirmYes() {
        let f = confirm?.yes
        confirm?.answered = true
        confirm = nil
        f?()
    }
}
