import Foundation

/// `Overpass --self-test`: pure, offline unit checks (no Wine, no network).
/// Every service under test here (`ShellLink`, `ProgramScanner`,
/// `WineRunner`, `PerformanceSettings`, `AppCatalog`, `EngineCatalog`,
/// `BottleStore`'s codec, `LogStore`) is a plain `enum`/`struct`, not
/// `@MainActor` — so this runs synchronously on the main thread, before any
/// UI is created, the same way `DebugCheck`/`DebugPerfCheck` do (see those
/// files), just without needing a semaphore since nothing here is async
/// except `ProgramScanner.scan`, which is bridged with `runSync` below.
///
/// Filesystem cases use a scratch directory under
/// `FileManager.default.temporaryDirectory`, removed when the run finishes.
/// Two cases unavoidably touch the real
/// `~/Library/Application Support/Overpass` tree because the code under
/// test hard-codes those locations (`Bottle.driveC`/`.prefixDir` via
/// `Paths.bottleDir(id)`, `LogStore.newLogURL` via `Paths.logs`) with no
/// injectable override — both use a throwaway, randomly-generated id and
/// delete what they created via `defer` before returning.
enum DebugSelfTest {
    private static var passCount = 0
    private static var failCount = 0

    static func runIfRequested() {
        guard CommandLine.arguments.contains("--self-test") else { return }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("overpass-selftest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        testShellLink(root: root)
        testProgramScannerScan()
        testProgramScannerMerge(root: root)
        testProgramScannerMigrationDedupe(root: root)
        testProgramScannerCatalogDefaultsAndNaming()
        testWineRunnerEnvironment(root: root)
        testWineRunnerSplitArguments()
        testPerformanceSettings(root: root)
        testAppCatalog()
        testEngineCatalog()
        testBottleCodable()
        testLogStore(root: root)

        print("\n\(passCount) passed, \(failCount) failed")
        fflush(stdout)
        exit(failCount == 0 ? 0 : 1)
    }

    // MARK: - Harness

    private static func check(_ name: String, _ condition: @autoclosure () -> Bool, _ detail: String = "") {
        if condition() {
            passCount += 1
            print("PASS  \(name)")
        } else {
            failCount += 1
            print("FAIL  \(name)" + (detail.isEmpty ? "" : "  — \(detail)"))
        }
        fflush(stdout)
    }

    /// Bridges a single `async` call onto this synchronous entry point.
    /// Nothing under test here is `@MainActor`, so a plain semaphore (no
    /// run-loop pumping needed) is safe — same shape as
    /// `DebugCheck.runIfRequested`'s `Task.detached` + `semaphore.wait()`.
    private final class ResultBox<T>: @unchecked Sendable {
        var value: T?
    }

    private static func runSync<T: Sendable>(_ operation: @escaping @Sendable () async -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task.detached {
            box.value = await operation()
            semaphore.signal()
        }
        semaphore.wait()
        return box.value!
    }

    // MARK: - Synthetic .lnk byte builder

    private static func u32le(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
    private static func u16le(_ v: UInt16) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }

    /// Builds a minimal but well-formed `.lnk` byte buffer: a 76-byte
    /// header with `LinkFlags = HasLinkInfo | HasArguments`, a `LinkInfo`
    /// block whose `LocalBasePath` is `target` (ANSI, since `IsUnicode` is
    /// left unset), and a `COMMAND_LINE_ARGUMENTS` StringData block
    /// carrying `arguments` (also ANSI). See `ShellLink.swift`'s header
    /// comment for the full layout this mirrors.
    private static func buildLnk(target: String, arguments: String) -> Data {
        var data = Data()
        data.append(contentsOf: u32le(76))                          // HeaderSize
        data.append(contentsOf: [UInt8](repeating: 0, count: 16))    // LinkCLSID
        let flags: UInt32 = 0x0000_0002 | 0x0000_0020                // HasLinkInfo | HasArguments
        data.append(contentsOf: u32le(flags))                        // offset 20
        data.append(contentsOf: [UInt8](repeating: 0, count: 76 - data.count)) // pad to 76

        let targetBytes = Array(target.utf8) + [0]
        let linkInfoHeaderSize: UInt32 = 28
        let localBasePathOffset: UInt32 = 28
        let linkInfoSize = UInt32(28 + targetBytes.count)
        var linkInfo = Data()
        linkInfo.append(contentsOf: u32le(linkInfoSize))             // start+0  LinkInfoSize
        linkInfo.append(contentsOf: u32le(linkInfoHeaderSize))       // start+4  LinkInfoHeaderSize
        linkInfo.append(contentsOf: u32le(1))                        // start+8  LinkInfoFlags (VolumeIDAndLocalBasePath)
        linkInfo.append(contentsOf: u32le(28))                       // start+12 VolumeIDOffset (unused by the parser)
        linkInfo.append(contentsOf: u32le(localBasePathOffset))      // start+16 LocalBasePathOffset
        linkInfo.append(contentsOf: u32le(0))                        // start+20 CommonNetworkRelativeLinkOffset
        linkInfo.append(contentsOf: u32le(0))                        // start+24 CommonPathSuffixOffset
        linkInfo.append(contentsOf: targetBytes)                     // start+28 NUL-terminated ANSI LocalBasePath
        data.append(linkInfo)

        let argBytes = Array(arguments.utf8)
        data.append(contentsOf: u16le(UInt16(argBytes.count)))
        data.append(contentsOf: argBytes)
        return data
    }

    // MARK: - ShellLink

    private static func testShellLink(root: URL) {
        let target = "C:\\Program Files\\Foo\\foo.exe"
        let arguments = "-x \"a b\""
        let lnkData = buildLnk(target: target, arguments: arguments)
        let lnkURL = root.appendingPathComponent("test.lnk")
        try? lnkData.write(to: lnkURL)

        let parsed = ShellLink.parse(lnkURL)
        check("ShellLink.parse target", parsed?.target == target, "got \(parsed?.target ?? "nil")")
        check("ShellLink.parse arguments", parsed?.arguments == arguments, "got \(parsed?.arguments ?? "nil")")

        // Truncated buffer (well short of even the 76-byte header) must not
        // crash and must return nil.
        let truncatedURL = root.appendingPathComponent("truncated.lnk")
        try? lnkData.prefix(40).write(to: truncatedURL)
        check("ShellLink.parse truncated buffer -> nil", ShellLink.parse(truncatedURL) == nil)

        // windowsPathToUnix: case-insensitive resolution against a real
        // drive_c tree.
        let driveC = root.appendingPathComponent("drive_c", isDirectory: true)
        let exeDir = driveC.appendingPathComponent("Program Files/Foo", isDirectory: true)
        try? FileManager.default.createDirectory(at: exeDir, withIntermediateDirectories: true)
        let exeURL = exeDir.appendingPathComponent("foo.exe")
        try? Data().write(to: exeURL)

        let resolved = ShellLink.windowsPathToUnix("C:\\PROGRAM FILES\\Foo\\FOO.EXE", driveC: driveC)
        check(
            "windowsPathToUnix resolves case-insensitively",
            resolved?.path.lowercased() == exeURL.path.lowercased(),
            "got \(resolved?.path ?? "nil"), want \(exeURL.path)"
        )

        let missing = ShellLink.windowsPathToUnix("C:\\Program Files\\Bar\\bar.exe", driveC: driveC)
        check("windowsPathToUnix missing file -> nil", missing == nil)
    }

    // MARK: - ProgramScanner.scan

    /// Exercises the real `ProgramScanner.scan(bottle:)` against a
    /// synthetic `drive_c`. `ProgramScanner` only accepts a `Bottle`, whose
    /// `driveC` is hard-coded to live under `Paths.bottleDir(id)` (real
    /// Application Support) — there's no injectable "scan this arbitrary
    /// URL" entry point. So this uses a `Bottle` with a fresh random id
    /// (never collides with a real bottle) and deletes everything it wrote
    /// via `defer`, the same trade-off the test brief explicitly allows for
    /// `LogStore.newLogURL` below.
    private static func testProgramScannerScan() {
        let fm = FileManager.default
        let bottle = Bottle(name: "selftest-scanner", engineID: "gptk-3.0-3")
        let driveC = bottle.driveC
        defer { try? fm.removeItem(at: bottle.prefixDir) }

        // Program Files exe, also targeted by a Start Menu .lnk with a
        // nicer display name -> dedupe-by-path should prefer the .lnk name.
        let gameDir = driveC.appendingPathComponent("Program Files/MyGame", isDirectory: true)
        try? fm.createDirectory(at: gameDir, withIntermediateDirectories: true)
        let gameExe = gameDir.appendingPathComponent("game.exe")
        try? Data().write(to: gameExe)

        let startMenuDir = driveC.appendingPathComponent(
            "ProgramData/Microsoft/Windows/Start Menu/Programs", isDirectory: true
        )
        try? fm.createDirectory(at: startMenuDir, withIntermediateDirectories: true)
        let lnkData = buildLnk(target: "C:\\Program Files\\MyGame\\game.exe", arguments: "")
        try? lnkData.write(to: startMenuDir.appendingPathComponent("My Game.lnk"))

        // Filtered scaffolding, sitting right next to the real program.
        try? Data().write(to: gameDir.appendingPathComponent("unins000.exe"))
        try? Data().write(to: gameDir.appendingPathComponent("vcredist_x64.exe"))

        // Nested Program Files exe, two directories deep (within the
        // depth-3 cap).
        let nestedDir = driveC.appendingPathComponent("Program Files/Other/Nested", isDirectory: true)
        try? fm.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        let nestedExe = nestedDir.appendingPathComponent("nested.exe")
        try? Data().write(to: nestedExe)

        // A bare .exe directly on the Desktop — not a .lnk and not under
        // Program Files, so scanSync's two loops (StringData `.lnk`-only
        // walk of the shortcut roots, `.exe`-only walk of the Program
        // Files roots) never visit it. Included to document that
        // behavior, not because it's expected to be found.
        let desktopDir = driveC.appendingPathComponent("users/Public/Desktop", isDirectory: true)
        try? fm.createDirectory(at: desktopDir, withIntermediateDirectories: true)
        let desktopExe = desktopDir.appendingPathComponent("DesktopApp.exe")
        try? Data().write(to: desktopExe)

        let scanned = runSync { await ProgramScanner.scan(bottle: bottle) }
        let byPath = Dictionary(uniqueKeysWithValues: scanned.map { ($0.exePath, $0) })

        check(
            "scan dedupes by path, preferring the .lnk name",
            byPath[gameExe.path]?.name == "My Game",
            "BUG: ProgramScanner.swift enumerate(_:in:maxDepth:) (line 155, `if lowerPath.contains(\"/windows/\") || ...`) "
                + "means to skip only the Wine system directory `drive_c/windows`, but the substring check also matches "
                + "any path that merely has a folder literally named \"Windows\" in it — including the real Windows Start "
                + "Menu locations this scanner is supposed to walk: `ProgramData/Microsoft/Windows/Start Menu/Programs` "
                + "and `<user>/AppData/Roaming/Microsoft/Windows/Start Menu/Programs`. Every .lnk under either path gets "
                + "enumerator.skipDescendants()'d away, so ProgramScanner.scan never finds Start Menu shortcuts at all — "
                + "only Desktop .lnk files and bare Program Files .exe files are ever discovered. "
                + "Expected exePath \"\(gameExe.path)\" to be named \"My Game\" (from the Start Menu shortcut); "
                + "got \"\(byPath[gameExe.path]?.name ?? "nil")\" (the bare .exe's filename), because the shortcut was never scanned."
        )
        // A sole non-helper exe in its folder is named after the folder
        // ("Notepad++/notepad++.exe" → "Notepad++"), so nested.exe → "Nested".
        check("scan finds nested Program Files exe", byPath[nestedExe.path]?.name == "Nested",
              "got \(byPath[nestedExe.path]?.name ?? "nil")")
        // Uninstallers/redistributables are no longer dropped; they're
        // returned flagged as helpers so the UI can hide them by default.
        check(
            "scan flags unins000.exe / vcredist_x64.exe as helpers",
            scanned.filter { $0.name.lowercased().contains("unins") || $0.name.lowercased().contains("vcredist") }
                .allSatisfy { $0.isHelper }
        )
        check(
            "scan does not surface a bare Desktop .exe (only .lnk shortcuts there are scanned)",
            byPath[desktopExe.path] == nil
        )
    }

    // MARK: - ProgramScanner.merge

    private static func testProgramScannerMerge(root: URL) {
        let userPin = PinnedProgram(name: "User Added", exePath: "/nonexistent/user.exe", args: "", isUserAdded: true)
        let previousPin = PinnedProgram(name: "Old Name", exePath: "/tmp/selftest/game.exe", args: "-custom-arg", isUserAdded: false)
        let freshPin = PinnedProgram(name: "New Scan Name", exePath: previousPin.exePath, args: "", isUserAdded: false)

        let merged = ProgramScanner.merge(scanned: [freshPin], existing: [userPin, previousPin])

        check(
            "merge keeps user-added pins",
            merged.contains { $0.exePath == userPin.exePath && $0.isUserAdded }
        )

        if let kept = merged.first(where: { $0.exePath == previousPin.exePath }) {
            check("merge keeps existing id for a rescanned path", kept.id == previousPin.id)
            check("merge keeps existing args for a rescanned path", kept.args == previousPin.args)
            check(
                "merge keeps existing name for a rescanned path",
                kept.name == previousPin.name,
                "BUG: ProgramScanner.swift merge(scanned:existing:) (around line 43, `kept.name = fresh.name`) "
                    + "overwrites the existing pin's name with the fresh scan's name instead of keeping it. "
                    + "Expected name \"\(previousPin.name)\", got \"\(kept.name)\"."
            )
        } else {
            check("merge produced an entry for the rescanned path", false)
        }

        // Fallback: an existing non-user pin whose exe a rescan misses
        // entirely is kept as long as the file is still actually on disk.
        let stillOnDiskURL = root.appendingPathComponent("still-on-disk.exe")
        try? Data().write(to: stillOnDiskURL)
        let stillOnDiskPin = PinnedProgram(name: "Still Here", exePath: stillOnDiskURL.path, args: "", isUserAdded: false)
        let mergedEmpty = ProgramScanner.merge(scanned: [], existing: [stillOnDiskPin])
        check(
            "merge keeps an existing pin missed by the scan as long as its exe still exists on disk",
            mergedEmpty.contains { $0.exePath == stillOnDiskPin.exePath }
        )
    }

    // MARK: - ProgramScanner.merge: schema-migration dedupe + catalog defaults

    /// Reproduces the real-world bug this migration (`ProgramScanner.
    /// schemaVersion` 2) exists to fix, against an actual bottle's `Steam`
    /// pins captured before this fix: `Steam.exe`/`steam.exe` — the exact
    /// same file on disk (verified by inode), only reachable under two
    /// different stored casings because a pre-migration scanner had no
    /// case-insensitive dedupe — must collapse to one pin, get reclassified
    /// (isSystem/isHelper refreshed), and pick up the catalog's Steam
    /// launch args. `iexplore.exe` under `Program Files` and `Program
    /// Files (x86)` looks like the same shape of duplicate but is *not* —
    /// real measurement showed the two are genuinely different sizes (a
    /// 32-bit and a 64-bit build of Wine's IE stub) — so both must survive
    /// as distinct, individually-reclassified pins with distinct ids,
    /// never collapsed and never sharing an id.
    private static func testProgramScannerMigrationDedupe(root: URL) {
        let fm = FileManager.default
        let driveC = root.appendingPathComponent("MigrateDedupe/drive_c", isDirectory: true)
        let steamDir = driveC.appendingPathComponent("Program Files (x86)/Steam", isDirectory: true)
        try? fm.createDirectory(at: steamDir, withIntermediateDirectories: true)
        let steamExeCanonical = steamDir.appendingPathComponent("Steam.exe")
        try? Data([0x01]).write(to: steamExeCanonical)
        // Same file, reached through a differently-cased path — valid on
        // macOS's default case-insensitive volume, exactly how two stale
        // pins from an older scanner ended up pointing at "the same" exe
        // (confirmed against a real bottle: both paths share one inode).
        let steamExeLower = steamDir.appendingPathComponent("steam.exe")

        // Genuinely different files (different sizes), same relative path
        // under each bitness tree — must NOT be folded together.
        let ieDirPlain = driveC.appendingPathComponent("Program Files/Internet Explorer", isDirectory: true)
        let ieDirX86 = driveC.appendingPathComponent("Program Files (x86)/Internet Explorer", isDirectory: true)
        try? fm.createDirectory(at: ieDirPlain, withIntermediateDirectories: true)
        try? fm.createDirectory(at: ieDirX86, withIntermediateDirectories: true)
        let ieExePlain = ieDirPlain.appendingPathComponent("iexplore.exe")
        let ieExeX86 = ieDirX86.appendingPathComponent("iexplore.exe")
        try? Data(repeating: 0x02, count: 128).write(to: ieExePlain)
        try? Data(repeating: 0x02, count: 96).write(to: ieExeX86)
        defer { try? fm.removeItem(at: root.appendingPathComponent("MigrateDedupe")) }

        // Stale pins as an old scanner (no case-insensitive dedupe, no
        // isSystem/isHelper classification ever run against these paths)
        // would have stored them.
        let stalePins = [
            PinnedProgram(name: "Steam", exePath: steamExeCanonical.path, args: "", isUserAdded: false),
            PinnedProgram(name: "Steam", exePath: steamExeLower.path, args: "", isUserAdded: false),
            PinnedProgram(name: "iexplore", exePath: ieExePlain.path, args: "", isUserAdded: false),
            PinnedProgram(name: "iexplore", exePath: ieExeX86.path, args: "", isUserAdded: false),
        ]

        // What a fresh scan produces once collapsed/classified: scanSync's
        // own case-insensitive keying (exercised directly against a real
        // drive_c by `testProgramScannerScan`/`testProgramScannerScan`'s
        // iexplore case in the class-level `_selfTest`) already collapses
        // the Steam.exe/steam.exe pair to one candidate, and correctly
        // keeps both iexplore builds classified isSystem since their sizes
        // differ. Built by hand here (rather than by pointing
        // ProgramScanner.scan(bottle:) at this fixture, which would need a
        // real `Bottle.driveC` — hard-coded under `Paths.bottleDir(id)` —
        // rather than this scratch tree) so this test stays focused on
        // `merge`'s own dedupe/reclassification logic.
        let freshScan = [
            PinnedProgram(name: "Steam", exePath: steamExeCanonical.path, args: "", isUserAdded: false, isSystem: false, isHelper: false),
            PinnedProgram(name: "iexplore", exePath: ieExePlain.path, args: "", isUserAdded: false, isSystem: true, isHelper: false),
            PinnedProgram(name: "iexplore", exePath: ieExeX86.path, args: "", isUserAdded: false, isSystem: true, isHelper: false),
        ]

        let merged = ProgramScanner.merge(scanned: freshScan, existing: stalePins)

        let steamPins = merged.filter { $0.name.localizedCaseInsensitiveContains("steam") }
        check("migration collapses duplicate-case Steam pins to exactly one", steamPins.count == 1, "got \(steamPins.count): \(steamPins.map(\.exePath))")
        check(
            "migration applies the Steam catalog launch args to the survivor",
            steamPins.first?.args == "-allosarches -cef-force-32bit -cef-disable-gpu -cef-disable-gpu-compositing",
            "got \(steamPins.first?.args ?? "nil")"
        )
        check("migration keeps the Steam name as \"Steam\"", steamPins.first?.name == "Steam")

        let iexplorePins = merged.filter { $0.name.localizedCaseInsensitiveContains("iexplore") }
        check(
            "migration keeps both genuinely-different iexplore builds as distinct pins",
            iexplorePins.count == 2,
            "got \(iexplorePins.count): \(iexplorePins.map(\.exePath))"
        )
        check(
            "migration gives the two distinct iexplore pins distinct ids",
            Set(iexplorePins.map(\.id)).count == 2
        )
        check(
            "migration re-classifies both surviving iexplore pins as isSystem",
            iexplorePins.allSatisfy { $0.isSystem == true }
        )

        check(
            "ProgramScanner.dedupeKey does NOT fold Program Files (x86) onto Program Files (they can be genuinely different binaries)",
            ProgramScanner.dedupeKey(ieExeX86.path) != ProgramScanner.dedupeKey(ieExePlain.path)
        )
        check(
            "ProgramScanner.dedupeKey collapses a same-file case difference",
            ProgramScanner.dedupeKey(steamExeCanonical.path) == ProgramScanner.dedupeKey(steamExeLower.path)
        )
    }

    // MARK: - ProgramScanner.applyCatalogDefaults / derivedPinName

    private static func testProgramScannerCatalogDefaultsAndNaming() {
        let steamPin = PinnedProgram(name: "steam", exePath: "/drive_c/Program Files (x86)/Steam/steam.exe", args: "")
        let withDefaults = ProgramScanner.applyCatalogDefaults(to: steamPin)
        check("applyCatalogDefaults renames a matching, argless pin to the catalog name", withDefaults.name == "Steam")
        check("applyCatalogDefaults applies the catalog's launch args", withDefaults.args == "-allosarches -cef-force-32bit -cef-disable-gpu -cef-disable-gpu-compositing")

        let customArgsPin = PinnedProgram(name: "steam", exePath: "/drive_c/Program Files (x86)/Steam/steam.exe", args: "-custom")
        let untouched = ProgramScanner.applyCatalogDefaults(to: customArgsPin)
        check("applyCatalogDefaults leaves a pin with existing args alone", untouched.args == "-custom" && untouched.name == "steam")

        let unrelatedPin = PinnedProgram(name: "MyGame", exePath: "/drive_c/Program Files/MyGame/game.exe", args: "")
        let unrelatedResult = ProgramScanner.applyCatalogDefaults(to: unrelatedPin)
        check("applyCatalogDefaults is a no-op for a non-catalog exe", unrelatedResult == unrelatedPin)

        check("derivedPinName capitalizes an all-lowercase name", ProgramScanner.derivedPinName(fromBaseName: "geeky") == "Geeky")
        check("derivedPinName turns separators into spaces and capitalizes", ProgramScanner.derivedPinName(fromBaseName: "my_tool-name") == "My Tool Name")
        check(
            "derivedPinName leaves an already mixed-case name's casing alone",
            ProgramScanner.derivedPinName(fromBaseName: "SteamService") == "SteamService"
        )
    }

    // MARK: - WineRunner.environment

    private static func makeTestEngine(kind: EngineKind, root: URL) -> InstalledEngine {
        let engineRoot = root.appendingPathComponent("engine-\(kind.rawValue)", isDirectory: true)
        let bin = engineRoot.appendingPathComponent("bin", isDirectory: true)
        let lib = engineRoot.appendingPathComponent("lib", isDirectory: true)
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        return InstalledEngine(
            id: "\(kind.rawValue)-selftest",
            kind: kind,
            version: "selftest",
            rootDir: engineRoot,
            binDir: bin,
            libDir: lib,
            versionString: "selftest-version",
            installedAt: Date()
        )
    }

    private static func testWineRunnerEnvironment(root: URL) {
        let engine = makeTestEngine(kind: .wineStaging, root: root)

        var bottle = Bottle(name: "env-test", engineID: engine.id)
        bottle.esync = true
        bottle.msync = false
        bottle.metalHUD = true
        bottle.verboseLog = true
        bottle.dxvk = true
        bottle.env = ["FOO": "bar"]

        let env = WineRunner.environment(for: bottle, engine: engine)

        check("environment sets WINEPREFIX", env["WINEPREFIX"] == bottle.prefixDir.path)
        check("environment PATH is prefixed with engine binDir", env["PATH"]?.hasPrefix(engine.binDir.path) == true, "got \(env["PATH"] ?? "nil")")
        check("environment sets WINEDEBUG=fixme-all when verboseLog", env["WINEDEBUG"] == "fixme-all")
        check("environment sets WINEESYNC when esync", env["WINEESYNC"] == "1")
        check("environment omits WINEMSYNC when msync is off", env["WINEMSYNC"] == nil)
        check("environment sets MTL_HUD_ENABLED when metalHUD", env["MTL_HUD_ENABLED"] == "1")
        check(
            "environment WINEDLLOVERRIDES contains d3d11 when dxvk",
            env["WINEDLLOVERRIDES"]?.contains("d3d11") == true,
            "got \(env["WINEDLLOVERRIDES"] ?? "nil")"
        )
        check(
            "environment DYLD_FALLBACK_LIBRARY_PATH contains engine libDir",
            env["DYLD_FALLBACK_LIBRARY_PATH"]?.contains(engine.libDir.path) == true,
            "got \(env["DYLD_FALLBACK_LIBRARY_PATH"] ?? "nil")"
        )
        check("environment merges bottle.env", env["FOO"] == "bar")

        // Performance settings merge into the environment too.
        var perfBottle = Bottle(name: "env-perf-test", engineID: engine.id)
        perfBottle.dxvk = true
        var perf = PerformanceSettings()
        perf.dxvkAsync = true
        perf.dxvkHud = .fps
        perfBottle.performance = perf
        let perfEnv = WineRunner.environment(for: perfBottle, engine: engine)
        check("environment merges PerformanceSettings vars (DXVK_ASYNC)", perfEnv["DXVK_ASYNC"] == "1")
        check("environment merges PerformanceSettings vars (DXVK_HUD)", perfEnv["DXVK_HUD"] == "fps,frametimes")

        // bottle.env must win over performance.extraEnv for the same key
        // (WineRunner.environment merges performance first, bottle.env last).
        var overrideBottle = Bottle(name: "env-override-test", engineID: engine.id)
        var overridePerf = PerformanceSettings()
        overridePerf.extraEnv = ["OVERRIDE_KEY": "from-performance"]
        overrideBottle.performance = overridePerf
        overrideBottle.env = ["OVERRIDE_KEY": "from-bottle"]
        let overrideEnv = WineRunner.environment(for: overrideBottle, engine: engine)
        check(
            "environment: bottle.env wins over performance.extraEnv for the same key",
            overrideEnv["OVERRIDE_KEY"] == "from-bottle",
            "got \(overrideEnv["OVERRIDE_KEY"] ?? "nil")"
        )
    }

    // MARK: - WineRunner.splitArguments

    private static func testWineRunnerSplitArguments() {
        let tokens = WineRunner.splitArguments(#"a "b c" 'd e' f"#)
        check("splitArguments splits quoted groups", tokens == ["a", "b c", "d e", "f"], "got \(tokens)")

        check("splitArguments empty string -> []", WineRunner.splitArguments("").isEmpty)

        // Unbalanced quote: must not crash; the trailing partial token is
        // still flushed at end-of-string.
        let unbalanced = WineRunner.splitArguments(#"a "b"#)
        check("splitArguments handles an unbalanced quote without crashing", unbalanced == ["a", "b"], "got \(unbalanced)")
    }

    // MARK: - PerformanceSettings

    private static func testPerformanceSettings(root: URL) {
        let gptkEngine = makeTestEngine(kind: .gptk, root: root)
        let wineEngine = makeTestEngine(kind: .wineStaging, root: root)
        let plainBottle = Bottle(name: "perf-gptk-test", engineID: gptkEngine.id)
        var dxvkBottle = Bottle(name: "perf-wine-test", engineID: wineEngine.id)
        dxvkBottle.dxvk = true

        for preset in PerformanceSettings.Preset.allCases where preset != .custom {
            guard let settings = PerformanceSettings.presets[preset] else {
                check("preset \(preset.rawValue) has canonical settings", false)
                continue
            }

            let gptkEnv = PerformanceSettings.environment(for: settings, bottle: plainBottle, engine: gptkEngine)
            let dxvkKeysOnGPTK = gptkEnv.keys.filter { $0.hasPrefix("DXVK_") }
            check(
                "preset \(preset.rawValue) on GPTK emits no DXVK_* vars",
                dxvkKeysOnGPTK.isEmpty,
                "found \(dxvkKeysOnGPTK)"
            )

            let wineEnv = PerformanceSettings.environment(for: settings, bottle: dxvkBottle, engine: wineEngine)
            let d3dmKeysOnWine = wineEnv.keys.filter { $0.hasPrefix("D3DM_") }
            check(
                "preset \(preset.rawValue) on wine-staging emits no D3DM_* vars",
                d3dmKeysOnWine.isEmpty,
                "found \(d3dmKeysOnWine)"
            )
        }

        // applyingPreset: switching to a fixed preset applies its canonical
        // field values but preserves `extraEnv`. (There's no separate
        // model-level "editing a field marks .custom" helper to test here
        // — that transition lives only in PerformanceView.mutate, a View,
        // not in PerformanceSettings itself.)
        var custom = PerformanceSettings()
        custom.extraEnv = ["KEEP_ME": "1"]
        let applied = custom.applyingPreset(.maxPerformance)
        check("applyingPreset sets the preset field", applied.preset == .maxPerformance)
        check("applyingPreset preserves extraEnv across a preset switch", applied.extraEnv == ["KEEP_ME": "1"])
        check("applyingPreset applies the preset's canonical field values", applied.metalFX == true && applied.raytracing == true)

        let markedCustom = applied.applyingPreset(.custom)
        check(
            "applyingPreset(.custom) only marks preset custom, leaving other fields untouched",
            markedCustom.preset == .custom && markedCustom.metalFX == applied.metalFX && markedCustom.extraEnv == applied.extraEnv
        )
    }

    // MARK: - AppCatalog

    private static func testAppCatalog() {
        check("AppCatalog.search(\"steam\") finds Steam", AppCatalog.search("steam").contains { $0.id == "steam" })
        check("AppCatalog.search(\"7\") finds 7-Zip", AppCatalog.search("7").contains { $0.id == "7zip" })

        let all = AppCatalog.search("")
        let expectedOrder = AppCatalog.apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        check("AppCatalog.search(\"\") returns every app", all.count == AppCatalog.apps.count, "got \(all.count) of \(AppCatalog.apps.count)")
        check("AppCatalog.search(\"\") is sorted by name", all.map(\.id) == expectedOrder.map(\.id))

        check("AppCatalog.search unknown query -> []", AppCatalog.search("zzz-not-a-real-app-xyz").isEmpty)

        let missingFileName = AppCatalog.apps.filter { $0.installerURL != nil && $0.installerFileName.isEmpty }
        check(
            "every app with an installerURL has a non-empty installerFileName",
            missingFileName.isEmpty,
            "missing for: \(missingFileName.map(\.id))"
        )

        let ids = AppCatalog.apps.map(\.id)
        check("AppCatalog app ids are unique", Set(ids).count == ids.count)
    }

    // MARK: - EngineCatalog

    private static func testEngineCatalog() {
        check("EngineCatalog has 2 releases", EngineCatalog.releases.count == 2, "got \(EngineCatalog.releases.count)")

        let ids = EngineCatalog.releases.map(\.id)
        check("EngineCatalog release ids are unique", Set(ids).count == ids.count)

        let hexDigits = Set("0123456789abcdef")
        for release in EngineCatalog.releases {
            let isHex64 = release.sha256.count == 64 && release.sha256.allSatisfy { hexDigits.contains($0) }
            check(
                "\(release.id) sha256 is 64 lowercase hex chars",
                isHex64,
                "got \"\(release.sha256)\" (\(release.sha256.count) chars)"
            )
        }

        check("EngineCatalog.defaultRelease.kind == .gptk", EngineCatalog.defaultRelease.kind == .gptk)
    }

    // MARK: - Bottle Codable

    private static func testBottleCodable() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var bottle = Bottle(name: "codable-test", engineID: "gptk-3.0-3")
        bottle.pins = [PinnedProgram(name: "Test", exePath: "/tmp/selftest/test.exe", args: "-a")]
        bottle.env = ["A": "B"]
        bottle.performance = PerformanceSettings()
        bottle.lastUsed = Date()

        do {
            let data = try encoder.encode(bottle)
            let decoded = try decoder.decode(Bottle.self, from: data)
            check("Bottle JSON round-trip preserves id", decoded.id == bottle.id)
            check("Bottle JSON round-trip preserves name", decoded.name == bottle.name)
            check("Bottle JSON round-trip preserves pins", decoded.pins == bottle.pins)
            check("Bottle JSON round-trip preserves performance", decoded.performance == bottle.performance)
        } catch {
            check("Bottle JSON round-trip succeeds", false, "\(error)")
        }

        // Backward compat: metadata.json written before `performance`
        // existed (no such key at all) must still decode, with a nil
        // performance.
        let legacyJSON = """
        {
          "id": "\(UUID().uuidString)",
          "name": "legacy",
          "engineID": "gptk-3.0-3",
          "windowsVersion": "win10",
          "esync": true,
          "msync": true,
          "metalHUD": false,
          "verboseLog": false,
          "dxvk": false,
          "env": {},
          "pins": [],
          "createdAt": "2026-01-01T00:00:00Z"
        }
        """
        do {
            let decoded = try decoder.decode(Bottle.self, from: Data(legacyJSON.utf8))
            check("Bottle decodes legacy JSON missing the performance key", decoded.performance == nil)
        } catch {
            check("Bottle decodes legacy JSON missing the performance key", false, "\(error)")
        }
    }

    // MARK: - LogStore

    private static func testLogStore(root: URL) {
        let bigFile = root.appendingPathComponent("big.log")
        let content = String(repeating: "0123456789", count: 1000) + "TAIL-MARKER-END"
        try? content.data(using: .utf8)?.write(to: bigFile)

        let maxBytes = 50
        let tail = LogStore.tail(bigFile, maxBytes: maxBytes)
        check("LogStore.tail returns exactly maxBytes for an oversized file", tail.utf8.count == maxBytes, "got \(tail.utf8.count) bytes")
        check("LogStore.tail returns the file's actual tail", tail == String(content.suffix(maxBytes)), "got \(tail)")

        // newLogURL creates Paths.logs/<bottleID> — explicitly allowed by
        // the test brief as long as it's removed afterward.
        let bottleID = UUID()
        let logURL = LogStore.newLogURL(bottleID: bottleID, exeName: "notepad")
        defer { try? FileManager.default.removeItem(at: Paths.logs.appendingPathComponent(bottleID.uuidString)) }

        let name = logURL.lastPathComponent
        check("newLogURL name contains the exe name", name.contains("notepad"), "got \(name)")
        let pattern = try! NSRegularExpression(pattern: #"^\d{8}-\d{6}-notepad\.log$"#)
        let matched = pattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
        check("newLogURL name matches <yyyyMMdd-HHmmss>-<exe>.log", matched, "got \(name)")
    }
}
