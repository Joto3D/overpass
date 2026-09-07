import Foundation

/// Headless tool: `Overpass --check-steam <bottle-name>` applies
/// `AppTweaks.steam` (see `AppTweaks.swift`/`AppTweak.swift`'s doc
/// comments for exactly what that is and how it was verified) to an
/// *existing* bottle that already has Steam installed, printing each
/// step as it runs. Exists so the fix can be re-applied to a bottle the
/// user already set up by hand — e.g. after Overpass's own catalog entry
/// changes, or after manually installing Steam outside the catalog flow
/// — without having to delete and reinstall through "Install app".
///
/// Follows `DebugInstallCheck`'s `RunLoop.main.run(until:)` pattern, not
/// `DebugCheck`/`DebugPerfCheck`'s `DispatchSemaphore` one: `AppTweak.apply`
/// itself isn't `@MainActor`, but this hops onto the main actor anyway to
/// reuse `BottleStore`/`EngineManager.shared` the same way every other
/// `--check-*` entry point does, and blocking the main thread on a
/// semaphore while doing that risks the same deadlock class described in
/// `DebugInstallCheck`'s doc comment — the main dispatch queue would never
/// get pumped, so any hop back onto it (this file has none today, but the
/// pattern is copied wholesale specifically so a future edit that adds one
/// doesn't quietly reintroduce that deadlock) would hang forever. Runs
/// before any UI is created.
enum DebugSteamCheck {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let idx = args.firstIndex(of: "--check-steam") else { return }
        guard idx + 1 < args.count, !args[idx + 1].hasPrefix("--") else {
            print("CHECK-STEAM FAILED: --check-steam needs a bottle name, e.g. --check-steam Steam")
            exit(1)
        }
        let bottleName = args[idx + 1]

        nonisolated(unsafe) var exitCode: Int32 = 0
        nonisolated(unsafe) var finished = false
        Task { @MainActor in
            do {
                try await run(bottleName: bottleName)
                print("CHECK-STEAM OK")
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                print("CHECK-STEAM FAILED: \(message)")
                exitCode = 1
            }
            finished = true
        }
        while !finished {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        exit(exitCode)
    }

    private static func log(_ s: String) { print("[check-steam] \(s)"); fflush(stdout) }

    @MainActor
    private static func run(bottleName: String) async throws {
        try Paths.ensureAll()

        let bottles = BottleStore.loadAll()
        guard !bottles.isEmpty else {
            throw NSError(domain: "check-steam", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "no bottles found under \(Paths.bottles.path) — create one first.",
            ])
        }
        guard let bottle = bottles.first(where: { $0.name.caseInsensitiveCompare(bottleName) == .orderedSame }) else {
            let known = bottles.map(\.name).joined(separator: ", ")
            throw NSError(domain: "check-steam", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "no bottle named \"\(bottleName)\". Known bottles: \(known)",
            ])
        }
        log("bottle: \(bottle.name) (\(bottle.id)) at \(bottle.prefixDir.path)")

        let engines = await EngineManager.shared.installedEngines()
        guard let engine = engines.first(where: { $0.id == bottle.engineID }) else {
            let known = engines.map(\.id).joined(separator: ", ")
            throw NSError(domain: "check-steam", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "bottle \"\(bottle.name)\" needs engine \"\(bottle.engineID)\", which isn't installed. Installed engines: \(known)",
            ])
        }
        log("engine: \(engine.displayName) at \(engine.binDir.path)")

        let steamExe = bottle.driveC.appendingPathComponent("Program Files (x86)/Steam/steam.exe")
        guard FileManager.default.fileExists(atPath: steamExe.path) else {
            throw NSError(domain: "check-steam", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Steam isn't installed in \"\(bottle.name)\" (no \(steamExe.path)) — install it first, or point --check-steam at a bottle that already has it.",
            ])
        }

        log("applying Steam tweak (corefonts, msxml3, DWriteEnable=0)…")
        try await AppTweak.apply(AppTweaks.steam, to: bottle, engine: engine) { line in
            log(line)
        }
        log("done. Note: this fix was verified NOT to resolve the steamwebhelper crash on Wine Staging 11.16 as of 2026-09-07 — see AppTweaks.swift's doc comment.")
    }
}
