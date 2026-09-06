import Foundation

/// Applies (and reads back) the registry-backed half of `PerformanceSettings`
/// — the fields `PerformanceSettings.environment(for:bottle:engine:)`
/// doesn't cover because they're Wine registry keys, not environment
/// variables. Every command runs through `WineRunner.runTool` against the
/// wine loader (`wine64 reg add|delete|query ...`) so it shares the
/// bottle's environment (WINEPREFIX, PATH, ...).
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

    // MARK: - Apply

    /// Writes every registry-backed knob in `settings`, best-effort per
    /// key (a failure on one key doesn't stop the rest), then throws a
    /// single `RegistryError` summarizing every failure if any occurred.
    static func applyRegistry(settings: PerformanceSettings, bottle: Bottle, engine: InstalledEngine) async throws {
        var failures: [String] = []

        // Direct3D: csmt (DWORD). Disabling writes 0; enabling deletes the
        // value so the Wine build's own default (on) applies.
        if settings.disableCSMT {
            if let failure = await addDWORD(direct3DKey, "csmt", "0", bottle: bottle, engine: engine) {
                failures.append(failure)
            }
        } else {
            await deleteValue(direct3DKey, "csmt", bottle: bottle, engine: engine)
        }

        // Direct3D: VideoMemorySize (REG_SZ, megabytes).
        if let vram = settings.videoMemorySize, !vram.trimmingCharacters(in: .whitespaces).isEmpty {
            if let failure = await addString(direct3DKey, "VideoMemorySize", vram, bottle: bottle, engine: engine) {
                failures.append(failure)
            }
        } else {
            await deleteValue(direct3DKey, "VideoMemorySize", bottle: bottle, engine: engine)
        }

        // Direct3D: renderer (REG_SZ "gl"/"vulkan").
        if let renderer = settings.renderer {
            if let failure = await addString(direct3DKey, "renderer", renderer.rawValue, bottle: bottle, engine: engine) {
                failures.append(failure)
            }
        } else {
            await deleteValue(direct3DKey, "renderer", bottle: bottle, engine: engine)
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
            if let failure = await addString(macDriverKey, name, isOn ? "Y" : "N", bottle: bottle, engine: engine) {
                failures.append(failure)
            }
        }

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
            guard let result = try? await WineRunner.runTool(
                engine.wineBinary, ["reg", "query", query.key, "/v", query.name],
                bottle: bottle, engine: engine
            ), result.status == 0 else { continue }

            if let value = parseRegQueryValue(result.stdout, valueName: query.name) {
                values["\(query.key)\\\(query.name)"] = value
            }
        }
        return values
    }

    /// `wine reg query <key> /v <name>` prints a line like
    /// `    csmt    REG_DWORD    0x0` (or `REG_SZ` with a plain string
    /// value) among some header/blank lines. Finds that line and returns
    /// its last whitespace-separated token.
    private static func parseRegQueryValue(_ output: String, valueName: String) -> String? {
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(valueName) else { continue }
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 3 else { continue }
            return parts.last
        }
        return nil
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
        do {
            let result = try await WineRunner.runTool(
                engine.wineBinary,
                ["reg", "add", key, "/v", name, "/t", type, "/d", value, "/f"],
                bottle: bottle, engine: engine
            )
            guard result.status == 0 else {
                return "\(name): \(lastLine(of: result.stderr))"
            }
            return nil
        } catch {
            return "\(name): \(error.localizedDescription)"
        }
    }

    /// Deletes a value so its absence reverts to the Wine/macOS driver
    /// default. Best-effort: `reg delete` on a value that was never set
    /// normally exits non-zero, which is the expected/common case here,
    /// not a real failure — so errors are silently ignored.
    private static func deleteValue(_ key: String, _ name: String, bottle: Bottle, engine: InstalledEngine) async {
        _ = try? await WineRunner.runTool(
            engine.wineBinary, ["reg", "delete", key, "/v", name, "/f"],
            bottle: bottle, engine: engine
        )
    }

    private static func lastLine(of text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "(no output)" }
        return trimmed.split(separator: "\n").last.map(String.init) ?? trimmed
    }
}
