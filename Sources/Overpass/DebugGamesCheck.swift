import Foundation

/// Headless smoke test: `Overpass --check-games <bottle-name>` (see
/// `DebugCheck.swift`/`DebugInstallCheck.swift` for the pattern this
/// follows). Runs `GameLibrary.scan` against a real bottle's `drive_c` and
/// prints every discovered game's name, store, appid, size, and launch
/// command, then runs `KeyValues`'s self-test against a synthetic
/// `steamapps` tree (never written into the real bottle) and exits
/// non-zero if either step fails.
enum DebugGamesCheck {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let idx = args.firstIndex(of: "--check-games") else { return }
        guard idx + 1 < args.count, !args[idx + 1].hasPrefix("--") else {
            print("CHECK-GAMES FAILED: --check-games needs a bottle name, e.g. --check-games Steam")
            exit(1)
        }
        let bottleName = args[idx + 1]

        // `GameLibrary.scan` isn't `@MainActor` (it's a plain
        // `Task.detached`), so — unlike `DebugInstallCheck` — the simple
        // `DispatchSemaphore` + blocking `.wait()` pattern from
        // `DebugCheck` is safe to reuse here: nothing in this path ever
        // needs to hop onto the main actor.
        let semaphore = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0
        Task.detached {
            do {
                try await selfTestKeyValuesParser()
                try await run(bottleName: bottleName)
                print("CHECK-GAMES OK")
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                print("CHECK-GAMES FAILED: \(message)")
                exitCode = 1
            }
            semaphore.signal()
        }
        semaphore.wait()
        exit(exitCode)
    }

    private static func log(_ s: String) { print("[check-games] \(s)"); fflush(stdout) }

    private static func run(bottleName: String) async throws {
        try Paths.ensureAll()

        let bottles = BottleStore.loadAll()
        guard let bottle = bottles.first(where: { $0.name.caseInsensitiveCompare(bottleName) == .orderedSame }) else {
            let known = bottles.map(\.name).joined(separator: ", ")
            throw NSError(domain: "check-games", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "no bottle named \"\(bottleName)\". Known bottles: \(known)",
            ])
        }
        log("bottle: \(bottle.name) (\(bottle.id)) at \(bottle.prefixDir.path)")

        let games = await GameLibrary.scan(bottle: bottle)
        log("games found: \(games.count)")
        for game in games {
            let sizeString = game.sizeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "unknown size"
            let launchCommand = game.launchExe.map { exe -> String in
                game.launchArgs.isEmpty ? exe.path : "\(exe.path) \(game.launchArgs)"
            } ?? "(no launch exe found)"
            log("  - \(game.name) [\(game.store.displayName)] appid=\(game.appID ?? "-") size=\(sizeString) launch=\(launchCommand)")
        }
    }

    /// Builds a synthetic `steamapps` directory (TF2's real appid, 440,
    /// plus the Steamworks Common Redistributables tool entry, 228980)
    /// under a throwaway temp `drive_c`, runs `GameLibrary.scan` against
    /// it, and asserts TF2 is listed while the redistributable is
    /// filtered out. Never touches the real Steam bottle. Throws (rather
    /// than `assert`-trapping like `ProgramScanner._selfTest`) so
    /// `--check-games` can report failure through its normal exit-code
    /// path instead of crashing the process.
    private static func selfTestKeyValuesParser() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("OverpassGamesSelfTest-\(UUID().uuidString)", isDirectory: true)
        let driveC = root.appendingPathComponent("drive_c", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let steamDir = driveC.appendingPathComponent("Program Files (x86)/Steam", isDirectory: true)
        let steamappsDir = steamDir.appendingPathComponent("steamapps", isDirectory: true)
        try fm.createDirectory(at: steamappsDir, withIntermediateDirectories: true)
        // Steam.exe itself needs to exist for scanSteam to even look at
        // this drive_c as a Steam install.
        fm.createFile(atPath: steamDir.appendingPathComponent("Steam.exe").path, contents: Data())

        let tf2Manifest = #"""
        "AppState"
        {
        	"appid"		"440"
        	"Universe"		"1"
        	"name"		"Team Fortress 2"
        	"StateFlags"		"4"
        	"installdir"		"Team Fortress 2"
        	"LastUpdated"		"1700000000"
        	"SizeOnDisk"		"18234567890"
        	"UserConfig"
        	{
        		"language"		"english"
        	}
        }
        """#
        try tf2Manifest.write(
            to: steamappsDir.appendingPathComponent("appmanifest_440.acf"),
            atomically: true, encoding: .utf8
        )

        let redistManifest = #"""
        "AppState"
        {
        	"appid"		"228980"
        	"Universe"		"1"
        	"name"		"Steamworks Common Redistributables"
        	"StateFlags"		"4"
        	"installdir"		"Steamworks Shared"
        	"SizeOnDisk"		"123456"
        }
        """#
        try redistManifest.write(
            to: steamappsDir.appendingPathComponent("appmanifest_228980.acf"),
            atomically: true, encoding: .utf8
        )

        // A not-fully-installed entry (StateFlags missing the 0x4 bit)
        // should also be skipped.
        let pendingManifest = #"""
        "AppState"
        {
        	"appid"		"570"
        	"name"		"Dota 2"
        	"StateFlags"		"2"
        }
        """#
        try pendingManifest.write(
            to: steamappsDir.appendingPathComponent("appmanifest_570.acf"),
            atomically: true, encoding: .utf8
        )

        let games = await GameLibrary.scan(driveC: driveC)

        func check(_ condition: Bool, _ message: String) throws {
            log(condition ? "OK: \(message)" : "FAIL: \(message)")
            guard condition else {
                throw NSError(domain: "check-games", code: 2, userInfo: [NSLocalizedDescriptionKey: "self-test failed: \(message)"])
            }
        }

        try check(games.contains { $0.name == "Team Fortress 2" && $0.appID == "440" }, "TF2 (appid 440) is listed")
        try check(!games.contains { $0.appID == "228980" }, "Steamworks Common Redistributables (228980) is filtered out")
        try check(!games.contains { $0.appID == "570" }, "not-fully-installed entry (StateFlags 2) is filtered out")
        if let tf2 = games.first(where: { $0.appID == "440" }) {
            try check(tf2.sizeBytes == 18_234_567_890, "TF2 size parsed correctly, got \(tf2.sizeBytes.map(String.init) ?? "nil")")
            try check(tf2.launchArgs == "-applaunch 440", "TF2 launch args are \"-applaunch 440\", got \"\(tf2.launchArgs)\"")
        }
    }
}
