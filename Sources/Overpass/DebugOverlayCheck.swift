import Foundation

/// Headless smoke test: `Overpass --check-overlay <bottle-name>` (see
/// `DebugCheck.swift`/`DebugInstallCheck.swift` for the pattern this
/// follows). Installs the `D3DMetalOverlay` into the named bottle (which
/// must already exist and run on a Wine-staging engine), prints the
/// resulting `WineRunner.environment`, then runs a real load test —
/// `wine regsvr32 /s <name>.dll` for a handful of the overlaid dll names,
/// with `WINEDEBUG=+loaddll,+module` — and prints PASS/FAIL per name
/// plus an overall verdict. Unlike `DebugCheck`, it leaves both the
/// overlay and the bottle installed for further manual poking (the
/// caller-facing verification against the real "Steam" bottle is driven
/// separately, not by this entry point, since that one bottle is
/// pre-existing user data this check must not create/delete).
///
/// As of the September 2026 investigation this doc comment records
/// (see `D3DMetalOverlay.swift`'s doc comment for the full writeup),
/// this check is expected to print FAIL: on the shipped Wine Staging
/// 11.16 build, `WINEDLLPATH` is not consulted by the builtin-dll
/// resolver for these names, so the overlay never actually loads.
enum DebugOverlayCheck {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let idx = args.firstIndex(of: "--check-overlay") else { return }
        guard idx + 1 < args.count, !args[idx + 1].hasPrefix("--") else {
            print("CHECK-OVERLAY FAILED: --check-overlay needs a bottle name, e.g. --check-overlay Steam")
            exit(1)
        }
        let bottleName = args[idx + 1]

        // Same reasoning as DebugInstallCheck: code under test here
        // (EngineManager, the InstalledEngine list) isn't @MainActor, but
        // to stay uniform with the rest of the Debug* checks and avoid any
        // future @MainActor creep, pump the run loop rather than block a
        // semaphore.
        nonisolated(unsafe) var exitCode: Int32 = 0
        nonisolated(unsafe) var finished = false
        Task {
            do {
                try await run(bottleName: bottleName)
                print("CHECK-OVERLAY OK")
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                print("CHECK-OVERLAY FAILED: \(message)")
                exitCode = 1
            }
            finished = true
        }
        while !finished {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        exit(exitCode)
    }

    private static func log(_ s: String) { print("[check-overlay] \(s)"); fflush(stdout) }

    private static func run(bottleName: String) async throws {
        try Paths.ensureAll()

        // 1. Bottle — must already exist and be on Wine-staging.
        let bottles = BottleStore.loadAll()
        guard let bottle = bottles.first(where: { $0.name.caseInsensitiveCompare(bottleName) == .orderedSame }) else {
            let known = bottles.map(\.name).joined(separator: ", ")
            throw NSError(domain: "check-overlay", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "no bottle named \"\(bottleName)\". Known bottles: \(known)",
            ])
        }
        log("bottle: \(bottle.name) (\(bottle.id)) at \(bottle.prefixDir.path)")

