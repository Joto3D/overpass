import Foundation

/// A small, declarative "fix" applied to a bottle for one `CatalogApp` —
/// registry keys, winetricks verbs, a forced Windows version, and/or
/// launch arguments a particular Windows program needs to run under Wine.
/// Not every catalog app needs one; `CatalogApp.tweak` is `nil` unless a
/// specific, documented workaround exists for that app.
///
/// `GameFix` generalises this type: it is an `AppTweak` plus the matching
/// criteria (which executables it applies to) and identity, so fixes can
/// be applied at launch time and extended from JSON. The Steam recipe
/// discussed below now lives in `GameFixCatalog.steam`, the single source
/// of truth; the research notes stay here because they explain *why* that
/// recipe looks the way it does.
///
/// ## Where the Steam recipe below comes from
///
/// CrossOver 26.3 (`/Applications/CrossOver.app`) ships a profile for
/// Steam in its own app database,
/// `Contents/SharedSupport/CrossOver/share/crossover/data/crossover.tie`
/// (appid `com.codeweavers.c4.206`, `<name>Steam</name>`). As shipped, it
/// applies:
///   - Bottle template `win7`/`win7_64` (Windows 7, not 10)
///   - Dependencies: Core Fonts (`corefonts`), Microsoft XML Parser 3.0
///     (`msxml3`), an Asian Fonts Component, and "DirectX for
///     Pre-Windows XP Games"
///   - Registry: `HKCU\Software\Valve\Steam\DWriteEnable` = `0` (DWORD),
///     disabling Steam's DirectWrite text rendering
/// Historical entries in the same file, since removed by CodeWeavers,
/// also set `AppDefaults\steam.exe\Version` = `winxp`, a
/// `LargeAddressAware` override for steamwebhelper, and
/// `GPUAccelWebViews` = `0`.
///
/// ## What Overpass actually verified by hand (2026-09-07)
///
/// Against a from-scratch Wine Staging 11.16 prefix (Overpass engine
/// "wine-staging-11.16") with Steam installed, launched the same way
/// `WineRunner.launch` does (`wine explorer /desktop=Steam,1280x800
/// "...\steam.exe" -allosarches -cef-disable-gpu
/// -cef-disable-gpu-compositing`):
///
///   - **Baseline** (no tweaks): steamwebhelper crashed immediately —
///     Wine's own crash dialog, "The program steamwebhelper.exe has
///     encountered a serious problem and needs to close."
///   - `winetricks corefonts` + `DWriteEnable=0`: **still crashed**,
///     identical dialog.
///   - Adding `winetricks msxml3` on top: **still crashed**.
///   - Switching the whole bottle to Windows 7 (`winecfg -v win7`):
///     **worse** — Steam downloaded a different, older `cef.win7x64`
///     helper build that crash-looped repeatedly (`startcount`
///     incrementing on each relaunch) and even produced a `steam.exe`
///     assert dump, rather than cleanly hitting the "not responding"
///     dialog. Reverted back to Windows 10.
///   - Adding the historical fallbacks — `GPUAccelWebViews=0`,
///     `AppDefaults\steamwebhelper.exe\Version=win7`,
///     `AppDefaults\steamwebhelper.exe\LargeAddressAware=1` — tried both
///     together and individually, on top of everything above: **still
///     crashed**, same dialog every time. The `Version=win7` per-exe
///     override at one point even crashed `steam.exe` itself instead of
///     steamwebhelper.
///
/// So: **this recipe does not fix the crash**, at least not against the
/// current Steam client build (buildid 1788652215) on Gcenx's Wine
/// Staging 11.16. It's still wired up here — applied automatically,
/// documented honestly in `AppCatalog`'s Steam entry — because every
/// piece of it (fonts, an XML parser, a text-rendering registry flag) is
/// cheap and harmless even when it doesn't help, matches what CrossOver
/// itself ships, and may matter for other Steam client builds or engine
/// combinations Overpass hasn't tested. `windowsVersion` is deliberately
/// left `nil` here (not `.win7`) since switching Windows version was
/// verified to make things *worse*, not better.
struct AppTweak: Hashable, Sendable {
    /// `Codable` so `GameFix` — which carries these verbatim — can be
    /// expressed as JSON on disk rather than only as Swift.
    struct RegistryEntry: Codable, Hashable, Sendable {
        let key: String
        let name: String
        let type: String
        let data: String
    }

    var registry: [RegistryEntry] = []
    var winetricks: [String] = []
    var windowsVersion: WindowsVersion? = nil
    var launchArgs: String? = nil

