import Foundation

/// Errors surfaced by `D3DMetalImporter`.
enum D3DMetalImporterError: LocalizedError {
    case attachFailed(String)
    case unsupportedLayout
    case copyFailed(String)
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .attachFailed(let detail):
            return "Couldn't mount the .dmg: \(detail)"
        case .unsupportedLayout:
            return "This .dmg doesn't look like a GPTK D3DMetal payload — no \"external\" folder containing libd3dshared.dylib was found on it."
        case .copyFailed(let detail):
            return "Couldn't copy the new D3DMetal into place: \(detail)"
        case .verificationFailed(let detail):
            return "D3DMetal was copied in, but the engine's wine64 failed to run afterward — the previous D3DMetal was left backed up rather than restored automatically. \(detail)"
        }
    }
}

/// Imports Apple's own D3DMetal build from a GPTK "Evaluation environment
/// for Windows games" `.dmg` — the developer-account download Apple ships
/// ahead of Gcenx publishing a matching open build — into an already
/// installed GPTK engine, replacing its `lib/external` in place.
///
/// Apple's D3DMetal is distributed under a **non-commercial licence**; see
/// Apple's Game Porting Toolkit developer page. A GPTK 4 `.dmg` may also
/// need a newer macOS than this Mac is running — Apple's June 2026 GPTK 4
/// announcement named macOS 27 for some of it. Overpass doesn't gate on
/// macOS version itself; a mismatched dmg simply fails to mount usefully,
/// or fails the post-copy `wine64 --version` check below.
enum D3DMetalImporter {
    /// Mounts `dmg`, locates its D3DMetal payload, backs up `engine`'s
    /// current `lib/external`, copies the new one in, strips quarantine,
    /// verifies the engine's `wine64 --version` still runs, reads the new
    /// D3DMetal version, persists it to the engine's `installed.json` via
    /// `EngineManager.persist`, and returns it. The dmg is always detached
    /// again, even on failure. `progress` may be called from any thread.
    static func importFromDMG(
        _ dmg: URL,
        into engine: InstalledEngine,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let fm = FileManager.default
        let mountPoint = fm.temporaryDirectory.appendingPathComponent("overpass-gptk-dmg-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        progress("Mounting \(dmg.lastPathComponent)…")
        let attach = try await ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/hdiutil"),
            ["attach", "-nobrowse", "-readonly", "-mountpoint", mountPoint.path, dmg.path]
        )
        guard attach.status == 0 else {
            try? fm.removeItem(at: mountPoint)
            throw D3DMetalImporterError.attachFailed(attach.stderr.isEmpty ? "hdiutil exited with status \(attach.status)" : attach.stderr)
        }

        do {
            let version = try await performImport(mountPoint: mountPoint, engine: engine, progress: progress)
            await detach(mountPoint, progress: progress)
            return version
        } catch {
            await detach(mountPoint, progress: progress)
            throw error
        }
    }

