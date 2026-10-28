import CNoonix
import Foundation

struct CoreError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// the rust core: the same rpc calls and pushes the qt app uses, answered on the core's threads
final class Core: @unchecked Sendable {
    static let shared = Core()

    private let lock = NSLock()
    private var waiting: [UInt64: CheckedContinuation<Data, Error>] = [:]
    // main thread only
    private var listeners: [String: [String: (Data) -> Void]] = [:]

    func start() {
        _ = noonix_start(nil, { _, id, ok, json in
            let text = json.map { String(cString: $0) } ?? "null"
            Core.shared.answer(id, ok, Data(text.utf8))
        }, { _, name, json in
            guard let name, let json else { return }
            let (n, data) = (String(cString: name), Data(String(cString: json).utf8))
            DispatchQueue.main.async { Core.shared.listeners[n]?.values.forEach { $0(data) } }
        })
    }

    /// raw json of one call
    func raw(_ method: String, _ args: [String: Any] = [:]) async throws -> Data {
        let body = String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)
        return try await withCheckedThrowingContinuation { cont in
            // held across the call: an answer that comes back at once waits for the entry
            lock.lock()
            let id = noonix_call(method, body)
            waiting[id] = cont
            lock.unlock()
        }
    }

    func call<T: Decodable>(_ method: String, _ args: [String: Any] = [:], as type: T.Type = T.self) async throws -> T {
        let data = try await raw(method, args)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// a push from the core ("streams", "trakt", ...) on the main thread; one listener per key
    func on(_ name: String, key: String, _ f: @escaping (Data) -> Void) {
        listeners[name, default: [:]][key] = f
    }

    private func answer(_ id: UInt64, _ ok: Bool, _ data: Data) {
        lock.lock()
        let cont = waiting.removeValue(forKey: id)
        lock.unlock()
        if ok {
            cont?.resume(returning: data)
        } else {
            let msg = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? "failed"
            cont?.resume(throwing: CoreError(message: msg))
        }
    }
}
