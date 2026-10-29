import Foundation

// MARK: - Research record (verified October 2026)
//
// Everything below the "Findings" heading was observed on this machine
// (Mac mini, Apple silicon, macOS 27) or read from a primary source, on
// 2026-10-29. It is recorded here so nobody re-derives it.
//
// ## What Apple's Game Porting Toolkit 4 ships as
//
// - **It is not a Wine build.** Apple's download is the "Evaluation
//   environment for Windows games" `.dmg`; the part Overpass can use is its
//   `redist/lib` folder: `external/{D3DMetal.framework, libd3dshared.dylib}`
//   plus `wine/x86_64-windows/*.dll` (thin PE stubs) and
//   `wine/x86_64-unix/*.so` (symlinks to `../../external/libd3dshared.dylib`).
//   Apple's own licence calls the contents of `/redist` "Redistributables".
//   Independent confirmation: Bridgeplay (installed at /Applications) tells
//   its user to "Copy the redist/lib folder of Apple's Game Porting Toolkit"
//   into its own `gptk` folder, and mounts the `.dmg` with `hdiutil` to find
//   it — the same layout `D3DMetalImporter` already searches for.
//   Gcenx's `game-porting-toolkit` releases are different: they are Apple's
//   Wine 7.7 fork *built from source* with the redistributables dropped in,
//   which is why a pinned URL exists for GPTK 3 and cannot exist for GPTK 4
//   until somebody repackages it (newest Gcenx release is still 3.0-3,
//   2026-03-03; checked via the GitHub API).
// - **Apple has no Wine in it for us to use.** There is nothing to install
//   "as an engine" from the `.dmg` alone — it has to be layered on top of a
//   Wine that already exists. That is what `EngineManager
//   .installUserSuppliedGPTK` does: clone an installed base engine, then
//   overlay the redistributables into the clone's *own* `lib/` tree.
//
// ## What is in it, as far as can be seen (GPTK 4.0b3 only)
//
// The only GPTK 4 payload available here is Bridgeplay's copy of the
// **4.0b3** redistributables at
// `~/Library/Application Support/bridgeplay/gptk` (D3DMetal.framework
// `CFBundleShortVersionString` = "4.0b3", built with Xcode 26.4.1). The
// final GPTK 4 release may differ from it; nothing below has been checked
// against a final build.
//
// - `libd3dshared.dylib` is 250,672 bytes vs 95,952 for GPTK 3.0.
// - The D3DMetal binary mentions 20 `MTL4*` strings (`MTL4CommandQueue`,
//   `MTL4CommitFeedback`, `MTL4BufferRange`, ...) against 1 in GPTK 3.0's
//   — i.e. it is built against the Metal 4 API, consistent with Apple's
//   "evaluation environment now supports Metal 4" announcement.
// - Against the 3.0 engine, the copy examined adds `d3d12core.dll` and has
//   no `atidxx64`, `nvngx`, `d3d9`, `d3d10_1` or `d3d10core` (Bridgeplay may
//   have pruned its copy; the real `.dmg` was not available to compare).
// - **Still x86_64-only.** `lipo -archs` on both `libd3dshared.dylib` and
//   `D3DMetal.framework/D3DMetal` says `x86_64` (thin, `minos 14.0`,
//   SDK 26.4). So it still needs an x86_64 Wine under Rosetta 2 — press
//   coverage that GPTK 4 "removes Intel support" refers to Intel *Macs*, not
//   to the translation layer's own architecture. A future arm64-only build
//   cannot be `dlopen`ed by an x86_64 Wine; `GPTKRedist.validate` rejects
//   such a download with a clear message instead of installing it.
// - Signed by Apple: `codesign -dvv` shows the chain
//   `Software Signing` → `Apple Code Signing Certification Authority` →
//   `Apple Root CA`, and `codesign --verify --deep --strict` passes.
//   TeamIdentifier is "not set" (Apple's own platform signing). This is
//   the strongest provenance check available — Apple publishes no
//   checksum for the `.dmg` — so `validate` requires it.
//
// ## Redistribution / auto-download: NOT permitted, so user-supplied only
//
// - The download link on developer.apple.com redirects to
//   `idmsa.apple.com/IDMSWebAuth/signin.html` (observed with `curl -I`):
//   it is gated behind an Apple Account sign-in. There is no public URL.
// - The licence (`License.rtf`, "Software License Agreement for Game Porting
//   Toolkit", EA18380) lets you "distribute the Apple Software solely for
//   non-commercial purposes" (2A(iii)) and says components "may not be
//   separated from the Apple Software for distribution", except that "the
//   Framework in its entirety or any part of the Redistributables may be
//   distributed separately", still subject to the non-commercial restriction
//   (2C). It also forbids reverse engineering and modification (2D), and
//   restricts use to Apple-branded hardware. The text we read is the
//   licence file shipped inside Bridgeplay's copy (dated 8/17/2023 in its
//   footer); whether the GPTK 4 `.dmg` carries a newer one is unverified.
//   Overpass therefore never bundles, mirrors or downloads these files; it
//   only operates on a file the user fetched themselves while signed in,
//   and copies the licence next to the installed engine so the notice
//   travels with the copy (2C: "reproduce ... all copyright or other
//   proprietary notices").
//
// ## Findings: does GPTK 4.0b3 work on the engines Overpass already has?
//
// Each test used a throwaway APFS clone of an installed engine and a
// scratch `WINEPREFIX` in the session scratchpad; no real bottle was
// touched.
//
// 1. **On `gptk-3.0-3` (Apple's Wine 7.7): the full 4.0b3 overlay breaks.**
//    `dxgi.dll` fails to initialise:
//    `warn:module:import_dll No implementation for gdi32.dll
//    .D3DKMTEnumAdapters2 imported from L"C:\windows\system32\dxgi.dll"` then
//    `warn:module:process_attach Initialization of L"dxgi.dll" failed`.
//    The same `dxdiag` run on the untouched 3.0-3 clone exits 0 and loads
//    `dxgi.dll` cleanly. The new stub needs a Win32 API Wine 7.7 does not
//    have, so GPTK 4 cannot ride on Gcenx's GPTK 3 build. (Replacing only
//    `lib/external`, as `D3DMetalImporter` does, left `dxdiag` exiting 0 —
//    but `dxdiag` there never proves D3DMetal engaged, so that mixed 3.0-PE
//    + 4.0b3-dylib state is **unverified**, not "works".)
//    `GPTKRedist.unresolvedImports` reproduces this check statically from
//    the PE import tables, so the install is refused up front.
// 2. **On a clone of `wine-staging-11.20`, with the files placed inside
//    the clone's own `lib/wine/x86_64-{windows,unix}` and `lib/external`:**
//    - Wine maps the *new* stubs (`WINEDEBUG=+module` shows `dxgi.dll`
//      mapped over 0x1028000 bytes — the 4.0b3 image's virtual size, the
//      same figure the Wine 7.7 run printed for it) and `regsvr32` loads
//      `d3d12.dll`,
//      `d3d12core.dll`, `dxgi.dll` and `nvngx-on-metalfx.dll` as builtin
//      without error.
//    - `vmmap` of a running process shows `libd3dshared.dylib` and
//      D3DMetal's `libdxccontainer.dylib` mapped from the clone's
//      `lib/external` — so, unlike the `WINEDLLPATH` overlay in
//      `D3DMetalOverlay` (which the findings there show is never consulted),
//      placing the files *inside the engine's own tree* does make the
//      unixlib load.
//    - **But:** `regsvr32 d3d11.dll` then hangs (killed by a 90 s alarm,
//      exit 142) and only then, so something in D3DMetal's `d3d11`
//      initialisation does not return. It was not diagnosed.
//    - **Not verified:** that any D3D11/D3D12 game actually renders. This
//      machine has no Windows toolchain and no D3D test executable, so no
//      device was ever created. Treat the resulting engine as an
//      experiment, not a known-good configuration.
// 3. Consequence for the design: the base engine is chosen by a **static
//    compatibility check** (`unresolvedImports`) rather than by assuming
//    which `EngineKind` is safe. On the two cases above it names exactly
//    the symbol that broke case 1 and finds nothing missing for case 2
//    (see `DebugEngineCheck --check-gptk-supplied`).

