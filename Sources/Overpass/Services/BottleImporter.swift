import Foundation

/// Discovers Wine prefixes created by other tools (CrossOver, Whisky,
/// Wineskin, or a bare `~/.wine`) and copies one into a fresh Overpass
/// bottle so it can be run under an Overpass-managed engine.
///
/// **Caveats worth knowing before importing:**
/// - Apps installed under CrossOver often link against CrossOver's own
///   bundled D3DMetal/Wine build (CXG streaming, CrossOver-specific
///   registry keys and DLL overrides). After import, `wineboot -u` lets
///   the *new* engine update the prefix in place, but some apps —
///   especially anything CrossOver installed through "CrossTie" or its
///   built-in installers — may need reinstalling once the bottle is
///   running on a plain GPTK/Wine-staging engine.
/// - Steam bottles copy over fine, but Steam re-verifies its entire
///   library on first launch in the new prefix (it fingerprints the
///   install path/drive serial), so expect a verification pass, not an
///   instant resume.
/// - Wineskin prefixes rarely carry a `system.reg` at the top level
///   (some wrap the actual prefix one directory deeper, e.g.
///   `Contents/Resources/wine`); `discover()` only finds the ones that
///   look like a normal `WINEPREFIX` — point `validate(_:)` at the inner
///   folder by hand for anything nested.
enum BottleImporter {
    // MARK: - Source

    enum Kind: String, Codable, Sendable {
        case crossOver
        case whisky
        case wineskin
        case genericPrefix

        var displayName: String {
            switch self {
            case .crossOver: return "CrossOver"
            case .whisky: return "Whisky"
            case .wineskin: return "Wineskin"
            case .genericPrefix: return "Wine prefix"
            }
        }
    }

    /// One discovered (or user-chosen) Wine prefix, not yet imported.
    struct Source: Identifiable, Hashable, Sendable {
        /// The prefix folder itself — stable and unique per source.
        var id: URL { prefixDir }
        let name: String
        let kind: Kind
        let prefixDir: URL
        let windowsVersion: WindowsVersion?
        /// `nil` when the size wasn't computed (very large tree, or the
        /// walk exceeded its time budget) rather than actually unknown.
        let sizeBytes: Int64?
    }

    struct ImportError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - Discovery

    /// Scans the well-known locations other Wine launchers keep their
    /// bottles/prefixes in. Folders that don't look like a real
    /// `WINEPREFIX` (see `isPrefix(_:)`) are skipped. Size is computed
    /// with a short time budget per source so `discover()` stays fast
    /// even with a large bottle on disk.
    static func discover() -> [Source] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var sources: [Source] = []

        // CrossOver: ~/Library/Application Support/CrossOver/Bottles/*
        let crossOverRoot = home
            .appendingPathComponent("Library/Application Support/CrossOver/Bottles", isDirectory: true)
        for dir in subdirectories(of: crossOverRoot) {
            guard isPrefix(dir) else { continue }
            let name = dir.lastPathComponent
            let windowsVersion = crossOverWindowsVersion(dir)
            sources.append(Source(
                name: name, kind: .crossOver, prefixDir: dir,
                windowsVersion: windowsVersion, sizeBytes: sizeWithBudget(dir)
            ))
        }

        // Whisky: two historical locations for the Bottles folder.
        let whiskyRoots = [
            home.appendingPathComponent("Library/Containers/com.isaacmarovitz.Whisky/Bottles", isDirectory: true),
            home.appendingPathComponent("Library/Application Support/com.isaacmarovitz.Whisky/Bottles", isDirectory: true),
        ]
        var seenWhisky = Set<URL>()
        for root in whiskyRoots {
            for dir in subdirectories(of: root) {
                guard isPrefix(dir) else { continue }
                let standardized = dir.standardizedFileURL
                guard !seenWhisky.contains(standardized) else { continue }
                seenWhisky.insert(standardized)
                let name = whiskyName(dir) ?? dir.lastPathComponent
                sources.append(Source(
                    name: name, kind: .whisky, prefixDir: dir,
                    windowsVersion: nil, sizeBytes: sizeWithBudget(dir)
                ))
            }
        }

        // Generic: ~/.wine, if it's actually a prefix.
        let dotWine = home.appendingPathComponent(".wine", isDirectory: true)
        if isPrefix(dotWine) {
            sources.append(Source(
                name: ".wine", kind: .genericPrefix, prefixDir: dotWine,
                windowsVersion: nil, sizeBytes: sizeWithBudget(dotWine)
            ))
        }

