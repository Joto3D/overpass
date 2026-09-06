import Foundation
import Observation
import SwiftUI

/// Root observable state. Services live in `Services/` and are reached via
/// `extension AppState` in their own files (EngineManager+AppState,
/// BottleStore+AppState, ...) so features can be developed independently.
@MainActor
@Observable
final class AppState {
    // MARK: Engines
    var installedEngines: [InstalledEngine] = []
    /// Engine id → 0...1 download/extract progress while installing.
    var engineInstallProgress: [String: Double] = [:]
    /// Engine id → human-readable status line while installing.
    var engineInstallStatus: [String: String] = [:]

    // MARK: Bottles
    var bottles: [Bottle] = []
    var selectedBottleID: UUID?
    /// Bottle id → progress text while a bottle is being created.
    var bottleCreationStatus: [UUID: String] = [:]

    // MARK: Runs
    var runs: [RunRecord] = []

    // MARK: Navigation
    enum SidebarItem: Hashable {
        case bottle(UUID)
        case installApps
        case engines
        case settings
    }
    var selection: SidebarItem? = nil

    // MARK: Errors / first run
    var errorMessage: String?
    var showSetupWizard = false

    /// Files handed to us by Finder/drag-drop that still need a bottle picked.
    var pendingOpenFiles: [URL] = []

    init() {}

    var selectedBottle: Bottle? {
        guard case .bottle(let id)? = selection else { return nil }
        return bottles.first { $0.id == id }
    }

    func engine(for bottle: Bottle) -> InstalledEngine? {
        installedEngines.first { $0.id == bottle.engineID }
    }

    func report(_ error: Error, context: String) {
        errorMessage = "\(context): \(error.localizedDescription)"
    }

    func report(_ message: String) {
        errorMessage = message
    }

    /// True when Rosetta 2 is installed (its daemon `oahd` is registered).
    nonisolated static func rosettaInstalled() -> Bool {
        FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime")
            || FileManager.default.fileExists(atPath: "/Library/Apple/usr/share/rosetta")
    }
}
