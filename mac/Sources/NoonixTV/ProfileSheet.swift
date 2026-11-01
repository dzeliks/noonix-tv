import SwiftUI

/// a profile as a .noonix file (qml ProfileSheet): export shows what goes in (watch history and keys
/// are choices) and saves it to the downloads folder; import shows what the file adds before the new
/// profile is made
@MainActor @Observable
final class ProfileSheetModel {
    /// export | import
    let mode: String
    /// profiles.exportSummary / profiles.importPreview
    let info: [String: Any]
    let profile: Int
    var watch = true
    var keys = false
    var busy = false
    /// the options, then the buttons' row
    var index = 0
    var button = 0
    @ObservationIgnored var imported: () -> Void = {}

    init(mode: String, info: [String: Any], profile: Int = -1) {
        self.mode = mode
        self.info = info
        self.profile = profile
    }

    /// the picture: a file here (export) or the file's own (import, a data url)
    var picture: NSImage? {
        guard let s = info["image"] as? String, !s.isEmpty else { return nil }
        if s.hasPrefix("data:"), let comma = s.firstIndex(of: ",") {
            return Data(base64Encoded: String(s[s.index(after: comma)...])).flatMap(NSImage.init(data:))
        }
        return NSImage(contentsOfFile: s)
    }

    private func names(_ k: String) -> [String] { info[k] as? [String] ?? [] }
    private func count(_ f: String, _ list: [String]) -> String {
        Ln(f, list.count).replacingOccurrences(of: "%1", with: list.joined(separator: ", "))
    }

    var lines: [String] {
        var out: [String] = []
        let langs = names("languages").map(Lc), subs = names("subtitles").map(Lc)
        var l = langs.isEmpty ? "" : L("Audio: %1", langs.joined(separator: ", "))
        if !subs.isEmpty { l += (l.isEmpty ? "" : "  ·  ") + L("Subtitles: %1", subs.joined(separator: ", ")) }
        if !l.isEmpty { out.append(l) }
        let ext = names("extensions"), ad = names("addons")
        if mode == "export" {
            if !ext.isEmpty { out.append(count("%n extension(s): %1", ext)) }
            if !ad.isEmpty { out.append(count("%n addon(s): %1", ad)) }
            if ext.isEmpty && ad.isEmpty { out.append(L("No addons or extensions")) }
        } else {
            if !ext.isEmpty { out.append(count("Adds %n extension(s): %1", ext)) }
            if !ad.isEmpty { out.append(count("Adds %n addon(s): %1", ad)) }
            if info["torrents"] as? Bool == true { out.append(L("Its sources are torrents: they play only once you allow torrents")) }
        }
        let patterns = (info["patterns"] as? NSNumber)?.intValue ?? 0
        if patterns > 0 { out.append(Ln(mode == "export" ? "%n release pattern(s)" : "Adds %n release pattern(s) to yours", patterns)) }
        if mode == "import" {
            if !names("keys").isEmpty { out.append(L("Brings keys for %1", names("keys").joined(separator: ", "))) }
            if !names("keptKeys").isEmpty { out.append(L("Keeps the keys here for %1", names("keptKeys").joined(separator: ", "))) }
            if let w = info["watch"] as? [String: Any] {
                out.append(Ln("With its watch history: %n title(s)", (w["titles"] as? NSNumber)?.intValue ?? 0))
            } else {
                out.append(L("Without watch history"))
            }
        } else if !keys, !names("keyedAddons").isEmpty {
            out.append(count("Leaves out %n address(es) that may hold a key: %1", names("keyedAddons")))
        }
        if info["trakt"] as? Bool == true {
            out.append(mode == "export" ? L("Trakt stays here: sign in again on the other one") : L("Sign in to Trakt again after adding it"))
        }
        return out
    }

    /// export's choices: toggles above the buttons
    var options: [SettingsModel.Line] {
        guard mode == "export" else { return [] }
        let n = ((info["watch"] as? [String: Any])?["titles"] as? NSNumber)?.intValue ?? 0
        var out = [SettingsModel.Line(label: L("Watch history"),
                                      detail: n > 0 ? Ln("Progress, history, watchlist and rated sources: %n title(s)", n) : L("Progress, history, watchlist and rated sources"),
                                      checkable: true, checked: watch, act: "watch")]
        let k = names("keys")
        if !k.isEmpty || !names("keyedAddons").isEmpty {
            out.append(.init(label: L("Keys"),
                             detail: (k.isEmpty ? L("Addresses with a key in them") : L("Your keys for %1, and addresses with a key in them", k.joined(separator: ", ")))
                                + ". " + L("Anyone with the file can use them"),
                             checkable: true, checked: keys, act: "keys"))
        }
        return out
    }

    var buttons: [(text: String, act: String, primary: Bool)] {
        mode == "export" ? [(L("Save to Downloads"), "save", true), (L("Cancel"), "close", false)]
                         : [(L("Add Profile"), "import", true), (L("Cancel"), "close", false)]
    }

