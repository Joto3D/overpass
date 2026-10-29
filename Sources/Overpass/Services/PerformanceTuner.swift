import Foundation

/// Applies (and reads back) the registry-backed half of `PerformanceSettings`
/// — the fields `PerformanceSettings.environment(for:bottle:engine:)`
/// doesn't cover because they're Wine registry keys, not environment
/// variables.
///
/// Every command here is run via `runCommand` (below), a small local
/// `Process` wrapper — *not* `WineRunner.runTool`/`ProcessRunner.run`.
/// Reason: `ProcessRunner.run` waits for both process termination *and*
/// end-of-file on the child's stdout/stderr `Pipe`s (deliberately, so it
/// doesn't miss output from something the child itself spawned and
/// outlives it — see the comment on `ProcessRunner`). But a `wine reg`
/// invocation that doesn't find an already-reachable `wineserver` for this
/// prefix auto-spawns one as its own child, and that auto-spawned server
/// — persistent (`-p`) or not — can inherit and hold open its copy of the
/// pipe's write end well past the point our direct child (the `wine reg`
/// process itself) has exited, so the pipe's read end never sees EOF and
/// `ProcessRunner.run` never resolves. Confirmed directly: `wineserver -p`
/// piped through `cat` never lets `cat` see EOF, even though the `-p`
/// invocation itself returns in well under a second. Routing through
/// temp files instead of pipes sidesteps this entirely — a file has no
/// "still has an open writer" concept, and `runCommand` only waits for
/// the *direct* child's `terminationHandler`, never for anything it may
/// have spawned.
///
/// `nonisolated` like `WineRunner`: a plain enum, not an actor or
/// `@MainActor` type — callers `await` these `async` functions from the
/// main actor.
enum PerformanceTuner {
    private static let direct3DKey = "HKCU\\Software\\Wine\\Direct3D"
    private static let macDriverKey = "HKCU\\Software\\Wine\\Mac Driver"

    struct RegistryError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct CommandResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    // MARK: - Apply

