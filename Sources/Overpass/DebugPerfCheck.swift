import Foundation

/// Headless smoke tests for Performance/Extras (see DebugCheck.swift for the
/// shared pattern: semaphore + `Task.detached`, `print` + `fflush`, exit
/// non-zero on the first failure). Three independent flags, each operating
/// on an *existing* bottle by name (created ahead of time, e.g. via
/// `Overpass --check <engine-id> --keep`):
///
///   `Overpass --check-perf <bottle-name>`
///       Writes every registry-backed `PerformanceSettings` knob to a
///       non-default value via `PerformanceTuner.applyRegistry`, reads them
///       back with `currentRegistry`, prints expected vs. actual, then
///       applies the all-defaults settings again and confirms the keys are
///       reset. Also prints `PerformanceSettings.environment(...)` for each
///       preset. Exits non-zero on any mismatch.
///
///   `Overpass --check-dxvk <bottle-name>`
///       Runs `DXVKInstaller.install`/`uninstall` for real against the
///       bottle's `system32`, confirming `d3d11.dll` changes and a
///       `.overpass-bak` appears, then that `uninstall` restores the
///       original bytes and removes the backup.
///
///   `Overpass --check-winetricks <bottle-name> <verb>`
///       Runs `Winetricks.run(verb:...)` for real and confirms it exits
///       without throwing and that its log file has output.
enum DebugPerfCheck {
    static func runIfRequested() {
        let args = CommandLine.arguments

        if let idx = args.firstIndex(of: "--check-perf") {
            let bottleName = value(after: idx, in: args)
            runAndExit(label: "CHECK-PERF") { try await checkPerf(bottleName: bottleName) }
            return
        }

        if let idx = args.firstIndex(of: "--check-dxvk") {
            let bottleName = value(after: idx, in: args)
            runAndExit(label: "CHECK-DXVK") { try await checkDXVK(bottleName: bottleName) }
            return
        }

        if let idx = args.firstIndex(of: "--check-winetricks") {
            let bottleName = value(after: idx, in: args)
            let verb = idx + 2 < args.count ? args[idx + 2] : ""
            runAndExit(label: "CHECK-WINETRICKS") { try await checkWinetricks(bottleName: bottleName, verb: verb) }
            return
        }
    }

    private static func value(after idx: Int, in args: [String]) -> String {
        idx + 1 < args.count ? args[idx + 1] : ""
    }

    /// Shared harness: runs `body` to completion on a detached task, blocks
    /// the main thread (there is no run loop yet — this runs before any UI)
    /// on a semaphore until it finishes, then exits the process. Same shape
    /// as `DebugCheck.runIfRequested`.
    private static func runAndExit(label: String, _ body: @escaping @Sendable () async throws -> Void) {
        let semaphore = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0
        Task.detached {
            do {
                try await body()
                print("\(label) OK"); fflush(stdout)
            } catch {
                print("\(label) FAILED: \(error.localizedDescription)"); fflush(stdout)
                exitCode = 1
            }
            semaphore.signal()
        }
        semaphore.wait()
        exit(exitCode)
    }

    private static func log(_ s: String) { print("[check-perf] \(s)"); fflush(stdout) }

