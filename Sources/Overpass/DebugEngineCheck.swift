import Foundation

/// Headless checks for the engine-update feature (see `DebugCheck.swift`
/// for the pattern this follows):
///
/// - `Overpass --check-engine-updates` fetches and prints the merged
///   built-in + live catalog.
/// - `Overpass --check-d3dmetal <dmg-path> <engine-id>` runs
///   `D3DMetalImporter.importFromDMG` against an already-installed engine.
/// - `Overpass --check-d3dmetal-restore <engine-id>` restores the backup
///   `--check-d3dmetal` made.
///
/// None of `EngineUpdateChecker`, `D3DMetalImporter`, or `EngineManager`
/// are `@MainActor`, so — unlike `DebugInstallCheck`, which pumps
/// `RunLoop.main` to service `@MainActor` hops — this can use the simpler
/// `DispatchSemaphore` + `Task.detached` pattern from `DebugCheck.swift`.
enum DebugEngineCheck {
    static func runIfRequested() {
        let args = CommandLine.arguments

        if args.contains("--check-engine-updates") {
            runBlocking { try await checkEngineUpdates() }
            return
        }

        if let idx = args.firstIndex(of: "--check-d3dmetal") {
            guard idx + 2 < args.count else {
                print("CHECK-ENGINE FAILED: --check-d3dmetal needs a .dmg path and an engine id, e.g. --check-d3dmetal /tmp/gptk.dmg gptk-3.0-3")
                exit(1)
            }
            let dmgPath = args[idx + 1]
            let engineID = args[idx + 2]
            runBlocking { try await checkD3DMetal(dmgPath: dmgPath, engineID: engineID) }
            return
        }

        if let idx = args.firstIndex(of: "--check-d3dmetal-restore") {
            guard idx + 1 < args.count else {
                print("CHECK-ENGINE FAILED: --check-d3dmetal-restore needs an engine id, e.g. --check-d3dmetal-restore gptk-3.0-3")
                exit(1)
            }
            let engineID = args[idx + 1]
            runBlocking { try await checkD3DMetalRestore(engineID: engineID) }
            return
        }
    }

    private static func log(_ s: String) { print("[check-engine] \(s)"); fflush(stdout) }

    private static func runBlocking(_ body: @escaping @Sendable () async throws -> Void) {
        let semaphore = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0
        Task.detached {
            do {
                try await body()
                print("CHECK-ENGINE OK")
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                print("CHECK-ENGINE FAILED: \(message)")
                exitCode = 1
            }
            semaphore.signal()
        }
        semaphore.wait()
        exit(exitCode)
    }

    private static func checkEngineUpdates() async throws {
        try Paths.ensureAll()
        log("fetching latest releases from GitHub…")
        let fetched = try await EngineUpdateChecker.fetchLatest()
        log("fetched \(fetched.count) release(s) from GitHub")
        let merged = EngineCatalog.merged(with: fetched)
        for release in merged {
            log("\(release.id)  version=\(release.version)  verified=\(release.verified)  url=\(release.url.absoluteString)")
        }
        guard merged.contains(where: { $0.id == "gptk-3.0-3" }) else {
            throw NSError(domain: "check-engine", code: 1, userInfo: [NSLocalizedDescriptionKey: "merged catalog is missing gptk-3.0-3"])
        }
        guard merged.contains(where: { $0.id == "wine-staging-11.16" }) else {
            throw NSError(domain: "check-engine", code: 2, userInfo: [NSLocalizedDescriptionKey: "merged catalog is missing wine-staging-11.16"])
        }
    }

    private static func checkD3DMetal(dmgPath: String, engineID: String) async throws {
        try Paths.ensureAll()
        guard let engine = await EngineManager.shared.installedEngines().first(where: { $0.id == engineID }) else {
            throw NSError(domain: "check-engine", code: 3, userInfo: [NSLocalizedDescriptionKey: "engine \(engineID) is not installed"])
        }
        log("importing D3DMetal from \(dmgPath) into \(engine.displayName)…")
        let version = try await D3DMetalImporter.importFromDMG(URL(fileURLWithPath: dmgPath), into: engine) { status in
            log("  \(status)")
        }
        log("new D3DMetal version: \(version)")
    }

    private static func checkD3DMetalRestore(engineID: String) async throws {
        try Paths.ensureAll()
        guard let engine = await EngineManager.shared.installedEngines().first(where: { $0.id == engineID }) else {
            throw NSError(domain: "check-engine", code: 4, userInfo: [NSLocalizedDescriptionKey: "engine \(engineID) is not installed"])
        }
        guard try await D3DMetalImporter.restoreBackup(engine: engine) else {
            throw NSError(domain: "check-engine", code: 5, userInfo: [NSLocalizedDescriptionKey: "no D3DMetal backup found for \(engineID)"])
        }
        log("restored previous D3DMetal for \(engine.displayName)")
    }
}