    func toggle(_ id: String) { if id == "watch" { watch.toggle() } else if id == "keys" { keys.toggle() } }

    private func call(_ m: String, _ a: [String: Any]) async -> ([String: Any]?, String?) {
        do {
            let d = try await Core.shared.raw(m, a)
            return (try? JSONSerialization.jsonObject(with: d) as? [String: Any], nil)
        } catch let e as CoreError {
            return (nil, Lc(e.message))
        } catch {
            return (nil, nil)
        }
    }

    func act(_ a: String, app: AppModel) {
        guard !busy else { return }
        if a == "close" { app.profileSheet = nil; return }
        busy = true
        Task {
            if a == "save" {
                let (r, err) = await call("profiles.export", ["id": profile, "watch": watch, "keys": keys])
                busy = false
                guard let r else { app.toast(err ?? L("Couldn't save it")); return }
                app.toast(L("Saved to Downloads as %1", r["file"] as? String ?? ""))
                app.profileSheet = nil
            } else {
                let (r, err) = await call("profiles.import", ["token": info["token"] as? String ?? ""])
                busy = false
                guard let r else { app.toast(err ?? L("Couldn't add it")); return }
                let name = r["name"] as? String ?? "", failed = r["failed"] as? [String] ?? []
                app.toast(failed.isEmpty ? L("Added %1", name) : L("Added %1, without %2", name, failed.joined(separator: ", ")))
                app.profileSheet = nil
                imported()
            }
        }
    }

    func key(_ k: Key, app: AppModel) {
        let opts = options, b = buttons
        switch k {
        case .up: index = max(0, index - 1)
        case .down: index = min(opts.count, index + 1)
        case .left: if index == opts.count { button = max(0, button - 1) }
        case .right: if index == opts.count { button = min(b.count - 1, button + 1) }
        case .ok:
            if index < opts.count { toggle(opts[index].act) } else if let x = b[safe: button] { act(x.act, app: app) }
        case .back: app.profileSheet = nil
        default: break
        }
    }
}

struct ProfileSheetView: View {
    @Environment(AppModel.self) private var app
    let model: ProfileSheetModel
    @State private var shown = false

    var body: some View {
        let u = app.u
        let info = model.info
        let name = info["name"] as? String ?? ""
        let opts = model.options
        ZStack {
            Rectangle().fill(.ultraThinMaterial).overlay { Color.black.opacity(0.74) }
                .ignoresSafeArea()
                .onTapGesture { app.profileSheet = nil }
            VStack(alignment: .leading, spacing: 30 * u) {
                Text(model.mode == "export" ? L("Export a profile") : L("Add this profile?"))
                    .font(Theme.text(26 * u, .medium)).foregroundStyle(Theme.fg3)
                HStack(spacing: 28 * u) {
                    Avatar(colour: info["color"] as? String ?? "green",
                           letter: String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased(),
                           size: 96 * u, picture: model.picture)
                    Text(name).font(Theme.display(60 * u, .bold)).foregroundStyle(Theme.fg).lineLimit(1)
                }
                VStack(alignment: .leading, spacing: 14 * u) {
                    ForEach(Array(model.lines.enumerated()), id: \.offset) { _, l in
                        Text(l).font(Theme.text(29 * u)).foregroundStyle(Theme.fg2)
                            .lineSpacing(3 * u).lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !opts.isEmpty {
                    VStack(spacing: 4 * u) {
                        ForEach(Array(opts.enumerated()), id: \.offset) { i, l in
                            SettingsRow(line: l, focused: model.index == i, u: u, grow: 1)
                                .opacity(model.busy ? 0.5 : 1)
                                .onContinuousHover { phase in if case .active = phase, Input.pointerLive { model.index = i } }
                                .onTapGesture { model.index = i; model.toggle(l.act) }
                        }
                    }
                }
                if model.mode == "import", !((info["extensions"] as? [Any] ?? []) + (info["addons"] as? [Any] ?? [])).isEmpty {
                    Text(L("Noonix TV doesn't check what an addon or extension offers. Only add ones you trust, for videos you have the right to watch."))
                        .font(Theme.text(24 * u)).foregroundStyle(Theme.fg3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 24 * u) {
                    ForEach(Array(model.buttons.enumerated()), id: \.offset) { i, b in
                        GlassButton(text: b.text, primary: b.primary, focused: model.index == opts.count && model.button == i, u: u, flat: true)
                            .opacity(model.busy ? 0.5 : 1)
                            .onContinuousHover { phase in if case .active = phase, Input.pointerLive { model.index = opts.count; model.button = i } }
                            .onTapGesture { model.act(b.act, app: app) }
                    }
                }
                .padding(.top, 4 * u)
            }
            .frame(width: 1240 * u, alignment: .leading)
            .scaleEffect(shown ? 1 : 0.96)
        }
        .onAppear { withAnimation(.timingCurve(0.33, 1, 0.68, 1, duration: 0.22)) { shown = true } }
    }
}
