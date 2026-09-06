import Foundation

/// Per-run log files: `Logs/<bottleID>/<yyyyMMdd-HHmmss>-<exe>.log`. Files
/// are written by `WineRunner` as a run streams; this type only creates
/// URLs and reads back what's already on disk.
enum LogStore {
    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static func bottleLogDir(_ bottleID: UUID) -> URL {
        Paths.logs.appendingPathComponent(bottleID.uuidString, isDirectory: true)
    }

    /// A fresh, not-yet-existing log path for a run of `exeName` in
    /// `bottleID`. Creates the bottle's log directory if needed.
    static func newLogURL(bottleID: UUID, exeName: String) -> URL {
        let dir = bottleLogDir(bottleID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let sanitized = exeName
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let safeName = sanitized.isEmpty ? "run" : sanitized
        let stamp = stampFormatter.string(from: Date())
        return dir.appendingPathComponent("\(stamp)-\(safeName).log")
    }

    /// Every `.log` file for a bottle, newest first.
    static func logs(for bottleID: UUID) -> [URL] {
        let dir = bottleLogDir(bottleID)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return entries
            .filter { $0.pathExtension.lowercased() == "log" }
            .sorted { lhs, rhs in
                let lDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lDate > rDate
            }
    }

    /// The last `maxBytes` of a log file, decoded as UTF-8 (lossily, so a
    /// truncated multibyte sequence at the start doesn't throw the whole
    /// tail away).
    static func tail(_ url: URL, maxBytes: Int = 200_000) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return "" }

        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        do {
            try handle.seek(toOffset: offset)
        } catch {
            return ""
        }
        let data = (try? handle.readToEnd()) ?? Data()
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(decoding: data, as: UTF8.self)
    }
}
