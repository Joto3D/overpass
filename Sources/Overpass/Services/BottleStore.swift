import Foundation

/// Reads/writes `metadata.json` inside each bottle's prefix folder under
/// `Paths.bottles`. Pure filesystem + JSON — no process work, no `AppState`
/// coupling (that lives in `BottleStore+AppState.swift`).
enum BottleStore {
    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    /// Every bottle with a readable `metadata.json` under `Paths.bottles`,
    /// sorted by name. Folders with missing/corrupt metadata (a create that
    /// crashed mid-way, for example) are silently skipped.
    static func loadAll() -> [Bottle] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: Paths.bottles, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let decoder = makeDecoder()
        var bottles: [Bottle] = []
        for entry in entries {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let metadataURL = entry.appendingPathComponent("metadata.json")
            guard let data = try? Data(contentsOf: metadataURL),
                  let bottle = try? decoder.decode(Bottle.self, from: data) else { continue }
            bottles.append(bottle)
        }
        return bottles.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Writes `bottle`'s `metadata.json`, creating its prefix folder first
    /// if needed.
    static func save(_ bottle: Bottle) throws {
        try FileManager.default.createDirectory(at: bottle.prefixDir, withIntermediateDirectories: true)
        let data = try makeEncoder().encode(bottle)
        try data.write(to: bottle.metadataURL, options: .atomic)
    }

    /// Moves the bottle's prefix folder to the Trash.
    static func delete(_ bottle: Bottle) throws {
        try FileManager.default.trashItem(at: bottle.prefixDir, resultingItemURL: nil)
    }
}
