import Foundation
import Observation

/// Live progress for whatever `BottleImporter.importPrefix` call is
/// currently running. A single shared instance — there's only ever one
/// import in flight at a time — kept separate from `AppState` (like
/// `AppInstallState`) since a bottle's id doesn't exist yet when the
/// import starts, so there's nothing to key `AppState.bottleCreationStatus`
/// by until the very end.
@MainActor
@Observable
final class BottleImportState {
    static let shared = BottleImportState()

    var isImporting = false
    var status: String = ""
    var lastError: String?

    private init() {}

    fileprivate func begin() {
        isImporting = true
        status = "Starting…"
        lastError = nil
    }

    fileprivate func set(_ newStatus: String) {
        status = newStatus
    }

    fileprivate func finish(error: String?) {
        isImporting = false
        lastError = error
    }
}

/// UI entry point for importing a foreign Wine prefix as a new Overpass
/// bottle. Mirrors `AppInstaller.install(_:into:engine:appState:)`: the
/// actual copy/adopt/scan logic lives in `BottleImporter.importPrefix`
/// (no `AppState` dependency), this just drives it, publishes progress
/// through `BottleImportState.shared`, and wires the result into
/// `AppState` on success.
extension AppState {
    /// Imports `source` as a new bottle named `name` running on
    /// `engineID`, appends it to `bottles`, and selects it. Failures are
    /// routed through `report(_:context:)` — nothing fails silently — and
    /// also recorded on `BottleImportState.shared.lastError` for the sheet.
    func importBottle(from source: BottleImporter.Source, name: String, engineID: String, windowsVersion: WindowsVersion) async {
        let state = BottleImportState.shared
        state.begin()

        do {
            let bottle = try await BottleImporter.importPrefix(
                source, as: name, engineID: engineID, windowsVersion: windowsVersion, copy: true
            ) { message in
                Task { @MainActor in state.set(message) }
            }

            bottles.append(bottle)
            bottles.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            selection = .bottle(bottle.id)
            state.finish(error: nil)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            state.finish(error: message)
            report(error, context: "Importing bottle \"\(name)\"")
        }
    }
}
