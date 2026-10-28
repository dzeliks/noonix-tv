import SwiftUI

/// "what's this?" next to torrents / a debrid service (qml SourcesHelp): the difference in a few
/// lines. asking: the torrent one also takes the user's yes or no (a source of theirs answers with
/// torrents)
@MainActor @Observable
final class SourcesHelpModel {
    /// torrent | debrid
    let topic: String
    let asking: Bool
    var button = 0
    @ObservationIgnored var answered: (Bool) -> Void = { _ in }

    init(topic: String, asking: Bool = false) {
        self.topic = topic
        self.asking = asking
    }

    var title: String { topic == "debrid" ? L("Debrid services") : asking ? L("Allow torrents?") : L("Torrents") }

    var texts: [String] {
        topic == "debrid" ? [
            L("A debrid service (TorBox, Real-Debrid, AllDebrid and others) is a paid service that fetches videos to its own fast servers, and you watch from there. It starts quickly and plays smoothly."),
            L("An addon or extension you added asks for your key from the service. Noonix TV sends it only to the addresses that extension listed."),
            L("Only watch what you have the right to. You're responsible for the sources you add."),
        ] : [
            L("A source of yours can answer with torrents: the video comes straight from other people who have it. Noonix TV only downloads, it never shares pieces back, and deletes the file when you stop."),
            L("It can be slower to start, and videos few people have may not play. Others in the swarm can see your IP address."),
            L("Downloading videos you have no right to is illegal in many countries. Use it at your own risk, and only for what you're allowed to watch."),
        ]
    }

    func answer(_ yes: Bool, app: AppModel) {
        app.help = nil
        answered(yes)
    }

    func close(app: AppModel) {
        if asking { answer(false, app: app) } else { app.help = nil }
    }

    func key(_ k: Key, app: AppModel) {
        switch k {
        case .left: button = 0
        case .right: if asking { button = 1 }
        case .ok: if button == 1 { answer(false, app: app) } else if asking { answer(true, app: app) } else { app.help = nil }
        case .back: close(app: app)
        default: break
        }
    }
}

struct SourcesHelpView: View {
    @Environment(AppModel.self) private var app
    let model: SourcesHelpModel
    @State private var shown = false

    var body: some View {
        let u = app.u
        ZStack {
            Rectangle().fill(.ultraThinMaterial).overlay { Color.black.opacity(0.6) }
                .ignoresSafeArea()
                .onTapGesture { if !model.asking { app.help = nil } }
            VStack(alignment: .leading, spacing: 34 * u) {
                Text(model.title).font(Theme.display(60 * u, .bold)).foregroundStyle(Theme.fg)
                ForEach(Array(model.texts.enumerated()), id: \.offset) { _, t in
                    Text(t).font(Theme.text(30 * u)).foregroundStyle(Theme.fg2).lineSpacing(5 * u)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.topic == "torrent" {
                    Text(L("You can change it any time in Settings › Sources.")).font(Theme.text(26 * u)).foregroundStyle(Theme.fg3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 24 * u) {
                    GlassButton(text: model.asking ? L("Allow Torrents") : L("Got It"), primary: true, focused: model.button == 0, u: u, flat: true, width: 340 * u)
                        .onContinuousHover { phase in if case .active = phase, Input.pointerLive { model.button = 0 } }
                        .onTapGesture { if model.asking { model.answer(true, app: app) } else { app.help = nil } }
                    if model.asking {
                        GlassButton(text: L("Not Now"), focused: model.button == 1, u: u, flat: true, width: 300 * u)
                            .onContinuousHover { phase in if case .active = phase, Input.pointerLive { model.button = 1 } }
                            .onTapGesture { model.answer(false, app: app) }
                    }
                }
                .padding(.top, 6 * u)
            }
            .frame(width: 1240 * u, alignment: .leading)
            .scaleEffect(shown ? 1 : 0.96)
        }
        .onAppear { withAnimation(.timingCurve(0.33, 1, 0.68, 1, duration: 0.22)) { shown = true } }
    }
}
