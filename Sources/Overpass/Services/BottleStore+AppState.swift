import Foundation
import AppKit

/// Bottle lifecycle and run/stop/tool actions on `AppState`. Mirrors the
/// shape of `EngineManager+AppState.swift`: `AppState` itself only holds
/// state (`bottles`, `runs`, `bottleCreationStatus`, ...); the actual
/// filesystem/process work lives in `BottleStore`/`WineRunner` and is
/// wired up here. Every failure is routed through `report(_:context:)` —
/// nothing fails silently.
extension AppState {
    // MARK: - Loading

    func loadBottles() {
        bottles = BottleStore.loadAll()
    }

    // MARK: - Create

    /// Creates a new bottle: makes its prefix folder, runs `wineboot -i`
    /// then `winecfg -v <version>` (progress surfaced via
    /// `bottleCreationStatus`), writes `metadata.json`, and selects it. On
    /// any failure the partial folder is removed and the error reported.
    func createBottle(name: String, engineID: String, windowsVersion: WindowsVersion) async {
        guard let engine = installedEngines.first(where: { $0.id == engineID }) else {
            report("No installed engine to create the bottle with.")
            return
        }

        let bottle = Bottle(name: name, engineID: engineID, windowsVersion: windowsVersion)
        bottleCreationStatus[bottle.id] = "Creating bottle…"

        do {
            try FileManager.default.createDirectory(at: bottle.prefixDir, withIntermediateDirectories: true)

            try await WineRunner.createPrefix(bottle: bottle, engine: engine) { [weak self] message in
                Task { @MainActor in
                    self?.bottleCreationStatus[bottle.id] = message
                }
            }

            try BottleStore.save(bottle)
            bottles.append(bottle)
            bottles.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            bottleCreationStatus[bottle.id] = nil
            selection = .bottle(bottle.id)
        } catch {
            bottleCreationStatus[bottle.id] = nil
            try? FileManager.default.removeItem(at: bottle.prefixDir)
            report(error, context: "Creating bottle \"\(name)\"")
        }
    }

    // MARK: - Delete

    /// Stops everything running in the bottle, then moves its prefix to
    /// the Trash and deselects it.
    func deleteBottle(_ bottle: Bottle) async {
        if let engine = engine(for: bottle) {
            await WineRunner.stop(bottle: bottle, engine: engine)
        }
        for index in runs.indices where runs[index].bottleID == bottle.id {
            runs[index].isRunning = false
        }

        do {
            try BottleStore.delete(bottle)
            bottles.removeAll { $0.id == bottle.id }
            bottleCreationStatus[bottle.id] = nil
            if selection == .bottle(bottle.id) {
                selection = nil
            }
        } catch {
            report(error, context: "Deleting bottle \"\(bottle.name)\"")
        }
    }

    // MARK: - Update

    /// Persists `bottle` and replaces it in `bottles`.
    func updateBottle(_ bottle: Bottle) {
        do {
            try BottleStore.save(bottle)
            if let index = bottles.firstIndex(where: { $0.id == bottle.id }) {
                bottles[index] = bottle
            }
        } catch {
            report(error, context: "Saving bottle \"\(bottle.name)\"")
        }
    }

    // MARK: - Run

    /// Launches `exe` (or `.msi`) inside `bottle`: allocates a fresh log
    /// file, starts the Wine process, records a `RunRecord`, bumps
    /// `lastUsed`, and watches for termination on a detached task so
    /// `RunRecord.isRunning` flips without blocking the main actor.
    func run(exe: URL, args: String = "", in bottle: Bottle) async {
        guard let engine = engine(for: bottle) else {
            report("No engine installed for bottle \"\(bottle.name)\".")
            return
        }

        let logURL = LogStore.newLogURL(bottleID: bottle.id, exeName: exe.lastPathComponent)
        do {
            let process = try WineRunner.launch(exe: exe, args: args, bottle: bottle, engine: engine, logURL: logURL)

            let record = RunRecord(bottleID: bottle.id, exePath: exe.path, logURL: logURL, pid: process.processIdentifier)
            runs.append(record)

            var updated = ensuringPin(for: exe, in: bottle)
            updated.lastUsed = Date()
            updateBottle(updated)

            let recordID = record.id
            let prefixPath = bottle.prefixDir.path
            Task.detached { [weak self] in
                process.waitUntilExit()
                // The process we're watching is `wine ... start /unix
                // <exe>` — Wine's launcher hands the real Windows process
                // off to wineserver and exits almost immediately, well
                // before that process actually finishes. Waiting on it
                // alone flips `isRunning` off (and the Stop button back to
                // disabled) within a second or two of every launch, no
                // matter how long the program itself keeps running. Keep
                // polling for any process still alive under this bottle's
                // prefix before declaring the run over.
                //
                // `pgrep -f <prefix>` (what `WineRunner.stop` uses to
                // decide whether to escalate) can't be reused here: none of
                // the wine64-preloader children actually carry the prefix
                // path in their argv, so it never matches. `lsof +D
                // <prefix>` instead lists every process with an open file
                // (cwd, loaded dll, the exe itself, ...) anywhere under the
                // prefix, which every process in the bottle always has.
                while true {
                    guard let result = try? await ShellRunner.run("/usr/sbin/lsof", ["+D", prefixPath]),
                          !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { break }
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }
                await MainActor.run {
                    guard let self else { return }
                    if let index = self.runs.firstIndex(where: { $0.id == recordID }) {
                        self.runs[index].isRunning = false
                    }
                }
            }
        } catch {
            report(error, context: "Running \(exe.lastPathComponent)")
        }
    }