        return sources.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Validates a user-chosen folder (from an `NSOpenPanel`) as an
    /// importable prefix, classifying it the same way `discover()` would
    /// if it happened to live under a known launcher's Bottles folder.
    static func validate(_ url: URL) -> Source? {
        guard isPrefix(url) else { return nil }
        let path = url.standardizedFileURL.path
        let kind: Kind
        let name: String
        let windowsVersion: WindowsVersion?
        if path.contains("/CrossOver/Bottles/") {
            kind = .crossOver
            name = url.lastPathComponent
            windowsVersion = crossOverWindowsVersion(url)
        } else if path.contains("/com.isaacmarovitz.Whisky/Bottles/") {
            kind = .whisky
            name = whiskyName(url) ?? url.lastPathComponent
            windowsVersion = nil
        } else if path.hasSuffix(".wineskin") || path.contains("Wineskin") {
            kind = .wineskin
            name = url.lastPathComponent
            windowsVersion = nil
        } else {
            kind = .genericPrefix
            name = url.lastPathComponent
            windowsVersion = nil
        }
        return Source(name: name, kind: kind, prefixDir: url, windowsVersion: windowsVersion, sizeBytes: sizeWithBudget(url))
    }

    // MARK: - Import

    /// Copies `source`'s prefix into a brand-new Overpass bottle running
    /// on `engineID`, then lets that engine adopt the prefix
    /// (`wineboot -u`), applies `windowsVersion`, and scans for programs.
    ///
    /// `copy` only matters when the source lives on the same volume as
    /// `Paths.bottles` — Overpass never moves or symlinks another
    /// launcher's bottle (it might still be in use, or the user might
    /// want to keep it), so a same-volume "move" request is honored by
    /// still copying; the parameter exists so a future fast path (e.g.
    /// APFS clonefile) can use it without changing the signature.
    static func importPrefix(
        _ source: Source,
        as name: String,
        engineID: String,
        windowsVersion: WindowsVersion,
        copy: Bool,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> Bottle {
        let engines = await EngineManager.shared.installedEngines()
        guard let engine = engines.first(where: { $0.id == engineID }) else {
            throw ImportError(message: "Engine \"\(engineID)\" isn't installed.")
        }

        var bottle = Bottle(name: name, engineID: engineID, windowsVersion: windowsVersion)
        let destination = bottle.prefixDir

        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

            let sizeNote = source.sizeBytes.map { " (\(formatBytes($0)))" } ?? ""
            progress("Copying bottle\(sizeNote)…")
            try await copyPrefix(from: source.prefixDir, to: destination)

            progress("Relinking drive letters…")
            try relinkDosDevices(destination)

            try BottleStore.save(bottle)

            progress("Updating prefix for the new engine…")
            let updateResult = try await WineRunner.runTool(engine.wineBinary, ["wineboot", "-u"], bottle: bottle, engine: engine)
            guard updateResult.status == 0 else {
                throw ImportError(message: "wineboot -u failed: \(lastLines(updateResult.stderr))")
            }

            progress("Setting Windows version…")
            try await WineRunner.applyWindowsVersion(windowsVersion, bottle: bottle, engine: engine)

            progress("Scanning programs…")
            let scanned = await ProgramScanner.scan(bottle: bottle)
            bottle.pins = ProgramScanner.merge(scanned: scanned, existing: bottle.pins)

            try BottleStore.save(bottle)
            progress("Done.")
            return bottle
        } catch {
            try? FileManager.default.removeItem(at: destination)
            if let importError = error as? ImportError { throw importError }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            throw ImportError(message: message)
        }
    }

    // MARK: - Copying

