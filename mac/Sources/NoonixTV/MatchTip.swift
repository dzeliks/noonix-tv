import SwiftUI

/// one-time tip on the first play (qml MatchTip): what "how's this one?" is and how to open it.
/// ok = again next launch, don't show again = never
struct MatchTipView: View {
    @Environment(AppModel.self) private var app
    let choice: Int
    @State private var shown = false

    var body: some View {
        let u = app.u
        ZStack {
            Color.black.opacity(0.32).ignoresSafeArea()
                .onTapGesture { app.closeTip(forever: false) }
            VStack(spacing: 0) {
                // the button it's about, as it looks when focused
                Image(systemName: "text.bubble")
                    .font(.system(size: 42 * u, weight: .semibold))
                    .foregroundStyle(Theme.focusFg)
                    .frame(width: 104 * u, height: 104 * u)
                    .background { Circle().fill(.white) }
                Text(L("How's this one?"))
                    .font(Theme.display(46 * u, .bold)).foregroundStyle(Theme.fg)
                    .padding(.top, 30 * u)
                // the siri remote has no menu key: its click, held
                Text(Theme.say(Platform.tv ? L("Hold OK while watching to say if the source and subtitles fit.") : L("Press Menu while watching to say if the source and subtitles fit."),
                               L("Tap the screen while watching, then the speech bubble, to say if the source and subtitles fit.")))
                    .font(Theme.text(27 * u, .medium)).foregroundStyle(Theme.fg2)
                    .multilineTextAlignment(.center)
                    .padding(.top, 14 * u)
                HStack(spacing: 12 * u) {
                    ForEach([("checkmark.circle", L("Good match")), ("arrow.triangle.2.circlepath", L("Out of sync")),
                             ("captions.bubble", L("Wrong subtitles")), ("film", L("Picture or sound"))], id: \.1) { icon, label in
                        HStack(spacing: 10 * u) {
                            Image(systemName: icon).font(.system(size: 20 * u, weight: .semibold)).frame(width: 26 * u, height: 26 * u)
                            Text(label).font(Theme.text(21 * u, .medium))
                        }
                        .foregroundStyle(Theme.fg)
                        .padding(.horizontal, 20 * u)
                        .frame(height: 58 * u)
                        .background { Capsule().fill(Color.white.opacity(0.08)) }
                        .overlay { Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1) }
                    }
                }
                .padding(.top, 34 * u)
                Text(L("What works is remembered for the next episodes.\nWhat doesn't gets fixed where you are.").replacingOccurrences(of: "\n", with: " "))
                    .font(Theme.text(22 * u)).foregroundStyle(Theme.fg3)
                    .multilineTextAlignment(.center)
                    .padding(.top, 26 * u)
                HStack(spacing: 24 * u) {
                    ForEach(Array([L("OK"), L("Don't show again")].enumerated()), id: \.offset) { i, t in
                        GlassButton(text: t, primary: i == 0 && Theme.touch, focused: choice == i, u: u, width: 360 * u)
                            .onContinuousHover { phase in if case .active = phase, Input.pointerLive { app.tipChoice = i } }
                            .onTapGesture { app.closeTip(forever: i == 1) }
                    }
                }
                .padding(.top, 44 * u)
            }
            .frame(width: 1040 * u - 120 * u)
            .padding(.horizontal, 60 * u)
            .padding(.top, 56 * u)
            .padding(.bottom, 56 * u)
            .panelGlass(52 * u, u: u)
            .scaleEffect(shown ? 1 : 0.96)
        }
        .onAppear { withAnimation(.timingCurve(0.33, 1, 0.68, 1, duration: 0.26)) { shown = true } }
    }
}

extension AppModel {
    /// the first play: what the match button is for, once the picture has settled (qml tipTimer)
    func scheduleTip() {
        guard !matchTipOff, !matchTipShown else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(2500))
            guard playing, player.state == .playing, let osd = Osd.shared,
                  osd.match == nil, osd.timing == nil, osd.picker == nil, sources == nil, !matchTipShown else { return }
            matchTipShown = true
            tipPaused = !player.paused
            if tipPaused { player.setPaused(true) }
            osd.hideNow()
            tipChoice = 0
        }
    }

    func closeTip(forever: Bool) {
        tipChoice = nil
        if forever {
            matchTipOff = true
            Task { _ = try? await Core.shared.raw("settings.setApp", ["key": "match_tip_off", "value": true]) }
        }
        if tipPaused { player.setPaused(false) }
        tipPaused = false
    }

    func tipKey(_ k: Key) {
        switch k {
        case .left: tipChoice = 0
        case .right: tipChoice = 1
        case .ok: closeTip(forever: tipChoice == 1)
        case .back: closeTip(forever: false)
        default: break
        }
    }
}