    /// Writes every registry-backed knob in `settings`, best-effort per
    /// key (a failure on one key doesn't stop the rest), then throws a
    /// single `RegistryError` summarizing every failure if any occurred.
    ///
    /// ## Performance: the per-key `wine reg` calls run concurrently
    ///
    /// Applying used to run its seven `wine reg add` / `reg delete`
    /// calls one after another, and each of those is a whole Wine
    /// process start, which is essentially all of its cost. They write
    /// different value names, depend on nothing from each other, and all
    /// talk to the single persistent wineserver started below (which
    /// serializes registry requests itself, as it does for any set of
    /// Windows programs), so there is no reason to queue them.
    ///
    /// MEASURED on this machine against the real "Default" GPTK bottle,
    /// warm, end to end including the `wineserver -p` / `-k` pair, steady
    /// state over several runs, with the registry read back through
    /// `currentRegistry` after each apply to confirm every value landed
    /// (non-default settings written, then the bottle's own restored):
    ///
    ///     sequential (before)   2.45 s   (2.46 s on each repeat)
    ///     concurrent (after)    1.23 s   (1.21-1.25 s on each repeat)
    ///
    /// A cold first run after the machine has been idle is dominated by
    /// loading Wine from disk and is slow either way (8.1 s before, 6.9 s
    /// after). One concurrent run out of ten measured 3.2 s, which is the
    /// only evidence of contention seen; it was not reproduced, and the
    /// values read back correctly every time. The remaining ~1.2 s is the
    /// two wineserver commands plus one Wine start, i.e. the floor for
    /// this design.
    ///
    /// The summarized failure text lists failures in key order, exactly as
    /// before, because each step's result is tagged with its index and
    /// re-sorted. This cannot be unit-tested without a Wine engine; it
    /// was verified with `DebugPerfCheck` (`--check-perf`) and the
    /// read-back above.
    static func applyRegistry(settings: PerformanceSettings, bottle: Bottle, engine: InstalledEngine) async throws {
        var failures: [String] = []

        // Keep one wineserver instance alive for this whole batch of `reg`
        // calls rather than letting each `wine reg add/delete` invocation
        // start and tear down its own ephemeral server. Wineserver saves
        // the registry to disk asynchronously and only guarantees a flush
        // on clean shutdown; if a torn-down server's save lags behind the
        // *next* call's fresh server loading from disk (easy to hit when
        // the machine is under load and each `wine` invocation itself
        // takes seconds to start under Rosetta), that next server — and
        // anything that queries through it, including `currentRegistry`
        // right after this returns — can read stale, pre-write data even
        // though every individual `reg add` reported success. `-p` opts
        // this server out of the normal "exit shortly after the last
        // client disconnects" behavior; the `-k` below, run after every
        // write in this batch, both shuts it down and forces the save.
        _ = await runCommand(engine.wineserverBinary, ["-p"], bottle: bottle, engine: engine)

        // The writes below are independent of each other (different value
        // names, no ordering requirement) and go through the one
        // persistent wineserver started above, which serializes registry
        // requests itself. Each is a separate `wine reg` process whose
        // cost is almost entirely Wine startup, so they are issued
        // concurrently instead of one after another. Each step returns
        // its failure text (or nil), and results are re-sorted by step
        // index afterwards so the summarized error lists failures in the
        // same order the sequential version did. See the doc comment on
        // this function for the measured effect.
        typealias Step = @Sendable () async -> String?
        var steps: [Step] = []

        // Direct3D: csmt (DWORD). Disabling writes 0; enabling deletes the
        // value so the Wine build's own default (on) applies.
        let direct3DKey = Self.direct3DKey
        let macDriverKey = Self.macDriverKey
        if settings.disableCSMT {
            steps.append { await addDWORD(direct3DKey, "csmt", "0", bottle: bottle, engine: engine) }
        } else {
            steps.append { await deleteValue(direct3DKey, "csmt", bottle: bottle, engine: engine); return nil }
        }

        // Direct3D: VideoMemorySize (REG_SZ, megabytes).
        if let vram = settings.videoMemorySize, !vram.trimmingCharacters(in: .whitespaces).isEmpty {
            steps.append { await addString(direct3DKey, "VideoMemorySize", vram, bottle: bottle, engine: engine) }
        } else {
            steps.append { await deleteValue(direct3DKey, "VideoMemorySize", bottle: bottle, engine: engine); return nil }
        }

        // Direct3D: renderer (REG_SZ "gl"/"vulkan").
        if let renderer = settings.renderer {
            let value = renderer.rawValue
            steps.append { await addString(direct3DKey, "renderer", value, bottle: bottle, engine: engine) }
        } else {
            steps.append { await deleteValue(direct3DKey, "renderer", bottle: bottle, engine: engine); return nil }
        }

        // Mac Driver: always written explicitly (Y/N) rather than
        // deleted-when-off, since these are plain booleans with no
        // ambiguity about what "off" should mean.
        for (name, isOn) in [
            ("RetinaMode", settings.retinaMode),
            ("LeftOptionIsAlt", settings.optionAsAlt),
            ("RightOptionIsAlt", settings.optionAsAlt),
            ("UsePreciseScrolling", settings.preciseScrolling),
        ] {
            steps.append { await addString(macDriverKey, name, isOn ? "Y" : "N", bottle: bottle, engine: engine) }
        }

        let results = await withTaskGroup(of: (Int, String?).self) { group -> [(Int, String?)] in
            for (index, step) in steps.enumerated() {
                group.addTask { (index, await step()) }
            }
            var collected: [(Int, String?)] = []
            for await result in group { collected.append(result) }
            return collected
        }
        failures.append(contentsOf: results.sorted { $0.0 < $1.0 }.compactMap(\.1))

        // Shut the persistent server back down, forcing its save to disk,
        // so a `currentRegistry` call (or a plain `wine` launch) right
        // after this returns always sees what was just written.
        _ = await runCommand(engine.wineserverBinary, ["-k"], bottle: bottle, engine: engine)

        if !failures.isEmpty {
            throw RegistryError(message: failures.joined(separator: "; "))
        }
    }

