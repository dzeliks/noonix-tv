import SwiftUI

/// a file through the system's picker on an iphone or ipad (the in-app browser sees only the app's own
/// folder there): copied out while the app may read it, the core gets the copy. tag: one folder per
/// kind, only its latest pick kept
@MainActor
final class SystemFile {
    enum Picked { case file(String), tooBig, unreadable, none }
    let tag: String
    let max: Int
    let done: (Picked) -> Void

    init(tag: String, max: Int, done: @escaping (Picked) -> Void) {
        self.tag = tag
        self.max = max
        self.done = done
    }

    static var available: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    func finish(_ url: URL?) {
        guard let url else { done(.none); return }
        let tag = tag, max = max, done = done
        Task.detached(priority: .userInitiated) {
            let r = Self.copy(url, tag: tag, max: max)
            await MainActor.run { done(r) }
        }
    }

    nonisolated private static func copy(_ url: URL, tag: String, max: Int) -> Picked {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > max { return .tooBig }
        guard let data = try? Data(contentsOf: url) else { return .unreadable }
        if data.count > max { return .tooBig }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "picked/" + tag.filter(\.isLetter), directoryHint: .isDirectory)
        try? fm.removeItem(at: dir)
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { return .unreadable }
        // the name is kept for its extension and the subtitle list: no hidden files
        var name = String(url.lastPathComponent.drop(while: { $0 == "." }).suffix(120))
        if name.isEmpty { name = "file" }
        let out = dir.appending(path: name, directoryHint: .notDirectory)
        guard (try? data.write(to: out)) != nil else { return .unreadable }
        return .file(out.path)
    }
}