        let engines = await EngineManager.shared.installedEngines()
        guard let engine = engines.first(where: { $0.id == bottle.engineID }) else {
            throw NSError(domain: "check-overlay", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "bottle's engine \"\(bottle.engineID)\" isn't installed.",
            ])
        }
        guard engine.kind == .wineStaging else {
            throw NSError(domain: "check-overlay", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "bottle \"\(bottle.name)\" runs on \(engine.kind.displayName), not Wine-staging — the overlay is only meaningful there.",
            ])
        }
        log("engine: \(engine.displayName) at \(engine.binDir.path)")

        guard let gptk = D3DMetalOverlay.sourceEngine(from: engines) else {
            throw NSError(domain: "check-overlay", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "no installed GPTK engine has usable D3DMetal files to copy from.",
            ])
        }
        log("D3DMetal source: \(gptk.displayName) at \(gptk.libDir.path)")

        // 2. Install the overlay.
        try D3DMetalOverlay.install(into: bottle, from: gptk) { log($0) }
        guard D3DMetalOverlay.isInstalled(in: bottle) else {
            throw NSError(domain: "check-overlay", code: 5, userInfo: [NSLocalizedDescriptionKey: "install() returned but isInstalled(in:) is still false"])
        }
        log("overlay installed at \(D3DMetalOverlay.overlayDir(for: bottle).path)")

        var overlaidBottle = bottle
        overlaidBottle.d3dMetalOverlay = true
        try BottleStore.save(overlaidBottle)

        // 3. Print the resulting environment.
        let env = WineRunner.environment(for: overlaidBottle, engine: engine)
        log("environment:")
        for key in ["WINEDLLPATH", "WINEDLLOVERRIDES", "DYLD_FALLBACK_LIBRARY_PATH", "D3DMetal", "CX_APPLEGPTK_LIBD3DSHARED_PATH"] {
            log("  \(key)=\(env[key] ?? "(unset)")")
        }

        // 4. Real load test. `wine dxdiag /t` turned out to be a dead end
        //    here — Wine's dxdiag is a stub that never touches d3d11/dxgi
        //    at all for a text report, so it can't tell us anything. A
        //    much more direct real-program test: `regsvr32` is a genuine
        //    Wine-shipped Windows executable whose entire job is
        //    `LoadLibrary` + look up `DllRegisterServer` — exactly the
        //    mechanism that would need to resolve to the overlay's dll
        //    for D3DMetal to engage. `/s` suppresses the result message
        //    box regsvr32 would otherwise pop up (which hangs this
        //    headless check waiting for a click that never comes — hit
        //    during manual testing before this flag was added).
        //    `WINEDEBUG=+loaddll,+module` makes Wine log which dll
        //    resolved (and any unixlib pairing error) for each name.
        //
        //    `atidxx64.dll` — present only in the overlay, not in Wine
        //    Staging's own `x86_64-windows` — is the decisive probe: if
        //    `WINEDLLPATH` is actually consulted, it loads; if not, it
        //    fails outright with no other explanation possible.
        let loadedAtidxx64 = try await testRegsvr32Load(name: "atidxx64", bottle: overlaidBottle, engine: engine)
        let loadedD3D11 = try await testRegsvr32Load(name: "d3d11", bottle: overlaidBottle, engine: engine)
        let loadedDXGI = try await testRegsvr32Load(name: "dxgi", bottle: overlaidBottle, engine: engine)

        log("atidxx64.dll (overlay-only name) loaded via WINEDLLPATH: \(loadedAtidxx64)")
        log("d3d11.dll loaded (either the overlay's or Wine-staging's own — see log for which): \(loadedD3D11)")
        log("dxgi.dll loaded: \(loadedDXGI)")

        if loadedAtidxx64 {
            log("PASS: the D3DMetal overlay is being consulted by this Wine build's dll loader.")
        } else {
            log("FAIL: WINEDLLPATH is not consulted by this Wine Staging 11.16 build's builtin-dll resolver — the overlay never loads, regardless of WINEDLLOVERRIDES. See D3DMetalOverlay.swift's doc comment for the full investigation (including why the DXVK-style system32-copy fallback doesn't work for these particular DLLs either).")
        }

        log("Bottle and overlay left installed for follow-up inspection.")
    }

    /// Runs `wine regsvr32 /s <name>.dll` under `bottle`'s environment
    /// (with `WINEDEBUG=+loaddll,+module,-all` forced on, overriding
    /// `verboseLog`) and reports whether `<name>.dll` actually loaded —
    /// i.e. whether the log's `module:load_dll ... Failed to load module`
    /// line for that name is present (`false`) or absent (`true`; a
    /// clean load either logs nothing further at `-all` or logs
    /// `loaddll:build_module Loaded ...`). A hard 20s watchdog runs
    /// alongside: if `regsvr32` doesn't exit on its own (a failed load
    /// can otherwise leave a hung Wine message pump — hit once during
    /// manual testing before `/s` was added, and kept here as a
    /// safety net), `wineserver -k` is issued so this check can't hang
    /// the whole run indefinitely.
    private static func testRegsvr32Load(name: String, bottle: Bottle, engine: InstalledEngine) async throws -> Bool {
        var testBottle = bottle
        testBottle.verboseLog = false
        testBottle.env["WINEDEBUG"] = "+loaddll,+module,-all"
        let logURL = LogStore.newLogURL(bottleID: bottle.id, exeName: "check-overlay-regsvr32-\(name)")

        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled else { return }
            log("watchdog: regsvr32 \(name).dll didn't exit within 20s, forcing wineserver -k")
            await WineRunner.stop(bottle: testBottle, engine: engine)
        }
        defer { watchdog.cancel() }

        _ = try? await WineRunner.runTool(
            engine.wineBinary,
            ["regsvr32", "/s", "\(name).dll"],
            bottle: testBottle,
            engine: engine,
            logURL: logURL
        )

        let logText = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        let failed = logText.range(
            of: #"Failed to load module L?"?[^\n]*\#(name)\.dll"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
        if failed, let line = logText.split(separator: "\n").first(where: { $0.localizedCaseInsensitiveContains("failed to load module") && $0.localizedCaseInsensitiveContains(name) }) {
            log("  \(name).dll: \(line.trimmingCharacters(in: .whitespaces))")
        }
        return !failed
    }
}
