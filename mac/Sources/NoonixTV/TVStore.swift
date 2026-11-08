#if os(tvOS)
import Foundation
import SQLite3
import UIKit

/// apple tv keeps an app's files only as caches: the system may clear them when space runs low. the
/// database without its cache table (profiles, settings, logins, progress) is kept in the app's
/// defaults too, and comes back from there before the core opens it
enum TVStore {
    private static let key = "noonix.db"
    /// tvos keeps about 500 kb of defaults per app
    private static let limit = 450_000
    private static var timer: Timer?
    private static var lastSaved: Data?

    private static var dataDir: URL {
        if let home = ProcessInfo.processInfo.environment["NOONIX_HOME"] {
            return URL(fileURLWithPath: home).appendingPathComponent("data")
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Noonix TV/data")
    }
    private static var db: URL { dataDir.appendingPathComponent("noonix-tv.db") }

    /// at launch, before the core: the copy back when the files were cleared
    static func restore() {
        guard !FileManager.default.fileExists(atPath: db.path),
              let packed = UserDefaults.standard.data(forKey: key),
              let raw = try? (packed as NSData).decompressed(using: .zlib) as Data else { return }
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        if (try? raw.write(to: db)) != nil { NSLog("tvstore: database restored from defaults") }
    }

    /// saves on the way to the background and every 10 minutes while open
    static func install() {
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            let task = UIApplication.shared.beginBackgroundTask()
            DispatchQueue.global(qos: .utility).async {
                save()
                DispatchQueue.main.async { UIApplication.shared.endBackgroundTask(task) }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in
            DispatchQueue.global(qos: .utility).async { save() }
        }
    }

    /// a copy of the database without the cache, compacted and packed
    static func save() {
        guard FileManager.default.fileExists(atPath: db.path) else { return }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("noonix-backup.db")
        try? FileManager.default.removeItem(at: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        var src: OpaquePointer?
        guard sqlite3_open_v2(db.path, &src, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(src); return }
        let copied = sqlite3_exec(src, "VACUUM INTO '\(tmp.path.replacingOccurrences(of: "'", with: "''"))'", nil, nil, nil) == SQLITE_OK
        sqlite3_close(src)
        guard copied else { return }
        var out: OpaquePointer?
        guard sqlite3_open(tmp.path, &out) == SQLITE_OK else { sqlite3_close(out); return }
        sqlite3_exec(out, "DELETE FROM cache; VACUUM;", nil, nil, nil)
        sqlite3_close(out)
        guard let raw = try? Data(contentsOf: tmp),
              let packed = try? (raw as NSData).compressed(using: .zlib) as Data else { return }
        guard packed.count <= limit else {
            NSLog("tvstore: database too big for defaults (\(packed.count) bytes), not kept")
            return
        }
        DispatchQueue.main.async {
            guard packed != lastSaved else { return }
            lastSaved = packed
            UserDefaults.standard.set(packed, forKey: key)
        }
    }
}
#endif
