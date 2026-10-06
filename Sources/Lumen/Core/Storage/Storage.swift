import Foundation

/// JSON files under `~/Library/Application Support/Lumen/`.
enum Storage {
    static let directory: URL = {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Lumen", isDirectory: true)
        // Carry over data from before the app was renamed to Lumen.
        let legacy = base.appendingPathComponent("Stremio Native", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path), fileManager.fileExists(atPath: legacy.path) {
            try? fileManager.moveItem(at: legacy, to: dir)
        }
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        do {
            return try JSON.decoder.decode(type, from: data)
        } catch {
            Log.error("Failed to decode \(name): \(error)")
            return nil
        }
    }

    static func save<T: Encodable>(_ value: T, to name: String) {
        do {
            let data = try JSON.encoder.encode(value)
            let target = url(name)
            try data.write(to: target, options: [.atomic])
            // Profile data contains the auth key.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        } catch {
            Log.error("Failed to save \(name): \(error)")
        }
    }

    static func remove(_ name: String) {
        try? FileManager.default.removeItem(at: url(name))
    }
}

enum Log {
    static func info(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[Lumen] \(message())")
        #endif
    }

    static func error(_ message: @autoclosure () -> String) {
        print("[Lumen][error] \(message())")
    }
}