    struct CheckError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// A plain thread-safe counter — `Winetricks.run`'s `log` callback is
    /// `@Sendable` and the compiler can't see that `ProcessRunner`'s
    /// serial queue already serializes calls to it, so a captured `var`
    /// isn't allowed under Swift 6 concurrency checking.
    private final class LineCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() {
            lock.lock(); value += 1; lock.unlock()
        }
        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }

    // MARK: - Lookup

    private static func findBottleAndEngine(named name: String) async throws -> (Bottle, InstalledEngine) {
        guard let bottle = BottleStore.loadAll().first(where: { $0.name == name }) else {
            throw CheckError(message: "no bottle named \"\(name)\" (create one first, e.g. Overpass --check <engine-id> --keep)")
        }
        guard let engine = await EngineManager.shared.installedEngines().first(where: { $0.id == bottle.engineID }) else {
            throw CheckError(message: "bottle \"\(name)\" uses engine \(bottle.engineID), which isn't installed")
        }
        return (bottle, engine)
    }

    // MARK: - --check-perf

    /// Every registry-backed field in `PerformanceSettings` pushed to a
    /// value that differs from `PerformanceSettings()`'s default.
    private static var nonDefaultSettings: PerformanceSettings {
        var s = PerformanceSettings()
        s.preset = .custom
        s.disableCSMT = true                 // default false -> csmt=0
        s.videoMemorySize = "4096"           // default nil -> deleted
        s.renderer = .vulkan                 // default nil ("gl" build default)
        s.retinaMode = true                  // default false -> "N"
        s.optionAsAlt = false                // default true -> "Y"
        s.preciseScrolling = false           // default true -> "Y"
        return s
    }

    /// `"<hive path>\<value name>"` -> expected value, matching the keys
    /// `PerformanceTuner.currentRegistry` reads.
    private static func expectedRegistry(for settings: PerformanceSettings) -> [String: String?] {
        let direct3D = "HKCU\\Software\\Wine\\Direct3D"
        let macDriver = "HKCU\\Software\\Wine\\Mac Driver"
        return [
            "\(direct3D)\\csmt": settings.disableCSMT ? "0" : nil,
            "\(direct3D)\\VideoMemorySize": settings.videoMemorySize,
            "\(direct3D)\\renderer": settings.renderer?.rawValue,
            "\(macDriver)\\RetinaMode": settings.retinaMode ? "Y" : "N",
            "\(macDriver)\\LeftOptionIsAlt": settings.optionAsAlt ? "Y" : "N",
            "\(macDriver)\\RightOptionIsAlt": settings.optionAsAlt ? "Y" : "N",
            "\(macDriver)\\UsePreciseScrolling": settings.preciseScrolling ? "Y" : "N",
        ]
    }

    /// Applies `settings`, reads the registry back, and prints/checks every
    /// key from `expectedRegistry`. Returns the keys that didn't match
    /// (empty on full success).
    private static func applyAndVerify(_ label: String, settings: PerformanceSettings, bottle: Bottle, engine: InstalledEngine) async -> [String] {
        log("applying \(label) settings…")
        do {
            try await PerformanceTuner.applyRegistry(settings: settings, bottle: bottle, engine: engine)
        } catch {
            log("applyRegistry reported: \(error.localizedDescription) (continuing to read back)")
        }

        let actual = await PerformanceTuner.currentRegistry(bottle: bottle, engine: engine)
        let expected = expectedRegistry(for: settings)

        var mismatches: [String] = []
        log("\(label): expected vs actual")
        for key in expected.keys.sorted() {
            let expectedValue = expected[key] ?? nil
            let actualValue = actual[key]
            let ok = expectedValue == actualValue
            let expectedDisplay = expectedValue ?? "(absent)"
            let actualDisplay = actualValue ?? "(absent)"
            log("  \(ok ? "PASS" : "FAIL")  \(key)  expected=\(expectedDisplay)  actual=\(actualDisplay)")
            if !ok { mismatches.append(key) }
        }
        return mismatches
    }

    private static func checkPerf(bottleName: String) async throws {
        let (bottle, engine) = try await findBottleAndEngine(named: bottleName)
        log("bottle \"\(bottle.name)\" on \(engine.displayName) at \(bottle.prefixDir.path)")

        var failures: [String] = []

        // 1. Every registry-backed knob to a non-default value.
        let nonDefault = nonDefaultSettings
        failures += await applyAndVerify("non-default", settings: nonDefault, bottle: bottle, engine: engine)
            .map { "non-default \($0)" }

        // 2. Defaults again — csmt/VideoMemorySize/renderer should be
        // deleted (absent), Mac Driver keys explicitly reset.
        let defaults = PerformanceSettings()
        failures += await applyAndVerify("defaults", settings: defaults, bottle: bottle, engine: engine)
            .map { "defaults \($0)" }

        // 3. Environment preview for each preset, purely for eyeballing —
        // not part of the pass/fail check (no registry involved).
        log("environment(for:) per preset:")
        for preset in [PerformanceSettings.Preset.balanced, .maxPerformance, .compatibility] {
            guard let presetSettings = PerformanceSettings.presets[preset] else { continue }
            let env = PerformanceSettings.environment(for: presetSettings, bottle: bottle, engine: engine)
            log("  \(preset.displayName):")
            if env.isEmpty {
                log("    (no vars)")
            } else {
                for key in env.keys.sorted() {
                    log("    \(key)=\(env[key] ?? "")")
                }
            }
        }

        guard failures.isEmpty else {
            throw CheckError(message: "\(failures.count) registry mismatch(es): \(failures.joined(separator: "; "))")
        }
    }

    // MARK: - --check-dxvk

    private static func checkDXVK(bottleName: String) async throws {
        let (bottle, engine) = try await findBottleAndEngine(named: bottleName)
        log("bottle \"\(bottle.name)\" on \(engine.displayName) at \(bottle.prefixDir.path)")
        guard engine.kind.supportsDXVK else {
            throw CheckError(message: "\(engine.displayName) doesn't support DXVK (GPTK ships D3DMetal instead); pick a Wine-staging bottle")
        }

        let system32 = bottle.driveC.appendingPathComponent("windows/system32", isDirectory: true)
        let d3d11 = system32.appendingPathComponent("d3d11.dll")
        let backup = system32.appendingPathComponent("d3d11.dll.overpass-bak")

        guard let originalData = try? Data(contentsOf: d3d11) else {
            throw CheckError(message: "bottle has no drive_c/windows/system32/d3d11.dll to begin with — is it a fully-created bottle?")
        }
        log("original d3d11.dll: \(originalData.count) bytes")
        if FileManager.default.fileExists(atPath: backup.path) {
            log("warning: a stale .overpass-bak already exists — removing it so this run starts clean")
            try? FileManager.default.removeItem(at: backup)
        }
        guard !DXVKInstaller.isInstalled(in: bottle) else {
            throw CheckError(message: "DXVKInstaller.isInstalled(in:) already true before install — stale state")
        }

        log("installing DXVK…")
        try await DXVKInstaller.install(into: bottle) { message in log("  \(message)") }

        guard let installedData = try? Data(contentsOf: d3d11) else {
            throw CheckError(message: "d3d11.dll missing after install")
        }
        let changed = installedData != originalData
        let backupExists = FileManager.default.fileExists(atPath: backup.path)
        log("after install: d3d11.dll changed=\(changed) (\(installedData.count) bytes), .overpass-bak exists=\(backupExists), isInstalled=\(DXVKInstaller.isInstalled(in: bottle))")

        guard changed else { throw CheckError(message: "d3d11.dll bytes are unchanged after install") }
        guard backupExists else { throw CheckError(message: "d3d11.dll.overpass-bak was not created") }
        guard DXVKInstaller.isInstalled(in: bottle) else { throw CheckError(message: "DXVKInstaller.isInstalled(in:) is false after install") }

        var dxvkBottle = bottle
        dxvkBottle.dxvk = true
        try BottleStore.save(dxvkBottle)
        log("bottle.dxvk = true, saved")

        let env = WineRunner.environment(for: dxvkBottle, engine: engine)
        log("WineRunner.environment(...)[\"WINEDLLOVERRIDES\"] = \(env["WINEDLLOVERRIDES"] ?? "(absent)")")
        guard env["WINEDLLOVERRIDES"] != nil else {
            throw CheckError(message: "WINEDLLOVERRIDES missing from environment with bottle.dxvk = true")
        }

        log("launching notepad to prove the bottle still starts with DXVK overrides…")
        let logURL = LogStore.newLogURL(bottleID: dxvkBottle.id, exeName: "check-dxvk-notepad")
        let process = try WineRunner.launchTool(name: "notepad", bottle: dxvkBottle, engine: engine, logURL: logURL)
        log("launched notepad (launcher pid \(process.processIdentifier)), log: \(logURL.path)")
        try await Task.sleep(nanoseconds: 6_000_000_000)
        let notepadAlive = (try? await ShellRunner.run("/usr/bin/pgrep", ["-f", "notepad"]))?.status == 0
        log("notepad process visible: \(notepadAlive)")
        await WineRunner.stop(bottle: dxvkBottle, engine: engine)
        guard notepadAlive else {
            let tail = LogStore.tail(logURL, maxBytes: 4000)
            throw CheckError(message: "notepad did not start with DXVK overrides applied. Log tail:\n\(tail)")
        }

        log("uninstalling DXVK…")
        try DXVKInstaller.uninstall(from: bottle)
        dxvkBottle.dxvk = false
        try BottleStore.save(dxvkBottle)

        guard let restoredData = try? Data(contentsOf: d3d11) else {
            throw CheckError(message: "d3d11.dll missing after uninstall")
        }
        let restored = restoredData == originalData
        let backupGone = !FileManager.default.fileExists(atPath: backup.path)
        log("after uninstall: d3d11.dll restored=\(restored), backup removed=\(backupGone), isInstalled=\(DXVKInstaller.isInstalled(in: bottle))")

        guard restored else { throw CheckError(message: "d3d11.dll bytes do not match the pre-install original after uninstall") }
        guard backupGone else { throw CheckError(message: "d3d11.dll.overpass-bak still present after uninstall") }
        guard !DXVKInstaller.isInstalled(in: bottle) else { throw CheckError(message: "DXVKInstaller.isInstalled(in:) is still true after uninstall") }
    }

    // MARK: - --check-winetricks

    private static func checkWinetricks(bottleName: String, verb: String) async throws {
        guard !verb.isEmpty else {
            throw CheckError(message: "usage: --check-winetricks <bottle-name> <verb>")
        }
        let (bottle, engine) = try await findBottleAndEngine(named: bottleName)
        log("bottle \"\(bottle.name)\" on \(engine.displayName), verb \"\(verb)\"")

        let before = Date().addingTimeInterval(-1)
        let lineCount = LineCounter()
        try await Winetricks.run(verb: verb, bottle: bottle, engine: engine) { line in
            lineCount.increment()
            log("  | \(line)")
        }
        log("winetricks exited 0, streamed \(lineCount.count) output line(s)")

        // Winetricks.run writes its own timestamped log file under
        // Logs/<bottleID>/winetricks-<verb>-*.log; find the one it just
        // wrote and confirm it actually has content on disk (not just what
        // we saw streamed, in case buffering dropped something).
        let sanitizedVerb = verb.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        let candidateLogs = LogStore.logs(for: bottle.id).filter {
            $0.lastPathComponent.contains("winetricks-\(sanitizedVerb)")
        }
        guard let logURL = candidateLogs.first else {
            throw CheckError(message: "no winetricks-\(sanitizedVerb) log file found under Logs/\(bottle.id.uuidString)")
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path)
        let size = (attrs?[.size] as? Int) ?? 0
        let modified = (attrs?[.modificationDate] as? Date) ?? .distantPast
        log("log file: \(logURL.path) (\(size) bytes, modified \(modified))")

        guard size > 0 else { throw CheckError(message: "log file \(logURL.path) is empty") }
        guard modified >= before else { throw CheckError(message: "log file \(logURL.path) doesn't look like it was written by this run") }
    }
}
