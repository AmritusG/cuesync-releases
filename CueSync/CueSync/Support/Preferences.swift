import Foundation

/// Cross-platform key/value preferences. `UserDefaults` is Foundation-only and
/// compiles everywhere, but swift-corelibs-foundation's persistence on
/// Windows/Linux is not guaranteed, so every write is mirrored into a small JSON
/// file under the platform's Application Support directory as a durable fallback,
/// and reads prefer `UserDefaults` but fall back to that file.
enum Preferences {
    private static var fallbackFileURL: URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        let dir = base.appendingPathComponent("CueSync", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("preferences.json")
    }

    private static func readFallback() -> [String: String] {
        guard let url = fallbackFileURL,
              let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return dict
    }

    private static func writeFallback(_ dict: [String: String]) {
        guard let url = fallbackFileURL, let data = try? JSONEncoder().encode(dict) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func string(forKey key: String) -> String? {
        UserDefaults.standard.string(forKey: key) ?? readFallback()[key]
    }

    static func set(_ value: String?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        var dict = readFallback()
        dict[key] = value
        writeFallback(dict)
    }

    static func bool(forKey key: String) -> Bool {
        if UserDefaults.standard.object(forKey: key) != nil {
            return UserDefaults.standard.bool(forKey: key)
        }
        return readFallback()[key] == "true"
    }

    static func set(_ value: Bool, forKey key: String) {
        UserDefaults.standard.set(value, forKey: key)
        var dict = readFallback()
        dict[key] = value ? "true" : "false"
        writeFallback(dict)
    }
}
