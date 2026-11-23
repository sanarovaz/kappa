import Foundation
import AppKit

/// Log de diagnóstico: escribe `debug.log` junto a Kappa.app.
enum DebugLog {
    static var counters: [String: Int] = [:]
    static var snapshots = 0
    /// Fuentes extra de diagnóstico (se llaman en el hilo principal).
    static var providers: [@MainActor () -> String] = []

    static let url: URL = Bundle.main.bundleURL
        .deletingLastPathComponent()
        .appendingPathComponent("debug.log")

    static func bump(_ key: String) { counters[key, default: 0] += 1 }

    static func reset() {
        try? "".write(to: url, atomically: true, encoding: .utf8)
    }

    static func write(_ text: String) {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if size > 300_000 { return }
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(text)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