    /// Stops every process in `bottle` and marks its runs no longer
    /// running.
    func stopAll(in bottle: Bottle) async {
        guard let engine = engine(for: bottle) else { return }
        await WineRunner.stop(bottle: bottle, engine: engine)
        for index in runs.indices where runs[index].bottleID == bottle.id {
            runs[index].isRunning = false
        }
    }

    // MARK: - Built-in tools

    /// Launches a bundled Wine tool by name (`winecfg`, `regedit`,
    /// `explorer`, `taskmgr`) detached, logging to its own file.
    func runTool(name: String, in bottle: Bottle) {
        guard let engine = engine(for: bottle) else {
            report("No engine installed for bottle \"\(bottle.name)\".")
            return
        }
        let logURL = LogStore.newLogURL(bottleID: bottle.id, exeName: name)
        do {
            _ = try WineRunner.launchTool(name: name, bottle: bottle, engine: engine, logURL: logURL)
        } catch {
            report(error, context: "Launching \(name)")
        }
    }

    /// Reveals the bottle's `drive_c` in Finder.
    func openDriveC(_ bottle: Bottle) {
        NSWorkspace.shared.open(bottle.driveC)
    }

    // MARK: - Pin on run

    /// Ensures `exe` has a pin in `bottle.pins`, so anything ever launched
    /// through Overpass — Run .exe…, a drag-and-drop, Finder "Open With",
    /// or the bottle picker — can always be re-launched from the Programs
    /// list afterward without browsing to it again. Also un-removes it
    /// from `Bottle.removedPinPaths` if the user had previously removed
    /// that pin (running it again is treated as "I do want this back").
    ///
    /// Matching against an existing pin (and against `removedPinPaths`) is
    /// done via `ProgramScanner.dedupeKey` rather than a raw string
    /// compare, so running a program a second time — even by a
    /// differently-cased path, or via its Program Files (x86) copy — never
    /// creates a duplicate pin. A brand-new pin's `isUserAdded` is false
    /// when `exe` lives inside the bottle's own `drive_c` (it behaves like
    /// anything `ProgramScanner.scan` would have found, so a later rescan
    /// can freely reclassify it) and true otherwise (an external file the
    /// scanner would never discover on its own).
    ///
    /// Pure — returns the updated `Bottle` rather than persisting it, so
    /// callers can fold this into a single `updateBottle` alongside their
    /// own changes (e.g. bumping `lastUsed`).
    func ensuringPin(for exe: URL, in bottle: Bottle) -> Bottle {
        var updated = bottle
        let key = ProgramScanner.dedupeKey(exe.path)

        if let removed = updated.removedPinPaths, !removed.isEmpty {
            let filtered = removed.filter { ProgramScanner.dedupeKey($0) != key }
            if filtered.count != removed.count {
                updated.removedPinPaths = filtered
            }
        }

        guard !updated.pins.contains(where: { ProgramScanner.dedupeKey($0.exePath) == key }) else {
            return updated
        }

        let insideDriveC = exe.path.lowercased().hasPrefix(bottle.driveC.path.lowercased())
        let baseName = exe.deletingPathExtension().lastPathComponent
        var pin = PinnedProgram(
            name: ProgramScanner.derivedPinName(fromBaseName: baseName),
            exePath: exe.path,
            isUserAdded: !insideDriveC
        )
        pin = ProgramScanner.applyCatalogDefaults(to: pin)
        updated.pins.append(pin)
        return updated
    }
}