    // MARK: - Read back

    /// Best-effort read of the same keys `applyRegistry` writes, keyed
    /// `"<hive path>\<value name>"`. Any query that fails (value not set,
    /// tool error) is simply omitted rather than surfaced — this is for
    /// display/diagnostics, not a source of truth (`PerformanceSettings`
    /// on the bottle is that).
    static func currentRegistry(bottle: Bottle, engine: InstalledEngine) async -> [String: String] {
        var values: [String: String] = [:]
        let queries: [(key: String, name: String)] = [
            (direct3DKey, "csmt"),
            (direct3DKey, "VideoMemorySize"),
            (direct3DKey, "renderer"),
            (macDriverKey, "RetinaMode"),
            (macDriverKey, "LeftOptionIsAlt"),
            (macDriverKey, "RightOptionIsAlt"),
            (macDriverKey, "UsePreciseScrolling"),
        ]
        for query in queries {
            let result = await runCommand(
                engine.wineBinary, ["reg", "query", query.key, "/v", query.name],
                bottle: bottle, engine: engine
            )
            guard result.status == 0 else { continue }

            if let value = parseRegQueryValue(result.stdout, valueName: query.name) {
                values["\(query.key)\\\(query.name)"] = value
            }
        }
        return values
    }

    /// `wine reg query <key> /v <name>` prints a line like
    /// `    csmt    REG_DWORD    0x0` (or `REG_SZ` with a plain string
    /// value) among some header/blank lines. Finds that line and returns
    /// its value, normalized to match what callers pass to `reg add`:
    /// `REG_DWORD` prints its value in hex (`0x0`), but every DWORD this
    /// type writes (currently just `csmt`) is written as a plain decimal
    /// string via `addDWORD`, so a `REG_DWORD` hex token is converted back
    /// to decimal here — otherwise a value this file itself just wrote
    /// would never compare equal to what was read back.
    private static func parseRegQueryValue(_ output: String, valueName: String) -> String? {
        for line in splitLines(output) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(valueName) else { continue }
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 3, let rawValue = parts.last else { continue }

            if parts[1] == "REG_DWORD", rawValue.hasPrefix("0x"), let intValue = UInt32(rawValue.dropFirst(2), radix: 16) {
                return String(intValue)
            }
            return rawValue
        }
        return nil
    }

    /// Splits `text` into lines, tolerating `\n`, `\r`, or `\r\n` endings.
    /// `String.split(separator: "\n")` alone is *not* safe for Wine's
    /// CRLF-terminated console output: Swift's `Character` (an extended
    /// grapheme cluster) treats `"\r\n"` as a single combined character
    /// distinct from a lone `"\n"`, so splitting a CRLF string on `"\n"`
    /// finds no matches at all and returns the whole string as one
    /// "line" — confirmed directly against this build's output. Stripping
    /// `\r` first sidesteps the grapheme-clustering entirely.
    private static func splitLines(_ text: String) -> [Substring] {
        text.replacingOccurrences(of: "\r", with: "").split(separator: "\n")
    }

    // MARK: - Benchmark hint

    /// Shown in the UI next to the Metal HUD toggle so users know how to
    /// actually compare presets rather than guessing from feel.
    static let benchmarkHint = """
    Turn on "Show Metal HUD" and relaunch the game — a small overlay in the corner reports live FPS and frame time. To compare presets fairly: run the same scene or in-game benchmark for each preset, and look at the steadiest FPS and the worst frame-time spikes (not just the peak FPS) — a flatter frame-time line feels smoother even at a lower average FPS.
    """

    // MARK: - reg add/delete helpers

    private static func addDWORD(_ key: String, _ name: String, _ value: String, bottle: Bottle, engine: InstalledEngine) async -> String? {
        await runRegAdd(key, name, value: value, type: "REG_DWORD", bottle: bottle, engine: engine)
    }

    private static func addString(_ key: String, _ name: String, _ value: String, bottle: Bottle, engine: InstalledEngine) async -> String? {
        await runRegAdd(key, name, value: value, type: "REG_SZ", bottle: bottle, engine: engine)
    }

    private static func runRegAdd(_ key: String, _ name: String, value: String, type: String, bottle: Bottle, engine: InstalledEngine) async -> String? {
        let result = await runCommand(
            engine.wineBinary,
            ["reg", "add", key, "/v", name, "/t", type, "/d", value, "/f"],
            bottle: bottle, engine: engine
        )
        guard result.status == 0 else {
            return "\(name): \(lastLine(of: result.stderr))"
        }
        return nil
    }

    /// Deletes a value so its absence reverts to the Wine/macOS driver
    /// default. Best-effort: `reg delete` on a value that was never set
    /// normally exits non-zero, which is the expected/common case here,
    /// not a real failure — so errors are silently ignored.
    private static func deleteValue(_ key: String, _ name: String, bottle: Bottle, engine: InstalledEngine) async {
        _ = await runCommand(
            engine.wineBinary, ["reg", "delete", key, "/v", name, "/f"],
            bottle: bottle, engine: engine
        )
    }

    private static func lastLine(of text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "(no output)" }
        return splitLines(trimmed).last.map(String.init) ?? trimmed
    }

    // MARK: - Process execution (file-backed, not pipe-backed — see the enum's doc comment)

    /// Runs `executable` with `args` under `bottle`'s Wine environment,
    /// waiting only for the *direct* child to terminate — never for a
    /// pipe EOF that an auto-spawned `wineserver` might hold open
    /// indefinitely. Output is captured via temp files instead of `Pipe`s
    /// for exactly that reason.
    private static func runCommand(_ executable: URL, _ args: [String], bottle: Bottle, engine: InstalledEngine) async -> CommandResult {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = args
            process.environment = WineRunner.environment(for: bottle, engine: engine)
            process.currentDirectoryURL = bottle.prefixDir
            process.standardInput = FileHandle.nullDevice

            let tmp = FileManager.default.temporaryDirectory
            let token = UUID().uuidString
            let stdoutURL = tmp.appendingPathComponent("overpass-perftuner-\(token)-out.log")
            let stderrURL = tmp.appendingPathComponent("overpass-perftuner-\(token)-err.log")
            FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
            FileManager.default.createFile(atPath: stderrURL.path, contents: nil)

            guard
                let stdoutHandle = try? FileHandle(forWritingTo: stdoutURL),
                let stderrHandle = try? FileHandle(forWritingTo: stderrURL)
            else {
                continuation.resume(returning: CommandResult(status: -1, stdout: "", stderr: "couldn't open temp output files"))
                return
            }
            process.standardOutput = stdoutHandle
            process.standardError = stderrHandle

            process.terminationHandler = { finished in
                try? stdoutHandle.close()
                try? stderrHandle.close()
                let stdout = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
                let stderrText = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
                try? FileManager.default.removeItem(at: stdoutURL)
                try? FileManager.default.removeItem(at: stderrURL)
                continuation.resume(returning: CommandResult(status: finished.terminationStatus, stdout: stdout, stderr: stderrText))
            }

            do {
                try process.run()
            } catch {
                try? stdoutHandle.close()
                try? stderrHandle.close()
                try? FileManager.default.removeItem(at: stdoutURL)
                try? FileManager.default.removeItem(at: stderrURL)
                continuation.resume(returning: CommandResult(status: -1, stdout: "", stderr: error.localizedDescription))
            }
        }
    }
}
