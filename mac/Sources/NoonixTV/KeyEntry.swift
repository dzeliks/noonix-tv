import SwiftUI

/// one key, address or login typed in setup / settings (qml KeyEntry): the glass keyboard (pad,
/// remote), a real keyboard or cmd+v. `check` runs on done; its answer stays on the card until it works
@MainActor @Observable
final class KeyEntryModel {
    var title = ""
    var hint = ""
    var placeholder = ""
    var secret = false
    var text = ""
    var status = ""
    var busy = false
    var ok = false
    var isOpen = false
    /// done with nothing typed is an answer too (clears a list)
    var allowEmpty = false
    let kb = KeyboardModel()
    @ObservationIgnored private var check: ((String) async -> (Bool, String))?
    /// what to do with the value once it's in (the next card, a refresh)
    @ObservationIgnored private var after: ((String) -> Void)?

    init() {
        kb.enterLabel = L("done")
        kb.typed = { [weak self] t in
            guard let self, text.count < 400 else { return }
            text += t
            status = ""
        }
        kb.special = { [weak self] n in
            guard let self else { return }
            switch n {
            case "backspace": if !text.isEmpty { text.removeLast() }
            case "clear": text = ""
            case "enter": submit()
            default: break
            }
            if !busy { status = "" }
        }
    }

    func open(title: String, hint: String = "", placeholder: String = "", secret: Bool = false, text: String = "", allowEmpty: Bool = false,
              check: ((String) async -> (Bool, String))? = nil, after: ((String) -> Void)? = nil) {
        self.title = title; self.hint = hint; self.placeholder = placeholder; self.secret = secret
        self.check = check; self.after = after; self.allowEmpty = allowEmpty
        self.text = text; status = ""; busy = false; ok = false
        kb.shift = false
        isOpen = true
    }

    func cancel() {
        isOpen = false
        after = nil
    }

    func submit() {
        let v = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty || allowEmpty, !busy else { return }
        guard let check else { done(v); return }
        busy = true
        status = L("Checking…")
        Task {
            let (good, message) = await check(v)
            busy = false
            ok = good
            status = message.isEmpty ? (good ? L("Works") : L("That didn't work")) : message
            // the tick shows for a moment before the card goes
            if good {
                try? await Task.sleep(for: .milliseconds(700))
                done(v)
            }
        }
    }

    private func done(_ v: String) {
        isOpen = false
        let f = after
        after = nil
        f?(v)
    }

    func key(_ k: Key) -> Bool {
        if k == .back { cancel(); return true }
        _ = kb.key(k)
        return true
    }

    func typed(_ t: Typed) {
        switch t {
        case .text(let s): if text.count < 400 { text += s; status = "" }
        case .erase: if !text.isEmpty { text.removeLast(); status = "" }
        case .submit: submit()
        }
    }
}

extension AppModel {
    /// a service key: typed, checked with its service, kept (qml Setup / Settings enter())
    func enterCredential(_ key: String, then: @escaping () -> Void) {
        let t: [String: (String, String, String)] = [
            "TORBOX_API_KEY": (L("TorBox API key"), L("torbox.app › Settings › API key"), "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"),
            "REALDEBRID_API_KEY": (L("Real-Debrid API token"), L("real-debrid.com/apitoken, signed in"), L("API token")),
            "ALLDEBRID_API_KEY": (L("AllDebrid API key"), L("alldebrid.com › Account › API keys › Create"), L("API key")),
            "TMDB_API_KEY": (L("TMDB API key"), L("themoviedb.org › Settings › API › API Key (the short one)"), L("API key")),
            "OPENSUBTITLES_API_KEY": (L("OpenSubtitles API key"), L("opensubtitles.com › Consumers › New consumer › API key"), L("API key")),
        ]
        let (title, hint, placeholder) = t[key] ?? (key, "", "")
        entry.open(title: title, hint: hint, placeholder: placeholder,
                   check: { v in await AppModel.credential(key, v) }, after: { _ in then() })
    }

