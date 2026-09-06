import Foundation

enum WindowsVersion: String, Codable, CaseIterable, Sendable, Identifiable {
    case win7, win10, win11
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .win7: return "Windows 7"
        case .win10: return "Windows 10"
        case .win11: return "Windows 11"
        }
    }
    /// Argument to `winecfg -v`.
    var winecfgValue: String { rawValue }
}

/// A Wine prefix plus the settings Overpass applies when launching into it.
/// Persisted as `metadata.json` inside `Paths.bottleDir(id)`.
struct Bottle: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    /// `InstalledEngine.id` this bottle runs on.
    var engineID: String
    var windowsVersion: WindowsVersion
    var esync: Bool
    var msync: Bool
    var metalHUD: Bool
    var verboseLog: Bool
    /// DXVK dlls installed into system32 (Wine-staging only).
    var dxvk: Bool
    /// Extra environment variables appended at launch.
    var env: [String: String]
    var pins: [PinnedProgram]
    /// Performance/graphics tuning (Performance tab). Optional so older
    /// metadata.json files decode; nil means "defaults".
    var performance: PerformanceSettings?
    var createdAt: Date
    var lastUsed: Date?
    /// `ProgramScanner.schemaVersion` this bottle's `pins` were last
    /// migrated against. `nil` (any `metadata.json` written before this
    /// property existed) always mismatches the current
    /// `ProgramScanner.schemaVersion`, so `ProgramsGridView` runs one
    /// migration scan the first time the Programs tab is shown for it —
    /// re-classifying every existing pin's `isSystem`/`isHelper` and
    /// collapsing any stale case/bitness duplicates a pre-migration
    /// scanner left behind (see `ProgramScanner.merge`). Optional (rather
    /// than defaulting to `0`) so it round-trips through Codable's
    /// synthesized `decodeIfPresent` without a custom decoder.
    var pinsSchemaVersion: Int?
    /// Lower-cased `PinnedProgram.exePath` values (see
    /// `ProgramScanner.dedupeKey`) the user has explicitly removed from
    /// `pins`. Consulted by every `ProgramScanner.merge(scanned:existing:
    /// excluding:)` call so a rescan/migration doesn't silently re-add a
    /// program the user asked to stop seeing; cleared for a given path by
    /// "Add program…" or by running that exe again. Optional for the same
    /// backward-compatibility reason as `pinsSchemaVersion`.
    var removedPinPaths: [String]?

    init(id: UUID = UUID(), name: String, engineID: String, windowsVersion: WindowsVersion = .win10) {
        self.id = id
        self.name = name
        self.engineID = engineID
        self.windowsVersion = windowsVersion
        self.esync = true
        self.msync = true
        self.metalHUD = false
        self.verboseLog = false
        self.dxvk = false
        self.env = [:]
        self.pins = []
        self.createdAt = Date()
        self.lastUsed = nil
    }

    /// The WINEPREFIX directory.
    var prefixDir: URL { Paths.bottleDir(id) }
    var driveC: URL { prefixDir.appendingPathComponent("drive_c", isDirectory: true) }
    var metadataURL: URL { prefixDir.appendingPathComponent("metadata.json") }
}
