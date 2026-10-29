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

    // MARK: Launch serialisation

    /// Bottles whose per-game fixes are being prepared right now
    /// (`AppState.run` -> `GameFixService.prepare`). Preparing can run
    /// winetricks for minutes, and a second launch into the same bottle
    /// during that time would start a second winetricks on the same
    /// prefix, which corrupts it. It is state on `AppState` rather than a
    /// local of `run` because `run` is a separate invocation per click;
    /// not `private` only because `run` lives in an extension in another
    /// file. Nothing observes it, hence `@ObservationIgnored`.
    @ObservationIgnored var preparingBottleIDs: Set<UUID> = []

    init() {}

    var selectedBottle: Bottle? {
        guard case .bottle(let id)? = selection else { return nil }
        return bottles.first { $0.id == id }
    }

    func engine(for bottle: Bottle) -> InstalledEngine? {
        installedEngines.first { $0.id == bottle.engineID }
    }

    func report(_ error: Error, context: String) {
        report("\(context): \(error.localizedDescription)")
    }

    /// Longest `errorMessage` that `report` builds up by appending. Past
    /// this the oldest messages are dropped (see `appendingReport`).
    nonisolated static let reportCharacterLimit = 600

    /// Adds `message` to the alert text rather than replacing it. The alert
    /// has a single slot, and several failures in quick succession (a
    /// launch that trips a game-fix failure and then an advisory, or an
    /// install error followed by a save error) used to leave the user
    /// seeing only whichever came last, with the cause often being the
    /// one that was overwritten. Messages stack separated by a blank line
    /// until the user dismisses the alert (which sets `errorMessage` back
    /// to nil).
    func report(_ message: String) {
        errorMessage = Self.appendingReport(message, to: errorMessage)
    }

    /// The pure rule behind `report(_:)`, split out so it can be checked
    /// without an `AppState`:
    ///   - nothing showing yet: just `message`;
    ///   - `message` is already in the text (the same failure repeated,
    ///     e.g. a click that retries and fails identically): unchanged, so
    ///     the alert doesn't fill up with copies;
    ///   - otherwise `message` goes on the end after a blank line, and if
    ///     the result is longer than `reportCharacterLimit`, the oldest
    ///     whole blank-line-separated messages are dropped until it fits.
    ///     The newest message is always kept in full even if it alone is
    ///     over the limit: cutting mid-sentence would lose the part that
    ///     says what to do.
    nonisolated static func appendingReport(_ message: String, to existing: String?) -> String {
        guard let existing, !existing.isEmpty else { return message }
        guard !existing.contains(message) else { return existing }

        var parts = existing.components(separatedBy: "\n\n") + [message]
        while parts.count > 1, parts.joined(separator: "\n\n").count > reportCharacterLimit {
            parts.removeFirst()
        }
        return parts.joined(separator: "\n\n")
    }

    /// True when Rosetta 2 is installed (its daemon `oahd` is registered).
    nonisolated static func rosettaInstalled() -> Bool {
        FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime")
            || FileManager.default.fileExists(atPath: "/Library/Apple/usr/share/rosetta")
    }
}
