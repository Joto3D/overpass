import Foundation

/// Headless smoke test: `Overpass --check-import <source-name-or-path>
/// [--engine <id>]` (see `DebugCheck.swift` for the pattern this follows,
/// and `DebugInstallCheck.swift` for why this uses the `RunLoop.main`
/// pump instead of a blocking `DispatchSemaphore` — `BottleImporter`'s
/// AppState-facing pieces and `BottleImportState` are `@MainActor`, so a
/// semaphore-blocked main thread would never pump the queue that runs
/// them). Runs `BottleImporter.discover()`, prints what it found, then
/// imports the source matching `<source-name-or-path>` (by exact source
/// name first, then by comparing standardized paths, so either a
/// discovered bottle's display name or an arbitrary folder path works)
/// into a bottle named `import-<unix-timestamp>`, prints the resulting
/// pins, and exits non-zero on the first failure. Runs before any UI is
/// created.
enum DebugImportCheck {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let idx = args.firstIndex(of: "--check-import") else { return }
        guard idx + 1 < args.count, !args[idx + 1].hasPrefix("--") else {
            print("CHECK-IMPORT FAILED: --check-import needs a source name or folder path, e.g. --check-import Games")
            exit(1)
        }
        let sourceQuery = args[idx + 1]

        var engineID: String?
        if let engineIdx = args.firstIndex(of: "--engine"), engineIdx + 1 < args.count {
            engineID = args[engineIdx + 1]
        }

        // Same reasoning as DebugInstallCheck: spin the main run loop
        // (which services the main dispatch queue) rather than block it
        // with a semaphore, since the import path is `@MainActor`.
        nonisolated(unsafe) var exitCode: Int32 = 0
        nonisolated(unsafe) var finished = false
        Task { @MainActor in
            do {
                try await run(sourceQuery: sourceQuery, engineID: engineID)
                print("CHECK-IMPORT OK")
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                print("CHECK-IMPORT FAILED: \(message)")
                exitCode = 1
            }
            finished = true
        }
        while !finished {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        exit(exitCode)
    }

    private static func log(_ s: String) { print("[check-import] \(s)"); fflush(stdout) }

    @MainActor
    private static func run(sourceQuery: String, engineID: String?) async throws {
        try Paths.ensureAll()

        let sources = BottleImporter.discover()
        log("discovered \(sources.count) source(s):")
        for source in sources {
            let sizeText = source.sizeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "unknown size"
            let winText = source.windowsVersion.map(\.displayName) ?? "unknown Windows version"
            log("  - [\(source.kind.displayName)] \(source.name) — \(source.prefixDir.path) (\(sizeText), \(winText))")
        }

        // Resolve the requested source: exact name match first, else
        // treat the query as a path (standardized comparison so a
        // trailing slash or "~"-expansion difference doesn't matter).
        let resolvedSource: BottleImporter.Source
        if let byName = sources.first(where: { $0.name.caseInsensitiveCompare(sourceQuery) == .orderedSame }) {
            resolvedSource = byName
        } else {
            let candidateURL = URL(fileURLWithPath: (sourceQuery as NSString).expandingTildeInPath).standardizedFileURL
            if let byPath = sources.first(where: { $0.prefixDir.standardizedFileURL == candidateURL }) {
                resolvedSource = byPath
            } else if let validated = BottleImporter.validate(candidateURL) {
                resolvedSource = validated
            } else {
                let known = sources.map(\.name).joined(separator: ", ")
                throw NSError(domain: "check-import", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "no source named or at path \"\(sourceQuery)\" (not a valid Wine prefix — needs drive_c/ and system.reg). Known sources: \(known)",
                ])
            }
        }
        log("importing: [\(resolvedSource.kind.displayName)] \(resolvedSource.name) from \(resolvedSource.prefixDir.path)")

        // Engine: explicit --engine, else the default catalog engine if
        // it's installed, else whatever's installed first.
        let installedEngines = await EngineManager.shared.installedEngines()
        guard !installedEngines.isEmpty else {
            throw NSError(domain: "check-import", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "no engines installed. Install one first (e.g. `Overpass --check`).",
            ])
        }
        let resolvedEngine: InstalledEngine
        if let engineID {
            guard let match = installedEngines.first(where: { $0.id == engineID }) else {
                let known = installedEngines.map(\.id).joined(separator: ", ")
                throw NSError(domain: "check-import", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "no installed engine \"\(engineID)\". Installed engines: \(known)",
                ])
            }
            resolvedEngine = match
        } else {
            resolvedEngine = installedEngines.first { $0.id == EngineCatalog.defaultRelease.id } ?? installedEngines[0]
        }
        log("engine: \(resolvedEngine.displayName) at \(resolvedEngine.binDir.path)")

        let bottleName = "import-\(Int(Date().timeIntervalSince1970))"
        let windowsVersion = resolvedSource.windowsVersion ?? .win10

        let bottle = try await BottleImporter.importPrefix(
            resolvedSource, as: bottleName, engineID: resolvedEngine.id, windowsVersion: windowsVersion, copy: true
        ) { message in
            log(message)
        }
        log("imported bottle \"\(bottle.name)\" (\(bottle.id)) at \(bottle.prefixDir.path)")

        log("pins (\(bottle.pins.count)):")
        for pin in bottle.pins {
            log("  - \(pin.name): \(pin.exePath)\(pin.args.isEmpty ? "" : " \(pin.args)")")
        }

        // Prove the imported prefix actually runs under its new engine:
        // launch notepad, confirm it's alive, then stop it. Mirrors
        // DebugCheck's launch/verify/stop sequence.
        let logURL = LogStore.newLogURL(bottleID: bottle.id, exeName: "notepad")
        let process = try WineRunner.launchTool(name: "notepad", bottle: bottle, engine: resolvedEngine, logURL: logURL)
        log("launched notepad (launcher pid \(process.processIdentifier)), log: \(logURL.path)")
        try await Task.sleep(nanoseconds: 8_000_000_000)
        let alive = try await pgrep("notepad")
        log("notepad process visible: \(alive)")
        guard alive else {
            let tail = LogStore.tail(logURL, maxBytes: 4000)
            throw NSError(domain: "check-import", code: 4, userInfo: [NSLocalizedDescriptionKey: "notepad not running in imported bottle. Log tail:\n\(tail)"])
        }

        await WineRunner.stop(bottle: bottle, engine: resolvedEngine)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let stillThere = try await pgrep(bottle.prefixDir.path)
        log("processes left after stop: \(stillThere)")
        guard !stillThere else {
            throw NSError(domain: "check-import", code: 5, userInfo: [NSLocalizedDescriptionKey: "wine processes survived stop() in imported bottle"])
        }
    }

    private static func pgrep(_ pattern: String) async throws -> Bool {
        let r = try await ShellRunner.run("/usr/bin/pgrep", ["-f", pattern])
        return r.status == 0
    }
}
