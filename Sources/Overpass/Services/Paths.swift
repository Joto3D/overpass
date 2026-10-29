import Foundation

/// Every on-disk location Overpass owns. All under
/// `~/Library/Application Support/Overpass/`.
enum Paths {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Overpass", isDirectory: true)
    }()

    /// Installed Wine engines, one folder per `EngineRelease.id`.
    static let engines = root.appendingPathComponent("Engines", isDirectory: true)
    /// Bottles (WINEPREFIX dirs), one folder per `Bottle.id`.
    static let bottles = root.appendingPathComponent("Bottles", isDirectory: true)
    /// Per-run logs: Logs/<bottleID>/<timestamp>-<exe>.log
    static let logs = root.appendingPathComponent("Logs", isDirectory: true)
    /// Helper downloads: winetricks script, DXVK zips, engine tarballs.
    static let tools = root.appendingPathComponent("Tools", isDirectory: true)
    static let downloads = tools.appendingPathComponent("downloads", isDirectory: true)
    /// User-supplied `GameFix` JSON files (one fix or an array per file),
    /// merged over the built-in fixes by `GameFixCatalog`. Never written
    /// by Overpass itself — it only reads whatever the user drops here.
    static let fixes = root.appendingPathComponent("Fixes", isDirectory: true)

    /// Creates every directory above if missing. Safe to call repeatedly.
    static func ensureAll() throws {
        for dir in [root, engines, bottles, logs, tools, downloads, fixes] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    static func bottleDir(_ id: UUID) -> URL {
        bottles.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func engineDir(_ id: String) -> URL {
        engines.appendingPathComponent(id, isDirectory: true)
    }
}
