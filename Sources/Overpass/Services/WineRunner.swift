import Foundation

/// Builds the environment a bottle runs Wine under, and launches/stops
/// Wine processes inside it. Everything here is `nonisolated` (a plain
/// enum, not an actor or `@MainActor` type) — callers on `AppState`
/// (`@MainActor`) `await` these `async` functions, which suspend on I/O via
/// `Process` pipe/termination callbacks rather than blocking a thread;
/// `launch`/`launchTool` themselves are synchronous (`Process.run()` just
/// forks/execs) and return the still-running `Process` for the caller to
/// watch.
enum WineRunner {
    struct Result: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    struct ToolError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - Environment

    /// The environment a bottle's Wine processes launch with. See PLAN.md
    /// §6 "Bottle environment" — order matters only in that `bottle.env`
    /// is merged last so user overrides always win.
    static func environment(for bottle: Bottle, engine: InstalledEngine) -> [String: String] {
        var env: [String: String] = [:]
        env["WINEPREFIX"] = bottle.prefixDir.path
        env["PATH"] = "\(engine.binDir.path):/usr/bin:/bin"
        env["WINEDEBUG"] = bottle.verboseLog ? "fixme-all" : "-all"
        if bottle.esync { env["WINEESYNC"] = "1" }
        if bottle.msync { env["WINEMSYNC"] = "1" }
        if bottle.metalHUD { env["MTL_HUD_ENABLED"] = "1" }
        // Needed by GPTK to load D3DMetal; harmless for plain Wine-staging.
        env["DYLD_FALLBACK_LIBRARY_PATH"] = "\(engine.libDir.path):\(engine.libDir.path)/external"
        if bottle.dxvk {
            env["WINEDLLOVERRIDES"] = "d3d9,d3d10core,d3d11,dxgi=n,b"
        }

        let processEnv = ProcessInfo.processInfo.environment
        if let home = processEnv["HOME"] { env["HOME"] = home }
        if let user = processEnv["USER"] { env["USER"] = user }
        env["TMPDIR"] = NSTemporaryDirectory()

        if let perf = bottle.performance {
            for (key, value) in PerformanceSettings.environment(for: perf, bottle: bottle, engine: engine) { env[key] = value }
        }
        for (key, value) in bottle.env { env[key] = value }
        return env
    }

    // MARK: - Running a tool to completion

    /// Runs `toolPath` with `args` under the bottle's environment, waiting
    /// for it to finish and returning its captured output. If `logURL` is
    /// given, stdout+stderr are also appended to it as they stream.
    static func runTool(
        _ toolPath: URL,
        _ args: [String],
        bottle: Bottle,
        engine: InstalledEngine,
        logURL: URL? = nil
    ) async throws -> Result {
        let r = try await ProcessRunner.run(
            toolPath, args,
            environment: environment(for: bottle, engine: engine),
            currentDirectory: bottle.prefixDir,
            logURL: logURL
        )
        return Result(status: r.status, stdout: r.stdout, stderr: r.stderr)
    }

    // MARK: - Launching a detached, streaming process

    /// Shared launch path for `launch` and `launchTool`: starts `executable`
    /// with `arguments`/`environment`, streams stdout+stderr into `logURL`
    /// as they arrive (same continuous-drain reasoning as `runTool` above,
    /// minus the "wait for it to finish" part — the caller gets the running
    /// `Process` back immediately), and returns without waiting for exit.
    private static func spawnStreaming(
        executable: URL,
        arguments: [String],
        environment env: [String: String],
        currentDirectory: URL,
        logURL: URL
    ) throws -> Process {
        try ProcessRunner.spawn(executable, arguments, environment: env, currentDirectory: currentDirectory, logURL: logURL)
    }

    /// Launches `exe` (or, for `.msi`, runs it through `msiexec /i`) inside
    /// `bottle`, working directory set to the exe's own folder. Returns the
    /// running `Process` immediately; the caller watches `isRunning`/exit
    /// via `Process.waitUntilExit()` on a background task, never on the
    /// main actor.
    static func launch(exe: URL, args: String, bottle: Bottle, engine: InstalledEngine, logURL: URL) throws -> Process {
        let parsedArgs = splitArguments(args)
        let arguments: [String]
        if exe.pathExtension.lowercased() == "msi" {
            arguments = ["msiexec", "/i", exe.path] + parsedArgs
        } else {
            arguments = ["start", "/unix", exe.path] + parsedArgs
        }
        return try spawnStreaming(
            executable: engine.wineBinary,
            arguments: arguments,
            environment: environment(for: bottle, engine: engine),
            currentDirectory: exe.deletingLastPathComponent(),
            logURL: logURL
        )
    }

