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
    var createdAt: Date
    var lastUsed: Date?

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
