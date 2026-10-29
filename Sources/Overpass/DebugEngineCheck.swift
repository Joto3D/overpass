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
/// - `Overpass --check-gptk-selftest` runs offline fixture tests of the
///   user-supplied GPTK 4 path (`GPTKRedist` + `EngineManager
///   .installUserSuppliedGPTK`) against fake payloads in a temp directory.
///   These are NOT part of `--self-test` (that file is owned elsewhere), so
///   run this flag separately; it prints its own pass/fail count.
/// - `Overpass --check-gptk-supplied <dmg-or-folder> [--install]` validates
///   a REAL download the user supplies, prints what it found and which
///   installed engines could carry it, and with `--install` assembles an
///   engine into a scratch directory (never into the real engines folder)
///   and runs its `wine --version`. Needs a real GPTK 4 file; none was
///   available when this was written beyond the already-extracted 4.0b3
///   `redist/lib` Bridgeplay keeps, so see the findings in `GPTKRedist`.
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

        if args.contains("--check-gptk-selftest") {
            runBlocking { try await checkGPTKSelfTest() }
            return
        }

        if let idx = args.firstIndex(of: "--check-gptk-supplied") {
            guard idx + 1 < args.count else {
                print("CHECK-ENGINE FAILED: --check-gptk-supplied needs a .dmg or folder path")
                exit(1)
            }
            let path = args[idx + 1]
            let install = args.contains("--install")
            runBlocking { try await checkGPTKSupplied(path: path, install: install) }
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
        guard merged.contains(where: { $0.id == "wine-staging-11.20" }) else {
            throw NSError(domain: "check-engine", code: 2, userInfo: [NSLocalizedDescriptionKey: "merged catalog is missing wine-staging-11.20"])
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

    // MARK: - User-supplied GPTK 4

    /// Validates (and optionally installs, into a scratch folder) a real
    /// user-supplied GPTK download, printing every fact `GPTKRedist` read.
    private static func checkGPTKSupplied(path: String, install: Bool) async throws {
        let source = URL(fileURLWithPath: path)
        let installed = await EngineManager.shared.installedEngines()
        log("installed engines: \(installed.map(\.id).joined(separator: ", "))")

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDir) else {
            throw GPTKRedistError.unsupportedSource("\"\(path)\" doesn't exist.")
        }
        // Folder sources can be inspected directly; a .dmg is inspected by
        // the install path's own mount, so only the folder gets the detailed
        // per-engine compatibility report here.
        if isDir.boolValue {
            guard let root = GPTKRedist.findRoot(under: source) else { throw GPTKRedistError.layoutNotFound }
            let report = try await GPTKRedist.validate(root: root)
            log("root: \(root.path)")
            log("D3DMetal \(report.d3dmetalVersion)  arch=\(report.architectures.joined(separator: ","))  signature checked=\(report.signatureChecked)")
            log("dlls: \(report.dllBaseNames.joined(separator: ", "))")
            log("license: \(report.licenseURL?.path ?? "none found")")
            for engine in installed {
                let gaps = GPTKRedist.unresolvedImports(
                    redistWindowsDir: root.appendingPathComponent("wine/x86_64-windows"),
                    baseWindowsDir: engine.libDir.appendingPathComponent("wine/x86_64-windows")
                )
                if gaps.isEmpty {
                    log("base \(engine.id): every by-name import resolves")
                } else {
                    for key in gaps.keys.sorted() { log("base \(engine.id): \(key) missing \((gaps[key] ?? []).sorted().joined(separator: ", "))") }
                }
            }
        }

        guard install else { return }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("overpass-gptk-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        log("installing into scratch folder \(scratch.path) (the real engines folder is not touched)…")
        let engine = try await EngineManager.shared.installUserSuppliedGPTK(from: source, enginesRoot: scratch, baseSearchRoot: Paths.engines) { fraction, status in
            log("  \(Int(fraction * 100))%  \(status)")
        }
        log("built \(engine.id) on \(engine.userSupplied?.baseEngineID ?? "?"): \(engine.versionString)")
        log("NOT verified by this check: that any Windows game renders on it.")
    }

    private static var selfTestPass = 0
    private static var selfTestFail = 0

    private static func expect(_ name: String, _ condition: @autoclosure () -> Bool, _ detail: String = "") {
        if condition() { selfTestPass += 1; print("  ok    \(name)") }
        else { selfTestFail += 1; print("  FAIL  \(name) \(detail)") }
    }

    private static func expectThrows(_ name: String, _ body: () async throws -> Void, matches: (GPTKRedistError) -> Bool) async {
        do { try await body(); expect(name, false, "did not throw") }
        catch let error as GPTKRedistError { expect(name, matches(error), "threw \(error)") }
        catch { expect(name, false, "threw unexpected \(error)") }
    }

    /// Offline fixture tests for the user-supplied GPTK path. Everything
    /// lives in a temp directory removed at the end; no network, no Wine
    /// except a one-line shell script standing in for `wine64`.
    private static func checkGPTKSelfTest() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("overpass-gptk-selftest-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        selfTestPass = 0; selfTestFail = 0

        // Mach-O headers
        let thin = root.appendingPathComponent("thin"), arm = root.appendingPathComponent("arm"), fat = root.appendingPathComponent("fat"), junk = root.appendingPathComponent("junk")
        try Data([0xCF, 0xFA, 0xED, 0xFE, 0x07, 0x00, 0x00, 0x01] + [UInt8](repeating: 0, count: 32)).write(to: thin)
        try Data([0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01] + [UInt8](repeating: 0, count: 32)).write(to: arm)
        try Data([0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 2,
                  // fat_arch = cputype, cpusubtype, offset, size, align (5 x 4 bytes, big-endian)
                  0x01, 0, 0, 0x07, 0, 0, 0, 3, 0, 0, 0x40, 0, 0, 0, 0x10, 0, 0, 0, 0, 0xE,
                  0x01, 0, 0, 0x0C, 0, 0, 0, 0, 0, 0, 0x80, 0, 0, 0, 0x10, 0, 0, 0, 0, 0xE]).write(to: fat)
        try Data("not a mach-o file".utf8).write(to: junk)
        expect("Mach-O thin x86_64", GPTKRedist.machOArchitectures(of: thin) == ["x86_64"])
        expect("Mach-O thin arm64", GPTKRedist.machOArchitectures(of: arm) == ["arm64"])
        expect("Mach-O fat x86_64+arm64", GPTKRedist.machOArchitectures(of: fat) == ["x86_64", "arm64"], "got \(GPTKRedist.machOArchitectures(of: fat))")
        expect("Mach-O garbage is empty", GPTKRedist.machOArchitectures(of: junk).isEmpty)

        // PE reader and import resolution
        let pe = PEImage(data: makePE(exports: ["Alpha", "Beta"], imports: [("GDI32.dll", ["Foo", "Bar"]), ("kernel32.dll", ["Baz"])]))
        expect("PE exports parsed", pe?.exportedNames == ["Alpha", "Beta"], "got \(String(describing: pe?.exportedNames))")
        expect("PE imports parsed", pe?.importsByName["gdi32.dll"] == ["Foo", "Bar"] && pe?.importsByName["kernel32.dll"] == ["Baz"], "got \(String(describing: pe?.importsByName))")
        expect("PE rejects non-PE", PEImage(data: Data("MZ but nothing else".utf8)) == nil)

        let redistWin = root.appendingPathComponent("rw"), baseWin = root.appendingPathComponent("bw")
        try fm.createDirectory(at: redistWin, withIntermediateDirectories: true)
        try fm.createDirectory(at: baseWin, withIntermediateDirectories: true)
        try makePE(exports: [], imports: [("gdi32.dll", ["Foo", "Bar"])]).write(to: redistWin.appendingPathComponent("dxgi.dll"))
        try makePE(exports: ["Foo"], imports: []).write(to: baseWin.appendingPathComponent("gdi32.dll"))
        let gaps = GPTKRedist.unresolvedImports(redistWindowsDir: redistWin, baseWindowsDir: baseWin)
        expect("unresolvedImports names the missing symbol", gaps == ["dxgi.dll -> gdi32.dll": ["Bar"]], "got \(gaps)")
        try makePE(exports: ["Foo", "Bar"], imports: []).write(to: baseWin.appendingPathComponent("gdi32.dll"))
        expect("unresolvedImports empty when satisfied", GPTKRedist.unresolvedImports(redistWindowsDir: redistWin, baseWindowsDir: baseWin).isEmpty)
        try fm.removeItem(at: baseWin.appendingPathComponent("gdi32.dll"))
        expect("unresolvedImports skips DLLs it cannot read", GPTKRedist.unresolvedImports(redistWindowsDir: redistWin, baseWindowsDir: baseWin).isEmpty)

        // ids
        expect("id sanitised", EngineCatalog.userSuppliedGPTKID(d3dmetalVersion: "4.0 b3/x", baseID: "wine-staging-11.20") == "gptk-4.0-b3-x-on-wine-staging-11.20")
        expect("leadingInteger", GPTKRedist.leadingInteger(of: "4.0b3") == 4 && GPTKRedist.leadingInteger(of: "x") == nil)

        // Layout discovery and validation
        let good = try makeRedist(at: root.appendingPathComponent("good/redist/lib"), version: "4.0b3", identifier: "com.apple.D3DMetal", machO: thin)
        expect("findRoot finds nested redist/lib", GPTKRedist.findRoot(under: root.appendingPathComponent("good"))?.standardizedFileURL == good.standardizedFileURL)
        expect("findRoot nil when absent", GPTKRedist.findRoot(under: root.appendingPathComponent("rw")) == nil)

        let report = try await GPTKRedist.validate(root: good, verifySignatures: false)
        expect("valid fixture validates", report.d3dmetalVersion == "4.0b3" && report.architectures == ["x86_64"] && report.dllBaseNames == ["d3d11", "d3d12", "dxgi"], "\(report)")
        await expectThrows("fake payload fails the real signature check", { _ = try await GPTKRedist.validate(root: good) }) {
            if case .signatureInvalid = $0 { return true }; return false
        }
        let v3 = try makeRedist(at: root.appendingPathComponent("v3"), version: "3.0", identifier: "com.apple.D3DMetal", machO: thin)
        await expectThrows("version 3 refused", { _ = try await GPTKRedist.validate(root: v3, verifySignatures: false) }) {
            if case .versionTooOld = $0 { return true }; return false
        }
        let notApple = try makeRedist(at: root.appendingPathComponent("notapple"), version: "4.0", identifier: "com.example.fake", machO: thin)
        await expectThrows("wrong bundle identifier refused", { _ = try await GPTKRedist.validate(root: notApple, verifySignatures: false) }) {
            if case .notD3DMetal = $0 { return true }; return false
        }
        let armOnly = try makeRedist(at: root.appendingPathComponent("armonly"), version: "4.0", identifier: "com.apple.D3DMetal", machO: arm)
        await expectThrows("arm64-only refused", { _ = try await GPTKRedist.validate(root: armOnly, verifySignatures: false) }) {
            if case .noX86Slice = $0 { return true }; return false
        }
        let partial = try makeRedist(at: root.appendingPathComponent("partial"), version: "4.0", identifier: "com.apple.D3DMetal", machO: thin)
        try fm.removeItem(at: partial.appendingPathComponent("wine/x86_64-windows/d3d12.dll"))
        await expectThrows("missing d3d12.dll refused", { _ = try await GPTKRedist.validate(root: partial, verifySignatures: false) }) {
            if case .missingFiles(let names) = $0 { return names.contains("wine/x86_64-windows/d3d12.dll") }; return false
        }

        // End-to-end install into a scratch engines folder
        let enginesRoot = root.appendingPathComponent("engines")
        let base = try makeBaseEngine(id: "wine-staging-fake", in: enginesRoot, gdi32Exports: ["Foo", "Bar", "D3DKMTEnumAdapters2"])
        let fixtureSource = root.appendingPathComponent("good")
        let built = try await EngineManager.shared.installUserSuppliedGPTK(
            from: fixtureSource, base: base, enginesRoot: enginesRoot, verifySignatures: false
        ) { _, _ in }
        expect("built engine id", built.id == "gptk-4.0b3-on-wine-staging-fake", built.id)
        expect("built engine kind/version", built.kind == .gptk && built.d3dmetalVersion == "4.0b3" && built.version == "4.0b3 + Wine Staging 12.0", built.version)
        expect("origin recorded", built.userSupplied?.baseEngineID == "wine-staging-fake" && built.userSupplied?.sourceSHA256 == nil && built.checksumVerified == false)
        let linkTarget = try? fm.destinationOfSymbolicLink(atPath: built.libDir.appendingPathComponent("wine/x86_64-unix/d3d11.so").path)
        expect("unix symlink recreated", linkTarget == "../../external/libd3dshared.dylib", "\(String(describing: linkTarget))")
        expect("external replaced", fm.fileExists(atPath: built.libDir.appendingPathComponent("external/libd3dshared.dylib").path))
        expect("D3DMetal dll replaced the base's", (try? Data(contentsOf: built.libDir.appendingPathComponent("wine/x86_64-windows/d3d11.dll")))?.count
               == (try? Data(contentsOf: good.appendingPathComponent("wine/x86_64-windows/d3d11.dll")))?.count)
        expect("license copied", fm.fileExists(atPath: built.rootDir.appendingPathComponent("GPTK-License.rtf").path))
        expect("base left untouched", !fm.fileExists(atPath: base.libDir.appendingPathComponent("external").path))
        let listed = await EngineManager.shared.installedEngines(in: enginesRoot).map(\.id)
        expect("listed alongside the base", listed == ["gptk-4.0b3-on-wine-staging-fake", "wine-staging-fake"], "\(listed)")
        let reread = await EngineManager.shared.installedEngines(in: enginesRoot).first?.userSupplied?.baseVersionString
        expect("re-read from installed.json", reread == "wine-fake", "\(String(describing: reread))")

        // Incompatible base: refuses, names the symbol, leaves no folder behind
        let oldBase = try makeBaseEngine(id: "wine-old-fake", in: enginesRoot, gdi32Exports: ["Foo"])
        let needy = try makeRedist(at: root.appendingPathComponent("needy"), version: "4.0b3", identifier: "com.apple.D3DMetal", machO: thin, dxgiImports: [("gdi32.dll", ["Foo", "D3DKMTEnumAdapters2"])])
        await expectThrows("incompatible base refused", {
            _ = try await EngineManager.shared.installUserSuppliedGPTK(from: needy, base: oldBase, enginesRoot: enginesRoot, verifySignatures: false) { _, _ in }
        }) {
            if case .incompatibleBase(_, let missing) = $0 { return missing.values.flatMap { $0 }.contains("D3DKMTEnumAdapters2") }; return false
        }
        expect("no engine folder left after refusal", !fm.fileExists(atPath: enginesRoot.appendingPathComponent("gptk-4.0b3-on-wine-old-fake").path))

        // Automatic base choice skips the old engine, takes the compatible one
        let auto = try await EngineManager.shared.installUserSuppliedGPTK(from: needy, enginesRoot: enginesRoot, verifySignatures: false) { _, _ in }
        expect("auto base skips the newer-but-incompatible engine", auto.userSupplied?.baseEngineID == "wine-staging-fake", "\(String(describing: auto.userSupplied?.baseEngineID))")

        let onlyOldRoot = root.appendingPathComponent("engines-only-old")
        _ = try makeBaseEngine(id: "wine-old-fake", in: onlyOldRoot, gdi32Exports: ["Foo"])
        await expectThrows("no compatible engine installed -> noSuitableBase", {
            _ = try await EngineManager.shared.installUserSuppliedGPTK(from: needy, enginesRoot: onlyOldRoot, verifySignatures: false) { _, _ in }
        }) {
            if case .noSuitableBase = $0 { return true }; return false
        }

        print("GPTK-SELFTEST: \(selfTestPass) passed, \(selfTestFail) failed")
        if selfTestFail > 0 {
            throw NSError(domain: "check-engine", code: 6, userInfo: [NSLocalizedDescriptionKey: "\(selfTestFail) GPTK fixture check(s) failed"])
        }
    }

    /// Builds a fake `redist/lib`: Mach-O stand-ins, an Info.plist, three
    /// PE stubs (dxgi optionally with imports) and the `.so` symlinks.
    @discardableResult
    private static func makeRedist(
        at root: URL, version: String, identifier: String, machO: URL, dxgiImports: [(String, [String])] = []
    ) throws -> URL {
        let fm = FileManager.default
        let external = root.appendingPathComponent("external")
        let resources = external.appendingPathComponent("D3DMetal.framework/Resources")
        let windows = root.appendingPathComponent("wine/x86_64-windows")
        let unix = root.appendingPathComponent("wine/x86_64-unix")
        for dir in [resources, windows, unix] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        try fm.copyItem(at: machO, to: external.appendingPathComponent("libd3dshared.dylib"))
        let plist: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": version]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: resources.appendingPathComponent("Info.plist"))
        for name in ["d3d11", "d3d12", "dxgi"] {
            let imports = name == "dxgi" ? dxgiImports : []
            try makePE(exports: ["Stub_\(name)"], imports: imports).write(to: windows.appendingPathComponent("\(name).dll"))
            try fm.createSymbolicLink(atPath: unix.appendingPathComponent("\(name).so").path, withDestinationPath: "../../external/libd3dshared.dylib")
        }
        try Data("license".utf8).write(to: root.deletingLastPathComponent().appendingPathComponent("License.rtf"))
        return root
    }

    /// A fake installed Wine: a shell script for `bin/wine64`, a stock
    /// `d3d11.dll`, and a `gdi32.dll` exporting `gdi32Exports`.
    private static func makeBaseEngine(id: String, in enginesRoot: URL, gdi32Exports: [String]) throws -> InstalledEngine {
        let fm = FileManager.default
        let rootDir = enginesRoot.appendingPathComponent(id, isDirectory: true)
        let app = rootDir.appendingPathComponent("Fake.app/Contents/Resources/wine")
        let bin = app.appendingPathComponent("bin"), lib = app.appendingPathComponent("lib")
        for dir in [bin, lib.appendingPathComponent("wine/x86_64-windows"), lib.appendingPathComponent("wine/x86_64-unix")] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let script = bin.appendingPathComponent("wine64")
        try "#!/bin/sh\necho wine-fake\n".write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try makePE(exports: ["Stock"], imports: []).write(to: lib.appendingPathComponent("wine/x86_64-windows/d3d11.dll"))
        try makePE(exports: gdi32Exports, imports: []).write(to: lib.appendingPathComponent("wine/x86_64-windows/gdi32.dll"))
        let engine = InstalledEngine(
            id: id, kind: .wineStaging, version: id.contains("old") ? "13.0" : "12.0", rootDir: rootDir, binDir: bin, libDir: lib,
            versionString: "wine-fake", installedAt: Date()
        )
        try JSONEncoder.iso.encode(engine).write(to: rootDir.appendingPathComponent("installed.json"))
        return engine
    }

    /// Emits a minimal PE32+ image with one `.rdata` section holding an
    /// export table (`exports`) and an import table (`imports`: DLL name ->
    /// symbol names), laid out per the PE format so `PEImage` parses it.
    private static func makePE(exports: [String], imports: [(String, [String])]) -> Data {
        var sec: [UInt8] = []
        func rva(_ offset: Int) -> UInt32 { UInt32(0x1000 + offset) }
        func put32(_ value: UInt32, at o: Int) { for i in 0..<4 { sec[o + i] = UInt8((value >> (8 * UInt32(i))) & 0xFF) } }
        func put64(_ value: UInt64, at o: Int) { for i in 0..<8 { sec[o + i] = UInt8((value >> (8 * UInt64(i))) & 0xFF) } }
        var exportRVA: UInt32 = 0, exportSize: UInt32 = 0, importRVA: UInt32 = 0, importSize: UInt32 = 0

        if !exports.isEmpty {
            let dir = sec.count; sec += [UInt8](repeating: 0, count: 40)
            let names = sec.count; sec += [UInt8](repeating: 0, count: exports.count * 4)
            var strings: [Int] = []
            for name in exports { strings.append(sec.count); sec += Array(name.utf8) + [0] }
            put32(UInt32(exports.count), at: dir + 24); put32(rva(names), at: dir + 32)
            for (i, o) in strings.enumerated() { put32(rva(o), at: names + i * 4) }
            exportRVA = rva(dir); exportSize = 40
        }
        if !imports.isEmpty {
            let descriptors = sec.count; sec += [UInt8](repeating: 0, count: (imports.count + 1) * 20)
            for (i, entry) in imports.enumerated() {
                let nameOffset = sec.count; sec += Array(entry.0.utf8) + [0]
                var hintNames: [Int] = []
                for symbol in entry.1 { hintNames.append(sec.count); sec += [0, 0] + Array(symbol.utf8) + [0] }
                while sec.count % 8 != 0 { sec.append(0) }
                let thunks = sec.count; sec += [UInt8](repeating: 0, count: (entry.1.count + 1) * 8)
                for (j, o) in hintNames.enumerated() { put64(UInt64(rva(o)), at: thunks + j * 8) }
                put32(rva(thunks), at: descriptors + i * 20)
                put32(rva(nameOffset), at: descriptors + i * 20 + 12)
                put32(rva(thunks), at: descriptors + i * 20 + 16)
            }
            importRVA = rva(descriptors); importSize = UInt32((imports.count + 1) * 20)
        }

        var file = [UInt8](repeating: 0, count: 0x400)
        func f16(_ v: UInt16, _ o: Int) { file[o] = UInt8(v & 0xFF); file[o + 1] = UInt8(v >> 8) }
        func f32(_ v: UInt32, _ o: Int) { f16(UInt16(v & 0xFFFF), o); f16(UInt16(v >> 16), o + 2) }
        f16(0x5A4D, 0); f32(0x40, 0x3C)                       // MZ, e_lfanew
        f32(0x0000_4550, 0x40)                                // "PE\0\0"
        f16(0x8664, 0x44); f16(1, 0x46); f16(240, 0x54)       // machine, sections, optional size
        f16(0x20B, 0x58)                                      // PE32+
        f32(exportRVA, 0xC8); f32(exportSize, 0xCC)           // data directory 0
        f32(importRVA, 0xD0); f32(importSize, 0xD4)           // data directory 1
        let table = 0x58 + 240
        f32(UInt32(sec.count), table + 8); f32(0x1000, table + 12); f32(UInt32(sec.count), table + 16); f32(0x400, table + 20)
        return Data(file + sec)
    }
}

private extension JSONEncoder {
    /// Same encoder settings `EngineManager.writeInstalledJSON` uses, so
    /// fixture `installed.json` files round-trip through `installedEngines`.
    static var iso: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
