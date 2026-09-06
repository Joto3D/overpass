import Foundation

/// Discovers launchable Windows programs already installed inside a
/// bottle by walking the usual places Windows itself puts shortcuts and
/// executables: Desktop, Start Menu, and Program Files. Read-only —
/// callers persist the result onto `Bottle.pins` themselves (see
/// `ProgramsGridView`'s "Rescan").
///
/// A raw Program Files tree is noisy: the same file often exists under
/// both `Program Files` and `Program Files (x86)`, a `.lnk` and a bare
/// `.exe` sometimes point at the same binary, and every real install adds
/// a handful of uninstallers/updaters/helper processes nobody would ever
/// pin directly. The scanner still returns everything it finds — nothing
/// is silently dropped — but classifies each result via `PinnedProgram`'s
/// `isSystem` and `isHelper` flags so a view can default to hiding them,
/// and dedupes exact/near-duplicate binaries down to one entry.
enum ProgramScanner {
    /// Name fragments (case-insensitive substring match against the
    /// executable's base name) that mark a program as installer/updater/
    /// utility scaffolding rather than something a user would want to
    /// launch directly. Matches set `PinnedProgram.isHelper` — they're
    /// still returned, just flagged.
    private static let helperNameFragments: Set<String> = [
        "uninstall", "unins", "setup", "install", "vcredist", "dxsetup", "redist",
        "crash", "handler", "helper", "update", "updater", "report", "gup",
        "service", "daemon", "agent", "launcher-helper", "elevate", "cef",
        "webhelper", "overlay", "dbg", "debug", "console",
    ]

    /// Trailing architecture markers stripped from derived display names
    /// (checked in order, case-insensitive, as a literal suffix).
    private static let archSuffixes = ["64-bit", "(x64)", "x64"]

    /// Walks `bottle`'s `drive_c` for `.lnk`/`.url` shortcuts and `.exe`
    /// files and returns them as freshly-minted `PinnedProgram`s
    /// (`isUserAdded: false`), sorted by name. Does not consult or
    /// preserve `bottle.pins` — see `merge(scanned:existing:)` for that.
    static func scan(bottle: Bottle) async -> [PinnedProgram] {
        await Task.detached(priority: .utility) {
            scanSync(driveC: bottle.driveC)
        }.value
    }

    /// Merges a fresh `scan(bottle:)` result with the bottle's existing
    /// pins: user-added pins are always kept (a scan never finds those —
    /// they're not on disk under a name the scanner would recognize as a
    /// "real" program on its own), and a previously-scanned pin whose
    /// `exePath` matches a newly-scanned program keeps its existing `id`
    /// (and any edited `args`) rather than being replaced wholesale, so
    /// per-program argument edits survive a rescan.
    ///
    /// `excluding` holds paths the user has explicitly removed from their
    /// pins (a view tracks this separately since a removed, non-user pin
    /// leaves no trace in `existing` to compare against): any freshly
    /// scanned entry at one of those paths is dropped rather than being
    /// re-added as if it were newly discovered.
    static func merge(scanned rawScanned: [PinnedProgram], existing: [PinnedProgram], excluding: Set<String> = []) -> [PinnedProgram] {
        let scanned = excluding.isEmpty ? rawScanned : rawScanned.filter { !excluding.contains($0.exePath) }

        var byPath: [String: PinnedProgram] = [:]
        for pin in existing where !pin.isUserAdded {
            byPath[pin.exePath] = pin
        }

        var merged: [PinnedProgram] = scanned.map { fresh in
            if let previous = byPath[fresh.exePath] {
                // Keep the existing name: it may have been set by the app
                // catalog (e.g. "Steam" with launch args) or edited by the
                // user, and the scanner's filename-derived name is only a
                // fallback for brand-new pins. The freshly-computed
                // isSystem/isHelper classification still wins, though — an
                // older pin predating those flags always decoded to
                // `false`/`false`, which would otherwise stick forever.
                var kept = previous
                kept.isSystem = fresh.isSystem
                kept.isHelper = fresh.isHelper
                kept.launchURL = fresh.launchURL
                return kept
            }
            return fresh
        }

        let scannedPaths = Set(scanned.map(\.exePath))
        let userAdded = existing.filter { $0.isUserAdded }
        // Also keep any existing non-user pin whose exe vanished from this
        // scan (e.g. it's on a network share, or the scan roots changed) —
        // don't silently drop a pin just because one rescan missed it,
        // as long as the file still exists on disk.
        let stillOnDisk = existing.filter { !$0.isUserAdded && !scannedPaths.contains($0.exePath) && FileManager.default.fileExists(atPath: $0.exePath) }

        merged.append(contentsOf: stillOnDisk)
        merged.append(contentsOf: userAdded)
        return merged.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Synchronous scan (runs off the main actor via Task.detached)

    /// A discovered `.exe`, before final name/flag resolution. Keyed (in
    /// `scanSync`) by the lower-cased resolved real path so a `.lnk` and a
    /// bare `.exe` that point at the same file collapse into one entry.
    private struct Candidate {
        /// Resolved (`resolvingSymlinksInPath`), standardized absolute
        /// path — what ends up in `PinnedProgram.exePath`.
        var realPath: String
        /// Best display name found so far: a `.lnk`'s filename once one
        /// is seen (preferred), else the bare `.exe`'s own filename.
        var name: String
        var fromLnk: Bool
        /// Set when the `.lnk` that pointed here lives somewhere that
        /// itself marks the target as a system program (e.g. Wine's
        /// built-in Start Menu\Programs\Accessories), independent of
        /// where the target `.exe` physically sits.
        var forceSystem: Bool
        var size: Int?
    }

    private static func scanSync(driveC: URL) -> [PinnedProgram] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: driveC.path) else { return [] }