    private static func detach(_ mountPoint: URL, progress: @escaping @Sendable (String) -> Void) async {
        progress("Ejecting disk image…")
        _ = try? await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), ["detach", mountPoint.path, "-quiet"])
        try? FileManager.default.removeItem(at: mountPoint)
    }

    private static func performImport(
        mountPoint: URL,
        engine: InstalledEngine,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let fm = FileManager.default

        progress("Looking for a D3DMetal payload…")
        guard let sourceExternal = findExternalDirectory(under: mountPoint) else {
            throw D3DMetalImporterError.unsupportedLayout
        }

        let destExternal = engine.libDir.appendingPathComponent("external", isDirectory: true)
        if fm.fileExists(atPath: destExternal.path) {
            let backup = engine.libDir.appendingPathComponent("external.bak-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
            progress("Backing up current D3DMetal to \(backup.lastPathComponent)…")
            try fm.moveItem(at: destExternal, to: backup)
        }

        progress("Copying new D3DMetal into place…")
        let ditto = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/ditto"), [sourceExternal.path, destExternal.path])
        guard ditto.status == 0 else {
            throw D3DMetalImporterError.copyFailed(ditto.stderr.isEmpty ? "ditto exited with status \(ditto.status)" : ditto.stderr)
        }

        progress("Removing quarantine flag…")
        _ = try? await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/xattr"), ["-dr", "com.apple.quarantine", destExternal.path])

        progress("Verifying the engine still runs…")
        try await verifyEngineRuns(engine)

        progress("Reading D3DMetal version…")
        let version = readD3DMetalVersion(externalDir: destExternal) ?? "unknown"

        var updated = engine
        updated.d3dmetalVersion = version
        try? await EngineManager.shared.persist(updated)

        return version
    }

    /// Reverts `engine`'s `lib/external` to the newest `external.bak-*`
    /// folder sitting next to it (there can be more than one after several
    /// imports; the lexicographically-greatest timestamp wins), and clears
    /// `d3dmetalVersion` back to `nil` in `installed.json` since the
    /// restored `external` is whatever originally shipped in the Gcenx
    /// tarball, not an Apple import. Returns `false` (rather than
    /// throwing) when there's nothing to restore.
    static func restoreBackup(engine: InstalledEngine) async throws -> Bool {
        let fm = FileManager.default
        let backups = backupFolders(engine: engine)
        guard let newest = backups.first else { return false }

        let current = engine.libDir.appendingPathComponent("external", isDirectory: true)
        if fm.fileExists(atPath: current.path) {
            try fm.removeItem(at: current)
        }
        try fm.moveItem(at: newest, to: current)

        var updated = engine
        updated.d3dmetalVersion = nil
        try? await EngineManager.shared.persist(updated)

        return true
    }

    /// True when `engine` has at least one backup `restoreBackup` could
    /// restore — drives the "Restore previous D3DMetal" button in
    /// `EnginesView`.
    static func hasBackup(engine: InstalledEngine) -> Bool {
        !backupFolders(engine: engine).isEmpty
    }

    private static func backupFolders(engine: InstalledEngine) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: engine.libDir, includingPropertiesForKeys: nil)) ?? []
        return entries
            .filter { $0.lastPathComponent.hasPrefix("external.bak-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    // MARK: - Locating the payload

    /// Walks the mounted volume for a directory named `external` that
    /// contains `libd3dshared.dylib`. Apple's dmgs have shipped this at
    /// both `redist/lib/external/` and `lib/external/`, so — same approach
    /// as `EngineManager`'s `findBinDirectory` — this is discovered by
    /// enumeration rather than assumed at a fixed depth.
    private static func findExternalDirectory(under root: URL) -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles], errorHandler: nil
        ) else { return nil }

        for case let candidate as URL in enumerator {
            guard candidate.lastPathComponent == "external" else { continue }
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            if fm.fileExists(atPath: candidate.appendingPathComponent("libd3dshared.dylib").path) {
                return candidate
            }
        }
        return nil
    }

    // MARK: - Verification

    /// Same environment `EngineManager`'s install-time version check needs
    /// for D3DMetal to even load — run again after the swap to prove it
    /// didn't break the engine.
    private static func verifyEngineRuns(_ engine: InstalledEngine) async throws {
        let environment: [String: String] = [
            "WINEDEBUG": "-all",
            "DYLD_FALLBACK_LIBRARY_PATH": "\(engine.libDir.path):\(engine.libDir.appendingPathComponent("external").path)",
            "PATH": "/usr/bin:/bin",
            "HOME": NSHomeDirectory(),
        ]
        let result = try await ProcessRunner.run(engine.wineBinary, ["--version"], environment: environment)
        guard result.status == 0 else {
            throw D3DMetalImporterError.verificationFailed(result.stderr.isEmpty ? "exited with status \(result.status)" : result.stderr)
        }
    }

    // MARK: - Version string

    /// `D3DMetal.framework/Resources/Info.plist`'s `CFBundleShortVersionString`,
    /// falling back to the first line of `strings` on the dylib that
    /// mentions "D3DMetal" when the framework's own Info.plist is missing
    /// or unreadable.
    private static func readD3DMetalVersion(externalDir: URL) -> String? {
        let plistURL = externalDir
            .appendingPathComponent("D3DMetal.framework")
            .appendingPathComponent("Resources")
            .appendingPathComponent("Info.plist")
        if let data = try? Data(contentsOf: plistURL),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let version = plist["CFBundleShortVersionString"] as? String, !version.isEmpty {
            return version
        }

        let dylib = externalDir.appendingPathComponent("libd3dshared.dylib")
        guard FileManager.default.isReadableFile(atPath: dylib.path) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/strings")
        process.arguments = [dylib.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            return text.split(separator: "\n").first { $0.localizedCaseInsensitiveContains("D3DMetal") }.map(String.init)
        } catch {
            return nil
        }
    }
}