    /// Launches a built-in Wine tool by name (`winecfg`, `regedit`,
    /// `explorer`, `taskmgr`, ...) through the wine loader directly, not
    /// via `start /unix`. Used by `AppState.runTool(name:in:)`.
    static func launchTool(name: String, bottle: Bottle, engine: InstalledEngine, logURL: URL) throws -> Process {
        try spawnStreaming(
            executable: engine.wineBinary,
            arguments: [name],
            environment: environment(for: bottle, engine: engine),
            currentDirectory: bottle.driveC,
            logURL: logURL
        )
    }

    /// Splits a shell-ish argument string on whitespace, respecting simple
    /// `"..."`/`'...'` quoting (no escapes, no nesting) — enough for the
    /// per-run and per-pin argument fields in the UI.
    static func splitArguments(_ string: String) -> [String] {
        var args: [String] = []
        var current = ""
        var quote: Character?

        for ch in string {
            if let openQuote = quote {
                if ch == openQuote {
                    quote = nil
                } else {
                    current.append(ch)
                }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch.isWhitespace {
                if !current.isEmpty {
                    args.append(current)
                    current = ""
                }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { args.append(current) }
        return args
    }

    // MARK: - Stopping a bottle

    /// `wineserver -k`, wait 3s, `-k9` if anything's still alive, then
    /// `pkill -9 -f <prefix>` as a last resort.
    static func stop(bottle: Bottle, engine: InstalledEngine) async {
        _ = try? await runTool(engine.wineserverBinary, ["-k"], bottle: bottle, engine: engine)

        try? await Task.sleep(nanoseconds: 3_000_000_000)
        if await stillRunning(bottle) {
            _ = try? await runTool(engine.wineserverBinary, ["-k9"], bottle: bottle, engine: engine)
        }
        if await stillRunning(bottle) {
            _ = try? await ShellRunner.run("/usr/bin/pkill", ["-9", "-f", bottle.prefixDir.path])
        }
    }

    private static func stillRunning(_ bottle: Bottle) async -> Bool {
        guard let result = try? await ShellRunner.run("/usr/bin/pgrep", ["-f", bottle.prefixDir.path]) else {
            return false
        }
        return result.status == 0
    }

    // MARK: - Prefix creation / config

    /// `wineboot -i` to materialize a fresh `WINEPREFIX`, then applies the
    /// bottle's Windows version. `status` is called on whatever queue the
    /// underlying process callbacks land on — callers hop back to the main
    /// actor themselves before touching UI state.
    static func createPrefix(
        bottle: Bottle,
        engine: InstalledEngine,
        status: @escaping @Sendable (String) -> Void
    ) async throws {
        status("Initializing Windows prefix…")
        // GPTK ships only wine64/wineserver in bin (no wineboot script), so
        // always go through the loader.
        let bootResult = try await runTool(engine.wineBinary, ["wineboot", "-i"], bottle: bottle, engine: engine)
        guard bootResult.status == 0 else {
            throw ToolError(message: "wineboot failed: \(lastLines(of: bootResult.stderr))")
        }

        status("Setting Windows version…")
        try await applyWindowsVersion(bottle.windowsVersion, bottle: bottle, engine: engine)
    }

    /// Runs `winecfg -v <version>` through the wine loader (`wine64
    /// winecfg -v ...`) rather than the `winecfg` shell script directly —
    /// more robust under Rosetta, and shares the same environment builder
    /// as everything else here.
    static func applyWindowsVersion(_ version: WindowsVersion, bottle: Bottle, engine: InstalledEngine) async throws {
        let result = try await runTool(engine.wineBinary, ["winecfg", "-v", version.winecfgValue], bottle: bottle, engine: engine)
        guard result.status == 0 else {
            throw ToolError(message: "winecfg failed: \(lastLines(of: result.stderr))")
        }
    }

    private static func lastLines(of text: String, count: Int = 20) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "(no output)" }
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(count).joined(separator: "\n")
    }
}