/// Errors from `GPTKRedist` validation and
/// `EngineManager.installUserSuppliedGPTK`, each with a user-facing message.
enum GPTKRedistError: LocalizedError {
    /// Source is neither a `.dmg` nor a folder, or does not exist.
    case unsupportedSource(String)
    /// `hdiutil attach` failed.
    case attachFailed(String)
    /// No folder with `external/libd3dshared.dylib` and `wine/x86_64-windows`.
    case layoutNotFound
    /// Required files absent from an otherwise recognisable payload.
    case missingFiles([String])
    /// `D3DMetal.framework`'s Info.plist is not Apple's D3DMetal.
    case notD3DMetal(String)
    /// D3DMetal major version is below what this path supports.
    case versionTooOld(found: String)
    /// No x86_64 slice, so an x86_64 Wine under Rosetta cannot load it.
    case noX86Slice(found: [String])
    /// `codesign` rejected the payload or it is not signed by Apple.
    case signatureInvalid(String)
    /// No installed engine can satisfy the payload's Win32 imports.
    case noSuitableBase(String)
    /// The chosen base engine lacks Win32 APIs the payload imports.
    case incompatibleBase(base: String, missing: [String: [String]])
    /// Cloning/overlaying files failed.
    case copyFailed(String)
    /// The new engine's wine binary would not run after the overlay.
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSource(let detail):
            return "Choose the Game Porting Toolkit .dmg you downloaded from developer.apple.com (or its redist/lib folder). \(detail)"
        case .attachFailed(let detail):
            return "Couldn't mount the .dmg: \(detail)"
        case .layoutNotFound:
            return "No Game Porting Toolkit redistributables found: expected a folder with external/libd3dshared.dylib and wine/x86_64-windows (normally redist/lib inside Apple's .dmg)."
        case .missingFiles(let names):
            return "The download is incomplete — missing: \(names.joined(separator: ", "))."
        case .notD3DMetal(let detail):
            return "This isn't Apple's D3DMetal: \(detail)"
        case .versionTooOld(let found):
            return "This is D3DMetal \(found). This option is for Game Porting Toolkit 4 or newer — for version 3, install the Game Porting Toolkit 3.0-3 engine from the list instead."
        case .noX86Slice(let found):
            return "This build of D3DMetal contains only \(found.isEmpty ? "unrecognised" : found.joined(separator: ", ")) code. Overpass's Wine engines are x86_64 programs running under Rosetta 2 and cannot load it."
        case .signatureInvalid(let detail):
            return "The D3DMetal files don't carry an intact Apple signature, so they were not installed. \(detail)"
        case .noSuitableBase(let detail):
            return "No installed Wine engine can run this version of D3DMetal. Install the newest Wine Staging engine first. \(detail)"
        case .incompatibleBase(let base, let missing):
            let detail = missing.keys.sorted().map { dll in
                "\(dll): \((missing[dll] ?? []).sorted().joined(separator: ", "))"
            }.joined(separator: "; ")
            return "\(base) is too old for this D3DMetal — it lacks Windows APIs the new files import (\(detail)). Choose a newer Wine engine."
        case .copyFailed(let detail):
            return "Couldn't build the engine: \(detail)"
        case .verificationFailed(let detail):
            return "The engine was assembled but its wine binary failed to run, so it was removed. \(detail)"
        }
    }
}

