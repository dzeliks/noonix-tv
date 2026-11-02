import SwiftUI

/// a card's options (qml Main's menu popup, the menu key): go to the show / play, play from the
/// beginning, library, remove from the row it's in
@MainActor @Observable
final class CardMenu {
    enum Act { case open, play, restart, library, dismiss }
    let item: Item
    let row: RowModel?
    /// the card's art in the window (qml menuAt): the menu sits above it
    let at: CGRect?
    var index = 0
    var library = -1          // -1 asking, -2 failed, 0 no, 1 in the library

    init(item: Item, row: RowModel?, at: CGRect? = nil) {
        self.item = item
        self.row = row
        self.at = at
        loadLibrary()
    }

    var episode: Bool { item.kind == "episode" }
    var title: String {
        episode ? (item.showTitle ?? "") + "  ·  " + (item.episodeCode ?? "") : item.title ?? ""
    }
    var target: [String: Any] {
        ["kind": item.isMovie ? "movie" : "show", "tmdb": (episode ? item.show : item.tmdb) ?? 0]
    }

    var options: [(String, Act)] {
        var o: [(String, Act)] = []
        if episode { o.append((L("Go to Show"), .open)) } else if item.isMovie { o.append((L("Play"), .play)) }
        if (episode || item.isMovie), (item.progress ?? 0) > 0.01 { o.append((L("Play from Beginning"), .restart)) }
        o.append((library == -1 ? L("Checking Library…") : library == -2 ? L("Retry Library") : library == 1 ? L("Remove from Library") : L("Add to Library"), .library))
        let rm = ["upnext": L("Remove from Up Next"), "continue": L("Remove from Continue Watching"),
                  "continue-movie": L("Remove from Continue Watching"), "recent": L("Remove from Recently Played")][row?.row.id ?? ""]
        if let rm { o.append((rm, .dismiss)) }
        return o
    }

    func loadLibrary() {
        library = -1
        Task {
            if let d = try? await Core.shared.call("library.state", target, as: [String: Bool].self) {
                library = d["inLibrary"] == true ? 1 : 0
            } else {
                library = -2
            }
        }
    }

    func key(_ k: Key, app: AppModel) {
        switch k {
        case .up: index = max(0, index - 1)
        case .down: index = min(options.count - 1, index + 1)
        case .ok: run(options[index].1, app: app)
        case .back, .menu: app.menu = nil
        default: break
        }
    }

    func run(_ a: Act, app: AppModel) {
        if a == .library && library < 0 {
            if library == -2 { loadLibrary() }
            return
        }
        app.menu = nil
        let it = item
        switch a {
        case .open:
            if let show = it.show {
                app.detailStack.append(DetailsModel(item: Item.show(show, title: it.showTitle, backdrop: it.backdrop, poster: it.poster), app: app))
            }
        case .play:
            app.play(PlayTarget(kind: "movie", tmdb: it.tmdb ?? 0, title: it.title ?? ""))
        case .restart:
            app.play(it.isMovie ? PlayTarget(kind: "movie", tmdb: it.tmdb ?? 0, title: it.title ?? "", start: 0)
                     : PlayTarget(kind: "show", tmdb: it.show ?? 0, season: it.season, episode: it.episode,
                                  title: it.showTitle ?? "", episodeTitle: it.episodeTitle, start: 0))
        case .library:
            let on = library != 1
            var args = target
            args["on"] = on
            // gone at once: trakt can take a while to answer
            if !on {
                if let row, row.id.hasPrefix("library") {
                    row.items.removeAll { $0.id == it.id }
                    row.index = min(row.index, max(0, row.items.count - 1))
                } else if row == nil, app.page == .library {
                    app.library.removeLocal(it)
                }
            }
            Task {
                let done = (try? await Core.shared.raw("library.set", args)) != nil
                app.refreshLists()
                guard done else {
                    app.toast(on ? L("Couldn't add it") : L("Couldn't remove it"))
                    return
                }
                app.toast(on ? L("Added to Library") : L("Removed from Library"), action: L("Undo"), run: {
                    var back = args
                    back["on"] = !on
                    Task {
                        if (try? await Core.shared.raw("library.set", back)) != nil { app.refreshLists() } else { app.toast(L("Couldn't undo that change")) }
                    }
                })
            }
        case .dismiss:
            guard let row else { return }
            row.items.removeAll { $0.id == it.id }
            row.index = min(row.index, max(0, row.items.count - 1))
            // gone here at once; trakt hears of it once the undo has passed
            let profile = app.profiles?.current ?? 0
            Task {
                if (try? await Core.shared.raw("home.dismiss", ["item": it.json, "profile": profile, "sync": false])) != nil {
                    // the same title can sit in rows on the other pages
                    app.refreshRows()
                    app.toast(L("Removed"), action: L("Undo"), secs: 6, run: {
                        Task {
                            if (try? await Core.shared.raw("home.dismiss", ["item": it.json, "profile": profile, "undo": true, "sync": false])) == nil {
                                app.toast(L("Couldn't undo that change"))
                            }
                            app.refreshRows()
                        }
                    }, commit: {
                        Task {
                            if (try? await Core.shared.raw("home.dismiss", ["item": it.json, "profile": profile])) == nil {
                                app.toast(L("Removed here · couldn't update Trakt"))
                            }
                        }
                    })
                } else {
                    app.toast(L("Couldn't remove it"))
                    await row.load(force: true)
                }
            }
        }
    }
}

