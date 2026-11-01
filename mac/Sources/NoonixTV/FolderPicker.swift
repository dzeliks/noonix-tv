import SwiftUI

/// picking a library folder, or a noonix file (files), with a remote or a controller (qml FolderPicker):
/// the places to start from (home, its video or downloads folder, the drives), then folder by folder.
/// ok opens a folder or picks the file, back goes up
@MainActor @Observable
final class FolderPickerModel {
    typealias Line = SettingsModel.Line
    /// library.browse: path, name, label, parent, folders, videos, files
    var view: [String: Any] = [:]
    /// file extensions to list and pick, none = a folder
    var files: [String] = []
    var caption = L("Add a folder")
    var index = 0
    var busy = false
    @ObservationIgnored var picked: (String) -> Void = { _ in }

    var path: String { view["path"] as? String ?? "" }

    private var folders: [[String: Any]] { view["folders"] as? [[String: Any]] ?? [] }

    private func placeName(_ f: [String: Any]) -> String {
        switch f["place"] as? String {
        case "home": return L("Home folder")
        case "videos": return f["name"] as? String == "Movies" ? L("Movies folder") : L("Videos folder")
        case "downloads": return L("Downloads folder")
        default: return f["name"] as? String ?? ""
        }
    }

    var lines: [Line] {
        var out: [Line] = []
        if !path.isEmpty {
            if files.isEmpty {
                let n = (view["videos"] as? NSNumber)?.intValue ?? 0
                out.append(Line(label: L("Use this folder"), detail: n > 0 ? Ln("%n video(s) right here, and what's in the folders inside", n) : L("With what's in the folders inside"),
                                value: L("Add"), act: "use"))
            }
            let parent = view["parent"] as? String ?? ""
            out.append(Line(label: L("Up a folder"), detail: !parent.isEmpty ? parent : files.isEmpty ? L("Back to where your videos may be") : L("Back to where it may be"),
                            value: "‹", act: "up"))
        }
        for f in view["files"] as? [[String: Any]] ?? [] {
            out.append(Line(label: f["name"] as? String ?? "", value: L("Open"), act: "file:" + (f["path"] as? String ?? "")))
        }
        for f in folders {
            let place = f["place"] as? String ?? ""
            let label = f["label"] as? String ?? ""
            out.append(Line(label: placeName(f), detail: place == "drive" ? L("Drive") + "  ·  " + label : place.isEmpty ? "" : label,
                            value: "›", act: "open:" + (f["path"] as? String ?? "")))
        }
        return out
    }

    func go(_ path: String, app: AppModel) {
        busy = true
        Task {
            let d = try? await Core.shared.raw("library.browse", ["path": path, "files": files])
            busy = false
            guard let d, let v = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], v["error"] == nil else {
                app.toast(L("Couldn't open that folder"))
                return
            }
            view = v
            index = 0
        }
    }

    func run(_ l: Line, app: AppModel) {
        guard !busy else { return }
        if l.act == "use" {
            app.folderPicker = nil
            picked(path)
        } else if l.act.hasPrefix("file:") {
            app.folderPicker = nil
            picked(String(l.act.dropFirst(5)))
        } else if l.act == "up" {
            up(app: app)
        } else if l.act.hasPrefix("open:") {
            go(String(l.act.dropFirst(5)), app: app)
        }
    }

    func up(app: AppModel) {
        if path.isEmpty { app.folderPicker = nil } else { go(view["parent"] as? String ?? "", app: app) }
    }

    func key(_ k: Key, app: AppModel) {
        let ls = lines
        switch k {
        case .up: index = max(0, index - 1)
        case .down: index = min(max(0, ls.count - 1), index + 1)
        case .ok: if let l = ls[safe: index] { run(l, app: app) }
        case .back: up(app: app)
        default: break
        }
    }
}

struct FolderPickerView: View {
    @Environment(AppModel.self) private var app
    let model: FolderPickerModel
    @State private var shown = false
    @State private var listH: CGFloat = 0

    var body: some View {
        let u = app.u
        let lines = model.lines
        ZStack {
            Rectangle().fill(.ultraThinMaterial).overlay { Color.black.opacity(0.74) }
                .ignoresSafeArea()
                .onTapGesture { app.folderPicker = nil }
            VStack(alignment: .leading, spacing: 30 * u) {
                Text(model.caption).font(Theme.text(26 * u, .medium)).foregroundStyle(Theme.fg3)
                VStack(alignment: .leading, spacing: 6 * u) {
                    Text(!model.path.isEmpty ? model.view["name"] as? String ?? "" : model.files.isEmpty ? L("Where are your videos?") : L("Where is it?"))
                        .font(Theme.display(60 * u, .bold)).foregroundStyle(Theme.fg).lineLimit(1)
                    if !model.path.isEmpty {
                        Text(model.view["label"] as? String ?? "").font(Theme.text(28 * u)).foregroundStyle(Theme.fg2)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(spacing: 0) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                                SettingsRow(line: l, focused: model.index == i, u: u, grow: 1)
                                    .opacity(model.busy ? 0.5 : 1)
                                    .onContinuousHover { phase in if case .active = phase, Input.pointerLive { model.index = i } }
                                    .onTapGesture { model.index = i; model.run(l, app: app) }
                                    .id(i)
                            }
                            if lines.isEmpty && !model.busy {
                                Text(model.files.isEmpty ? L("No folders here") : L("No folders or files here")).font(Theme.text(28 * u)).foregroundStyle(Theme.fg3)
                                    .frame(maxWidth: .infinity, minHeight: 120 * u)
                            }
                        }
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listH = $0 }
                    }
                    .scrollIndicators(.never)
                    .frame(height: min(640 * u, max(120 * u, listH)))
                    .onChange(of: model.index) { if !Input.pointerHolds { withAnimation(.easeOut(duration: 0.14)) { proxy.scrollTo(model.index, anchor: .center) } } }
                    .onChange(of: model.path) { proxy.scrollTo(0, anchor: .top) }
                }
                .padding(16 * u)
                .panelGlass(40 * u, u: u)
                Text(model.files.isEmpty ? L("OK opens a folder, Back goes up") : L("OK opens a folder or the file, Back goes up")).font(Theme.text(24 * u)).foregroundStyle(Theme.fg3)
            }
            .frame(width: 1240 * u, alignment: .leading)
            .scaleEffect(shown ? 1 : 0.96)
        }
        .onAppear { withAnimation(.timingCurve(0.33, 1, 0.68, 1, duration: 0.22)) { shown = true } }
    }
}
