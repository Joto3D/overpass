import Foundation

/// Discovers launchable Windows programs already installed inside a
/// bottle by walking the usual places Windows itself puts shortcuts and
/// executables: Desktop, Start Menu, and Program Files. Read-only —
/// callers persist the result onto `Bottle.pins` themselves (see
/// `ProgramsGridView`'s "Rescan").
enum ProgramScanner {
    /// Name fragments (case-insensitive substring match against the
    /// executable's base name) that mark a program as scaffolding rather
    /// than something a user would want to launch directly.
    private static let ignoredNameFragments = [
        "uninstall", "unins", "setup", "vcredist", "dxsetup", "redist",
        "crash", "handler", "helper", "update", "updater", "report",
    ]

    /// Walks `bottle`'s `drive_c` for `.lnk` shortcuts and `.exe` files
    /// and returns them as freshly-minted `PinnedProgram`s
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
    static func merge(scanned: [PinnedProgram], existing: [PinnedProgram]) -> [PinnedProgram] {
        var byPath: [String: PinnedProgram] = [:]
        for pin in existing where !pin.isUserAdded {
            byPath[pin.exePath] = pin
        }

        var merged: [PinnedProgram] = scanned.map { fresh in
            if let previous = byPath[fresh.exePath] {
                var kept = previous
                kept.name = fresh.name
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

    private static func scanSync(driveC: URL) -> [PinnedProgram] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: driveC.path) else { return [] }

        // exePath -> (display name, preferFromLnk)
        var found: [String: (name: String, fromLnk: Bool)] = [:]

        func consider(exeURL: URL, displayName: String, fromLnk: Bool) {
            let path = exeURL.standardizedFileURL.path
            guard exeURL.pathExtension.lowercased() == "exe" else { return }
            guard fm.fileExists(atPath: path) else { return }
            guard !isIgnoredName(exeURL.deletingPathExtension().lastPathComponent) else { return }

            if let existing = found[path] {
                // Prefer a name sourced from a .lnk shortcut over a bare
                // .exe's own filename.
                if fromLnk && !existing.fromLnk {
                    found[path] = (displayName, true)
                }
            } else {
                found[path] = (displayName, fromLnk)
            }
        }

        // 1. Shortcut locations: Desktop (per-user + Public), Start Menu
        //    (per-user + all-users).
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
            for fileURL in enumerate(root, in: fm, maxDepth: nil) {
                guard fileURL.pathExtension.lowercased() == "lnk" else { continue }
                guard let link = ShellLink.parse(fileURL), !link.target.isEmpty else { continue }
                guard let exeURL = ShellLink.windowsPathToUnix(link.target, driveC: driveC) else { continue }
                let name = fileURL.deletingPathExtension().lastPathComponent
                consider(exeURL: exeURL, displayName: name, fromLnk: true)
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
            for fileURL in enumerate(root, in: fm, maxDepth: 3) {
                guard fileURL.pathExtension.lowercased() == "exe" else { continue }
                let name = fileURL.deletingPathExtension().lastPathComponent
                consider(exeURL: fileURL, displayName: name, fromLnk: false)
            }
        }

        let pins = found.map { path, info in
            PinnedProgram(name: info.name, exePath: path, args: "", isUserAdded: false)
        }
        return pins.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Enumerates every file under `root` (root itself included in the
    /// walk), skipping `windows/` and any `AppData/Local/Temp` directory,
    /// and optionally capping recursion depth relative to `root`
    /// (`maxDepth == nil` means unlimited — used for the comparatively
    /// small Desktop/Start Menu trees; Program Files gets a depth cap
    /// since some installers unpack thousands of files many levels deep).
    private static func enumerate(_ root: URL, in fm: FileManager, maxDepth: Int?) -> [URL] {
        guard fm.fileExists(atPath: root.path) else { return [] }
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        let rootComponentCount = root.standardizedFileURL.pathComponents.count
        var results: [URL] = []

        for case let fileURL as URL in enumerator {
            let lowerPath = fileURL.path.lowercased()
            if lowerPath.contains("/windows/") || lowerPath.hasSuffix("/windows") {
                enumerator.skipDescendants()
                continue
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

    private static func isIgnoredName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ignoredNameFragments.contains { lower.contains($0) }
    }
}
