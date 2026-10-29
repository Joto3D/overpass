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
    ///
    /// Returns the bottle it created, or `nil` when creation failed (in
    /// which case the real error has already gone through `report`, so a
    /// caller that just wants to stop should simply return without
    /// reporting again). Callers that need the new bottle must use this
    /// return value rather than hunting for it afterwards by name or via
    /// `selection`: a same-named bottle left behind by an earlier attempt
    /// would be found instead, and the caller would silently carry on
    /// using a different, possibly half-configured prefix.
    @discardableResult
    func createBottle(name: String, engineID: String, windowsVersion: WindowsVersion) async -> Bottle? {
        guard let engine = installedEngines.first(where: { $0.id == engineID }) else {
            report("No installed engine to create the bottle with.")
            return nil
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
            return bottle
        } catch {
            bottleCreationStatus[bottle.id] = nil
            try? FileManager.default.removeItem(at: bottle.prefixDir)
            report(error, context: "Creating bottle \"\(name)\"")
            return nil
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

        // A pin can outlive its file (the program was uninstalled, or the
        // folder moved), and Wine's `start /unix` on a missing path just
        // exits non-zero with nothing on screen, so the click looked dead.
        // Say so up front instead.
        guard FileManager.default.fileExists(atPath: exe.path) else {
            report("\(exe.lastPathComponent) isn't there any more (\(exe.path)). It may have been uninstalled or moved. Rescan programs for this bottle to refresh the list.")
            return
        }

        // One fix preparation per bottle at a time. `prepare` can run
        // winetricks for minutes, and clicking Launch again used to start
        // a second winetricks on the same prefix, concurrently. Re-entry is
        // ignored rather than queued or alerted: the first launch is
        // already doing the work and will start its program when done, and
        // a double-click should not raise an alert about itself. Cleared
        // right after `prepare` returns (not at the end of `run`) so that
        // once the bottle is ready, other launches into it are unaffected.
        guard !preparingBottleIDs.contains(bottle.id) else { return }
        preparingBottleIDs.insert(bottle.id)

        let logURL = LogStore.newLogURL(bottleID: bottle.id, exeName: exe.lastPathComponent)

        // Per-game fixes (`GameFixCatalog`). Normally a no-op that returns
        // `bottle` untouched. When a fix matches, its slow bottle changes
        // (winetricks etc.) run here, once per bottle, before the program
        // starts. `progress` carries every winetricks output line, far
        // too chatty for `report` (a single-slot alert), so it only goes
        // to the log; failures come back in `prepared.failures` and are
        // reported once, together with the advisories, below. A failed fix
        // never blocks the launch — see `GameFixService`.
        let prepared = await GameFixService.prepare(exe: exe, bottle: bottle, engine: engine) { line in
            // Every line lands in this run's own log, so a first-run
            // winetricks install is inspectable rather than a silent
            // multi-minute freeze before the program appears.
            WineRunner.appendLogLine(line, to: logURL)
        }
        preparingBottleIDs.remove(bottle.id)
        // `prepared.bottle` is the persistable one: it may carry new
        // `appliedFixes`, which must survive into the `updateBottle`
        // below rather than being overwritten by the caller's older copy.
        let fixedBottle = prepared.bottle

        // Launch-local copy with the fixes' env merged over the bottle's
        // own (fix wins). Passed to `WineRunner.launch` only — never to
        // `updateBottle` — so per-launch fix env is not persisted into
        // metadata.json and disappears when the fix does.
        var launchBottle = fixedBottle
        for (key, value) in prepared.env { launchBottle.env[key] = value }

        // Fix launch args follow the caller's own.
        var launchArgs = args
        if let extra = prepared.args {
            launchArgs = launchArgs.isEmpty ? extra : launchArgs + " " + extra
        }

        // Advisories: compatibility facts no bottle setting can change.
        // All of them go to the run log; the ones that change whether it
        // is worth launching at all also raise the alert, so the user
        // learns *before* staring at a window that never appears. `.info`
        // (usually "a native Mac build exists") stays in the log — it is
        // worth recording, not worth interrupting for.
        //
        // Everything that should interrupt (fix failures, those advisories,
        // and a one-time note about unreadable user fix files) is gathered
        // into `notices` and reported ONCE after the loop. The alert is a
        // single slot, so separate `report` calls per item left the user
        // seeing only the last one.
        var notices = prepared.failures
        for resolved in prepared.advisories {
            // `AlternativeApp.message` adds one sentence when the advisory
            // names an app that can run the program, and returns the
            // message unchanged when it does not.
            let line = "\(resolved.fixName): \(AlternativeApp.message(for: resolved.advisory))"
            WineRunner.appendLogLine(line, to: logURL)
            switch resolved.advisory.severity {
            case .wontRun, .degraded: notices.append(line)
            case .info: break
            }
        }
        if let brokenFixFiles = GameFixCatalog.takeUserFixFailureNotice() {
            WineRunner.appendLogLine(brokenFixFiles, to: logURL)
            notices.append(brokenFixFiles)
        }
        if !notices.isEmpty { report(notices.joined(separator: "\n")) }

        do {
            let launchedAt = Date()
            let process = try WineRunner.launch(exe: exe, args: launchArgs, bottle: launchBottle, engine: engine, logURL: logURL)

            let record = RunRecord(bottleID: bottle.id, exePath: exe.path, logURL: logURL, pid: process.processIdentifier)
            runs.append(record)

            var updated = ensuringPin(for: exe, in: fixedBottle)
            updated.lastUsed = Date()
            updateBottle(updated)

            let recordID = record.id
            Task.detached { [weak self] in
                process.waitUntilExit()

                // Normally this launcher process exits within a second or
                // two even though the program lives on (see below), so its
                // exit status is not "how the program ended" and a non-zero
                // value alone means nothing. But a launcher that fails
                // *and* disappears almost immediately means Wine couldn't
                // start the program at all (bad path, missing runtime,
                // crash on load), which used to look exactly like a click
                // that did nothing. 10 seconds separates that from a
                // program that ran and was then closed or crashed on its
                // own, which isn't ours to second-guess here.
                let status = process.terminationStatus
                if status != 0, Date().timeIntervalSince(launchedAt) < 10, let appState = self {
                    let name = exe.lastPathComponent
                    await MainActor.run {
                        appState.report("\(name) closed right after starting (exit status \(status)). Open the Logs tab and read the newest log for \(name) to see why.")
                    }
                }

                // The process we're watching is `wine ... start /unix
                // <exe>` — Wine's launcher hands the real Windows process
                // off to wineserver and exits almost immediately, well
                // before that process actually finishes. Waiting on it
                // alone flips `isRunning` off (and the Stop button back to
                // disabled) within a second or two of every launch, no
                // matter how long the program itself keeps running.
                //
                // A previous version of this polled `lsof +D <prefix>`
                // every 1.5s to see whether anything was still alive under
                // the bottle's prefix. Measured against the "Steam" bottle
                // (a full Steam client install, ~2GB / ~9.6k files under
                // its prefix — the worst case on this machine): ~0.12s real
                // time and ~0.12s combined user+sys CPU per invocation
                // (`/usr/sbin/lsof +D <prefix>`, 5-run average). That's
                // roughly 8% of a CPU core spent purely on bookkeeping for
                // the entire time any program is running in that bottle —
                // real, avoidable cost for something with a much cheaper
                // event-driven answer.
                //
                // `wineserver -w` waits until the wineserver instance
                // servicing this exact `WINEPREFIX` has no clients left and
                // exits — i.e. "nothing is running in this bottle anymore"
                // — with zero polling: it blocks on the server's own exit
                // notification and returns instantly if the prefix is
                // already idle (measured: ~0.02s against the same Steam
                // prefix with nothing running in it).
                _ = try? await ProcessRunner.run(
                    engine.wineserverBinary,
                    ["-w"],
                    environment: WineRunner.environment(for: bottle, engine: engine)
                )
                guard let self else { return }
                await MainActor.run {
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
