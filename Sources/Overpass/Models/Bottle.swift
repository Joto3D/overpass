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
    /// Apple D3DMetal (DirectX 11/12 → Metal) layered onto a Wine-staging
    /// bottle via `D3DMetalOverlay`, the same overlay technique CrossOver
    /// 26.3 uses on its own modern-Wine base. Meaningless (and left
    /// permanently `false`) for a GPTK bottle, since GPTK already includes
    /// D3DMetal natively — see `D3DMetalOverlay`'s doc comment. Defaults to
    /// `false` and decodes via `decodeIfPresent` so `metadata.json` files
    /// written before this field existed still load.
    var d3dMetalOverlay: Bool

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
        self.d3dMetalOverlay = false
    }

    /// The WINEPREFIX directory.
    var prefixDir: URL { Paths.bottleDir(id) }
    var driveC: URL { prefixDir.appendingPathComponent("drive_c", isDirectory: true) }
    var metadataURL: URL { prefixDir.appendingPathComponent("metadata.json") }

    // MARK: - Codable
    //
    // Custom, rather than synthesized, purely so `d3dMetalOverlay` (a
    // non-Optional `Bool` added after this type shipped) can default to
    // `false` when absent instead of failing to decode — the same
    // "extend a struct without breaking `metadata.json` on disk" concern
    // `pinsSchemaVersion`/`removedPinPaths`/`performance` solve by being
    // `Optional`. `d3dMetalOverlay` is kept non-Optional (per its own
    // doc comment) because every call site wants a plain `Bool`, not
    // `Bool?`, so the default is applied here instead.
    private enum CodingKeys: String, CodingKey {
        case id, name, engineID, windowsVersion, esync, msync, metalHUD, verboseLog, dxvk
        case env, pins, performance, createdAt, lastUsed, pinsSchemaVersion, removedPinPaths
        case d3dMetalOverlay
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        engineID = try c.decode(String.self, forKey: .engineID)
        windowsVersion = try c.decode(WindowsVersion.self, forKey: .windowsVersion)
        esync = try c.decode(Bool.self, forKey: .esync)
        msync = try c.decode(Bool.self, forKey: .msync)
        metalHUD = try c.decode(Bool.self, forKey: .metalHUD)
        verboseLog = try c.decode(Bool.self, forKey: .verboseLog)
        dxvk = try c.decode(Bool.self, forKey: .dxvk)
        env = try c.decode([String: String].self, forKey: .env)
        pins = try c.decode([PinnedProgram].self, forKey: .pins)
        performance = try c.decodeIfPresent(PerformanceSettings.self, forKey: .performance)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        lastUsed = try c.decodeIfPresent(Date.self, forKey: .lastUsed)
        pinsSchemaVersion = try c.decodeIfPresent(Int.self, forKey: .pinsSchemaVersion)
        removedPinPaths = try c.decodeIfPresent([String].self, forKey: .removedPinPaths)
        d3dMetalOverlay = try c.decodeIfPresent(Bool.self, forKey: .d3dMetalOverlay) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(engineID, forKey: .engineID)
        try c.encode(windowsVersion, forKey: .windowsVersion)
        try c.encode(esync, forKey: .esync)
        try c.encode(msync, forKey: .msync)
        try c.encode(metalHUD, forKey: .metalHUD)
        try c.encode(verboseLog, forKey: .verboseLog)
        try c.encode(dxvk, forKey: .dxvk)
        try c.encode(env, forKey: .env)
        try c.encode(pins, forKey: .pins)
        try c.encodeIfPresent(performance, forKey: .performance)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(lastUsed, forKey: .lastUsed)
        try c.encodeIfPresent(pinsSchemaVersion, forKey: .pinsSchemaVersion)
        try c.encodeIfPresent(removedPinPaths, forKey: .removedPinPaths)
        try c.encode(d3dMetalOverlay, forKey: .d3dMetalOverlay)
    }
}