/// What `GPTKRedist.validate` established about a user-supplied download.
/// Everything here was read from the files, not from their names.
struct GPTKRedistReport: Sendable {
    /// Folder holding `external/` and `wine/` (Apple's `redist/lib`).
    let root: URL
    /// `D3DMetal.framework`'s `CFBundleShortVersionString`, e.g. "4.0b3".
    let d3dmetalVersion: String
    /// Architectures found in `libd3dshared.dylib` (always includes x86_64
    /// once validation has passed).
    let architectures: [String]
    /// Basenames (no extension) of every `.dll` under `wine/x86_64-windows`.
    let dllBaseNames: [String]
    /// Apple's `License.rtf`, if one sits at `root` or its parent.
    let licenseURL: URL?
    /// Whether the signature checks ran (false only in fixture tests).
    let signatureChecked: Bool
}

/// Reads, validates and describes Apple Game Porting Toolkit
/// "redistributables" a user obtained themselves. Pure file inspection —
/// nothing here writes outside a temp mount point, and nothing is trusted
/// beyond what `validate` verified. See the research record at the top of
/// this file for why this exists and what is and is not known to work.
enum GPTKRedist {
    /// Basenames that must be present for the payload to be D3DMetal at all:
    /// the DirectX 11 and 12 entry points and DXGI. Deliberately fewer
    /// than a full set — GPTK has shipped different extras per release
    /// (4.0b3 has `d3d12core`, 3.0 had `atidxx64`), so demanding the full
    /// list would reject a legitimate future build.
    static let requiredDLLs = ["d3d11", "d3d12", "dxgi"]