        var exeCandidates: [String: Candidate] = [:]
        var urlCandidates: [String: (name: String, url: String)] = [:]

        func consider(exeURL: URL, displayName: String, fromLnk: Bool, forceSystem: Bool = false) {
            guard exeURL.pathExtension.lowercased() == "exe" else { return }
            let resolved = exeURL.resolvingSymlinksInPath().standardizedFileURL
            let path = resolved.path
            guard fm.fileExists(atPath: path) else { return }
            let key = path.lowercased()
            let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int

            if var existing = exeCandidates[key] {
                // Prefer a name sourced from a .lnk shortcut over a bare
                // .exe's own filename.
                if fromLnk && !existing.fromLnk {
                    existing.name = displayName
                    existing.fromLnk = true
                }
                existing.forceSystem = existing.forceSystem || forceSystem
                exeCandidates[key] = existing
            } else {
                exeCandidates[key] = Candidate(realPath: path, name: displayName, fromLnk: fromLnk, forceSystem: forceSystem, size: size)
            }
        }

        func addURLCandidate(url: String, name: String) {
            let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let key = trimmed.lowercased()
            if urlCandidates[key] == nil {
                urlCandidates[key] = (name, trimmed)
            }
        }

        // 1. Shortcut locations: Desktop (per-user + Public), Start Menu
        //    (per-user + all-users). `.lnk` shortcuts here cover both
        //    installed programs and (on Desktops especially) game
        //    launchers dropped by Steam/GOG/Epic, some of which target a
        //    URL (`steam://rungameid/…`) rather than a Windows path;
        //    `.url` files (plain INI text) are the other common shape for
        //    those.
        var shortcutRoots: [URL] = []
        shortcutRoots.append(driveC.appendingPathComponent("users/Public/Desktop", isDirectory: true))
        shortcutRoots.append(driveC.appendingPathComponent("ProgramData/Microsoft/Windows/Start Menu/Programs", isDirectory: true))

