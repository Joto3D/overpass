import Foundation

/// Which family of Wine build an engine is. Drives default toggles and
/// which extras (DXVK) make sense.
enum EngineKind: String, Codable, CaseIterable, Sendable {
    /// Apple Game Porting Toolkit (Gcenx build): Wine + D3DMetal.
    case gptk
    /// Upstream Wine-staging (Gcenx build). DirectX via DXVK-macOS.
    case wineStaging

    var displayName: String {
        switch self {
        case .gptk: return "Game Porting Toolkit"
        case .wineStaging: return "Wine Staging"
        }
    }

    /// DXVK only makes sense on plain Wine; GPTK brings D3DMetal.
    var supportsDXVK: Bool { self == .wineStaging }
}

/// A downloadable engine, as listed in `EngineCatalog`.
struct EngineRelease: Identifiable, Codable, Hashable, Sendable {
    let id: String            // e.g. "gptk-3.0-3"
    let kind: EngineKind
    let version: String       // e.g. "3.0-3"
    let url: URL
    /// Lower-case hex SHA-256 of the tarball. Empty string = unverified.
    let sha256: String
    let notes: String

    var displayName: String { "\(kind.displayName) \(version)" }
}

/// An engine that has been downloaded and extracted under `Paths.engines`.
/// Persisted as `installed.json` inside its folder by `EngineManager`.
struct InstalledEngine: Identifiable, Codable, Hashable, Sendable {
    let id: String            // == EngineRelease.id
    let kind: EngineKind
    let version: String
    /// Folder under Paths.engines that holds bin/ and lib/.
    let rootDir: URL
    /// Directory containing `wine64` (or `wine`), `wineserver`, `wineboot`...
    let binDir: URL
    /// Directory containing `wine/` and, for GPTK, `external/`.
    let libDir: URL
    /// Output of `wine64 --version`, captured at install time.
    let versionString: String
    let installedAt: Date

    var displayName: String { "\(kind.displayName) \(version)" }

    /// Path of the main wine loader binary. Prefers `wine64`.
    var wineBinary: URL {
        let w64 = binDir.appendingPathComponent("wine64")
        if FileManager.default.isExecutableFile(atPath: w64.path) { return w64 }
        return binDir.appendingPathComponent("wine")
    }
    var wineserverBinary: URL { binDir.appendingPathComponent("wineserver") }
    var winebootBinary: URL { binDir.appendingPathComponent("wineboot") }
    var winecfgBinary: URL { binDir.appendingPathComponent("winecfg") }
}
