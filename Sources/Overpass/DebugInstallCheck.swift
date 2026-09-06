import Foundation

/// Headless smoke test: `Overpass --check-install <catalog-app-id>
/// [--bottle <name>]` (see `DebugCheck.swift` for the pattern this
/// follows). Resolves the catalog app, an installed engine, and a bottle
/// (by name if `--bottle` is given, else the first bottle whose engine is
/// installed), then drives the exact same install path the UI uses
/// (`AppInstaller.run`) — no `AppState`/SwiftUI involved. Prints every
/// phase/progress/output line as `AppInstallState.shared` changes, prints
/// the resulting pins, and exits non-zero on the first failure. Runs
/// before any UI is created.
enum DebugInstallCheck {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let idx = args.firstIndex(of: "--check-install") else { return }
        guard idx + 1 < args.count, !args[idx + 1].hasPrefix("--") else {
            print("CHECK-INSTALL FAILED: --check-install needs a catalog app id, e.g. --check-install 7zip")
            exit(1)
        }
        let appID = args[idx + 1]

        var bottleName: String?
        if let bottleIdx = args.firstIndex(of: "--bottle"), bottleIdx + 1 < args.count {
            bottleName = args[bottleIdx + 1]
        }

        // NOTE: this can't use DebugCheck's `DispatchSemaphore` + blocking
        // `.wait()` pattern — that works there only because none of its
        // code is `@MainActor`. `AppInstaller.run`/`AppInstallState` (like
        // the rest of the UI-facing install path) *are* `@MainActor`, and
        // `@MainActor`'s executor is the main dispatch queue: blocking the
        // main thread synchronously on a semaphore means that queue is
        // never pumped, so any `@MainActor` hop inside `run()` (including
        // its very first `state.begin(...)`) would deadlock forever.
        // Instead, spin the main run loop — which does service the main
        // dispatch queue — until an unstructured `@MainActor` task signals
        // completion via `finished`.
        nonisolated(unsafe) var exitCode: Int32 = 0
        nonisolated(unsafe) var finished = false
        Task { @MainActor in
            do {
                try await run(appID: appID, bottleName: bottleName)
                print("CHECK-INSTALL OK")
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                print("CHECK-INSTALL FAILED: \(message)")
                exitCode = 1
            }
            finished = true
        }
        while !finished {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        exit(exitCode)
    }

    private static func log(_ s: String) { print("[check-install] \(s)"); fflush(stdout) }

    private static func run(appID: String, bottleName: String?) async throws {
        try Paths.ensureAll()

        guard let app = AppCatalog.apps.first(where: { $0.id == appID }) else {
            let known = AppCatalog.apps.map(\.id).sorted().joined(separator: ", ")
            throw NSError(domain: "check-install", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "unknown catalog app id \"\(appID)\". Known ids: \(known)",
            ])
        }
        log("app: \(app.name) (\(app.id))")

        // 1. Bottle — named, if given, else the first bottle whose engine
        //    is actually installed (matches how the UI's bottle picker
        //    defaults to `appState.bottles.first`).
        let bottles = BottleStore.loadAll()
        guard !bottles.isEmpty else {
            throw NSError(domain: "check-install", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "no bottles found under \(Paths.bottles.path) — create one first.",
            ])
        }

        let bottle: Bottle
        if let bottleName {
            guard let match = bottles.first(where: { $0.name.caseInsensitiveCompare(bottleName) == .orderedSame }) else {
                let known = bottles.map(\.name).joined(separator: ", ")
                throw NSError(domain: "check-install", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "no bottle named \"\(bottleName)\". Known bottles: \(known)",
                ])
            }
            bottle = match
        } else {
            bottle = bottles[0]
        }
        log("bottle: \(bottle.name) (\(bottle.id)) at \(bottle.prefixDir.path)")

        // 2. Engine — whatever engine the bottle is actually configured
        //    for (same lookup `AppState.engine(for:)` does), not
        //    `app.preferredEngine` — an install always runs on the target
        //    bottle's own engine.
        let engines = await EngineManager.shared.installedEngines()
        guard let engine = engines.first(where: { $0.id == bottle.engineID }) else {
            let known = engines.map(\.id).joined(separator: ", ")
            throw NSError(domain: "check-install", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "bottle \"\(bottle.name)\" needs engine \"\(bottle.engineID)\", which isn't installed. Installed engines: \(known)",
            ])
        }
        log("engine: \(engine.displayName) at \(engine.binDir.path)")

        // 3. Print AppInstallState.shared's phase/progress/output live,
        //    on the main actor (it's an @Observable @MainActor type),
        //    while the install runs.
        let printer = Task { @MainActor in
            var lastPhase = ""
            var lastProgressTenth = -1
            var printedLineCount = 0
            while !Task.isCancelled {
                let state = AppInstallState.shared
                if state.phase != lastPhase {
                    lastPhase = state.phase
                    log("phase: \(lastPhase)")
                }
                let tenth = Int((state.progress * 10).rounded())
                if tenth != lastProgressTenth {
                    lastProgressTenth = tenth
                    log("progress: \(Int(state.progress * 100))%")
                }
                if state.output.count > printedLineCount {
                    for line in state.output[printedLineCount...] {
                        log("  \(line)")
                    }
                    printedLineCount = state.output.count
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        defer { printer.cancel() }

        // 4. Run the exact same install path the UI's "Install" button
        //    uses, minus AppState — persisting the bottle to disk
        //    ourselves at every step AppInstaller.run reports a change.
        let updated = try await AppInstaller.run(app, bottle: bottle, engine: engine) { changed in
            do {
                try BottleStore.save(changed)
            } catch {
                log("warning: failed to save bottle metadata: \(error.localizedDescription)")
            }
        }
        printer.cancel()
        // Let the printer's in-flight iteration (if any) finish before we
        // print the summary below, so output doesn't interleave.
        try? await Task.sleep(nanoseconds: 350_000_000)

        // 5. Report the resulting pins.
        log("pins (\(updated.pins.count)):")
        for pin in updated.pins {
            log("  - \(pin.name): \(pin.exePath)\(pin.args.isEmpty ? "" : " \(pin.args)")")
        }
        if !app.launchExeHints.isEmpty {
            guard updated.pins.contains(where: { $0.name == app.name }) else {
                throw NSError(domain: "check-install", code: 5, userInfo: [
                    NSLocalizedDescriptionKey: "install finished but no pin named \"\(app.name)\" was added. launchExeHints: \(app.launchExeHints)",
                ])
            }
        }
    }
}
