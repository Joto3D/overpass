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
        testProgramScannerShortcutBackedDefaultVisibility()
        testProgramScannerFallbackNeverEmpty()
        testWineRunnerEnvironment(root: root)
        testWineRunnerSplitArguments()
        testVirtualDesktopSizeValidation()
        testVirtualDesktopNameSanitization()
        testVirtualDesktopWindowsPathConversion(root: root)
        testVirtualDesktopLaunchArguments(root: root)
        testD3DMetalOverlay(root: root)
        testPerformanceSettings(root: root)
        testAppCatalog()
        testEngineCatalog()
        testBottleCodable()
        testGameFix()
        testUserFixFailureNotice()
        testReportAppending()
        testInstallerSignature(root: root)
        testLogStore(root: root)
        testLogFileName()
        testDiagnosticsFormatBytes()
        testLogStoreOrdering()
        testUserFixCache()
        testTreeSize(root: root)

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
            steamPins.first?.args == "-allosarches -cef-disable-gpu -cef-disable-gpu-compositing",
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
        check("applyCatalogDefaults applies the catalog's launch args", withDefaults.args == "-allosarches -cef-disable-gpu -cef-disable-gpu-compositing")

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

    // MARK: - ProgramScanner: shortcut-backed-by-default visibility

    /// Reproduces the real-world bug this feature exists to fix: a Steam
    /// bottle whose `bin/` folder (`fossilize-replay.exe`,
    /// `vulkandriverquery64.exe`, `x64launcher.exe`, …) sits in a
    /// *different* folder from the Start Menu shortcut's target
    /// (`Steam/steam.exe`), so the old same-folder "sibling" helper rule
    /// never caught them — a real bottle ended up with 14 of 34 pins
    /// visible, 13 of them Steam's own internal binaries. Builds the exact
    /// layout (`Steam/steam.exe` + a Start Menu `.lnk` to it + all 13
    /// `Steam/bin/*.exe`) and asserts the default-visible set — what
    /// `ProgramsGridView` shows with every filter off — is exactly
    /// `["Steam"]`.
    private static func testProgramScannerShortcutBackedDefaultVisibility() {
        let fm = FileManager.default
        let bottle = Bottle(name: "selftest-steam-shape", engineID: "gptk-3.0-3")
        let driveC = bottle.driveC
        defer { try? fm.removeItem(at: bottle.prefixDir) }

        let steamDir = driveC.appendingPathComponent("Program Files (x86)/Steam", isDirectory: true)
        let binDir = steamDir.appendingPathComponent("bin", isDirectory: true)
        try? fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        try? Data([0xAA]).write(to: steamDir.appendingPathComponent("steam.exe"))

        // The exact 13 Steam/bin binaries from the real bottle that
        // motivated this fix.
        let binNames = [
            "drivers", "fossilize-replay", "fossilize-replay64", "gldriverquery", "gldriverquery64",
            "secure_desktop_capture", "steam_monitor", "steamxboxutil", "steamxboxutil64",
            "vulkandriverquery", "vulkandriverquery64", "x64launcher", "x86launcher",
        ]
        for name in binNames {
            try? Data().write(to: binDir.appendingPathComponent("\(name).exe"))
        }

        let startMenuDir = driveC.appendingPathComponent(
            "ProgramData/Microsoft/Windows/Start Menu/Programs", isDirectory: true
        )
        try? fm.createDirectory(at: startMenuDir, withIntermediateDirectories: true)
        let lnkData = buildLnk(target: #"C:\Program Files (x86)\Steam\steam.exe"#, arguments: "")
        try? lnkData.write(to: startMenuDir.appendingPathComponent("Steam.lnk"))

        let scanned = runSync { await ProgramScanner.scan(bottle: bottle) }
        let merged = ProgramScanner.merge(scanned: scanned, existing: [])
        check(
            "Steam-shape scan produces exactly 14 pins (steam.exe + 13 Steam/bin exes)",
            merged.count == 14,
            "got \(merged.count): \(merged.map(\.name).sorted())"
        )

        let steamPin = merged.first { $0.name == "Steam" }
        check("Steam.exe pin has origin .shortcut", steamPin?.origin == .shortcut, "got \(String(describing: steamPin?.origin))")

        let binPins = merged.filter { $0.exePath.lowercased().contains("/steam/bin/") }
        check(
            "every Steam/bin/*.exe pin is flagged isHelper (path-segment rule)",
            binPins.count == 13 && binPins.allSatisfy(\.isHelper),
            "got \(binPins.count) bin pins, non-helper: \(binPins.filter { !$0.isHelper }.map(\.name))"
        )

        let visible = ProgramScanner.defaultVisiblePins(merged)
        check(
            "Steam-shape default-visible set is exactly [\"Steam\"]",
            Set(visible.map(\.name)) == ["Steam"],
            "got \(visible.map(\.name).sorted())"
        )

        // "Show helper executables" alone does nothing here: every
        // Steam/bin/*.exe pin is also `.discovered`-origin, and the
        // toolbar's system/helper toggles are nested *under* "Show all
        // programs" (refinements of the broadened set, not independent
        // overrides of the origin filter) — so revealing them needs both.
        let helpersOnly = ProgramScanner.defaultVisiblePins(merged, showHelpers: true)
        check(
            "Show helper executables alone (Show all off) still hides .discovered helpers",
            helpersOnly.count == 1,
            "got \(helpersOnly.count)"
        )
        let allPlusHelpers = ProgramScanner.defaultVisiblePins(merged, showHelpers: true, showAll: true)
        check(
            "Show all programs + Show helper executables reveals every Steam/bin/*.exe pin",
            allPlusHelpers.count == 14,
            "got \(allPlusHelpers.count)"
        )
    }

    /// A bottle with real installed content but no shortcuts anywhere
    /// (every exe is `.discovered`) must never present an empty Programs
    /// list — `ProgramScanner.fallbackVisiblePins` picks the largest
    /// non-helper exe per top-level Program Files folder as a stand-in.
    private static func testProgramScannerFallbackNeverEmpty() {
        let fm = FileManager.default
        let bottle = Bottle(name: "selftest-no-shortcuts", engineID: "gptk-3.0-3")
        let driveC = bottle.driveC
        defer { try? fm.removeItem(at: bottle.prefixDir) }

        let gameDir = driveC.appendingPathComponent("Program Files/SomeGame", isDirectory: true)
        try? fm.createDirectory(at: gameDir, withIntermediateDirectories: true)
        // The real game binary is the larger of the two — no .lnk targets
        // either, so both would be `.discovered` and hidden by default.
        try? Data(repeating: 0x01, count: 20_000).write(to: gameDir.appendingPathComponent("SomeGame.exe"))
        try? Data(repeating: 0x01, count: 200).write(to: gameDir.appendingPathComponent("crashpad_handler.exe"))

        let scanned = runSync { await ProgramScanner.scan(bottle: bottle) }
        let merged = ProgramScanner.merge(scanned: scanned, existing: [])
        check(
            "no-shortcut fixture: both exes are .discovered",
            merged.allSatisfy { $0.origin == .discovered },
            "got \(merged.map { ($0.name, $0.origin) })"
        )

        let normallyEmpty = merged.filter { pin in
            guard let origin = pin.origin else { return false }
            switch origin {
            case .shortcut, .catalogApp, .user: return true
            case .discovered: return false
            }
        }
        check("no-shortcut fixture: plain origin filtering would be empty", normallyEmpty.isEmpty)

        let visible = ProgramScanner.defaultVisiblePins(merged)
        check(
            "fallback keeps the Programs list non-empty when a shortcut-less bottle still has real content",
            !visible.isEmpty,
            "got empty list despite \(merged.count) pins on disk"
        )
        check(
            "fallback picks the larger exe (the real game, not the helper)",
            visible.map(\.name) == ["SomeGame"],
            "got \(visible.map(\.name))"
        )
    }

    // MARK: - WineRunner.environment

    private static func makeTestEngine(kind: EngineKind, root: URL, id: String? = nil) -> InstalledEngine {
        let engineID = id ?? "\(kind.rawValue)-selftest"
        let engineRoot = root.appendingPathComponent("engine-\(engineID)", isDirectory: true)
        let bin = engineRoot.appendingPathComponent("bin", isDirectory: true)
        let lib = engineRoot.appendingPathComponent("lib", isDirectory: true)
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        return InstalledEngine(
            id: engineID,
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
            "environment WINEDLLOVERRIDES covers every dll DXVK installs when dxvk",
            ["d3d8", "d3d9", "d3d10core", "d3d11", "dxgi"].allSatisfy {
                env["WINEDLLOVERRIDES"]?.contains($0) == true
            },
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
        perf.dxvkHud = .fps
        perf.frameRateCap = 60
        perfBottle.performance = perf
        let perfEnv = WineRunner.environment(for: perfBottle, engine: engine)
        check("environment merges PerformanceSettings vars (DXVK_HUD)", perfEnv["DXVK_HUD"] == "fps,frametimes")
        check(
            "frame rate cap goes out as DXVK_CONFIG, not the removed DXVK_FRAME_RATE",
            perfEnv["DXVK_CONFIG"] == "dxgi.maxFrameRate = 60; d3d9.maxFrameRate = 60"
                && perfEnv["DXVK_FRAME_RATE"] == nil,
            "got DXVK_CONFIG=\(perfEnv["DXVK_CONFIG"] ?? "nil")"
        )

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

    // MARK: - Virtual desktop: Bottle.validatedVirtualDesktopSize

    private static func testVirtualDesktopSizeValidation() {
        check(
            "validatedVirtualDesktopSize accepts a well-formed size",
            Bottle.validatedVirtualDesktopSize("1920x1080") == "1920x1080"
        )
        check(
            "validatedVirtualDesktopSize accepts the minimum bound",
            Bottle.validatedVirtualDesktopSize("640x480") == "640x480"
        )
        check(
            "validatedVirtualDesktopSize accepts the maximum bound",
            Bottle.validatedVirtualDesktopSize("7680x4320") == "7680x4320"
        )
        check(
            "validatedVirtualDesktopSize falls back to the default for nil",
            Bottle.validatedVirtualDesktopSize(nil) == Bottle.defaultVirtualDesktopSize
        )
        check(
            "validatedVirtualDesktopSize falls back for width below the minimum",
            Bottle.validatedVirtualDesktopSize("639x480") == Bottle.defaultVirtualDesktopSize
        )
        check(
            "validatedVirtualDesktopSize falls back for height above the maximum",
            Bottle.validatedVirtualDesktopSize("1920x4321") == Bottle.defaultVirtualDesktopSize
        )
        check(
            "validatedVirtualDesktopSize falls back for non-numeric parts",
            Bottle.validatedVirtualDesktopSize("wideXtall") == Bottle.defaultVirtualDesktopSize
        )
        check(
            "validatedVirtualDesktopSize falls back for a missing 'x'",
            Bottle.validatedVirtualDesktopSize("1920,1080") == Bottle.defaultVirtualDesktopSize
        )
        check(
            "validatedVirtualDesktopSize falls back for a malformed extra segment",
            Bottle.validatedVirtualDesktopSize("1920x1080x60") == Bottle.defaultVirtualDesktopSize
        )
        check(
            "validatedVirtualDesktopSize falls back for an empty string",
            Bottle.validatedVirtualDesktopSize("") == Bottle.defaultVirtualDesktopSize
        )
        check(
            "validatedVirtualDesktopSize falls back for negative numbers",
            Bottle.validatedVirtualDesktopSize("-100x-100") == Bottle.defaultVirtualDesktopSize
        )
        check("Bottle() defaults virtualDesktop to false", Bottle(name: "vd-default", engineID: "gptk-3.0-3").virtualDesktop == false)
        check(
            "Bottle() defaults virtualDesktopSize to 1280x800",
            Bottle(name: "vd-default", engineID: "gptk-3.0-3").virtualDesktopSize == "1280x800"
        )
    }

    // MARK: - Virtual desktop: WineRunner.sanitizedDesktopName

    private static func testVirtualDesktopNameSanitization() {
        check(
            "sanitizedDesktopName strips spaces",
            WineRunner.sanitizedDesktopName("My Bottle") == "MyBottle"
        )
        check(
            "sanitizedDesktopName strips commas",
            WineRunner.sanitizedDesktopName("Steam, Deluxe") == "SteamDeluxe"
        )
        check(
            "sanitizedDesktopName strips unicode/accented characters",
            WineRunner.sanitizedDesktopName("Café \u{1F600} \u{6E38}\u{620F}") == "Caf"
        )
        check(
            "sanitizedDesktopName keeps letters, digits, underscore, and hyphen",
            WineRunner.sanitizedDesktopName("Default_Bottle-2") == "Default_Bottle-2"
        )
        check(
            "sanitizedDesktopName falls back to Overpass when nothing survives",
            WineRunner.sanitizedDesktopName("\u{1F600}\u{1F600}, ,") == "Overpass"
        )
        check(
            "sanitizedDesktopName falls back to Overpass for an empty name",
            WineRunner.sanitizedDesktopName("") == "Overpass"
        )
    }

    // MARK: - Virtual desktop: WineRunner.windowsPath(forUnixPath:bottle:)

    private static func testVirtualDesktopWindowsPathConversion(root: URL) {
        let bottle = Bottle(name: "vd-path-test", engineID: "gptk-3.0-3")

        let inside = bottle.driveC.appendingPathComponent("Program Files/Notepad++/notepad++.exe").path
        check(
            "windowsPath converts a drive_c path to a backslash C: path",
            WineRunner.windowsPath(forUnixPath: inside, bottle: bottle) == #"C:\Program Files\Notepad++\notepad++.exe"#,
            "got \(WineRunner.windowsPath(forUnixPath: inside, bottle: bottle) ?? "nil")"
        )

        let root2 = bottle.driveC.path
        check(
            "windowsPath returns nil for drive_c itself (no relative file)",
            WineRunner.windowsPath(forUnixPath: root2, bottle: bottle) == nil
        )

        let outside = root.appendingPathComponent("Elsewhere/Geeky.exe").path
        check(
            "windowsPath returns nil for a path outside drive_c",
            WineRunner.windowsPath(forUnixPath: outside, bottle: bottle) == nil
        )

        let anotherBottleInside = Bottle(name: "other", engineID: "gptk-3.0-3").driveC
            .appendingPathComponent("Program Files/Foo/foo.exe").path
        check(
            "windowsPath returns nil for a path under a different bottle's drive_c",
            WineRunner.windowsPath(forUnixPath: anotherBottleInside, bottle: bottle) == nil
        )
    }

    // MARK: - Virtual desktop: WineRunner.launchArguments

    private static func testVirtualDesktopLaunchArguments(root: URL) {
        var bottle = Bottle(name: "Default", engineID: "gptk-3.0-3")
        let exeInside = bottle.driveC.appendingPathComponent("Program Files/Notepad++/notepad++.exe")

        // Virtual desktop off -> plain `start /unix`, unchanged from before
        // this feature existed.
        bottle.virtualDesktop = false
        let offResult = WineRunner.launchArguments(exe: exeInside, args: "-x", bottle: bottle)
        check(
            "launchArguments: virtual desktop off uses start /unix",
            offResult.arguments == ["start", "/unix", exeInside.path, "-x"],
            "got \(offResult.arguments)"
        )
        check("launchArguments: virtual desktop off reports no skip reason", offResult.skippedVirtualDesktopReason == nil)

        // Virtual desktop on, exe inside drive_c -> explorer /desktop=...
        bottle.virtualDesktop = true
        bottle.virtualDesktopSize = "1920x1080"
        let onResult = WineRunner.launchArguments(exe: exeInside, args: "-x \"a b\"", bottle: bottle)
        check(
            "launchArguments: virtual desktop on builds the exact explorer /desktop= vector",
            onResult.arguments == [
                "explorer", "/desktop=Default,1920x1080", #"C:\Program Files\Notepad++\notepad++.exe"#, "-x", "a b",
            ],
            "got \(onResult.arguments)"
        )
        check("launchArguments: successful virtual desktop reports no skip reason", onResult.skippedVirtualDesktopReason == nil)

        // Virtual desktop on, malformed size -> falls back to the default
        // size inside the explorer argument.
        bottle.virtualDesktopSize = "not-a-size"
        let malformedSizeResult = WineRunner.launchArguments(exe: exeInside, args: "", bottle: bottle)
        check(
            "launchArguments: malformed virtualDesktopSize falls back to 1280x800 in the built argument",
            malformedSizeResult.arguments.first(where: { $0.hasPrefix("/desktop=") }) == "/desktop=Default,1280x800",
            "got \(malformedSizeResult.arguments)"
        )
        bottle.virtualDesktopSize = "1920x1080"

        // Virtual desktop on, exe OUTSIDE drive_c -> declines the virtual
        // desktop, falls back to start /unix, and explains why.
        let exeOutside = root.appendingPathComponent("Elsewhere/Geeky.exe")
        let outsideResult = WineRunner.launchArguments(exe: exeOutside, args: "", bottle: bottle)
        check(
            "launchArguments: exe outside drive_c falls back to start /unix even with virtual desktop on",
            outsideResult.arguments == ["start", "/unix", exeOutside.path],
            "got \(outsideResult.arguments)"
        )
        check(
            "launchArguments: exe outside drive_c reports a skip reason mentioning drive_c",
            outsideResult.skippedVirtualDesktopReason?.contains("drive_c") == true,
            "got \(outsideResult.skippedVirtualDesktopReason ?? "nil")"
        )

        // .msi always goes through msiexec, virtual desktop or not.
        let msiInside = bottle.driveC.appendingPathComponent("Program Files/Foo/installer.msi")
        let msiResult = WineRunner.launchArguments(exe: msiInside, args: "/qn", bottle: bottle)
        check(
            "launchArguments: .msi always uses msiexec /i, ignoring virtualDesktop",
            msiResult.arguments == ["msiexec", "/i", msiInside.path, "/qn"],
            "got \(msiResult.arguments)"
        )
        check("launchArguments: .msi reports no skip reason", msiResult.skippedVirtualDesktopReason == nil)

        // A bottle name with characters wine's /desktop= argument can't
        // carry (spaces, commas) is sanitized in the built argument too.
        var punctuatedBottle = Bottle(name: "My Bottle, 2", engineID: "gptk-3.0-3")
        punctuatedBottle.virtualDesktop = true
        let punctuatedExe = punctuatedBottle.driveC.appendingPathComponent("Program Files/Foo/foo.exe")
        let punctuatedResult = WineRunner.launchArguments(exe: punctuatedExe, args: "", bottle: punctuatedBottle)
        check(
            "launchArguments: a bottle name with spaces/commas is sanitized in /desktop=",
            punctuatedResult.arguments.first(where: { $0.hasPrefix("/desktop=") }) == "/desktop=MyBottle2,1280x800",
            "got \(punctuatedResult.arguments)"
        )
    }

    // MARK: - D3DMetalOverlay

    /// Exercises `D3DMetalOverlay.sourceEngine`/`isAvailable` against fake
    /// engine trees under the scratch `root`, and `WineRunner.environment`
    /// with a real (but throwaway, deleted via `defer`) bottle+overlay
    /// under the actual `Paths.bottles` tree — same "unavoidably touches
    /// the real Overpass support directory" reasoning as
    /// `testProgramScannerMerge`/`testLogStore`, since `Bottle.prefixDir`
    /// has no injectable override.
    private static func testD3DMetalOverlay(root: URL) {
        // -- sourceEngine / isAvailable, against fake trees (no real Wine
        //    binaries needed — only file *presence* is checked). --
        let incompleteGPTK = makeTestEngine(kind: .gptk, root: root)
        check(
            "D3DMetalOverlay.sourceEngine ignores a GPTK engine missing D3DMetal files",
            D3DMetalOverlay.sourceEngine(from: [incompleteGPTK]) == nil
        )
        check(
            "D3DMetalOverlay.isAvailable is false with only an incomplete GPTK engine",
            D3DMetalOverlay.isAvailable(engines: [incompleteGPTK]) == false
        )

        let completeGPTK = makeTestEngine(kind: .gptk, root: root, id: "gptk-complete")
        populateFakeD3DMetalSource(in: completeGPTK)
        check(
            "D3DMetalOverlay.sourceEngine finds a GPTK engine with D3DMetal files",
            D3DMetalOverlay.sourceEngine(from: [incompleteGPTK, completeGPTK])?.id == completeGPTK.id
        )
        check(
            "D3DMetalOverlay.isAvailable is true once a complete GPTK engine is present",
            D3DMetalOverlay.isAvailable(engines: [incompleteGPTK, completeGPTK])
        )

        let wineStagingOnly = makeTestEngine(kind: .wineStaging, root: root)
        check(
            "D3DMetalOverlay.sourceEngine never picks a Wine-staging engine",
            D3DMetalOverlay.sourceEngine(from: [wineStagingOnly]) == nil
        )

        // -- install() against the fake GPTK tree, into a throwaway real
        //    bottle, then WineRunner.environment() with the overlay
        //    actually installed. --
        var bottle = Bottle(name: "overlay-selftest", engineID: "wine-staging-selftest")
        bottle.d3dMetalOverlay = true
        defer { try? FileManager.default.removeItem(at: bottle.prefixDir) }

        do {
            try D3DMetalOverlay.install(into: bottle, from: completeGPTK) { _ in }
            check("D3DMetalOverlay.install reports isInstalled afterward", D3DMetalOverlay.isInstalled(in: bottle))
            check(
                "D3DMetalOverlay.install copies the expected DLLs",
                FileManager.default.fileExists(atPath: D3DMetalOverlay.overlayWindowsDir(for: bottle).appendingPathComponent("d3d11.dll").path)
            )
            let so = D3DMetalOverlay.overlayUnixDir(for: bottle).appendingPathComponent("d3d11.so")
            let target = try? FileManager.default.destinationOfSymbolicLink(atPath: so.path)
            check(
                "D3DMetalOverlay.install recreates the d3d11.so symlink pointing at ../../external/libd3dshared.dylib",
                target == "../../external/libd3dshared.dylib",
                "got \(target ?? "nil")"
            )
        } catch {
            check("D3DMetalOverlay.install succeeds against a complete fake GPTK tree", false, "\(error)")
        }

        let wineStagingEngine = makeTestEngine(kind: .wineStaging, root: root, id: "wine-staging-selftest")
        let overlayEnv = WineRunner.environment(for: bottle, engine: wineStagingEngine)
        check(
            "environment prepends WINEDLLPATH with the overlay's lib/wine when the overlay is on and installed",
            overlayEnv["WINEDLLPATH"]?.hasPrefix(D3DMetalOverlay.overlayWineDir(for: bottle).path) == true,
            "got \(overlayEnv["WINEDLLPATH"] ?? "nil")"
        )
        check(
            "environment extends DYLD_FALLBACK_LIBRARY_PATH with the overlay's lib/external",
            overlayEnv["DYLD_FALLBACK_LIBRARY_PATH"]?.contains(D3DMetalOverlay.overlayExternalDir(for: bottle).path) == true,
            "got \(overlayEnv["DYLD_FALLBACK_LIBRARY_PATH"] ?? "nil")"
        )
        check("environment sets D3DMetal=1 when the overlay is on", overlayEnv["D3DMetal"] == "1")
        check(
            "environment sets CX_APPLEGPTK_LIBD3DSHARED_PATH to the overlay's dylib",
            overlayEnv["CX_APPLEGPTK_LIBD3DSHARED_PATH"] == D3DMetalOverlay.overlayLibD3DShared(for: bottle).path
        )
        check(
            "environment forces the overlay dll names to builtin (=b) in WINEDLLOVERRIDES",
            overlayEnv["WINEDLLOVERRIDES"]?.contains("d3d11") == true && overlayEnv["WINEDLLOVERRIDES"]?.hasSuffix("=b") == true,
            "got \(overlayEnv["WINEDLLOVERRIDES"] ?? "nil")"
        )

        // -- Guardrails: no-op on GPTK even with the flag set, and no-op
        //    on Wine-staging when the overlay hasn't actually been
        //    installed into the bottle. --
        let gptkEnv = WineRunner.environment(for: bottle, engine: completeGPTK)
        check("environment leaves D3DMetal unset on a GPTK engine even when bottle.d3dMetalOverlay is true", gptkEnv["D3DMetal"] == nil)
        check(
            "environment's WINEDLLPATH is untouched by the overlay on a GPTK engine",
            gptkEnv["WINEDLLPATH"] == nil
        )

        var uninstalledBottle = Bottle(name: "overlay-not-installed", engineID: "wine-staging-selftest")
        uninstalledBottle.d3dMetalOverlay = true
        let notInstalledEnv = WineRunner.environment(for: uninstalledBottle, engine: wineStagingEngine)
        check(
            "environment is a no-op when d3dMetalOverlay is on but never installed into the bottle",
            notInstalledEnv["D3DMetal"] == nil && notInstalledEnv["WINEDLLPATH"] == nil
        )

        do {
            try D3DMetalOverlay.uninstall(from: bottle)
            check("D3DMetalOverlay.uninstall removes the overlay directory", !D3DMetalOverlay.isInstalled(in: bottle))
        } catch {
            check("D3DMetalOverlay.uninstall succeeds", false, "\(error)")
        }
    }

    /// Populates a fake GPTK engine's `lib/` with just enough files
    /// (empty stand-ins, never actually loaded by these tests) for
    /// `D3DMetalOverlay.sourceEngine`/`install` to treat it as a real
    /// D3DMetal source: `external/libd3dshared.dylib`, one PE dll per
    /// `D3DMetalOverlay.dllBaseNames`, and its `.so` unixlib symlink.
    private static func populateFakeD3DMetalSource(in engine: InstalledEngine) {
        let fm = FileManager.default
        let external = engine.libDir.appendingPathComponent("external", isDirectory: true)
        let windows = engine.libDir.appendingPathComponent("wine/x86_64-windows", isDirectory: true)
        let unix = engine.libDir.appendingPathComponent("wine/x86_64-unix", isDirectory: true)
        try? fm.createDirectory(at: external, withIntermediateDirectories: true)
        try? fm.createDirectory(at: windows, withIntermediateDirectories: true)
        try? fm.createDirectory(at: unix, withIntermediateDirectories: true)
        fm.createFile(atPath: external.appendingPathComponent("libd3dshared.dylib").path, contents: Data("fake".utf8))
        for base in D3DMetalOverlay.dllBaseNames {
            fm.createFile(atPath: windows.appendingPathComponent("\(base).dll").path, contents: Data("fake".utf8))
            let so = unix.appendingPathComponent("\(base).so")
            try? fm.removeItem(at: so)
            try? fm.createSymbolicLink(atPath: so.path, withDestinationPath: "../../external/libd3dshared.dylib")
        }
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

        // Frame counter diagnostic: off by default and in every preset,
        // round-trips through JSON, survives an older metadata.json that
        // lacks the key, and only ever yields DYLD_INSERT_LIBRARIES when
        // both the toggle is on and the dylib exists.
        check("frameCounter defaults off", PerformanceSettings().frameCounter == false)
        check(
            "frameCounter is off in every preset",
            PerformanceSettings.presets.values.allSatisfy { $0.frameCounter == false }
        )
        do {
            var on = PerformanceSettings()
            on.frameCounter = true
            let data = try JSONEncoder().encode(on)
            let decoded = try JSONDecoder().decode(PerformanceSettings.self, from: data)
            check("frameCounter=true round-trips through JSON", decoded.frameCounter == true && decoded == on)
            let offDecoded = try JSONDecoder().decode(PerformanceSettings.self, from: JSONEncoder().encode(PerformanceSettings()))
            check("frameCounter=false round-trips through JSON", offDecoded.frameCounter == false)

            // An older metadata.json: a performance block written before
            // frameCounter (and with only some keys) must still decode.
            let legacyPerf = #"{"preset":"maxPerformance","metalFX":true,"d3dmLogging":false,"raytracing":true,"dxvkHud":"fps","largeAddressAware":true,"disableCSMT":false,"retinaMode":false,"optionAsAlt":true,"preciseScrolling":true,"extraEnv":{"K":"V"}}"#
            let legacy = try JSONDecoder().decode(PerformanceSettings.self, from: Data(legacyPerf.utf8))
            check(
                "performance JSON lacking frameCounter decodes with it off and the rest intact",
                legacy.frameCounter == false && legacy.metalFX && legacy.preset == .maxPerformance && legacy.extraEnv == ["K": "V"]
            )
        } catch {
            check("frameCounter JSON round trip", false, "\(error)")
        }

        let fakeShim = root.appendingPathComponent("fake-libfgshim.dylib")
        var counterBottle = Bottle(name: "perf-framecounter", engineID: wineEngine.id)
        var counterPerf = PerformanceSettings()
        counterPerf.frameCounter = true
        counterBottle.performance = counterPerf
        let counterOn = WineRunner.environment(for: counterBottle, engine: wineEngine, shimDylib: fakeShim)
        check("frameCounter on + dylib present sets DYLD_INSERT_LIBRARIES", counterOn["DYLD_INSERT_LIBRARIES"] == fakeShim.path)
        let counterNoDylib = WineRunner.environment(for: counterBottle, engine: wineEngine, shimDylib: nil)
        check("frameCounter on + dylib missing sets no DYLD_INSERT_LIBRARIES", counterNoDylib["DYLD_INSERT_LIBRARIES"] == nil)
        counterBottle.performance?.frameCounter = false
        let counterOff = WineRunner.environment(for: counterBottle, engine: wineEngine, shimDylib: fakeShim)
        check("frameCounter off + dylib present sets no DYLD_INSERT_LIBRARIES", counterOff["DYLD_INSERT_LIBRARIES"] == nil)
        let noPerfBottle = Bottle(name: "perf-framecounter-none", engineID: wineEngine.id)
        check(
            "bottle with no performance block sets no DYLD_INSERT_LIBRARIES",
            WineRunner.environment(for: noPerfBottle, engine: wineEngine, shimDylib: fakeShim)["DYLD_INSERT_LIBRARIES"] == nil
        )
        counterBottle.performance?.frameCounter = true
        counterBottle.performance?.extraEnv = ["DYLD_INSERT_LIBRARIES": "/other.dylib"]
        check(
            "frameCounter appends to an existing DYLD_INSERT_LIBRARIES instead of clobbering it",
            WineRunner.environment(for: counterBottle, engine: wineEngine, shimDylib: fakeShim)["DYLD_INSERT_LIBRARIES"]
                == "/other.dylib:\(fakeShim.path)"
        )

        // dylibURL: nil without a resource dir or without the file; the URL
        // once the file exists.
        let shimResources = root.appendingPathComponent("shim-resources", isDirectory: true)
        try? FileManager.default.createDirectory(at: shimResources, withIntermediateDirectories: true)
        check("FrameCounterShim.dylibURL is nil with no resource directory", FrameCounterShim.dylibURL(resourceURL: nil) == nil)
        check("FrameCounterShim.dylibURL is nil when the dylib is missing", FrameCounterShim.dylibURL(resourceURL: shimResources) == nil)
        FileManager.default.createFile(atPath: shimResources.appendingPathComponent(FrameCounterShim.dylibName).path, contents: Data("fake".utf8))
        check(
            "FrameCounterShim.dylibURL finds the dylib once present",
            FrameCounterShim.dylibURL(resourceURL: shimResources)?.lastPathComponent == FrameCounterShim.dylibName
        )

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
            check("Bottle JSON round-trip leaves appliedFixes nil when unset", decoded.appliedFixes == nil)
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

        // `appliedFixes` was added after the type shipped; a metadata.json
        // with no such key (the legacy JSON above) must decode with nil,
        // and a populated value must survive a round trip.
        do {
            let decoded = try decoder.decode(Bottle.self, from: Data(legacyJSON.utf8))
            check("Bottle decodes legacy JSON missing the appliedFixes key", decoded.appliedFixes == nil)
        } catch {
            check("Bottle decodes legacy JSON missing the appliedFixes key", false, "\(error)")
        }

        var fixed = Bottle(name: "fixed", engineID: "gptk-3.0-3")
        fixed.appliedFixes = ["steam", "example-game"]
        do {
            let decoded = try decoder.decode(Bottle.self, from: try encoder.encode(fixed))
            check(
                "Bottle JSON round-trip preserves appliedFixes",
                decoded.appliedFixes == ["steam", "example-game"],
                "got \(String(describing: decoded.appliedFixes))"
            )
        } catch {
            check("Bottle JSON round-trip preserves appliedFixes", false, "\(error)")
        }
    }

    // MARK: - GameFix

    private static func testGameFix() {
        let fix = GameFix(
            id: "example-game",
            name: "Example Game",
            executables: ["Steam.exe"],
            steamAppIDs: ["12345"]
        )
        check(
            "GameFix matches by exe basename case-insensitively",
            fix.matches(exe: URL(fileURLWithPath: "/tmp/selftest/STEAM.EXE"))
                && fix.matches(exe: URL(fileURLWithPath: "/tmp/selftest/steam.exe"))
        )
        check(
            "GameFix does not match an unrelated exe",
            !fix.matches(exe: URL(fileURLWithPath: "/tmp/selftest/notepad.exe"))
        )
        check(
            "GameFix matches by steamAppID when supplied",
            fix.matches(exe: URL(fileURLWithPath: "/tmp/selftest/other.exe"), steamAppID: "12345")
        )
        check(
            "GameFix does not match a different steamAppID",
            !fix.matches(exe: URL(fileURLWithPath: "/tmp/selftest/other.exe"), steamAppID: "999")
        )

        // Regression guard for a real bug: Swift's *synthesized*
        // `init(from:)` ignores a property's default value and requires
        // its key, so with synthesized decoding a fix file had to spell
        // out every field — including empty arrays it has no use for —
        // and the three-field example in `GameFixCatalog`'s own doc
        // comment was rejected as malformed. `GameFix` hand-writes
        // `init(from:)` so both of these decode.
        let minimalJSON = Data(#"{"id":"minimal","name":"Minimal"}"#.utf8)
        let minimal = try? JSONDecoder().decode(GameFix.self, from: minimalJSON)
        check(
            "GameFix decodes JSON that omits every optional field",
            minimal?.id == "minimal"
                && minimal?.executables.isEmpty == true
                && minimal?.steamAppIDs.isEmpty == true
                && minimal?.registry.isEmpty == true
                && minimal?.winetricks.isEmpty == true
                && minimal?.env.isEmpty == true
                && minimal?.windowsVersion == nil
                && minimal?.launchArgs == nil,
            "got \(String(describing: minimal))"
        )

        let docExampleJSON = Data(#"""
        [{"id":"example-game","name":"Example Game","executables":["example.exe"],
          "winetricks":["vcrun2019"],
          "registry":[{"key":"HKCU\\Software\\Example","name":"Windowed","type":"REG_DWORD","data":"1"}],
          "env":{"SOME_VAR":"1"},"notes":"n","source":"s"}]
        """#.utf8)
        let docExample = try? JSONDecoder().decode([GameFix].self, from: docExampleJSON)
        check(
            "GameFixCatalog's documented example file decodes as written",
            docExample?.count == 1
                && docExample?.first?.winetricks == ["vcrun2019"]
                && docExample?.first?.env["SOME_VAR"] == "1"
                && docExample?.first?.steamAppIDs.isEmpty == true,
            "got \(String(describing: docExample))"
        )

        // End-to-end through the real `Paths.fixes` directory — the one
        // path the in-memory checks above can't reach, and the one that
        // silently breaks in production if the directory is never created
        // or the extension filter is wrong. Writes a uniquely-named file,
        // reads it back through the actual loader, then removes it.
        try? Paths.ensureAll()
        let probeID = "selftest-probe-\(UUID().uuidString.prefix(8))"
        let probeURL = Paths.fixes.appendingPathComponent("\(probeID).json")
        let probeJSON = Data(#"""
        {"id":"\#(probeID)","name":"Self-test probe","executables":["selftest-probe.exe"],
         "env":{"OVERPASS_SELFTEST":"1"}}
        """#.utf8)
        var loadedFromDisk = false
        var matchedFromDisk = false
        if (try? probeJSON.write(to: probeURL)) != nil {
            let loaded = GameFixCatalog.loadUserFixes()
            loadedFromDisk = loaded.fixes.contains { $0.id == probeID } && loaded.failed.isEmpty
            matchedFromDisk = GameFixCatalog
                .matching(exe: URL(fileURLWithPath: "/tmp/selftest/SELFTEST-PROBE.EXE"))
                .contains { $0.id == probeID }
            try? FileManager.default.removeItem(at: probeURL)
        }
        check("GameFixCatalog loads a fix file written to Paths.fixes", loadedFromDisk)
        check("GameFixCatalog.matching finds a fix that came from disk", matchedFromDisk)
        check(
            "the self-test probe fix was cleaned up",
            !FileManager.default.fileExists(atPath: probeURL.path)
        )

        // Quality bar for the shipped catalog: every built-in fix must be
        // identifiable, attributable and actually do something. A fix with
        // no source is folklore, and a fix with no mechanism is inert.
        let builtIn = GameFixCatalog.builtIn
        check(
            "every built-in fix has a unique id",
            Set(builtIn.map(\.id)).count == builtIn.count,
            "ids: \(builtIn.map(\.id))"
        )
        check(
            "every built-in fix cites a source",
            builtIn.allSatisfy { !($0.source ?? "").isEmpty },
            "missing: \(builtIn.filter { ($0.source ?? "").isEmpty }.map(\.id))"
        )
        check(
            "every built-in fix matches at least one executable",
            builtIn.allSatisfy { !$0.executables.isEmpty },
            "missing: \(builtIn.filter(\.executables.isEmpty).map(\.id))"
        )
        // An entry must either change something or say something. Carrying
        // an advisory counts: "this cannot work, go there instead" is the
        // most useful thing the database can tell someone about a program
        // that has no fix.
        check(
            "no built-in fix is inert",
            builtIn.allSatisfy { !$0.isInert },
            "inert: \(builtIn.filter(\.isInert).map(\.id))"
        )
        check(
            "an advisory-only entry is allowed and is not inert",
            GameFixCatalog.ubisoftConnect.isInert == false
                && GameFixCatalog.ubisoftConnect.winetricks.isEmpty
                && GameFixCatalog.ubisoftConnect.registry.isEmpty
                && GameFixCatalog.ubisoftConnect.advisory?.severity == .wontRun
        )

        // Regression guard for a near-miss: Helldivers 2's Steam launch
        // entry is the anti-cheat wrapper, not the engine binary. The
        // obvious guess does not exist, and an advisory on it would never
        // have fired.
        check(
            "Helldivers 2 matches start_protected_game.exe, not helldivers2.exe",
            GameFixCatalog.helldivers2.matches(exe: URL(fileURLWithPath: "/g/start_protected_game.exe"))
                && !GameFixCatalog.helldivers2.matches(exe: URL(fileURLWithPath: "/g/helldivers2.exe"))
        )
        check(
            "native-build advisories are .info, not alerts",
            [GameFixCatalog.noMansSky, GameFixCatalog.deadCells,
             GameFixCatalog.riseOfTheTombRaider, GameFixCatalog.mechabellum]
                .allSatisfy { $0.advisory?.severity == .info }
        )
        check(
            "an advisory survives a JSON round-trip",
            {
                guard
                    let data = try? JSONEncoder().encode(GameFixCatalog.helldivers2),
                    let back = try? JSONDecoder().decode(GameFix.self, from: data)
                else { return false }
                return back.advisory?.severity == .wontRun
                    && back.advisory?.message == GameFixCatalog.helldivers2.advisory?.message
            }()
        )

        // Advisory alternatives (see `AlternativeApp`). The lookup is
        // injected, so neither outcome depends on what is installed here.
        let fx = GameFixCatalog.helldivers2.advisory?.alternative
        check(
            "Helldivers 2 names FX Steam Launcher as its alternative",
            fx?.name == "FX Steam Launcher"
                && fx?.bundleIdentifier == "es.fxgam.steamac"
                && fx?.url.absoluteString == "https://github.com/StonkGuy/steamac"
        )
        check(
            "EA app and Ubisoft Connect do not recommend an alternative",
            GameFixCatalog.eaApp.advisory?.alternative == nil
                && GameFixCatalog.ubisoftConnect.advisory?.alternative == nil
        )
        check(
            "only Helldivers 2 carries an alternative among built-ins",
            builtIn.filter { $0.advisory?.alternative != nil }.map(\.id) == ["helldivers-2"]
        )

        // MARK: second research pass (2026-10-29)
        //
        // Structural guards on the entries added in that pass. They check
        // shape and the project's own rules - not that a game works, which
        // none of them claim.
        let secondPass: [GameFix] = [
            GameFixCatalog.amdADLStubGames, GameFixCatalog.borderlands3, GameFixCatalog.palworld,
            GameFixCatalog.starfield, GameFixCatalog.deathStranding, GameFixCatalog.dyingLight2,
            GameFixCatalog.sonicFrontiers, GameFixCatalog.ratchetAndClankRiftApart,
            GameFixCatalog.horizonForbiddenWest, GameFixCatalog.yakuza6,
            GameFixCatalog.cyberpunk2077, GameFixCatalog.baldursGate3, GameFixCatalog.control,
            GameFixCatalog.liesOfP, GameFixCatalog.civilizationVII,
            GameFixCatalog.fortnite, GameFixCatalog.valorant, GameFixCatalog.destiny2,
            GameFixCatalog.rainbowSixSiege, GameFixCatalog.eaJavelinGames,
            GameFixCatalog.grandTheftAutoV, GameFixCatalog.roblox, GameFixCatalog.deadByDaylight,
        ]
        check(
            "second-pass entries are all registered in builtIn",
            secondPass.allSatisfy { entry in builtIn.contains { $0.id == entry.id } },
            "missing: \(secondPass.filter { e in !builtIn.contains { $0.id == e.id } }.map(\.id))"
        )
        check(
            "every second-pass entry carries notes saying what was observed versus claimed",
            secondPass.allSatisfy { !($0.notes ?? "").isEmpty },
            "missing: \(secondPass.filter { ($0.notes ?? "").isEmpty }.map(\.id))"
        )
        check(
            "no two built-in fixes claim the same executable name",
            {
                var seen: [String: String] = [:]
                var clashes: [String] = []
                for fix in builtIn {
                    for exe in fix.executables.map({ $0.lowercased() }) {
                        if let other = seen[exe], other != fix.id { clashes.append("\(exe): \(other) vs \(fix.id)") }
                        seen[exe] = fix.id
                    }
                }
                return clashes.isEmpty
            }(),
            "clashes - GameFixService applies every match, so these would stack"
        )
        check(
            "no two built-in fixes claim the same Steam app id",
            {
                let ids = builtIn.flatMap(\.steamAppIDs)
                return Set(ids).count == ids.count
            }()
        )

        // Linux-only mechanisms must not creep in. The allowlist is the
        // whole policy: a new env key has to be added here on purpose.
        check(
            "built-in env keys are limited to ones with a macOS meaning",
            builtIn.allSatisfy { $0.env.keys.allSatisfy { $0 == "ROSETTA_ADVERTISE_AVX" } },
            "env keys: \(builtIn.flatMap { $0.env.keys })"
        )
        check(
            "no built-in fix ships a launch argument or variable aimed at an anti-cheat",
            {
                let banned = ["nobattleye", "-eac", "eac_", "anticheat", "anti-cheat", "no-eac"]
                return builtIn.allSatisfy { fix in
                    let hay = ([fix.launchArgs ?? ""] + fix.env.map { "\($0.key)=\($0.value)" })
                        .joined(separator: " ").lowercased()
                    return !banned.contains { hay.contains($0) }
                }
            }()
        )
        check(
            "no built-in fix ships a -vulkan argument (there is no Vulkan on macOS)",
            builtIn.allSatisfy { !($0.launchArgs ?? "").lowercased().contains("vulkan") }
        )
        check(
            "an empty-string registry value is always REG_SZ",
            builtIn.allSatisfy { fix in fix.registry.allSatisfy { !$0.data.isEmpty || $0.type == "REG_SZ" } }
        )

        // Anti-cheat titles say so and do nothing else.
        let antiCheat: [GameFix] = [
            GameFixCatalog.fortnite, GameFixCatalog.valorant, GameFixCatalog.destiny2,
            GameFixCatalog.rainbowSixSiege, GameFixCatalog.eaJavelinGames, GameFixCatalog.roblox,
        ]
        check(
            "unrunnable anti-cheat titles are .wontRun and only advise",
            antiCheat.allSatisfy { fix in
                fix.advisory?.severity == .wontRun
                    && fix.registry.isEmpty && fix.winetricks.isEmpty && fix.env.isEmpty
                    && fix.launchArgs == nil && fix.windowsVersion == nil
            }
        )
        check(
            "partly-working anti-cheat titles are .degraded and only advise",
            [GameFixCatalog.grandTheftAutoV, GameFixCatalog.deadByDaylight].allSatisfy { fix in
                fix.advisory?.severity == .degraded
                    && fix.registry.isEmpty && fix.winetricks.isEmpty && fix.env.isEmpty
                    && fix.launchArgs == nil && fix.windowsVersion == nil
            }
        )
        check(
            "Apex and Battlefield share one entry because they share EAAntiCheat.GameServiceLauncher.exe",
            GameFixCatalog.eaJavelinGames.matches(exe: URL(fileURLWithPath: "/g/EAAntiCheat.GameServiceLauncher.exe"))
                && GameFixCatalog.eaJavelinGames.steamAppIDs.contains("1172470")
                && GameFixCatalog.eaJavelinGames.steamAppIDs.contains("2807960")
        )
        check(
            "Elden Ring's launch executable resolves to the shared EAC-shim entry, whose text covers it (see its doc comment)",
            GameFixCatalog.matching(exe: URL(fileURLWithPath: "/g/Game/start_protected_game.exe")).map(\.id) == ["helldivers-2"]
        )

        // Native-build advisories added in this pass.
        let natives: [GameFix] = [
            GameFixCatalog.cyberpunk2077, GameFixCatalog.baldursGate3, GameFixCatalog.control,
            GameFixCatalog.liesOfP, GameFixCatalog.civilizationVII,
        ]
        check(
            "new native-build advisories are .info, carry an app id, and do not repeat the unmeasured 'slower' claim",
            natives.allSatisfy { fix in
                fix.advisory?.severity == .info && !fix.steamAppIDs.isEmpty
                    && !(fix.advisory?.message ?? "").contains("slower")
                    && (fix.advisory?.message ?? "").contains("native macOS build")
            }
        )
        check(
            "the four original native-build advisories keep their shared wording",
            [GameFixCatalog.noMansSky, GameFixCatalog.deadCells,
             GameFixCatalog.riseOfTheTombRaider, GameFixCatalog.mechabellum]
                .allSatisfy { ($0.advisory?.message ?? "").contains("slower and more fragile") }
        )
        check(
            "Baldur's Gate 3 matches Steam's launcher and both engine binaries",
            ["LariLauncher.exe", "bg3.exe", "bg3_dx11.exe"].allSatisfy {
                GameFixCatalog.baldursGate3.matches(exe: URL(fileURLWithPath: "/g/\($0)"))
            }
        )

        // ROSETTA_ADVERTISE_AVX group.
        let avx: [GameFix] = [
            GameFixCatalog.starfield, GameFixCatalog.deathStranding, GameFixCatalog.dyingLight2,
            GameFixCatalog.sonicFrontiers, GameFixCatalog.ratchetAndClankRiftApart,
            GameFixCatalog.horizonForbiddenWest, GameFixCatalog.yakuza6,
        ]
        check(
            "AVX entries set exactly ROSETTA_ADVERTISE_AVX=1 and nothing else",
            avx.allSatisfy { fix in
                fix.env == ["ROSETTA_ADVERTISE_AVX": "1"]
                    && fix.registry.isEmpty && fix.winetricks.isEmpty && fix.launchArgs == nil
                    && fix.windowsVersion == nil && fix.advisory == nil
            }
        )
        check(
            "AVX entries are launch-only, so they are never recorded as applied to a bottle",
            avx.allSatisfy(\.isLaunchOnly)
        )
        check(
            "AVX entries say what was verified first-hand and what is only claimed",
            avx.allSatisfy { fix in
                let n = fix.notes ?? ""
                return n.contains("FIRST-HAND") && n.contains("SOURCE-CLAIMED") && n.contains("NOT verified")
            }
        )
        check(
            "the Death Stranding entry matches ds.exe for both Steam editions",
            GameFixCatalog.deathStranding.matches(exe: URL(fileURLWithPath: "/g/ds.exe"))
                && GameFixCatalog.deathStranding.steamAppIDs.sorted() == ["1190460", "1850570"]
        )
        check(
            "Red Dead Redemption 2 is deliberately not in the AVX group",
            GameFixCatalog.matching(exe: URL(fileURLWithPath: "/g/RDR2.exe")).isEmpty
        )
        check(
            "fix env reaches the launch environment for an AVX title",
            GameFixCatalog.matching(exe: URL(fileURLWithPath: "/g/Starfield.exe"))
                .reduce(into: [String: String]()) { $0.merge($1.env) { _, new in new } }["ROSETTA_ADVERTISE_AVX"] == "1"
        )

        // The atiadlxx entry: one per-exe AppDefaults key per executable.
        let adl = GameFixCatalog.amdADLStubGames
        check(
            "the ADL fix scopes atiadlxx=\"\" to each executable through AppDefaults, not bottle-wide",
            adl.registry.count == adl.executables.count
                && adl.executables.allSatisfy { exe in
                    adl.registry.contains {
                        $0.key == "HKCU\\Software\\Wine\\AppDefaults\\\(exe)\\DllOverrides"
                            && $0.name == "atiadlxx" && $0.type == "REG_SZ" && $0.data == ""
                    }
                }
        )
        check(
            "the ADL fix never touches the bottle-wide DllOverrides key",
            !adl.registry.contains { $0.key == "HKCU\\Software\\Wine\\DllOverrides" }
        )
        check(
            "the ADL fix matches its three games and not Red Dead Redemption 2",
            ["FarCry5.exe", "WatchDogs2.exe", "CrashBandicootNSaneTrilogy.exe"].allSatisfy {
                adl.matches(exe: URL(fileURLWithPath: "/g/\($0)"))
            } && !adl.matches(exe: URL(fileURLWithPath: "/g/RDR2.exe"))
        )
        check(
            "the ADL fix survives a JSON round-trip including the empty value",
            {
                guard let data = try? JSONEncoder().encode(adl),
                      let back = try? JSONDecoder().decode(GameFix.self, from: data) else { return false }
                return back == adl && back.registry.allSatisfy { $0.data.isEmpty }
            }()
        )
        check(
            "the ADL fix is a bottle change (recorded once), unlike the launch-only entries",
            !adl.isLaunchOnly && adl.env.isEmpty
        )

        // Borderlands 3 and Palworld.
        check(
            "Borderlands 3 installs d3dcompiler_47 and vcrun2022 and forces no Windows version",
            GameFixCatalog.borderlands3.winetricks == ["d3dcompiler_47", "vcrun2022"]
                && GameFixCatalog.borderlands3.windowsVersion == nil
                && GameFixCatalog.borderlands3.matches(exe: URL(fileURLWithPath: "/g/Borderlands3.exe"))
        )
        check(
            "Palworld passes -dx12 to Palworld.exe and is launch-only",
            GameFixCatalog.palworld.launchArgs == "-dx12"
                && GameFixCatalog.palworld.isLaunchOnly
                && GameFixCatalog.palworld.matches(exe: URL(fileURLWithPath: "/g/Palworld.exe"))
        )
        check(
            "an advisory alternative survives a JSON round-trip",
            {
                guard
                    let data = try? JSONEncoder().encode(GameFixCatalog.helldivers2),
                    let back = try? JSONDecoder().decode(GameFix.self, from: data)
                else { return false }
                return back.advisory?.alternative == fx && fx != nil
            }()
        )
        check(
            "an advisory with no alternative key still decodes (old fix files)",
            {
                let json = #"{"id":"x","name":"X","executables":["x.exe"],"advisory":{"severity":"info","message":"m"}}"#
                guard let fix = try? JSONDecoder().decode(GameFix.self, from: Data(json.utf8)) else { return false }
                return fix.advisory?.message == "m" && fix.advisory?.alternative == nil
            }()
        )
        check(
            "an advisory without an alternative encodes without the key",
            {
                guard let data = try? JSONEncoder().encode(GameFixCatalog.eaApp) else { return false }
                return !String(decoding: data, as: UTF8.self).contains("alternative")
            }()
        )
        if let helldivers = GameFixCatalog.helldivers2.advisory, let fx {
            let installed = AlternativeApp.message(for: helldivers, lookup: { _ in URL(fileURLWithPath: "/Applications/FX.app") })
            let missing = AlternativeApp.message(for: helldivers, lookup: { _ in nil })
            check(
                "the message keeps the advisory text and adds the alternative",
                installed.hasPrefix(helldivers.message) && missing.hasPrefix(helldivers.message)
                    && installed.contains("FX Steam Launcher") && missing.contains("FX Steam Launcher")
            )
            check(
                "installed wording says it is installed and gives no URL",
                installed.contains("is installed on this Mac") && !installed.contains("github.com")
            )
            check(
                "not-installed wording says it is not installed and gives the URL",
                missing.contains("it is not installed") && missing.hasSuffix("https://github.com/StonkGuy/steamac.")
            )
            check(
                "the lookup is asked for the alternative's bundle identifier",
                {
                    var asked: String?
                    _ = AlternativeApp.installedURL(of: fx, lookup: { asked = $0; return nil })
                    return asked == "es.fxgam.steamac"
                }()
            )
            check(
                "the alternative adds exactly one sentence",
                missing.dropFirst(helldivers.message.count).filter { $0 == "." }.count == 2
                    && installed.dropFirst(helldivers.message.count).filter { $0 == "." }.count == 1
            )
        }
        check(
            "an advisory without an alternative is returned unchanged",
            GameFixCatalog.eaApp.advisory.map { AlternativeApp.message(for: $0, lookup: { _ in nil }) == $0.message } ?? false
        )

        // The DCS entry deliberately does NOT match the updater — it would
        // push a meaningless --no-launcher at it. See GameFixCatalog.
        check(
            "DCS fix matches DCS.exe but not DCS_updater.exe",
            GameFixCatalog.dcsWorld.matches(exe: URL(fileURLWithPath: "/g/bin/DCS.exe"))
                && !GameFixCatalog.dcsWorld.matches(exe: URL(fileURLWithPath: "/g/bin/DCS_updater.exe"))
        )
        check(
            "DCS fix carries the wbemprox override, d3dcompiler_47 and --no-launcher",
            GameFixCatalog.dcsWorld.registry.contains { $0.name == "wbemprox" && $0.data == "native" }
                && GameFixCatalog.dcsWorld.winetricks == ["d3dcompiler_47"]
                && GameFixCatalog.dcsWorld.launchArgs == "--no-launcher"
        )
        check(
            "Battle.net fix matches both of its executables",
            GameFixCatalog.battleNet.matches(exe: URL(fileURLWithPath: "/b/Battle.net Launcher.exe"))
                && GameFixCatalog.battleNet.matches(exe: URL(fileURLWithPath: "/b/Battle.net.exe"))
        )
        check(
            "the Epic fix is launch-only, so it costs no install time",
            GameFixCatalog.epicGamesLauncher.isLaunchOnly
        )
        check(
            "GameFix matches the exe basename, not a directory component",
            !fix.matches(exe: URL(fileURLWithPath: "/tmp/steam.exe/other.exe"))
        )

        let full = GameFix(
            id: "full",
            name: "Full",
            executables: ["full.exe"],
            registry: [.init(key: "HKCU\\Software\\Example", name: "Windowed", type: "REG_DWORD", data: "1")],
            winetricks: ["vcrun2019"],
            windowsVersion: .win7,
            env: ["SOME_VAR": "1"],
            launchArgs: "-windowed",
            notes: "Crashes on startup without vcrun2019."
        )
        do {
            let decoded = try JSONDecoder().decode(GameFix.self, from: try JSONEncoder().encode(full))
            check("GameFix JSON round-trip preserves registry", decoded.registry == full.registry)
            check("GameFix JSON round-trip preserves winetricks", decoded.winetricks == ["vcrun2019"])
            check("GameFix JSON round-trip preserves env", decoded.env == ["SOME_VAR": "1"])
            check("GameFix JSON round-trip preserves notes", decoded.notes == full.notes)
            check("GameFix JSON round-trip preserves the whole value", decoded == full)
        } catch {
            check("GameFix JSON round-trip succeeds", false, "\(error)")
        }

        // Merge precedence: user wins — the opposite of EngineCatalog,
        // deliberately (see GameFixCatalog's doc comment).
        let override = GameFix(id: "steam", name: "Steam (user override)", executables: ["steam.exe"])
        let extra = GameFix(id: "extra", name: "Extra", executables: ["extra.exe"])
        let merged = GameFixCatalog.merged(with: [override, extra])
        check(
            "GameFixCatalog.merged: a user fix with the same id overrides the built-in",
            merged.first(where: { $0.id == "steam" })?.name == "Steam (user override)"
        )
        check(
            "GameFixCatalog.merged: ids stay unique and user-only fixes are added",
            merged.count == Set(merged.map(\.id)).count && merged.contains(where: { $0.id == "extra" }),
            "got \(merged.map(\.id))"
        )
        check(
            "GameFixCatalog.merged with no user fixes is exactly builtIn",
            GameFixCatalog.merged(with: []).map(\.id) == GameFixCatalog.builtIn.map(\.id).sorted()
        )

        let builtInSteam = GameFixCatalog.builtIn.first(where: { $0.id == "steam" })
        check(
            "GameFixCatalog.builtIn contains the steam fix with its DWriteEnable registry entry",
            builtInSteam?.registry.contains(where: { $0.name == "DWriteEnable" && $0.data == "0" }) == true
        )
        check(
            "The built-in steam fix matches steam.exe",
            builtInSteam?.matches(exe: URL(fileURLWithPath: "/tmp/selftest/Steam.exe")) == true
        )

        // Regression guard: one copy of the Steam recipe, not two.
        check("AppTweaks.steam equals GameFixCatalog.steam.tweak", AppTweaks.steam == GameFixCatalog.steam.tweak)

        let envOnly = GameFix(id: "env-only", name: "Env only", executables: ["e.exe"], env: ["A": "1"], launchArgs: "-x")
        let withTricks = GameFix(id: "tricks", name: "Tricks", executables: ["t.exe"], winetricks: ["corefonts"])
        let withVersion = GameFix(id: "version", name: "Version", executables: ["v.exe"], windowsVersion: .win7)
        check("GameFix.isLaunchOnly is true for an env-only fix", envOnly.isLaunchOnly)
        check("GameFix.isLaunchOnly is false for a fix with winetricks", !withTricks.isLaunchOnly)
        check("GameFix.isLaunchOnly is false for a fix with a Windows version", !withVersion.isLaunchOnly)
        check("GameFix.tweak carries launchArgs and omits env", envOnly.tweak.launchArgs == "-x")
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

        testLogCursor(root: root)
    }

    // MARK: - LogStore.Cursor (install log de-duplication)

    /// Regression for the install progress view repeating itself: the
    /// poller used to re-append a sliding 4 KB tail every second.
    private static func testLogCursor(root: URL) {
        let url = root.appendingPathComponent("cursor.log")
        func append(_ text: String) {
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(text.utf8))
                try? handle.close()
            } else {
                try? Data(text.utf8).write(to: url)
            }
        }
        try? FileManager.default.removeItem(at: url)

        var cursor = LogStore.Cursor()
        check("cursor: a missing file yields nothing", cursor.advance(url) == "")

        append("one\ntwo\n")
        check("cursor: first read returns the whole file", cursor.advance(url) == "one\ntwo\n")
        check("cursor: a second read with no growth returns nothing", cursor.advance(url) == "")

        append("three\n")
        check("cursor: only the newly appended line is returned", cursor.advance(url) == "three\n")

        // Simulate the install view: feed every read through the same
        // splitting `AppInstallState.log` does and make sure no line is
        // ever emitted twice.
        var emitted: [String] = []
        var feed = LogStore.Cursor()
        try? FileManager.default.removeItem(at: url)
        for i in 1...40 {
            append("line \(i)\n")
            if i % 3 == 0 {
                emitted += feed.advance(url).split(separator: "\n").map(String.init)
            }
        }
        emitted += feed.advance(url).split(separator: "\n").map(String.init)
        check(
            "cursor: 40 lines polled every third line are each emitted exactly once, in order",
            emitted == (1...40).map { "line \($0)" },
            "got \(emitted.count) lines"
        )

        // A partial line is held back until its newline arrives.
        try? FileManager.default.removeItem(at: url)
        var partial = LogStore.Cursor()
        append("done\nhalf a li")
        check("cursor: an unterminated trailing line is held back", partial.advance(url) == "done\n")
        append("ne\n")
        check("cursor: the held-back line arrives whole", partial.advance(url) == "half a line\n")

        // The final flush releases an unterminated last line.
        append("no newline at end")
        check("cursor: no newline means nothing yet", partial.advance(url) == "")
        check("cursor: flushPartial releases it", partial.advance(url, flushPartial: true) == "no newline at end")
        check("cursor: and it is not released twice", partial.advance(url, flushPartial: true) == "")

        // Multibyte text is never split by the line boundary.
        try? FileManager.default.removeItem(at: url)
        var utf = LogStore.Cursor()
        append("caf\u{00E9} \u{2713}\n")
        check("cursor: multibyte text round-trips", utf.advance(url) == "caf\u{00E9} \u{2713}\n")

        // A pile-up larger than maxBytes is bounded to the newest bytes.
        try? FileManager.default.removeItem(at: url)
        var bounded = LogStore.Cursor()
        append((1...200).map { "row \($0)\n" }.joined())
        let burst = bounded.advance(url, maxBytes: 100)
        check(
            "cursor: a burst past maxBytes returns only the newest lines",
            burst.utf8.count <= 100 && burst.hasSuffix("row 200\n") && !burst.contains("row 1\n"),
            "got \(burst.utf8.count) bytes"
        )

        // A truncated or replaced file restarts from the top.
        try? Data("a\nb\nc\nd\n".utf8).write(to: url)
        var reset = LogStore.Cursor()
        _ = reset.advance(url)
        try? Data("x\n".utf8).write(to: url)
        check("cursor: a truncated file is re-read from the start", reset.advance(url) == "x\n")
    }

    // MARK: - LogFileName

    private static func testLogFileName() {
        let bottleID = UUID()
        let url = LogStore.newLogURL(bottleID: bottleID, exeName: "My-Game")
        defer { try? FileManager.default.removeItem(at: Paths.logs.appendingPathComponent(bottleID.uuidString)) }

        let parsed = LogFileName.parse(url)
        check("LogFileName.parse extracts the program name", parsed?.program == "My-Game", "got \(parsed?.program ?? "nil")")
        check(
            "LogFileName.parse's date round-trips through the stamp within a minute",
            parsed.map { abs($0.date.timeIntervalSinceNow) < 60 } ?? false
        )

        let display = LogFileName.displayName(for: url)
        check(
            "LogFileName.displayName includes the program name",
            display.contains("My-Game"),
            "got \(display)"
        )
        check(
            "LogFileName.displayName is not just the raw filename",
            display != url.lastPathComponent,
            "got \(display)"
        )

        // A filename that doesn't match the `<stamp>-<exe>.log` shape (no
        // dash at all) must not crash, and falls back to the raw name.
        let unrelated = Paths.logs.appendingPathComponent("not-a-log-name-at-all-either.log")
        check("LogFileName.parse returns nil for a non-conforming name", LogFileName.parse(unrelated) == nil)
        check(
            "LogFileName.displayName falls back to the raw filename when parse fails",
            LogFileName.displayName(for: unrelated) == unrelated.lastPathComponent
        )
    }

    // MARK: - Unreadable user fix files are surfaced once

    private static func testUserFixFailureNotice() {
        try? Paths.ensureAll()
        let badName = "selftest-broken-\(UUID().uuidString.prefix(8)).json"
        let badURL = Paths.fixes.appendingPathComponent(badName)
        defer { try? FileManager.default.removeItem(at: badURL) }
        guard (try? Data("{ this is not json".utf8).write(to: badURL)) != nil else {
            check("could write a broken fix file for the notice test", false)
            return
        }

        // `all` is what every launch goes through; it must note the file.
        _ = GameFixCatalog.all
        let first = GameFixCatalog.takeUserFixFailureNotice()
        check("a broken user fix file is named in the notice", first?.contains(badName) == true, "got \(String(describing: first))")

        // The next launch re-reads the same broken file: no second alert.
        _ = GameFixCatalog.all
        let second = GameFixCatalog.takeUserFixFailureNotice()
        check("the same broken file is not reported again", second == nil || second?.contains(badName) == false, "got \(String(describing: second))")

        // Fixed (removed) then broken again counts as new.
        try? FileManager.default.removeItem(at: badURL)
        _ = GameFixCatalog.all
        _ = GameFixCatalog.takeUserFixFailureNotice()
        try? Data("{ still not json".utf8).write(to: badURL)
        _ = GameFixCatalog.all
        let third = GameFixCatalog.takeUserFixFailureNotice()
        check("a file that breaks again after being fixed is reported again", third?.contains(badName) == true, "got \(String(describing: third))")
    }

    // MARK: - LogStore.logs ordering (decorate-sort rewrite)

    /// `LogStore.logs(for:)` now reads each file's modification date once
    /// instead of inside the sort comparator. Pins the behaviour the
    /// rewrite must keep: newest first by modification time, only `.log`
    /// files, hidden files ignored, and a deterministic order when two
    /// files share a timestamp.
    private static func testLogStoreOrdering() {
        let fm = FileManager.default
        let bottleID = UUID()
        let dir = Paths.logs.appendingPathComponent(bottleID.uuidString, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        func make(_ name: String, age: TimeInterval) {
            let path = dir.appendingPathComponent(name).path
            fm.createFile(atPath: path, contents: Data("x".utf8))
            try? fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: path)
        }
        make("20260101-000001-oldest.log", age: 300)
        make("20260101-000002-middle.log", age: 200)
        make("20260101-000003-newest.log", age: 100)
        make("notes.txt", age: 1)            // not a log
        make(".hidden.log", age: 1)          // hidden
        // Two files with an identical timestamp: order must be stable and
        // put the later-stamped name first.
        let tieDate = Date(timeIntervalSinceNow: -150)
        for name in ["20260101-000010-tie-a.log", "20260101-000020-tie-b.log"] {
            fm.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data("x".utf8))
            try? fm.setAttributes([.modificationDate: tieDate], ofItemAtPath: dir.appendingPathComponent(name).path)
        }

        let names = LogStore.logs(for: bottleID).map(\.lastPathComponent)
        check(
            "LogStore.logs lists .log files newest first, ties by name descending, skipping non-logs and hidden files",
            names == [
                "20260101-000003-newest.log",
                "20260101-000020-tie-b.log",
                "20260101-000010-tie-a.log",
                "20260101-000002-middle.log",
                "20260101-000001-oldest.log",
            ],
            "got \(names)"
        )
        check("LogStore.logs on a bottle with no log folder is empty", LogStore.logs(for: UUID()).isEmpty)
    }

    // MARK: - GameFixCatalog cache (fingerprint-validated)

    /// The user-fix cache must (a) actually avoid re-reading the folder
    /// when nothing changed, and (b) never serve stale data after any kind
    /// of write. These are the cases that matter, each against the real
    /// `Paths.fixes` folder with uniquely named files that are removed
    /// afterwards.
    private static func testUserFixCache() {
        let fm = FileManager.default
        try? Paths.ensureAll()
        let tag = UUID().uuidString.prefix(8)
        let urlA = Paths.fixes.appendingPathComponent("selftest-cache-a-\(tag).json")
        let urlB = Paths.fixes.appendingPathComponent("selftest-cache-b-\(tag).json")
        defer {
            // Restore permissions first so removal can't be blocked.
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: urlA.path)
            try? fm.removeItem(at: urlA)
            try? fm.removeItem(at: urlB)
        }
        let idA = "selftest-cache-a-\(tag)"
        let idB = "selftest-cache-b-\(tag)"

        func json(_ id: String, exe: String = "x.exe") -> Data {
            Data(#"{"id":"\#(id)","name":"Cache probe","executables":["\#(exe)"]}"#.utf8)
        }
        /// Writes `data` and stamps the file `age` seconds in the past.
        /// An age beyond the cache's racy window (2 s) lets the entry be
        /// cached; a smaller one exercises the racy-timestamp guard.
        func write(_ data: Data, to url: URL, age: TimeInterval, exactDate: Date? = nil) {
            try? data.write(to: url)
            try? fm.setAttributes([.modificationDate: exactDate ?? Date(timeIntervalSinceNow: -age)], ofItemAtPath: url.path)
        }
        func ids() -> Set<String> { Set(GameFixCatalog.all.map(\.id)) }

        // (a) A settled file is read once, then served from the cache.
        write(json(idA), to: urlA, age: 60)
        _ = GameFixCatalog.all
        let loadsAfterFirst = GameFixCatalog.userFixDiskLoadCount
        for _ in 0..<5 { _ = GameFixCatalog.all }
        check("fix cache: an unchanged folder is not re-read", GameFixCatalog.userFixDiskLoadCount == loadsAfterFirst,
              "loads went \(loadsAfterFirst) -> \(GameFixCatalog.userFixDiskLoadCount)")
        check("fix cache: the cached catalog contains the file", ids().contains(idA))
        check("fix cache: built-ins are still present", ids().isSuperset(of: GameFixCatalog.builtIn.map(\.id)))

        // (b1) Edit: different content, same byte length (the case a
        // size-only check would miss), new modification time.
        let idA2 = "selftest-cache-A-\(tag)"   // same length as idA
        check("fix cache test setup: edited id has the same length", idA2.utf8.count == idA.utf8.count)
        write(json(idA2), to: urlA, age: 50)
        let afterEdit = ids()
        check("fix cache: an edit with unchanged size is picked up", afterEdit.contains(idA2) && !afterEdit.contains(idA))

        // (b2) Racy edit: the file is rewritten with the same size AND the
        // identical timestamp, both inside the racy window. The
        // fingerprint cannot tell these apart, so the guard must force a
        // reload.
        let racyDate = Date(timeIntervalSinceNow: -0.5)
        write(json(idA), to: urlA, age: 0, exactDate: racyDate)
        check("fix cache: racy write is seen (1)", ids().contains(idA))
        write(json(idA2), to: urlA, age: 0, exactDate: racyDate)
        let racy = ids()
        check("fix cache: same-size same-timestamp rewrite inside the racy window is not served stale",
              racy.contains(idA2) && !racy.contains(idA))

        // Settle the file again so it can be cached, then add / remove.
        write(json(idA2), to: urlA, age: 60)
        _ = GameFixCatalog.all
        let settled = GameFixCatalog.userFixDiskLoadCount
        _ = GameFixCatalog.all
        check("fix cache: re-settled file is cached again", GameFixCatalog.userFixDiskLoadCount == settled)

        write(json(idB, exe: "b.exe"), to: urlB, age: 60)
        check("fix cache: a newly added file appears", ids().contains(idB))
        try? fm.removeItem(at: urlB)
        check("fix cache: a removed file disappears", !ids().contains(idB))
        check("fix cache: matching() sees the live catalog",
              GameFixCatalog.matching(exe: URL(fileURLWithPath: "/g/X.EXE")).contains { $0.id == idA2 })

        // (c) Failures: a broken file is reported once even though the
        // catalog is served from cache many times, and a file that is
        // fixed and then breaks again is reported again.
        _ = GameFixCatalog.takeUserFixFailureNotice()
        let badName = "selftest-cache-bad-\(tag).json"
        let badURL = Paths.fixes.appendingPathComponent(badName)
        defer { try? fm.removeItem(at: badURL) }
        write(Data("{ nope".utf8), to: badURL, age: 60)
        _ = GameFixCatalog.all
        _ = GameFixCatalog.all
        let first = GameFixCatalog.takeUserFixFailureNotice()
        check("fix cache: a broken file is reported", first?.contains(badName) == true, "got \(String(describing: first))")
        _ = GameFixCatalog.all
        let again = GameFixCatalog.takeUserFixFailureNotice()
        check("fix cache: a cache hit does not re-report the same broken file", again == nil || again?.contains(badName) == false)
        write(json("selftest-cache-fixed-\(tag)"), to: badURL, age: 40)
        _ = GameFixCatalog.all
        write(Data("{ nope again".utf8), to: badURL, age: 30)
        _ = GameFixCatalog.all
        let third = GameFixCatalog.takeUserFixFailureNotice()
        check("fix cache: a file that breaks again after being fixed is reported again", third?.contains(badName) == true)
        try? fm.removeItem(at: badURL)

        // (d) Permission change with no change to mtime or size: fixing a
        // chmod must turn a failure into a loaded fix.
        let idPerm = "selftest-cache-p-\(tag)"
        write(json(idPerm), to: urlA, age: 60)
        try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: urlA.path)
        _ = GameFixCatalog.all
        let unreadable = ids().contains(idPerm)
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: urlA.path)
        let readableAgain = ids().contains(idPerm)
        check("fix cache: an unreadable file is not loaded, and a chmod that fixes it is noticed",
              !unreadable && readableAgain, "unreadable=\(unreadable) readableAgain=\(readableAgain)")
        _ = GameFixCatalog.takeUserFixFailureNotice()

        // (e) Concurrency: many threads hammering `all` while the folder
        // changes underneath them must neither crash nor ever return a
        // catalog without the built-ins.
        let builtInCount = GameFixCatalog.builtIn.count
        let bad = ConcurrentFlag()
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for i in 0..<100 {
                if worker == 0, i % 10 == 0 {
                    write(json(idPerm, exe: "c\(i).exe"), to: urlA, age: 60 + Double(i))
                }
                if GameFixCatalog.all.count < builtInCount { bad.set() }
            }
        }
        check("fix cache: concurrent readers during writes stay consistent", !bad.isSet)
        _ = GameFixCatalog.takeUserFixFailureNotice()
    }

    /// Tiny thread-safe boolean for the concurrency check above.
    private final class ConcurrentFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    // MARK: - TreeSize (fts-based directory size)

    /// The `FileManager.enumerator` loop `TreeSize` replaced, kept here as
    /// the reference it must agree with.
    private static func referenceTreeSize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return -1 }
        var total: Int64 = 0
        while let fileURL = enumerator.nextObject() as? URL {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]) else { continue }
            if values.isDirectory == true { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    private static func testTreeSize(root: URL) {
        let fm = FileManager.default
        let tree = root.appendingPathComponent("treesize", isDirectory: true)
        let sub = tree.appendingPathComponent("a/b", isDirectory: true)
        let hiddenDir = tree.appendingPathComponent(".hiddendir", isDirectory: true)
        let outside = root.appendingPathComponent("treesize-outside", isDirectory: true)
        try? fm.createDirectory(at: sub, withIntermediateDirectories: true)
        try? fm.createDirectory(at: hiddenDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try? Data(count: 10).write(to: tree.appendingPathComponent("one.bin"))
        try? Data(count: 20).write(to: sub.appendingPathComponent("two.bin"))
        try? Data(count: 1000).write(to: tree.appendingPathComponent(".hidden-file"))
        try? Data(count: 1000).write(to: hiddenDir.appendingPathComponent("inside.bin"))
        try? Data(count: 5000).write(to: outside.appendingPathComponent("big.bin"))
        // A symlink to a directory with a 5000-byte file in it. It must be
        // counted as the link itself and never followed.
        try? fm.createSymbolicLink(atPath: tree.appendingPathComponent("link").path, withDestinationPath: outside.path)
        let linkSize = (try? fm.attributesOfItem(atPath: tree.appendingPathComponent("link").path)[.size] as? Int) ?? 0

        let size = TreeSize.totalFileSize(of: tree)
        check("TreeSize counts files, skips dot-files and dot-directories, and does not follow symlinks",
              size == Int64(10 + 20 + linkSize), "got \(String(describing: size)), expected \(10 + 20 + linkSize)")
        check("TreeSize agrees with the enumerator loop it replaced", size == referenceTreeSize(tree),
              "fts \(String(describing: size)) vs enumerator \(referenceTreeSize(tree))")
        check("TreeSize of a missing folder is nil",
              TreeSize.totalFileSize(of: root.appendingPathComponent("does-not-exist")) == nil)

        // Budget: more than 256 entries are needed before the clock is
        // consulted, and an already-expired budget must give up.
        let many = root.appendingPathComponent("treesize-many", isDirectory: true)
        try? fm.createDirectory(at: many, withIntermediateDirectories: true)
        for i in 0..<600 { fm.createFile(atPath: many.appendingPathComponent("f\(i)").path, contents: Data([1])) }
        check("TreeSize with an unlimited budget counts every file", TreeSize.totalFileSize(of: many) == 600)
        check("TreeSize returns nil once its time budget has run out", TreeSize.totalFileSize(of: many, budgetSeconds: -1) == nil)

        // The importer's size label goes through the same code.
        let prefix = root.appendingPathComponent("treesize-prefix", isDirectory: true)
        try? fm.createDirectory(at: prefix.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
        try? Data(count: 7).write(to: prefix.appendingPathComponent("system.reg"))
        try? Data(count: 11).write(to: prefix.appendingPathComponent("drive_c/x.bin"))
        check("BottleImporter.validate reports the prefix size via TreeSize",
              BottleImporter.validate(prefix)?.sizeBytes == 18, "got \(String(describing: BottleImporter.validate(prefix)?.sizeBytes))")
    }

    // MARK: - AppState.report appends

    private static func testReportAppending() {
        check("report: first message shows as-is", AppState.appendingReport("one", to: nil) == "one")
        check("report: empty existing text is treated as none", AppState.appendingReport("one", to: "") == "one")
        check(
            "report: a second message is appended after a blank line",
            AppState.appendingReport("two", to: "one") == "one\n\ntwo"
        )
        check(
            "report: an identical repeat is not duplicated",
            AppState.appendingReport("one", to: "one\n\ntwo") == "one\n\ntwo"
        )

        // Cap: oldest whole messages go first, newest stays.
        let chunk = String(repeating: "x", count: 200)
        var text: String? = nil
        for index in 1...5 { text = AppState.appendingReport("\(index)\(chunk)", to: text) }
        check(
            "report: stays within the character cap when messages fit individually",
            (text?.count ?? Int.max) <= AppState.reportCharacterLimit,
            "count \(text?.count ?? -1)"
        )
        check("report: the newest message survives the cap", text?.hasPrefix("1") == false && text?.hasSuffix("5" + chunk) == true)
        check("report: the oldest message is the one dropped", text?.contains("1" + chunk) == false)

        let huge = String(repeating: "y", count: AppState.reportCharacterLimit + 100)
        check(
            "report: a single over-long message is kept whole, not cut",
            AppState.appendingReport(huge, to: "earlier") == huge
        )

        // And through a real AppState: this test runs on the main thread.
        let combined = MainActor.assumeIsolated { () -> String? in
            let state = AppState()
            state.report("first problem")
            state.report(NSError(domain: "t", code: 1, userInfo: [NSLocalizedDescriptionKey: "second problem"]), context: "Doing a thing")
            return state.errorMessage
        }
        check(
            "report: AppState keeps both an error and a plain message",
            combined == "first problem\n\nDoing a thing: second problem",
            "got \(String(describing: combined))"
        )
    }

    // MARK: - Installer signature check

    private static func testInstallerSignature(root: URL) {
        check("installer signature: MZ is a PE", AppInstaller.hasWindowsInstallerSignature(Data([0x4D, 0x5A, 0x90, 0x00])))
        check("installer signature: OLE magic is an MSI", AppInstaller.hasWindowsInstallerSignature(Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1])))
        check("installer signature: HTML is not an installer", !AppInstaller.hasWindowsInstallerSignature(Data("<!DOCTYPE html>".utf8)))
        check("installer signature: empty data is not an installer", !AppInstaller.hasWindowsInstallerSignature(Data()))
        check("installer signature: a lone M is not an installer", !AppInstaller.hasWindowsInstallerSignature(Data([0x4D])))
        check("installer signature: a truncated OLE magic is not an installer", !AppInstaller.hasWindowsInstallerSignature(Data([0xD0, 0xCF, 0x11])))

        func probe(_ name: String, _ bytes: Data) -> Bool {
            let url = root.appendingPathComponent(name)
            try? bytes.write(to: url)
            return AppInstaller.looksLikeWindowsInstaller(at: url)
        }
        check("installer signature: reads an .exe-shaped file from disk", probe("sig-pe.exe", Data([0x4D, 0x5A] + [UInt8](repeating: 0, count: 64))))
        check("installer signature: reads an .msi-shaped file from disk", probe("sig-ole.msi", Data([0xD0, 0xCF, 0x11, 0xE0] + [UInt8](repeating: 0, count: 64))))
        check("installer signature: rejects an HTML error page saved as Setup.exe", !probe("sig-html.exe", Data("<html><body>404 Not Found</body></html>".utf8)))
        check(
            "installer signature: a missing file is not an installer",
            !AppInstaller.looksLikeWindowsInstaller(at: root.appendingPathComponent("does-not-exist.exe"))
        )
    }

    // MARK: - Diagnostics.formatBytes

    private static func testDiagnosticsFormatBytes() {
        check("formatBytes: bytes stay in B", Diagnostics.formatBytes(512) == "512 B", "got \(Diagnostics.formatBytes(512))")
        check("formatBytes: exactly 1024 rolls over to KB", Diagnostics.formatBytes(1024) == "1.0 KB", "got \(Diagnostics.formatBytes(1024))")
        check(
            "formatBytes: MB range",
            Diagnostics.formatBytes(5 * 1024 * 1024) == "5.0 MB",
            "got \(Diagnostics.formatBytes(5 * 1024 * 1024))"
        )
        check(
            "formatBytes: GB range (matches the ~2GB Steam-bottle measurement used for the run-tracking change)",
            Diagnostics.formatBytes(2 * 1024 * 1024 * 1024) == "2.0 GB",
            "got \(Diagnostics.formatBytes(2 * 1024 * 1024 * 1024))"
        )
        check("formatBytes: zero", Diagnostics.formatBytes(0) == "0 B", "got \(Diagnostics.formatBytes(0))")
    }
}