        let usersDir = driveC.appendingPathComponent("users", isDirectory: true)
        if let userEntries = try? fm.contentsOfDirectory(at: usersDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for userDir in userEntries {
                guard (try? userDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                shortcutRoots.append(userDir.appendingPathComponent("Desktop", isDirectory: true))
                shortcutRoots.append(userDir.appendingPathComponent("AppData/Roaming/Microsoft/Windows/Start Menu/Programs", isDirectory: true))
            }
        }

        for root in shortcutRoots {
            for fileURL in enumerate(root, in: fm, driveC: driveC, maxDepth: nil) {
                let ext = fileURL.pathExtension.lowercased()
                if ext == "lnk" {
                    guard let link = ShellLink.parse(fileURL), !link.target.isEmpty else { continue }
                    let name = fileURL.deletingPathExtension().lastPathComponent
                    if let exeURL = ShellLink.windowsPathToUnix(link.target, driveC: driveC) {
                        let forceSystem = isSystemPath(fileURL.standardizedFileURL.path, driveC: driveC)
                        consider(exeURL: exeURL, displayName: name, fromLnk: true, forceSystem: forceSystem)
                    } else if link.target.contains("://") {
                        // Not a Windows path this bottle can resolve — a
                        // URL-target shortcut (Steam/GOG/Epic game).
                        addURLCandidate(url: link.target, name: name)
                    }
                } else if ext == "url" {
                    // .url files are INI text: `[InternetShortcut]` /
                    // `URL=steam://…`. ShellLink only parses the binary
                    // .lnk format, so these need their own tiny parser.
                    if let target = parseDotURLFile(fileURL), target.contains("://") {
                        let name = fileURL.deletingPathExtension().lastPathComponent
                        addURLCandidate(url: target, name: name)
                    }
                }
            }
        }

        // 2. Program Files trees: bare .exe files, depth-limited so we
        //    don't wander into every data/cache subfolder an installed
        //    app ships.
        let programFilesRoots = [
            driveC.appendingPathComponent("Program Files", isDirectory: true),
            driveC.appendingPathComponent("Program Files (x86)", isDirectory: true),
        ]
        for root in programFilesRoots {
            for fileURL in enumerate(root, in: fm, driveC: driveC, maxDepth: 3) {
                guard fileURL.pathExtension.lowercased() == "exe" else { continue }
                let name = fileURL.deletingPathExtension().lastPathComponent
                consider(exeURL: fileURL, displayName: name, fromLnk: false)
            }
        }

        // 3. Second dedupe pass: Wine's Program Files (x86) is often a
        //    genuine copy of Program Files, not a symlink, so two
        //    byte-identical binaries at the same relative path (one under
        //    each root) don't collapse via the resolved-real-path key
        //    above. Collapse those too, keyed on (relative path with the
        //    "(x86)" folder normalized away) + file size, so we don't
        //    accidentally merge two different programs that just happen
        //    to be the same number of bytes.
        var byNormalizedPath: [String: [String]] = [:]
        for (key, candidate) in exeCandidates {
            guard let size = candidate.size else { continue }
            let norm = normalizedRelativePath(candidate.realPath, driveC: driveC) + "#\(size)"
            byNormalizedPath[norm, default: []].append(key)
        }
        for (_, keys) in byNormalizedPath where keys.count > 1 {
            let winnerKey = keys.min { a, b in
                let pathA = exeCandidates[a]!.realPath.lowercased()
                let pathB = exeCandidates[b]!.realPath.lowercased()
                let aIsX86 = pathA.contains("(x86)")
                let bIsX86 = pathB.contains("(x86)")
                if aIsX86 != bIsX86 { return !aIsX86 } // prefer the plain (non-x86) copy
                return pathA.count < pathB.count
            }!
            var winner = exeCandidates[winnerKey]!
            if let lnkNamed = keys.compactMap({ exeCandidates[$0] }).first(where: { $0.fromLnk }) {
                winner.name = lnkNamed.name
                winner.fromLnk = true
            }
            winner.forceSystem = keys.contains { exeCandidates[$0]!.forceSystem }
            for key in keys where key != winnerKey {
                exeCandidates.removeValue(forKey: key)
            }
            exeCandidates[winnerKey] = winner
        }

        // 4. Classify: isSystem (Wine/Windows-bundled software) and
        //    isHelper (installer/updater scaffolding, or an untargeted
        //    .exe sitting next to a .lnk-targeted one in the same folder
        //    — e.g. 7z.exe/7zG.exe beside 7-Zip's 7zFM.exe).
        var isHelperByKey: [String: Bool] = [:]
        var isSystemByKey: [String: Bool] = [:]
        for (key, candidate) in exeCandidates {
            let baseName = URL(fileURLWithPath: candidate.realPath).deletingPathExtension().lastPathComponent
            isHelperByKey[key] = isHelperName(baseName)
            isSystemByKey[key] = isSystemPath(candidate.realPath, driveC: driveC) || candidate.forceSystem
        }

        var lnkTargetDirs: [String: Set<String>] = [:] // lowercased parent dir -> set of target keys
        for (key, candidate) in exeCandidates where candidate.fromLnk {
            let parent = URL(fileURLWithPath: candidate.realPath).deletingLastPathComponent().path.lowercased()
            lnkTargetDirs[parent, default: []].insert(key)
        }
        for (key, candidate) in exeCandidates where !candidate.fromLnk {
            let parent = URL(fileURLWithPath: candidate.realPath).deletingLastPathComponent().path.lowercased()
            if let targets = lnkTargetDirs[parent], !targets.contains(key) {
                isHelperByKey[key] = true
            }
        }

        // 5. Names: prefer the .lnk's own filename; otherwise, if this
        //    .exe is the only non-helper .exe in its folder, use the
        //    folder name (so Notepad++/notepad++.exe -> "Notepad++");
        //    otherwise fall back to the .exe's own filename. Either way,
        //    strip a trailing architecture marker.
        var nonHelperCountByParent: [String: Int] = [:]
        for (key, candidate) in exeCandidates where isHelperByKey[key] != true {
            let parent = URL(fileURLWithPath: candidate.realPath).deletingLastPathComponent().path.lowercased()
            nonHelperCountByParent[parent, default: 0] += 1
        }

        var pins: [PinnedProgram] = []
        for (key, candidate) in exeCandidates {
            let isHelper = isHelperByKey[key] ?? false
            let isSystem = isSystemByKey[key] ?? false
            let exeURL = URL(fileURLWithPath: candidate.realPath)

            let displayName: String
            if candidate.fromLnk {
                displayName = stripArchSuffix(candidate.name)
            } else {
                let parent = exeURL.deletingLastPathComponent()
                let parentKey = parent.path.lowercased()
                // The folder-name promotion is meant to turn a bare
                // "notepad++.exe" into the nicer "Notepad++" for a
                // user-installed program; a Wine-bundled system program
                // (Internet Explorer, WordPad's "Windows NT/Accessories",
                // …) keeps its own exe-derived name instead, since the
                // folder name there is Windows' internal grouping, not a
                // product name.
                if !isSystem, !isHelper, nonHelperCountByParent[parentKey] == 1 {
                    displayName = stripArchSuffix(parent.lastPathComponent)
                } else {
                    displayName = stripArchSuffix(exeURL.deletingPathExtension().lastPathComponent)
                }
            }

            pins.append(PinnedProgram(
                name: displayName,
                exePath: candidate.realPath,
                args: "",
                isUserAdded: false,
                isSystem: isSystem,
                isHelper: isHelper,
                launchURL: nil
            ))
        }

        for (_, entry) in urlCandidates {
            pins.append(PinnedProgram(
                name: entry.name,
                exePath: entry.url,
                args: "",
                isUserAdded: false,
                isSystem: false,
                isHelper: false,
                launchURL: entry.url
            ))
        }

        return pins.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Enumerates every file under `root` (root itself included in the
    /// walk), skipping the top-level `drive_c/windows` system directory
    /// and any `AppData/Local/Temp` directory, and optionally capping
    /// recursion depth relative to `root` (`maxDepth == nil` means
    /// unlimited — used for the comparatively small Desktop/Start Menu
    /// trees; Program Files gets a depth cap since some installers unpack
    /// thousands of files many levels deep).
    ///
    /// The `drive_c/windows` skip is anchored to `driveC` specifically
    /// (rather than a bare substring match against "windows" anywhere in
    /// the path) because a plain `path.contains("/windows/")` check also
    /// matches legitimate, unrelated folders that happen to have a
    /// "Windows" path component of their own — most importantly
    /// `ProgramData/Microsoft/Windows/Start Menu/Programs`, one of this
    /// scanner's own shortcut roots. A substring match there would prune
    /// every Start Menu `.lnk` before ever seeing it.
    private static func enumerate(_ root: URL, in fm: FileManager, driveC: URL, maxDepth: Int?) -> [URL] {
        guard fm.fileExists(atPath: root.path) else { return [] }
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        let rootComponentCount = root.standardizedFileURL.pathComponents.count
        let driveCPath = driveC.standardizedFileURL.path
        var results: [URL] = []

        for case let fileURL as URL in enumerator {
            let standardizedPath = fileURL.standardizedFileURL.path
            let lowerPath = standardizedPath.lowercased()
            if standardizedPath.hasPrefix(driveCPath) {
                let relativeToDriveC = String(lowerPath.dropFirst(driveCPath.count))
                if relativeToDriveC == "/windows" || relativeToDriveC.hasPrefix("/windows/") {
                    enumerator.skipDescendants()
                    continue
                }
            }
            if lowerPath.contains("/appdata/local/temp") {
                enumerator.skipDescendants()
                continue
            }

            let isDirectory = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false

            if let maxDepth {
                let depth = fileURL.standardizedFileURL.pathComponents.count - rootComponentCount
                if isDirectory, depth >= maxDepth {
                    enumerator.skipDescendants()
                    continue
                }
            }

            if !isDirectory {
                results.append(fileURL)
            }
        }
        return results
    }

    private static func isHelperName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return helperNameFragments.contains { lower.contains($0) }
    }

    /// `path` relative to `driveC`, lower-cased, forward-slash separated,
    /// with no leading slash (e.g. `program files/7-zip/7zfm.exe`). Falls
    /// back to the lower-cased absolute path if `path` isn't under
    /// `driveC` at all (shouldn't normally happen).
    private static func relativePath(_ path: String, driveC: URL) -> String {
        let drivePath = driveC.standardizedFileURL.path
        guard path.hasPrefix(drivePath) else { return path.lowercased() }
        var rel = String(path.dropFirst(drivePath.count))
        while rel.hasPrefix("/") { rel.removeFirst() }
        return rel.lowercased()
    }

    /// `relativePath`, with a leading `program files (x86)/` folded into
    /// `program files/` — used both for system-path classification and
    /// for the "same file, both bitness trees" dedupe pass, so the two
    /// trees compare equal regardless of which one a given install used.
    private static func normalizedRelativePath(_ path: String, driveC: URL) -> String {
        var rel = relativePath(path, driveC: driveC)
        let x86Prefix = "program files (x86)/"
        if rel.hasPrefix(x86Prefix) {
            rel = "program files/" + rel.dropFirst(x86Prefix.count)
        }
        return rel
    }

    /// True for anything under the folders Wine ships as part of a fresh
    /// prefix rather than something a user installed: everything under
    /// `drive_c/windows`, Internet Explorer / Windows Media Player /
    /// Windows NT (WordPad, Notepad's "real" home) / Common Files under
    /// either `Program Files` or `Program Files (x86)`, and shortcuts
    /// filed under the Start Menu's built-in Accessories folder.
    private static func isSystemPath(_ path: String, driveC: URL) -> Bool {
        let rel = relativePath(path, driveC: driveC)
        if rel.hasPrefix("windows/") || rel == "windows" { return true }

        let normalized = normalizedRelativePath(path, driveC: driveC)
        let systemProgramFilesSubdirs = [
            "program files/internet explorer/",
            "program files/windows media player/",
            "program files/windows nt/",
            "program files/common files/",
        ]
        if systemProgramFilesSubdirs.contains(where: { normalized.hasPrefix($0) }) { return true }

        if rel.hasPrefix("programdata/microsoft/windows/start menu/programs/accessories/") { return true }

        return false
    }

    /// Strips a trailing architecture marker ("Foo x64", "Foo (x64)",
    /// "Foo 64-bit") and any separator left dangling after it.
    private static func stripArchSuffix(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespaces)
        for suffix in archSuffixes {
            guard name.count > suffix.count,
                  let range = name.range(of: suffix, options: [.caseInsensitive, .backwards]),
                  range.upperBound == name.endIndex
            else { continue }
            name = String(name[name.startIndex..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            while let last = name.last, "-–—".contains(last) {
                name.removeLast()
                name = name.trimmingCharacters(in: .whitespaces)
            }
        }
        return name.isEmpty ? raw : name
    }

    /// Parses a `.url` file (plain INI text — `[InternetShortcut]` /
    /// `URL=steam://…`) and returns the `URL=` value, or `nil` if there
    /// isn't one.
    private static func parseDotURLFile(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.lowercased().hasPrefix("url=") else { continue }
            let value = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    // MARK: - Debug-only self test

    #if DEBUG
    /// Builds a synthetic `drive_c` reproducing the real-world case this
    /// scanner was rewritten for (7-Zip + Notepad++ installed alongside
    /// Wine's built-in Internet Explorer/WordPad) and asserts the
    /// classification/dedupe/naming rules above. Not run automatically —
    /// call manually from a throwaway driver. Traps (via `assert`) on
    /// failure; prints a summary either way.
    static func _selfTest() {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("OverpassScannerSelfTest-\(UUID().uuidString)", isDirectory: true)
        let driveC = root.appendingPathComponent("drive_c", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        func makeExe(_ path: String, bytes: Int = 4096) {
            let url = driveC.appendingPathComponent(path)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: url.path, contents: Data(repeating: 0x90, count: bytes))
        }
        func makeLnk(_ path: String, targetWindowsPath: String) {
            let url = driveC.appendingPathComponent(path)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? makeShellLinkData(targetWindowsPath: targetWindowsPath).write(to: url)
        }

        // 7-Zip: real launcher (7zFM.exe) + two helper CLIs, one Start
        // Menu shortcut targeting only the launcher.
        makeExe("Program Files/7-Zip/7zFM.exe")
        makeExe("Program Files/7-Zip/7z.exe")
        makeExe("Program Files/7-Zip/7zG.exe")
        makeLnk("ProgramData/Microsoft/Windows/Start Menu/Programs/7-Zip.lnk", targetWindowsPath: #"C:\Program Files\7-Zip\7zFM.exe"#)

        // Notepad++: real program + its updater in a subfolder, shortcut
        // targeting the main exe.
        makeExe("Program Files/Notepad++/notepad++.exe")
        makeExe("Program Files/Notepad++/updater/GUP.exe")
        makeLnk("ProgramData/Microsoft/Windows/Start Menu/Programs/Notepad++.lnk", targetWindowsPath: #"C:\Program Files\Notepad++\notepad++.exe"#)

        // Internet Explorer: identical stub under both Program Files and
        // Program Files (x86) — should collapse to one System entry.
        makeExe("Program Files/Internet Explorer/iexplore.exe", bytes: 2048)
        makeExe("Program Files (x86)/Internet Explorer/iexplore.exe", bytes: 2048)

        // WordPad: Wine's built-in Accessories shortcut, target lives
        // under drive_c/windows.
        makeExe("windows/system32/wordpad.exe", bytes: 8192)
        makeLnk("ProgramData/Microsoft/Windows/Start Menu/Programs/Accessories/WordPad.lnk", targetWindowsPath: #"C:\windows\system32\wordpad.exe"#)

        let result = scanSync(driveC: driveC)
        let byName = Dictionary(grouping: result, by: { $0.name })

        func check(_ condition: Bool, _ message: String) {
            if condition {
                print("[selfTest] OK: \(message)")
            } else {
                print("[selfTest] FAIL: \(message)")
                assertionFailure(message)
            }
        }

        let nonSystemNonHelperNames = Set(result.filter { !$0.isSystem && !$0.isHelper }.map(\.name))
        check(nonSystemNonHelperNames == ["7-Zip", "Notepad++"], "non-system non-helper set is exactly {7-Zip, Notepad++}, got \(nonSystemNonHelperNames.sorted())")

        check((byName["iexplore"]?.count ?? 0) == 1, "iexplore appears exactly once, got \(byName["iexplore"]?.count ?? 0)")
        check(byName["iexplore"]?.first?.isSystem == true, "iexplore is flagged isSystem")

        check((byName["WordPad"]?.count ?? 0) == 1, "WordPad appears exactly once")
        check(byName["WordPad"]?.first?.isSystem == true, "WordPad is flagged isSystem")

        for helperName in ["7z", "7zG", "GUP"] {
            check(byName[helperName]?.first?.isHelper == true, "\(helperName) is flagged isHelper")
        }

        print("[selfTest] full result:")
        for pin in result.sorted(by: { $0.name < $1.name }) {
            print("  \(pin.name)\tsystem=\(pin.isSystem)\thelper=\(pin.isHelper)\t\(pin.exePath)")
        }
    }

    /// Runs the real scanner against an already-existing `drive_c` (e.g.
    /// a real bottle under `~/Library/Application Support/Overpass/
    /// Bottles/<id>/drive_c`) and prints the result. Read-only — never
    /// writes into the given tree. Not called from product code.
    static func _debugPrintScan(driveCPath: String) {
        let driveC = URL(fileURLWithPath: driveCPath)
        let result = scanSync(driveC: driveC)
        for pin in result.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            print("\(pin.name)\tsystem=\(pin.isSystem)\thelper=\(pin.isHelper)\turl=\(pin.launchURL ?? "-")\t\(pin.exePath)")
        }
    }

    /// Minimal well-formed `.lnk` bytes: header (HasLinkInfo, ANSI) + a
    /// `LinkInfo` carrying only a `LocalBasePath`. Enough for
    /// `ShellLink.parse` per its documented layout — see
    /// `Services/ShellLink.swift`.
    private static func makeShellLinkData(targetWindowsPath: String) -> Data {
        var data = Data()

        func appendUInt32(_ v: UInt32) {
            data.append(UInt8(v & 0xff))
            data.append(UInt8((v >> 8) & 0xff))
            data.append(UInt8((v >> 16) & 0xff))
            data.append(UInt8((v >> 24) & 0xff))
        }

        // Header (76 bytes): HeaderSize, CLSID(16), ... LinkFlags at 20 ...
        appendUInt32(76) // HeaderSize
        data.append(contentsOf: [UInt8](repeating: 0, count: 16)) // CLSID
        // LinkFlags: HasLinkInfo (0x2) only — no target id list, no
        // strings, ANSI (not unicode) so LocalBasePath is a plain
        // NUL-terminated ANSI string.
        appendUInt32(0x0000_0002)
        data.append(contentsOf: [UInt8](repeating: 0, count: 76 - data.count)) // pad to HeaderSize

        // LinkInfo, starting right after the header.
        let pathBytes = Array(targetWindowsPath.utf8) + [0] // NUL-terminated ANSI
        let linkInfoHeaderSize = 0x1c // no Unicode offset fields
        let localBasePathOffset = linkInfoHeaderSize // right after the fixed header
        let linkInfoSize = localBasePathOffset + pathBytes.count

        appendUInt32(UInt32(linkInfoSize))        // LinkInfoSize
        appendUInt32(UInt32(linkInfoHeaderSize))  // LinkInfoHeaderSize
        appendUInt32(0x0000_0001)                 // LinkInfoFlags: VolumeIDAndLocalBasePath
        appendUInt32(0)                           // VolumeIDOffset (unused, no VolumeID emitted)
        appendUInt32(UInt32(localBasePathOffset)) // LocalBasePathOffset
        appendUInt32(0)                           // CommonNetworkRelativeLinkOffset
        appendUInt32(0)                           // CommonPathSuffixOffset
        data.append(contentsOf: pathBytes)

        return data
    }
    #endif
}
