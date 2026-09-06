import Foundation

/// Wires `EngineManager` into `AppState` — the pattern every feature in
/// this app follows so screens can be built against `AppState` alone
/// without reaching into `Services/` directly. Lives in its own file per
/// `PLAN.md` so bottles/programs/etc. can add their own `AppState`
/// extensions without touching this one.
extension AppState {
    /// Refreshes `installedEngines` from disk (each engine folder's
    /// `installed.json`). Cheap, but still hops through the engine actor,
    /// so it's fired off as a detached-from-the-caller `Task` — call this
    /// from `.task { }`/`onAppear` without `await`.
    func loadEngines() {
        Task {
            let engines = await EngineManager.shared.installedEngines()
            self.installedEngines = engines
        }
    }

    /// True while `release`'s (or any installed engine's, by id) install
    /// is in flight — drives the progress bar / disables the Install
    /// button in `EnginesView`.
    func isInstalling(_ id: String) -> Bool {
        engineInstallProgress[id] != nil
    }

    /// Downloads, verifies, and extracts `release`, updating
    /// `engineInstallProgress`/`engineInstallStatus` as it goes and
    /// appending the result to `installedEngines` on success. Errors are
    /// routed through `report(_:context:)` rather than thrown, since this
    /// is meant to be called straight from a button action.
    func installEngine(_ release: EngineRelease) async {
        guard !isInstalling(release.id) else { return }

        engineInstallProgress[release.id] = 0
        engineInstallStatus[release.id] = "Starting…"

        do {
            let installed = try await EngineManager.shared.install(release) { [weak self] fraction, status in
                Task { @MainActor in
                    guard let self else { return }
                    self.engineInstallProgress[release.id] = fraction
                    self.engineInstallStatus[release.id] = status
                }
            }
            installedEngines.removeAll { $0.id == installed.id }
            installedEngines.append(installed)
            installedEngines.sort { $0.id < $1.id }
        } catch {
            report(error, context: "Installing \(release.displayName)")
        }

        engineInstallProgress[release.id] = nil
        engineInstallStatus[release.id] = nil
    }

    /// Moves an installed engine's folder to the Trash and drops it from
    /// `installedEngines`. Any bottle still configured to use it will
    /// simply fail to launch until repointed at another engine — v1 does
    /// not block removal or migrate bottles automatically.
    func removeEngine(_ id: String) async {
        do {
            try await EngineManager.shared.remove(id)
            installedEngines.removeAll { $0.id == id }
        } catch {
            report(error, context: "Removing engine")
        }
    }
}