struct CardMenuView: View {
    @Environment(AppModel.self) private var app
    let model: CardMenu

    var body: some View {
        let u = app.u
        let opts = model.options
        let W = app.size.width, H = app.size.height
        // above the card, left edges aligned; below it when there's no room (qml optPanel). no
        // card: the margin, above the middle
        let at = model.at ?? CGRect(x: Theme.margin(u), y: H / 2, width: 440 * u, height: 0)
        let w = max(440 * u, at.width)
        let h = (64 + 32) * u + opts.reduce(0) { $0 + ($1.1 == .dismiss ? 108 : 84) * u }
        let x = max(40 * u, min(at.minX, W - w - 40 * u))
        let y = max(120 * u, min(H - h - 40 * u, at.minY - h - 20 * u > 120 * u ? at.minY - h - 20 * u : at.maxY + 20 * u))
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.001).contentShape(.rect).onTapGesture { app.menu = nil }
            VStack(alignment: .leading, spacing: 0) {
                Text(model.title)
                    .font(Theme.display(24 * u, .semibold)).foregroundStyle(Theme.fg2).lineLimit(1)
                    .padding(.horizontal, 30 * u)
                    .frame(height: 64 * u)
                ForEach(Array(opts.enumerated()), id: \.offset) { i, o in
                    let foc = model.index == i
                    Text(o.0)
                        .font(Theme.text(27 * u, .medium))
                        .foregroundStyle(foc ? Theme.focusFg : Theme.fg)
                        .opacity(o.1 == .library && model.library == -1 ? 0.5 : 1)
                        .padding(.horizontal, 30 * u)
                        .frame(maxWidth: .infinity, minHeight: (o.1 == .dismiss ? 108 : 84) * u, alignment: .leading)
                        .background { RoundedRectangle(cornerRadius: 24 * u).fill(foc ? Color.white : .clear) }
                        .contentShape(.rect)
                        .onContinuousHover { phase in if case .active = phase, Input.pointerLive { model.index = i } }
                        .onTapGesture { model.run(o.1, app: app) }
                }
            }
            .padding(16 * u)
            .frame(width: w)
            .panelGlass(40 * u, u: u)
            .offset(x: x, y: y)
        }
        .frame(width: app.size.width, height: app.size.height, alignment: .topLeading)
    }
}

/// a short note top right just under the bar (qml Toast): the tab pill's height and glass, with
/// its action key
struct ToastView: View {
    @Environment(AppModel.self) private var app
    let text: String

    var body: some View {
        let u = app.u
        HStack(spacing: 26 * u) {
            Text(text).font(Theme.display(28 * u, .medium)).foregroundStyle(Theme.fg)
            if !app.toastAction.isEmpty {
                KeyHint(key: "MENU", label: app.toastAction, u: u * 0.9, labelSize: 28 / 0.9)
            }
        }
        .padding(.horizontal, 36 * u)
        .frame(height: 78 * u)
        .glassEffect(.regular.tint(.black.opacity(0.3)), in: .capsule)
        .overlay { GlassRim(shape: Capsule(), u: u) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        // under the bar, or under the player's clock and end time
        .padding(.top, (app.playing ? 168 : 140) * u)
        .padding(.trailing, Theme.margin(u))
        .allowsHitTesting(false)
    }
}
