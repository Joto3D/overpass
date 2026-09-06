import Foundation
import AppKit

/// Headless smoke test: `Overpass --check [engine-id]`. Installs the engine
/// (from the download cache when possible), creates a throwaway bottle,
/// launches Notepad, checks it is alive, stops it, deletes the bottle, and
/// exits non-zero on the first failure. Runs before any UI is created.
enum DebugCheck {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let idx = args.firstIndex(of: "--check") else { return }
        let candidate = idx + 1 < args.count ? args[idx + 1] : ""
        let engineID = candidate.isEmpty || candidate.hasPrefix("--") ? EngineCatalog.defaultRelease.id : candidate
        let keepBottle = args.contains("--keep")

        let semaphore = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0
        Task.detached {
            do {
                try await run(engineID: engineID, keepBottle: keepBottle)
                print("CHECK OK")
            } catch {
                print("CHECK FAILED: \(error.localizedDescription)")
                exitCode = 1
            }
            semaphore.signal()
        }
        semaphore.wait()
        exit(exitCode)
    }

    private static func log(_ s: String) { print("[check] \(s)"); fflush(stdout) }

    private static func run(engineID: String, keepBottle: Bool) async throws {
        try Paths.ensureAll()
        guard let release = EngineCatalog.releases.first(where: { $0.id == engineID }) else {
            throw NSError(domain: "check", code: 1, userInfo: [NSLocalizedDescriptionKey: "unknown engine id \(engineID)"])
        }

        // 1. Engine
        var engine = await EngineManager.shared.installedEngines().first { $0.id == engineID }
        if engine == nil {
            log("installing \(release.displayName)…")
            engine = try await EngineManager.shared.install(release) { fraction, status in
                print("[check]   \(Int(fraction * 100))% \(status)"); fflush(stdout)
            }
        }
        guard let engine else { throw NSError(domain: "check", code: 2) }
        log("engine ready: \(engine.versionString) at \(engine.binDir.path)")

        // 2. Bottle
        var bottle = Bottle(name: "check-\(Int(Date().timeIntervalSince1970))", engineID: engine.id)
        try FileManager.default.createDirectory(at: bottle.prefixDir, withIntermediateDirectories: true)
        let t0 = Date()
        try await WineRunner.createPrefix(bottle: bottle, engine: engine) { log($0) }
        try BottleStore.save(bottle)
        let windowsDir = bottle.driveC.appendingPathComponent("windows")
        guard FileManager.default.fileExists(atPath: windowsDir.path) else {
            throw NSError(domain: "check", code: 3, userInfo: [NSLocalizedDescriptionKey: "drive_c/windows missing after wineboot"])
        }
        log("bottle created in \(Int(Date().timeIntervalSince(t0)))s: \(bottle.prefixDir.path)")

        // 3. Launch notepad
        let logURL = LogStore.newLogURL(bottleID: bottle.id, exeName: "notepad")
        let process = try WineRunner.launchTool(name: "notepad", bottle: bottle, engine: engine, logURL: logURL)
        log("launched notepad (launcher pid \(process.processIdentifier)), log: \(logURL.path)")
        try await Task.sleep(nanoseconds: 8_000_000_000)
        let alive = try await pgrep("notepad")
        log("notepad process visible: \(alive)")
        guard alive else {
            let tail = LogStore.tail(logURL, maxBytes: 4000)
            throw NSError(domain: "check", code: 4, userInfo: [NSLocalizedDescriptionKey: "notepad not running. Log tail:\n\(tail)"])
        }

        // 4. Stop
        await WineRunner.stop(bottle: bottle, engine: engine)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let stillThere = try await pgrep(bottle.prefixDir.path)
        log("processes left after stop: \(stillThere)")
        guard !stillThere else { throw NSError(domain: "check", code: 5, userInfo: [NSLocalizedDescriptionKey: "wine processes survived stop()"]) }

        // 5. Cleanup
        if keepBottle {
            bottle.lastUsed = Date()
            try BottleStore.save(bottle)
            log("kept bottle \(bottle.name)")
        } else {
            try BottleStore.delete(bottle)
            log("bottle deleted")
        }
    }

    private static func pgrep(_ pattern: String) async throws -> Bool {
        let r = try await ShellRunner.run("/usr/bin/pgrep", ["-f", pattern])
        return r.status == 0
    }
}
