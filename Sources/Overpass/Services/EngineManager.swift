import Foundation
import CryptoKit

/// Errors surfaced by `EngineManager`, all with a user-facing description
/// suitable for `AppState.report(_:context:)`.
enum EngineManagerError: LocalizedError {
    case httpStatus(Int)
    case hashMismatch(expected: String, actual: String)
    case extractionFailed(String)
    case layoutNotFound
    case versionCheckFailed(String)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code):
            return "Download failed (server returned HTTP \(code))."
        case .hashMismatch(let expected, let actual):
            return "Downloaded file's checksum didn't match. Expected \(expected), got \(actual). The download may be corrupt, or the release changed upstream — try again, and if it keeps happening please update the catalog hash."
        case .extractionFailed(let detail):
            return "Failed to extract the engine archive: \(detail)"
        case .layoutNotFound:
            return "Couldn't find a wine64 or wine executable inside the extracted engine. The archive's internal layout may have changed."
        case .versionCheckFailed(let detail):
            return "Installed the engine but couldn't run its wine binary to read a version string: \(detail)"
        }
    }
}

/// Downloads, verifies, extracts, and removes Wine engines under
/// `Paths.engines`. One folder per `EngineRelease.id`, each holding the
/// extracted tree plus an `installed.json` describing it (`InstalledEngine`).
///
/// An actor because installs involve several await points (network, tar,
/// version-check) touching no other shared mutable state than the
/// filesystem itself, and callers (`AppState`) hop across the actor
/// boundary with `await` anyway.
actor EngineManager {
    /// Shared instance — `AppState` (via `EngineManager+AppState.swift`)
    /// talks to engines through this single instance rather than each
    /// screen owning its own.
    static let shared = EngineManager()

    private init() {}

    // MARK: - Reading installed engines

    /// Reads `installed.json` from every folder under `Paths.engines`.
    /// Folders without a valid `installed.json` (a half-finished install
    /// that crashed before this file was written, for example) are
    /// silently skipped — they read as "not installed".
    ///
    /// `root` defaults to the real engines folder; it is a parameter only so
    /// offline tests can point the user-supplied-GPTK install at a scratch
    /// directory instead of the user's `Paths.engines`.
    func installedEngines(in root: URL = Paths.engines) -> [InstalledEngine] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var result: [InstalledEngine] = []
        for entry in entries {
            let jsonURL = entry.appendingPathComponent("installed.json")
            guard let data = try? Data(contentsOf: jsonURL),
                  let engine = try? decoder.decode(InstalledEngine.self, from: data) else { continue }
            result.append(engine)
        }
        return result.sorted { $0.id < $1.id }
    }

    // MARK: - Install

    /// Downloads `release`'s tarball, verifies its SHA-256, extracts it
    /// into `Paths.engineDir(release.id)`, strips quarantine, locates the
    /// wine binaries, runs `wine64 --version` to prove it actually works,
    /// and writes `installed.json`. `progress` is called repeatedly with a
    /// 0...1 fraction and a short human-readable status line; it may be
    /// called from any thread/actor, hence `@Sendable`.
    ///
    /// On any failure the partial engine folder (and any leftover
    /// tarball) is removed before rethrowing, so a retry starts clean.
    func install(
        _ release: EngineRelease,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> InstalledEngine {
        try Paths.ensureAll()

        let engineDir = Paths.engineDir(release.id)
        let tarballURL = Paths.downloads.appendingPathComponent("\(release.id).tar.xz")

        do {
            // Reuse a previously downloaded tarball when its hash still
            // matches (a failed extract, or a reinstall) instead of
            // pulling a few hundred MB again.
            var reusedExisting = false
            if FileManager.default.fileExists(atPath: tarballURL.path),
               let existingHash = try? Self.sha256Hex(of: tarballURL),
               existingHash.caseInsensitiveCompare(release.sha256) == .orderedSame {
                reusedExisting = true
                progress(0.8, "Using previously downloaded archive…")
            }

            if !reusedExisting {
                progress(0, "Starting download…")
                let downloadedTemp = try await Self.downloadFile(from: release.url) { fraction in
                    progress(fraction * 0.8, "Downloading \(release.displayName)…")
                }

                if FileManager.default.fileExists(atPath: tarballURL.path) {
                    try? FileManager.default.removeItem(at: tarballURL)
                }
                try FileManager.default.moveItem(at: downloadedTemp, to: tarballURL)
            }

            progress(0.8, "Verifying checksum…")
            let actualHash = try Self.sha256Hex(of: tarballURL)
            let checksumVerified: Bool
            if release.sha256.isEmpty {
                // No known-good hash for this release (typically one
                // `EngineUpdateChecker` fetched without finding a `.sha256`
                // asset or a checksum in the release body) — install
                // anyway, but record what we actually got rather than
                // silently trusting it.
                checksumVerified = false
                NSLog("[EngineManager] %@ has no catalog checksum; installing unverified. SHA-256: %@", release.id, actualHash)
            } else {
                guard actualHash.caseInsensitiveCompare(release.sha256) == .orderedSame else {
                    throw EngineManagerError.hashMismatch(expected: release.sha256, actual: actualHash)
                }
                checksumVerified = true
            }

            if FileManager.default.fileExists(atPath: engineDir.path) {
                try? FileManager.default.removeItem(at: engineDir)
            }
            try FileManager.default.createDirectory(at: engineDir, withIntermediateDirectories: true)

            progress(0.82, "Extracting \(release.displayName)…")
            let tarResult = try await ShellRunner.run("/usr/bin/tar", ["-xJf", tarballURL.path, "-C", engineDir.path])
            guard tarResult.status == 0 else {
                throw EngineManagerError.extractionFailed(
                    tarResult.stderr.isEmpty ? "tar exited with status \(tarResult.status)" : tarResult.stderr
                )
            }

            progress(0.9, "Removing quarantine flag…")
            // Best-effort: a fresh download always carries com.apple.quarantine,
            // but xattr can fail harmlessly on files that don't have it
            // (some entries inside .app bundles). Never fails the install.
            _ = try? await ShellRunner.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", engineDir.path])

            progress(0.92, "Locating wine binaries…")
            let binDir = try Self.findBinDirectory(in: engineDir)
            let libDir = binDir.deletingLastPathComponent().appendingPathComponent("lib", isDirectory: true)
            guard FileManager.default.fileExists(atPath: libDir.path) else {
                throw EngineManagerError.layoutNotFound
            }

            progress(0.95, "Checking wine version…")
            let versionString = try await Self.wineVersion(binDir: binDir, libDir: libDir)

            let installed = InstalledEngine(
                id: release.id,
                kind: release.kind,
                version: release.version,
                rootDir: engineDir,
                binDir: binDir,
                libDir: libDir,
                versionString: versionString,
                installedAt: Date(),
                actualSHA256: actualHash,
                checksumVerified: checksumVerified
            )

            progress(0.98, "Writing metadata…")
            try Self.writeInstalledJSON(installed, to: engineDir)

            try? FileManager.default.removeItem(at: tarballURL)

            progress(1.0, "Installed \(installed.displayName).")
            return installed
        } catch {
            try? FileManager.default.removeItem(at: engineDir)
            try? FileManager.default.removeItem(at: tarballURL)
            throw error
        }
    }

    // MARK: - Install from a user-supplied GPTK download

    /// Builds a selectable engine from Apple's Game Porting Toolkit 4
    /// download, which the user fetched themselves (it is behind an Apple
    /// Account sign-in and under a licence that stops Overpass shipping or
    /// auto-fetching it — see `GPTKRedist`'s research record).
    ///
    /// The download holds D3DMetal only, not a Wine, so this **clones an
    /// installed base engine** (`cp -c`, an APFS clone: instant and nearly
    /// free on disk) and overlays the redistributables into the clone's own
    /// `lib/` tree. The base engine is left untouched, so the original and
    /// the GPTK 4 variant stay selectable side by side — unlike
    /// `D3DMetalImporter`, which swaps `lib/external` in place and, per the
    /// findings in `GPTKRedist`, leaves new D3DMetal dylibs paired with
    /// old PE stubs.
    ///
    /// Steps: mount the `.dmg` (or take a folder) -> `GPTKRedist.validate`
    /// (required files, Apple's bundle identity and version, an x86_64
    /// slice, Apple's code signature) -> pick or check the base engine
    /// against the new DLLs' Win32 imports (`GPTKRedist.unresolvedImports`)
    /// -> clone, overlay, strip quarantine -> run the clone's wine to prove
    /// it starts -> write `installed.json`. The mount is always ejected, and
    /// on any failure the half-built engine folder is deleted, as
    /// `install(_:progress:)` does.
    ///
    /// **What this does not establish:** that a Windows game renders on the
    /// result. See `GPTKRedist`'s findings 2: on wine-staging 11.20 the
    /// D3DMetal unixlib loads, but nothing could be rendered in testing.
    ///
    /// - Parameters:
    ///   - source: the `.dmg`, or a folder containing (at any depth up to 6)
    ///     the `redist/lib` payload.
    ///   - requestedBase: engine to clone; `nil` chooses automatically (the
    ///     newest installed Wine Staging whose Win32 APIs satisfy the new
    ///     DLLs, then any other installed engine that does).
    ///   - enginesRoot: where the new engine is created; only tests change
    ///     this.
    ///   - baseSearchRoot: where installed engines are looked up when
    ///     choosing a base; defaults to `enginesRoot`. `--check-gptk-supplied`
    ///     sets it to the real engines folder while building into a scratch
    ///     one, so the check exercises real engines without touching them.
    ///   - verifySignatures: only tests with fake payloads pass `false`.
    func installUserSuppliedGPTK(
        from source: URL,
        base requestedBase: InstalledEngine? = nil,
        enginesRoot: URL = Paths.engines,
        baseSearchRoot: URL? = nil,
        verifySignatures: Bool = true,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> InstalledEngine {
        try FileManager.default.createDirectory(at: enginesRoot, withIntermediateDirectories: true)

        progress(0.02, "Reading \(source.lastPathComponent)…")
        let (redistRoot, sourceSHA, cleanup) = try await Self.resolveRedistRoot(from: source, progress: progress)
        do {
            let engine = try await assembleUserSuppliedGPTK(
                redistRoot: redistRoot, sourceName: source.lastPathComponent, sourceSHA256: sourceSHA,
                requestedBase: requestedBase, enginesRoot: enginesRoot, baseSearchRoot: baseSearchRoot ?? enginesRoot,
                verifySignatures: verifySignatures, progress: progress
            )
            await cleanup()
            return engine
        } catch {
            await cleanup()
            throw error
        }
    }

    /// Mounts `source` if it is a `.dmg` (hashing it first), otherwise
    /// searches it as a folder, and returns the redistributables' root, the
    /// `.dmg`'s SHA-256 (or `nil`), and a closure that ejects the mount.
    nonisolated private static func resolveRedistRoot(
        from source: URL,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> (URL, String?, @Sendable () async -> Void) {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            throw GPTKRedistError.unsupportedSource("\"\(source.lastPathComponent)\" doesn't exist.")
        }

        if isDirectory.boolValue {
            guard let root = GPTKRedist.findRoot(under: source) else { throw GPTKRedistError.layoutNotFound }
            return (root, nil, {})
        }
        guard source.pathExtension.lowercased() == "dmg" else {
            throw GPTKRedistError.unsupportedSource("\"\(source.lastPathComponent)\" isn't a .dmg or a folder.")
        }

        progress(0.04, "Fingerprinting \(source.lastPathComponent)…")
        let sha = try sha256Hex(of: source)

        let mountPoint = fm.temporaryDirectory.appendingPathComponent("overpass-gptk4-dmg-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        progress(0.08, "Mounting \(source.lastPathComponent)…")
        let attach = try await ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/hdiutil"),
            ["attach", "-nobrowse", "-readonly", "-mountpoint", mountPoint.path, source.path]
        )
        guard attach.status == 0 else {
            try? fm.removeItem(at: mountPoint)
            throw GPTKRedistError.attachFailed(attach.stderr.isEmpty ? "hdiutil exited with status \(attach.status)" : attach.stderr)
        }
        let cleanup: @Sendable () async -> Void = {
            _ = try? await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), ["detach", mountPoint.path, "-quiet"])
            try? FileManager.default.removeItem(at: mountPoint)
        }
        guard let root = GPTKRedist.findRoot(under: mountPoint) else {
            await cleanup()
            throw GPTKRedistError.layoutNotFound
        }
        return (root, sha, cleanup)
    }

    /// The validate -> choose base -> clone -> overlay -> verify -> persist
    /// half of `installUserSuppliedGPTK`, split out so the mount's cleanup
    /// can wrap it in one place.
    private func assembleUserSuppliedGPTK(
        redistRoot: URL,
        sourceName: String,
        sourceSHA256: String?,
        requestedBase: InstalledEngine?,
        enginesRoot: URL,
        baseSearchRoot: URL,
        verifySignatures: Bool,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> InstalledEngine {
        let fm = FileManager.default

        progress(0.15, "Checking it is Apple's D3DMetal…")
        let report = try await GPTKRedist.validate(root: redistRoot, verifySignatures: verifySignatures)

        progress(0.30, "Checking which Wine can run it…")
        let redistWindows = redistRoot.appendingPathComponent("wine/x86_64-windows", isDirectory: true)
        let base = try chooseBase(
            requested: requestedBase, redistWindowsDir: redistWindows, candidates: installedEngines(in: baseSearchRoot)
        )

        let id = EngineCatalog.userSuppliedGPTKID(d3dmetalVersion: report.d3dmetalVersion, baseID: base.id)
        let engineDir = enginesRoot.appendingPathComponent(id, isDirectory: true)

        do {
            guard let binRelative = Self.relativePath(of: base.binDir, in: base.rootDir),
                  let libRelative = Self.relativePath(of: base.libDir, in: base.rootDir) else {
                throw GPTKRedistError.copyFailed("\(base.displayName)'s folders are not laid out under its root.")
            }

            if fm.fileExists(atPath: engineDir.path) { try fm.removeItem(at: engineDir) }
            progress(0.40, "Cloning \(base.displayName)…")
            try await Self.cloneTree(from: base.rootDir, to: engineDir)

            let binDir = engineDir.appendingPathComponent(binRelative, isDirectory: true)
            let libDir = engineDir.appendingPathComponent(libRelative, isDirectory: true)

            progress(0.60, "Adding D3DMetal \(report.d3dmetalVersion)…")
            try await Self.overlay(redistRoot: redistRoot, onto: libDir)
            if let license = report.licenseURL {
                // Apple's licence 2C: keep the notices with every copy.
                try? fm.copyItem(at: license, to: engineDir.appendingPathComponent("GPTK-License.rtf"))
            }

            progress(0.80, "Removing quarantine flag…")
            _ = try? await ShellRunner.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", engineDir.path])

            progress(0.88, "Checking the engine starts…")
            let versionString: String
            do {
                versionString = try await Self.wineVersion(binDir: binDir, libDir: libDir)
            } catch {
                throw GPTKRedistError.verificationFailed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }

            let installed = InstalledEngine(
                id: id,
                kind: .gptk,
                version: "\(report.d3dmetalVersion) + \(base.displayName)",
                rootDir: engineDir,
                binDir: binDir,
                libDir: libDir,
                versionString: versionString,
                installedAt: Date(),
                actualSHA256: sourceSHA256,
                // Apple publishes no checksum, so there is nothing to have
                // verified a hash against; the signature check is what
                // establishes authenticity (see `userSupplied`).
                checksumVerified: false,
                d3dmetalVersion: report.d3dmetalVersion,
                userSupplied: UserSuppliedOrigin(
                    sourceName: sourceName, sourceSHA256: sourceSHA256, baseEngineID: base.id,
                    baseVersionString: base.versionString, signatureVerified: report.signatureChecked
                )
            )
            progress(0.96, "Writing metadata…")
            try Self.writeInstalledJSON(installed, to: engineDir)
            progress(1.0, "Installed \(installed.displayName).")
            return installed
        } catch {
            try? fm.removeItem(at: engineDir)
            throw error
        }
    }

    /// Picks the engine to clone. A `requested` base is honoured but still
    /// checked (a named-but-incompatible engine fails with
    /// `incompatibleBase`); otherwise installed engines are tried newest
    /// Wine Staging first, because Wine 7.7 (the pinned GPTK 3 build) is
    /// the one known not to satisfy GPTK 4.0b3 (`GPTKRedist` finding 1).
    /// Engines already built from user-supplied files are never reused as a
    /// base, so overlays don't stack.
    private func chooseBase(
        requested: InstalledEngine?,
        redistWindowsDir: URL,
        candidates: [InstalledEngine]
    ) throws -> InstalledEngine {
        func missing(for engine: InstalledEngine) -> [String: [String]] {
            GPTKRedist.unresolvedImports(
                redistWindowsDir: redistWindowsDir,
                baseWindowsDir: engine.libDir.appendingPathComponent("wine/x86_64-windows", isDirectory: true)
            )
        }

        if let requested {
            let gaps = missing(for: requested)
            guard gaps.isEmpty else { throw GPTKRedistError.incompatibleBase(base: requested.displayName, missing: gaps) }
            return requested
        }

        let usable = candidates.filter { $0.userSupplied == nil }
        let ordered = usable.sorted { a, b in
            if (a.kind == .wineStaging) != (b.kind == .wineStaging) { return a.kind == .wineStaging }
            return EngineCatalog.compareVersions(a.version, b.version) > 0
        }
        guard !ordered.isEmpty else { throw GPTKRedistError.noSuitableBase("No Wine engine is installed yet.") }

        var firstGaps: (String, [String: [String]])?
        for engine in ordered {
            let gaps = missing(for: engine)
            if gaps.isEmpty { return engine }
            if firstGaps == nil { firstGaps = (engine.displayName, gaps) }
        }
        let (name, gaps) = firstGaps!
        let detail = gaps.keys.sorted().prefix(3).map { "\($0): \((gaps[$0] ?? []).sorted().joined(separator: ", "))" }.joined(separator: "; ")
        throw GPTKRedistError.noSuitableBase("The newest candidate, \(name), lacks Windows APIs the new files import (\(detail)).")
    }

    /// `url`'s path relative to `root`, or `nil` if it is not inside it.
    nonisolated private static func relativePath(of url: URL, in root: URL) -> String? {
        let base = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path == base || path.hasPrefix(base + "/") else { return nil }
        return String(path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Copies a directory tree, preferring `cp -c` (APFS clone: the 800 MB
    /// Wine tree duplicates in about a second and shares blocks) and
    /// falling back to `ditto` on volumes that cannot clone. Symlinks are
    /// preserved by both.
    nonisolated private static func cloneTree(from source: URL, to destination: URL) async throws {
        let clone = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/cp"), ["-cR", source.path, destination.path])
        if clone.status == 0 { return }
        try? FileManager.default.removeItem(at: destination)
        let ditto = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/ditto"), [source.path, destination.path])
        guard ditto.status == 0 else {
            throw GPTKRedistError.copyFailed(ditto.stderr.isEmpty ? "ditto exited with status \(ditto.status)" : ditto.stderr)
        }
    }

    /// The only unixlib link target Apple ships (and the one
    /// `D3DMetalOverlay` recreates): from `lib/wine/x86_64-unix` back up to
    /// `lib/external`. Any other target is refused rather than followed, so
    /// a crafted download cannot plant a link that points elsewhere.
    nonisolated private static let expectedUnixLibTarget = "../../external/libd3dshared.dylib"

    /// Replaces `libDir/external` and the D3DMetal PE/unix pairs under
    /// `libDir/wine` with the redistributables'. Placing them inside the
    /// engine's own tree (rather than a `WINEDLLPATH` side directory) is
    /// what makes Wine's builtin-DLL resolver find them at all — see
    /// `GPTKRedist` finding 2 versus the `D3DMetalOverlay` findings.
    nonisolated private static func overlay(redistRoot: URL, onto libDir: URL) async throws {
        let fm = FileManager.default
        let destExternal = libDir.appendingPathComponent("external", isDirectory: true)
        let destWindows = libDir.appendingPathComponent("wine/x86_64-windows", isDirectory: true)
        let destUnix = libDir.appendingPathComponent("wine/x86_64-unix", isDirectory: true)
        for dir in [destWindows, destUnix] {
            guard fm.fileExists(atPath: dir.path) else {
                throw GPTKRedistError.copyFailed("the base engine has no \(dir.pathComponents.suffix(2).joined(separator: "/")) folder.")
            }
        }

        if fm.fileExists(atPath: destExternal.path) { try fm.removeItem(at: destExternal) }
        let ditto = try await ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/ditto"), [redistRoot.appendingPathComponent("external").path, destExternal.path]
        )
        guard ditto.status == 0 else {
            throw GPTKRedistError.copyFailed(ditto.stderr.isEmpty ? "ditto exited with status \(ditto.status)" : ditto.stderr)
        }

        let sourceWindows = redistRoot.appendingPathComponent("wine/x86_64-windows")
        for file in try fm.contentsOfDirectory(atPath: sourceWindows.path) where file.hasSuffix(".dll") {
            let dest = destWindows.appendingPathComponent(file)
            if fm.fileExists(atPath: dest.path) || (try? fm.destinationOfSymbolicLink(atPath: dest.path)) != nil { try fm.removeItem(at: dest) }
            try fm.copyItem(at: sourceWindows.appendingPathComponent(file), to: dest)
        }

        let sourceUnix = redistRoot.appendingPathComponent("wine/x86_64-unix")
        for file in try fm.contentsOfDirectory(atPath: sourceUnix.path) where file.hasSuffix(".so") {
            let link = sourceUnix.appendingPathComponent(file).path
            guard (try? fm.destinationOfSymbolicLink(atPath: link)) == expectedUnixLibTarget else {
                throw GPTKRedistError.copyFailed("wine/x86_64-unix/\(file) is not the expected link to libd3dshared.dylib.")
            }
            let dest = destUnix.appendingPathComponent(file)
            if fm.fileExists(atPath: dest.path) || (try? fm.destinationOfSymbolicLink(atPath: dest.path)) != nil { try fm.removeItem(at: dest) }
            try fm.createSymbolicLink(atPath: dest.path, withDestinationPath: expectedUnixLibTarget)
        }
    }

    // MARK: - Persisting metadata changes

    /// Rewrites `engine`'s `installed.json` in place — used by
    /// `D3DMetalImporter` to persist a new `d3dmetalVersion` after swapping
    /// in a build from an Apple GPTK `.dmg`, without going through a full
    /// (re)install.
    func persist(_ engine: InstalledEngine) throws {
        try Self.writeInstalledJSON(engine, to: engine.rootDir)
    }

    // MARK: - Remove

    /// Moves an engine's folder to the Trash (falling back to a permanent
    /// delete if that fails, e.g. no Trash available for the volume).
    func remove(_ id: String) throws {
        let dir = Paths.engineDir(id)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        do {
            try FileManager.default.trashItem(at: dir, resultingItemURL: nil)
        } catch {
            try FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: - Download

    /// Streams `url` to a temporary file via a `URLSessionDownloadTask`
    /// delegate, so `progress` reflects real bytes-written/bytes-expected
    /// rather than an estimate. Returns the temp file's location; the
    /// caller is responsible for moving it into place.
    nonisolated private static func downloadFile(
        from url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let delegate = EngineDownloadDelegate(progress: progress, continuation: continuation)
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            let task = session.downloadTask(with: url)
            delegate.session = session
            task.resume()
        }
    }

    // MARK: - Checksum

    /// SHA-256 of a file, computed in bounded-size chunks via `FileHandle`
    /// so a ~200MB tarball never has to be loaded into memory at once.
    nonisolated private static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunkSize = 1 << 20 // 1MB
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Locating the extracted layout

    /// Walks the extracted tree looking for a directory named `bin` that
    /// contains a `wine64` or `wine` executable. The tarball's top-level
    /// folder name (and nesting depth) isn't fixed — GPTK ships
    /// `Game Porting Toolkit.app/Contents/Resources/wine/bin`, plain Wine
    /// builds ship `Wine Staging.app/Contents/Resources/wine/bin` — so this
    /// is discovered rather than assumed.
    nonisolated private static func findBinDirectory(in root: URL) throws -> URL {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles],
            errorHandler: nil
        ) else {
            throw EngineManagerError.layoutNotFound
        }
        for case let candidate as URL in enumerator {
            guard candidate.lastPathComponent == "bin" else { continue }
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let wine64 = candidate.appendingPathComponent("wine64")
            let wine = candidate.appendingPathComponent("wine")
            if fm.isExecutableFile(atPath: wine64.path) || fm.isExecutableFile(atPath: wine.path) {
                return candidate
            }
        }
        throw EngineManagerError.layoutNotFound
    }

    // MARK: - Version check

    /// Runs `wine64 --version` (falling back to `wine`) with the
    /// environment GPTK's D3DMetal needs to even load
    /// (`DYLD_FALLBACK_LIBRARY_PATH` pointing at `lib` and `lib/external`).
    /// This both proves the binary actually runs under Rosetta and gives
    /// us the version string shown in the UI.
    ///
    /// Note: `ShellRunner` (owned by another part of the app) has no way to
    /// pass a custom environment, so this uses a small private process
    /// runner below that mirrors its non-blocking pipe-draining pattern.
    nonisolated private static func wineVersion(binDir: URL, libDir: URL) async throws -> String {
        let fm = FileManager.default
        let wine64 = binDir.appendingPathComponent("wine64")
        let wine = binDir.appendingPathComponent("wine")
        let binaryPath = fm.isExecutableFile(atPath: wine64.path) ? wine64.path : wine.path
        guard fm.isExecutableFile(atPath: binaryPath) else {
            throw EngineManagerError.layoutNotFound
        }

        let environment: [String: String] = [
            "WINEDEBUG": "-all",
            "DYLD_FALLBACK_LIBRARY_PATH": "\(libDir.path):\(libDir.appendingPathComponent("external").path)",
            "PATH": "/usr/bin:/bin",
            "HOME": NSHomeDirectory(),
        ]

        let result = try await runProcess(binaryPath, ["--version"], environment: environment)
        guard result.status == 0 else {
            throw EngineManagerError.versionCheckFailed(
                result.stderr.isEmpty ? "exited with status \(result.status)" : result.stderr
            )
        }
        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw EngineManagerError.versionCheckFailed("no output")
        }
        return trimmed
    }

    /// Minimal environment-aware sibling of `ShellRunner.run` — needed
    /// only because that type doesn't expose an `environment` parameter
    /// and lives in a file this feature doesn't own. Same non-blocking
    /// pipe-draining approach: both pipes are read continuously via
    /// `readabilityHandler`, and the continuation resumes only once the
    /// process has terminated and both pipes have hit EOF.
    nonisolated private static func runProcess(
        _ executable: String,
        _ args: [String],
        environment: [String: String]
    ) async throws -> (status: Int32, stdout: String, stderr: String) {
        let r = try await ProcessRunner.run(URL(fileURLWithPath: executable), args, environment: environment)
        return (r.status, r.stdout, r.stderr)
    }

    /// Persists `installed.json` next to the extracted engine so
    /// `installedEngines()` can find it on the next launch.
    nonisolated private static func writeInstalledJSON(_ engine: InstalledEngine, to dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(engine)
        try data.write(to: dir.appendingPathComponent("installed.json"), options: .atomic)
    }
}

/// `URLSessionDownloadDelegate` that reports fractional progress and
/// resumes a continuation with the finished download's temp file location
/// (moved to a fresh temp path immediately, since the URL Loading System
/// deletes its own temp file the instant this delegate method returns).
private final class EngineDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    /// Held only so the session isn't deallocated before its delegate
    /// callbacks fire; cleared once we resume.
    var session: URLSession?

    init(progress: @escaping @Sendable (Double) -> Void, continuation: CheckedContinuation<URL, Error>) {
        self.progress = progress
        self.continuation = continuation
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return }
        switch result {
        case .success(let url): pending.resume(returning: url)
        case .failure(let error): pending.resume(throwing: error)
        }
        session?.finishTasksAndInvalidate()
        session = nil
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finish(.failure(EngineManagerError.httpStatus(http.statusCode)))
            return
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("overpass-download-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
        }
    }
}