    /// Copies the pieces of a `WINEPREFIX` that matter (`drive_c`,
    /// `dosdevices`, top-level `.reg` files, `.update-timestamp`) with
    /// `/usr/bin/ditto`, which preserves resource forks/xattrs and
    /// handles large trees efficiently. `/bin/cp -R` would work too but
    /// `ditto` is what macOS itself uses for this kind of bulk copy.
    private static func copyPrefix(from source: URL, to destination: URL) async throws {
        let fm = FileManager.default
        let entries = ["drive_c", "dosdevices", ".update-timestamp"]
        for entry in entries {
            let src = source.appendingPathComponent(entry)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = destination.appendingPathComponent(entry)
            let result = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/ditto"), [src.path, dst.path])
            guard result.status == 0 else {
                throw ImportError(message: "Copying \(entry) failed: \(lastLines(result.stderr))")
            }
        }

        // Top-level *.reg files (system.reg, user.reg, userdef.reg).
        if let topLevel = try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for file in topLevel where file.pathExtension.lowercased() == "reg" {
                let dst = destination.appendingPathComponent(file.lastPathComponent)
                try? fm.removeItem(at: dst)
                try fm.copyItem(at: file, to: dst)
            }
        }
    }

    /// Fixes `dosdevices/c:` to point at `../drive_c` (relative, so the
    /// bottle survives being moved) and `dosdevices/z:` to `/`, exactly
    /// as a freshly-created Overpass bottle would have them — the
    /// source's own symlinks are absolute paths into *its* prefix and
    /// are meaningless once copied.
    private static func relinkDosDevices(_ prefixDir: URL) throws {
        let fm = FileManager.default
        let dosDevices = prefixDir.appendingPathComponent("dosdevices", isDirectory: true)
        try fm.createDirectory(at: dosDevices, withIntermediateDirectories: true)

        let cLink = dosDevices.appendingPathComponent("c:")
        try? fm.removeItem(at: cLink)
        try fm.createSymbolicLink(atPath: cLink.path, withDestinationPath: "../drive_c")

        let zLink = dosDevices.appendingPathComponent("z:")
        try? fm.removeItem(at: zLink)
        try fm.createSymbolicLink(atPath: zLink.path, withDestinationPath: "/")
    }

    // MARK: - Prefix detection

    /// A folder counts as an importable Wine prefix if it has both a
    /// `drive_c` directory and a `system.reg` file — the two things every
    /// real `WINEPREFIX` has regardless of which tool created it.
    private static func isPrefix(_ url: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let driveC = url.appendingPathComponent("drive_c", isDirectory: true)
        guard fm.fileExists(atPath: driveC.path, isDirectory: &isDir), isDir.boolValue else { return false }
        return fm.fileExists(atPath: url.appendingPathComponent("system.reg").path)
    }

    private static func subdirectories(of root: URL) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        return entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    // MARK: - CrossOver metadata

    /// Reads `cxbottle.conf`'s `WindowsVersion` key, e.g. `"WindowsVersion" = "win10"`.
    /// CrossOver's own vocabulary (`win10`, `win11`, `win7`, `winxp`, ...)
    /// is mapped onto Overpass's smaller `WindowsVersion` enum; anything
    /// Overpass doesn't model (winxp, win2008, ...) comes back `nil` so
    /// the import sheet falls back to its own default.
    private static func crossOverWindowsVersion(_ prefixDir: URL) -> WindowsVersion? {
        let confURL = prefixDir.appendingPathComponent("cxbottle.conf")
        guard let text = try? String(contentsOf: confURL, encoding: .utf8) else { return nil }
        guard let range = text.range(of: #"WindowsVersion["\s]*=\s*"([^"]+)""#, options: .regularExpression) else { return nil }
        let match = String(text[range])
        guard let valueRange = match.range(of: #""[^"]+"\s*$"#, options: .regularExpression) else { return nil }
        let quoted = String(match[valueRange]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        switch quoted.lowercased() {
        case "win7": return .win7
        case "win10": return .win10
        case "win11": return .win11
        default: return nil
        }
    }

    // MARK: - Whisky metadata

    /// Whisky stores a `Metadata.plist` next to the prefix contents with
    /// a `"name"` string key. Read only that one field — everything else
    /// in Whisky's metadata (its own engine choice, DXVK state, ...)
    /// doesn't map onto Overpass's model.
    private static func whiskyName(_ prefixDir: URL) -> String? {
        let plistURL = prefixDir.appendingPathComponent("Metadata.plist")
        guard let data = try? Data(contentsOf: plistURL) else { return nil }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        if let name = plist["name"] as? String, !name.isEmpty { return name }
        if let name = plist["Name"] as? String, !name.isEmpty { return name }
        return nil
    }

    // MARK: - Size

    /// Sums file sizes under `url` with a short time budget so
    /// `discover()` doesn't stall on a multi-gigabyte bottle with
    /// hundreds of thousands of files. Returns `nil` if the walk didn't
    /// finish inside the budget — better an honest "unknown" than a
    /// truncated number presented as the real size.
    private static func sizeWithBudget(_ url: URL, budgetSeconds: Double = 2) -> Int64? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return nil }

        let deadline = Date().addingTimeInterval(budgetSeconds)
        var total: Int64 = 0
        var checkCounter = 0
        while let fileURL = enumerator.nextObject() as? URL {
            checkCounter += 1
            if checkCounter % 256 == 0, Date() > deadline { return nil }
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]) else { continue }
            if values.isDirectory == true { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func lastLines(_ text: String, count: Int = 20) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "(no output)" }
        return trimmed.split(separator: "\n", omittingEmptySubsequences: false).suffix(count).joined(separator: "\n")
    }
}