    struct TweakError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Applies `tweak` to `bottle`: optional Windows-version switch,
    /// winetricks verbs (in order), then every registry write, each
    /// step reported through `progress`. Best-effort on the registry
    /// writes (one failure doesn't stop the rest) but throws a single
    /// summarizing error if any step failed; a winetricks or Windows-
    /// version failure throws immediately since later steps may depend
    /// on it having succeeded.
    static func apply(
        _ tweak: AppTweak,
        to bottle: Bottle,
        engine: InstalledEngine,
        progress: @escaping @Sendable (String) -> Void
    ) async throws {
        if let windowsVersion = tweak.windowsVersion, windowsVersion != bottle.windowsVersion {
            progress("Setting Windows version to \(windowsVersion.displayName)…")
            try await WineRunner.applyWindowsVersion(windowsVersion, bottle: bottle, engine: engine)
        }

        for verb in tweak.winetricks {
            progress("Installing \(verb) via winetricks…")
            try await Winetricks.run(verb: verb, bottle: bottle, engine: engine) { line in
                progress(line)
            }
        }

        guard !tweak.registry.isEmpty else { return }

        var failures: [String] = []

        // One persistent wineserver for the whole batch of `reg add`
        // calls, exactly as `PerformanceTuner.applyRegistry` does and for
        // the same reason (see that type's doc comment in detail): a
        // `wine reg` call that can't reach an already-running wineserver
        // for this prefix spawns its own, and that auto-spawned server —
        // not this batch's explicit `-p`/`-k` pair — can hold the next
        // call's stdout pipe open well past its own exit, so
        // `WineRunner.runTool`/`ProcessRunner.run` (which wait for pipe
        // EOF, not just process exit) can hang forever. `runCommand`
        // below sidesteps the pipe-EOF problem entirely by capturing
        // output through temp files instead — same fix, same reasoning,
        // duplicated here rather than shared because `PerformanceTuner`'s
        // copy is private to that file.
        _ = await runCommand(engine.wineserverBinary, ["-p"], bottle: bottle, engine: engine)

        for entry in tweak.registry {
            progress("Setting \(entry.key)\\\(entry.name) = \(entry.data)…")
            let result = await runCommand(
                engine.wineBinary,
                ["reg", "add", entry.key, "/v", entry.name, "/t", entry.type, "/d", entry.data, "/f"],
                bottle: bottle, engine: engine
            )
            if result.status != 0 {
                failures.append("\(entry.key)\\\(entry.name): \(lastLine(of: result.stderr))")
            }
        }

        // Shut the persistent server back down, forcing its save to
        // disk — see `PerformanceTuner.applyRegistry`'s doc comment for
        // why this matters even though it looks redundant.
        _ = await runCommand(engine.wineserverBinary, ["-k"], bottle: bottle, engine: engine)

        if !failures.isEmpty {
            throw TweakError(message: failures.joined(separator: "; "))
        }
    }

    // MARK: - Process execution (file-backed, mirrors PerformanceTuner.runCommand)

    private struct CommandResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

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
            let stdoutURL = tmp.appendingPathComponent("overpass-apptweak-\(token)-out.log")
            let stderrURL = tmp.appendingPathComponent("overpass-apptweak-\(token)-err.log")
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

    private static func lastLine(of text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "(no output)" }
        let lines = trimmed.replacingOccurrences(of: "\r", with: "").split(separator: "\n")
        return lines.last.map(String.init) ?? trimmed
    }
}

/// Per-app tweaks, keyed by `CatalogApp.id`. Kept separate from
/// `AppCatalog.apps` itself (rather than as a stored property there)
/// only for the Steam entry so far — see `AppTweaks.steam`'s doc comment
/// — but `CatalogApp.tweak` is the actual attachment point new entries
/// should use directly. The per-game fix database that applies at launch
/// time is `GameFixCatalog`; this enum only bridges the catalog's
/// install-time attachment point to it.
enum AppTweaks {
    /// The CrossOver-derived Steam recipe. `GameFixCatalog.steam` is the
    /// single source of truth — this reads from it rather than repeating
    /// the registry/winetricks lists, so the catalog's install-time tweak
    /// (`CatalogApp.tweak`) and the launch-time fix (`GameFixService`) can
    /// never drift apart (`DebugSelfTest` guards that they stay equal).
    /// See `AppTweak`'s doc comment for the full CrossOver source and the
    /// by-hand verification (**did not fix the crash**) this is based on.
    static let steam = GameFixCatalog.steam.tweak
}