    /// `CFBundleIdentifier` of Apple's framework (observed in 4.0b3).
    static let frameworkIdentifier = "com.apple.D3DMetal"

    /// Lowest D3DMetal major version this install path accepts. Version 3
    /// ships as the pinned `gptk-3.0-3` engine, whose Wine it was built
    /// for; this path exists for 4.x (see research record, finding 1).
    static let minimumMajorVersion = 4

    /// Codesign `Authority=` line that proves the signature chains to
    /// Apple's root, not merely that the files hash to their own seal.
    static let appleRootAuthority = "Authority=Apple Root CA"

    // MARK: - Locating

    /// Finds the folder that contains `external/libd3dshared.dylib` and
    /// `wine/x86_64-windows`, searching at most `maxDepth` levels below
    /// `start` and preferring the shallowest. Discovered rather than
    /// assumed because Apple's `.dmg` layouts have varied (`redist/lib`,
    /// `lib`), exactly as `D3DMetalImporter` already allows for.
    static func findRoot(under start: URL, maxDepth: Int = 6) -> URL? {
        let fm = FileManager.default
        var best: (depth: Int, url: URL)?
        let baseDepth = start.standardizedFileURL.pathComponents.count
        guard let enumerator = fm.enumerator(
            at: start, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles], errorHandler: nil
        ) else { return nil }
        for case let candidate as URL in enumerator {
            let depth = candidate.standardizedFileURL.pathComponents.count - baseDepth
            if depth > maxDepth { enumerator.skipDescendants(); continue }
            guard candidate.lastPathComponent == "libd3dshared.dylib",
                  candidate.deletingLastPathComponent().lastPathComponent == "external" else { continue }
            let root = candidate.deletingLastPathComponent().deletingLastPathComponent()
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: root.appendingPathComponent("wine/x86_64-windows").path, isDirectory: &isDir), isDir.boolValue else { continue }
            if best == nil || depth < best!.depth { best = (depth, root) }
        }
        return best?.url
    }

    // MARK: - Validating

    /// Verifies that `root` really is a D3DMetal redistributable this app
    /// can use, in order of cheapness: required files; the framework's
    /// Info.plist identity and version; the Mach-O architectures; then (when
    /// `verifySignatures`) Apple's code signature. Throws a
    /// `GPTKRedistError` naming the first thing wrong.
    ///
    /// `verifySignatures` exists only so offline fixture tests can exercise
    /// the earlier stages with fake files; the real install path always
    /// leaves it `true`.
    static func validate(root: URL, verifySignatures: Bool = true) async throws -> GPTKRedistReport {
        let fm = FileManager.default
        let dylib = root.appendingPathComponent("external/libd3dshared.dylib")
        let framework = root.appendingPathComponent("external/D3DMetal.framework")
        let windowsDir = root.appendingPathComponent("wine/x86_64-windows")
        let unixDir = root.appendingPathComponent("wine/x86_64-unix")

        var missing: [String] = []
        if !fm.fileExists(atPath: dylib.path) { missing.append("external/libd3dshared.dylib") }
        if !fm.fileExists(atPath: framework.appendingPathComponent("Resources/Info.plist").path) {
            missing.append("external/D3DMetal.framework")
        }
        for name in requiredDLLs {
            if !fm.fileExists(atPath: windowsDir.appendingPathComponent("\(name).dll").path) { missing.append("wine/x86_64-windows/\(name).dll") }
            if !fm.fileExists(atPath: unixDir.appendingPathComponent("\(name).so").path)
                && (try? fm.destinationOfSymbolicLink(atPath: unixDir.appendingPathComponent("\(name).so").path)) == nil {
                missing.append("wine/x86_64-unix/\(name).so")
            }
        }
        guard missing.isEmpty else { throw GPTKRedistError.missingFiles(missing) }

        // Identity and version, from the framework's own Info.plist.
        let plistURL = framework.appendingPathComponent("Resources/Info.plist")
        guard let plistData = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else {
            throw GPTKRedistError.notD3DMetal("D3DMetal.framework/Resources/Info.plist is unreadable.")
        }
        guard (plist["CFBundleIdentifier"] as? String) == frameworkIdentifier else {
            throw GPTKRedistError.notD3DMetal("its bundle identifier is \"\((plist["CFBundleIdentifier"] as? String) ?? "missing")\", not \(frameworkIdentifier).")
        }
        guard let version = plist["CFBundleShortVersionString"] as? String, !version.isEmpty else {
            throw GPTKRedistError.notD3DMetal("it has no version string.")
        }
        guard let major = leadingInteger(of: version), major >= minimumMajorVersion else {
            throw GPTKRedistError.versionTooOld(found: version)
        }

        // Architecture: must be loadable by an x86_64 Wine under Rosetta.
        let architectures = machOArchitectures(of: dylib)
        guard architectures.contains("x86_64") else {
            throw GPTKRedistError.noX86Slice(found: architectures)
        }

        if verifySignatures {
            try await verifyAppleSignature(of: framework, deep: true)
            try await verifyAppleSignature(of: dylib, deep: false)
        }

        let dllNames = ((try? fm.contentsOfDirectory(atPath: windowsDir.path)) ?? [])
            .filter { $0.hasSuffix(".dll") }
            .map { String($0.dropLast(4)) }
            .sorted()

        let license = [root, root.deletingLastPathComponent()]
            .map { $0.appendingPathComponent("License.rtf") }
            .first { fm.fileExists(atPath: $0.path) }

        return GPTKRedistReport(
            root: root, d3dmetalVersion: version, architectures: architectures,
            dllBaseNames: dllNames, licenseURL: license, signatureChecked: verifySignatures
        )
    }

    /// Runs `codesign --verify --strict` (plus `--deep` for the framework)
    /// and requires the signing chain to reach Apple's root. The first
    /// proves the files are intact against their seal; the second proves
    /// the seal was made by Apple rather than by whoever repackaged them —
    /// an ad-hoc signature would pass the first alone.
    private static func verifyAppleSignature(of url: URL, deep: Bool) async throws {
        let codesign = URL(fileURLWithPath: "/usr/bin/codesign")
        var verifyArgs = ["--verify", "--strict"]
        if deep { verifyArgs.append("--deep") }
        verifyArgs.append(url.path)
        let verify = try await ProcessRunner.run(codesign, verifyArgs)
        guard verify.status == 0 else {
            let detail = verify.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GPTKRedistError.signatureInvalid("\(url.lastPathComponent): \(detail.isEmpty ? "codesign exited with status \(verify.status)" : detail)")
        }
        let describe = try await ProcessRunner.run(codesign, ["-dvv", url.path])
        // `codesign -d` writes its report to stderr.
        guard (describe.stderr + describe.stdout).contains(appleRootAuthority) else {
            throw GPTKRedistError.signatureInvalid("\(url.lastPathComponent) is signed, but not by a certificate chain that reaches Apple Root CA.")
        }
    }

    /// The leading run of ASCII digits in `version` ("4.0b3" -> 4).
    static func leadingInteger(of version: String) -> Int? {
        Int(version.prefix { $0.isASCII && $0.isNumber })
    }

    // MARK: - Mach-O

    /// Architecture names in a Mach-O or fat file, read from the header
    /// bytes (no `lipo` subprocess, so it works in offline tests). Returns
    /// `[]` for anything unrecognised.
    static func machOArchitectures(of url: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4096), head.count >= 8 else { return [] }
        let bytes = [UInt8](head)

        func le32(_ o: Int) -> UInt32 {
            UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24
        }
        func be32(_ o: Int) -> UInt32 {
            UInt32(bytes[o]) << 24 | UInt32(bytes[o + 1]) << 16 | UInt32(bytes[o + 2]) << 8 | UInt32(bytes[o + 3])
        }
        func name(_ cpu: UInt32) -> String {
            switch cpu {
            case 0x0100_0007: return "x86_64"
            case 0x0100_000C: return "arm64"
            case 0x0200_000C: return "arm64_32"
            case 0x0000_0007: return "i386"
            default: return String(format: "cpu-0x%x", cpu)
            }
        }

        if le32(0) == 0xFEED_FACF { return [name(le32(4))] }       // 64-bit thin
        if be32(0) == 0xCAFE_BABE {                                 // fat
            let count = Int(be32(4))
            var result: [String] = []
            for i in 0..<min(count, 8) where 8 + i * 20 + 4 <= bytes.count {
                result.append(name(be32(8 + i * 20)))
            }
            return result
        }
        return []
    }

    // MARK: - Base-engine compatibility

    /// For every `.dll` the redistributables will install, the imports that
    /// neither another redistributed DLL nor `baseWindowsDir` (the base
    /// engine's `lib/wine/x86_64-windows`) can satisfy. Empty means every
    /// by-name import resolves. This is the static equivalent of the
    /// runtime failure recorded in the research record: a 4.0b3 `dxgi.dll`
    /// importing `gdi32.D3DKMTEnumAdapters2` on Wine 7.7.
    ///
    /// Conservative on purpose: an imported DLL that cannot be found at all
    /// (an unusual forwarder stub) and ordinal imports are skipped rather
    /// than counted as missing, so this can only refuse an install for a
    /// symbol it positively saw absent from a DLL it positively read.
    static func unresolvedImports(redistWindowsDir: URL, baseWindowsDir: URL) -> [String: [String]] {
        let fm = FileManager.default
        var exportCache: [String: Set<String>?] = [:]

        func exports(of dllName: String) -> Set<String>? {
            if let cached = exportCache[dllName] { return cached }
            let candidates = [redistWindowsDir, baseWindowsDir].map { $0.appendingPathComponent(dllName) }
            var result: Set<String>?
            if let path = candidates.first(where: { fm.fileExists(atPath: $0.path) }),
               let image = PEImage(contentsOf: path) {
                result = image.exportedNames
            }
            exportCache[dllName] = .some(result)
            return result
        }

        var unresolved: [String: [String]] = [:]
        let files = ((try? fm.contentsOfDirectory(atPath: redistWindowsDir.path)) ?? []).filter { $0.hasSuffix(".dll") }.sorted()
        for file in files {
            guard let image = PEImage(contentsOf: redistWindowsDir.appendingPathComponent(file)) else { continue }
            for (importedDLL, symbols) in image.importsByName {
                guard let available = exports(of: importedDLL) else { continue }
                let missing = symbols.filter { !available.contains($0) }
                if !missing.isEmpty {
                    unresolved["\(file) -> \(importedDLL)", default: []].append(contentsOf: missing)
                }
            }
        }
        return unresolved
    }
}