    /// the opensubtitles login: the username, then the password on a second card
    func enterOpenSubtitlesLogin(then: @escaping () -> Void) {
        entry.open(title: L("OpenSubtitles username"), placeholder: L("Username"), after: { [weak self] user in
            self?.entry.open(title: L("OpenSubtitles password"), placeholder: L("Password"), secret: true,
                             check: { v in await AppModel.credential("OPENSUBTITLES_LOGIN", ["username": user, "password": v]) },
                             after: { _ in then() })
        })
    }

    static func credential(_ key: String, _ value: Any) async -> (Bool, String) {
        guard let d = try? await Core.shared.raw("setup.credential", ["key": key, "value": value]),
              let r = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return (false, L("Couldn't save it")) }
        var msg = r["message"] as? String ?? ""
        if let n = r["count"] { msg = msg.replacingOccurrences(of: "%1", with: "\(n)") }
        return (r["ok"] as? Bool == true, msg)
    }
}

struct KeyEntryView: View {
    @Environment(AppModel.self) private var app
    let model: KeyEntryModel

    var body: some View {
        let u = app.u
        let w = 900 * u, inner = w - 2 * 48 * u
        VStack(spacing: 22 * u) {
            Text(model.title).font(Theme.display(40 * u, .bold)).foregroundStyle(Theme.fg)
            if !model.hint.isEmpty {
                Text(model.hint).font(Theme.text(24 * u)).foregroundStyle(Theme.fg2)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            EntryField(text: model.text, placeholder: model.placeholder, secret: model.secret, active: model.isOpen, size: 26 * u, u: u)
            Text(model.status).font(Theme.text(24 * u, .medium))
                .foregroundStyle(model.ok ? Color(red: 0x30 / 255, green: 0xD1 / 255, blue: 0x58 / 255) : model.busy ? Theme.fg2 : Color(red: 1, green: 0x9F / 255, blue: 0x0A / 255))
                .frame(height: 30 * u)
            KeyboardView(model: model.kb, u: u / 2, width: inner, active: true)
            Text(L("A real keyboard works too, and ⌘V pastes. Back closes this."))
                .font(Theme.text(22 * u)).foregroundStyle(Theme.fg3)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: inner)
        .padding(48 * u)
        .panelGlass(56 * u, u: u)
        // in the middle of the app, part of it (not a window of its own in the corner)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// a typed value on a card (qml KeyEntry / ProfileAdd): a capsule, the end of a long one shown
/// a field's line (qml FieldText): what's typed (or a dim placeholder) and a blinking caret where
/// typing goes on. solid while keys come in, blinking once they stop
struct FieldLine: View {
    let text: String
    let placeholder: String
    var secret = false
    let active: Bool
    let size: CGFloat
    let u: CGFloat
    @State private var typedAt = Date()

    var body: some View {
        let shown = text.isEmpty ? placeholder : secret ? String(repeating: "•", count: text.count) : text
        HStack(spacing: 3 * u) {
            // empty: the caret first, where the first letter will go
            if text.isEmpty { caret.padding(.trailing, 6 * u) }
            Text(shown).font(Theme.display(size, .medium)).foregroundStyle(text.isEmpty ? Theme.fg3 : Theme.fg)
                .lineLimit(1).truncationMode(.head)
            if !text.isEmpty { caret }
        }
        .onChange(of: text) { typedAt = Date() }
        .onChange(of: active) { typedAt = Date() }
    }

    private var caret: some View {
        TimelineView(.periodic(from: typedAt, by: 0.53)) { ctx in
            let on = Int(ctx.date.timeIntervalSince(typedAt) / 0.53) % 2 == 0
            Capsule().fill(Theme.fg)
                .frame(width: 3 * u, height: size * 1.15)
                .opacity(active && on ? 1 : 0)
        }
        .frame(width: 3 * u)
    }
}

struct EntryField: View {
    let text: String
    let placeholder: String
    var secret = false
    let active: Bool
    let size: CGFloat
    let u: CGFloat

    var body: some View {
        FieldLine(text: text, placeholder: placeholder, secret: secret, active: active, size: size, u: u)
            .padding(.horizontal, 28 * u)
            .frame(maxWidth: .infinity, minHeight: 64 * u, maxHeight: 64 * u, alignment: .leading)
            .background {
                Capsule().fill(Color.white.opacity(0.1))
                    .overlay { Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1 * u) }
            }
    }
}