// MARK: - PE reader

/// A minimal read-only view of a PE32+ (64-bit Windows) image: just its
/// export names and by-name imports, enough for
/// `GPTKRedist.unresolvedImports`. Wine's builtin DLLs and D3DMetal's stubs
/// are ordinary mingw-built PE files, so the standard header walk suffices.
/// Every read is bounds-checked; a truncated or hostile file yields `nil`
/// or fewer names, never a crash.
struct PEImage {
    private let data: Data
    private struct Section { let virtualAddress: UInt32; let virtualSize: UInt32; let rawPointer: UInt32; let rawSize: UInt32 }
    private let sections: [Section]
    private let exportDirectory: (rva: UInt32, size: UInt32)
    private let importDirectory: (rva: UInt32, size: UInt32)

    /// Parses `url`, or returns `nil` if it is not a well-formed PE32+.
    init?(contentsOf url: URL) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        self.init(data: data)
    }

    /// Parses an in-memory image (used by fixture tests).
    init?(data: Data) {
        self.data = data
        func u16(_ o: Int) -> UInt16? {
            guard o >= 0, o + 2 <= data.count else { return nil }
            return UInt16(data[data.startIndex + o]) | UInt16(data[data.startIndex + o + 1]) << 8
        }
        func u32(_ o: Int) -> UInt32? {
            guard let lo = u16(o), let hi = u16(o + 2) else { return nil }
            return UInt32(lo) | UInt32(hi) << 16
        }
        guard u16(0) == 0x5A4D, let peOffset = u32(0x3C).map(Int.init), u32(peOffset) == 0x0000_4550,
              let sectionCount = u16(peOffset + 6), let optionalSize = u16(peOffset + 20) else { return nil }
        let optional = peOffset + 24
        guard u16(optional) == 0x20B, optionalSize >= 128, // PE32+ with data directories
              let exportRVA = u32(optional + 112), let exportSize = u32(optional + 116),
              let importRVA = u32(optional + 120), let importSize = u32(optional + 124) else { return nil }
        var parsed: [Section] = []
        let table = optional + Int(optionalSize)
        for i in 0..<min(Int(sectionCount), 96) {
            let o = table + i * 40
            guard let vsize = u32(o + 8), let va = u32(o + 12), let rawSize = u32(o + 16), let rawPtr = u32(o + 20) else { return nil }
            parsed.append(Section(virtualAddress: va, virtualSize: vsize, rawPointer: rawPtr, rawSize: rawSize))
        }
        self.sections = parsed
        self.exportDirectory = (exportRVA, exportSize)
        self.importDirectory = (importRVA, importSize)
    }

    private func u16(_ o: Int) -> UInt16? {
        guard o >= 0, o + 2 <= data.count else { return nil }
        return UInt16(data[data.startIndex + o]) | UInt16(data[data.startIndex + o + 1]) << 8
    }
    private func u32(_ o: Int) -> UInt32? {
        guard let lo = u16(o), let hi = u16(o + 2) else { return nil }
        return UInt32(lo) | UInt32(hi) << 16
    }
    private func u64(_ o: Int) -> UInt64? {
        guard let lo = u32(o), let hi = u32(o + 4) else { return nil }
        return UInt64(lo) | UInt64(hi) << 32
    }

    /// File offset for a relative virtual address, or `nil` if no section maps it.
    private func offset(forRVA rva: UInt32) -> Int? {
        for s in sections where rva >= s.virtualAddress && rva < s.virtualAddress &+ max(s.virtualSize, s.rawSize) {
            let delta = rva - s.virtualAddress
            guard delta < s.rawSize else { return nil }
            let off = Int(s.rawPointer) + Int(delta)
            return off < data.count ? off : nil
        }
        return nil
    }

    /// NUL-terminated ASCII string at the file offset, capped at 512 bytes.
    private func cString(at start: Int) -> String? {
        guard start >= 0, start < data.count else { return nil }
        var bytes: [UInt8] = []
        var i = start
        while i < data.count, bytes.count < 512 {
            let b = data[data.startIndex + i]
            if b == 0 { break }
            bytes.append(b)
            i += 1
        }
        return String(bytes: bytes, encoding: .ascii)
    }

    /// Names in the export table (forwarded exports included, since the
    /// name is listed either way).
    var exportedNames: Set<String> {
        guard exportDirectory.rva != 0, let dir = offset(forRVA: exportDirectory.rva),
              let count = u32(dir + 24), let namesRVA = u32(dir + 32), let namesOff = offset(forRVA: namesRVA) else { return [] }
        var result: Set<String> = []
        for i in 0..<min(Int(count), 100_000) {
            guard let nameRVA = u32(namesOff + i * 4), let nameOff = offset(forRVA: nameRVA), let name = cString(at: nameOff) else { continue }
            result.insert(name)
        }
        return result
    }

    /// Imported symbol names grouped by lower-cased DLL name. Ordinal
    /// imports are omitted (see `GPTKRedist.unresolvedImports`).
    var importsByName: [String: [String]] {
        guard importDirectory.rva != 0, var descriptor = offset(forRVA: importDirectory.rva) else { return [:] }
        var result: [String: [String]] = [:]
        for _ in 0..<512 {
            guard let originalFirstThunk = u32(descriptor), let nameRVA = u32(descriptor + 12), let firstThunk = u32(descriptor + 16) else { break }
            if originalFirstThunk == 0 && nameRVA == 0 && firstThunk == 0 { break }
            descriptor += 20
            guard let nameOff = offset(forRVA: nameRVA), let dll = cString(at: nameOff)?.lowercased() else { continue }
            guard var thunk = offset(forRVA: originalFirstThunk != 0 ? originalFirstThunk : firstThunk) else { continue }
            for _ in 0..<20_000 {
                guard let entry = u64(thunk), entry != 0 else { break }
                thunk += 8
                if entry & 0x8000_0000_0000_0000 != 0 { continue } // by ordinal
                guard let nameOff = offset(forRVA: UInt32(truncatingIfNeeded: entry)), let symbol = cString(at: nameOff + 2) else { continue }
                result[dll, default: []].append(symbol)
            }
        }
        return result
    }
}
