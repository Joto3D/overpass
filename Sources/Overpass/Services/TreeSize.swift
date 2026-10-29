import Foundation

/// Total size of every file under a directory, via `fts(3)` instead of
/// `FileManager.enumerator`.
///
/// Two places add up a folder's file sizes: `BottleImporter` (to label an
/// importable prefix with its size) and `GameLibrary` (the "42.1 GB"
/// subtitle on a GOG / Epic game). Both used the same loop:
/// `FileManager.enumerator(at:includingPropertiesForKeys:)` plus one
/// `URL.resourceValues` call per entry. That is correct but spends most
/// of its time building an `NSURL` and a resource-value dictionary for
/// every file just to read one integer.
///
/// `fts` walks the tree with plain `lstat` results and no per-file
/// object allocation.
///
/// ## MEASURED (this machine, APFS, warm cache, median of 8, `-O`)
///
///     tree                              enumerator   fts     speed-up
///     Steam bottle prefix (~8.8k files)    30.8 ms   12.5 ms   2.5x
///     Default bottle prefix (~9.0k files)  36.9 ms   17.0 ms   2.2x
///
/// Both walks returned byte-identical totals on both prefixes
/// (2,620,620,821 and 1,568,807,286) and on the two CrossOver prefixes
/// (802,088,554 and 27,499,597,132), so this is a drop-in replacement.
///
/// End to end through the real callers (debug build, median of 5):
///
///     GameLibrary.scan, 3 synthetic GOG games x 5k files   41.6 ms -> 14.4 ms
///     BottleImporter.validate, Default prefix              41.5 ms -> 17.5 ms
///     BottleImporter.validate, Steam prefix                32.9 ms -> 13.1 ms
///
/// The cost is per-file (about 3.7 us before, 1.9 us after), so the
/// saving scales with the tree: extrapolating, a 100k-file game that
/// took ~0.4 s to size should take ~0.2 s. It matters because
/// `BottleImporter.discover()` runs the walk for every importable prefix
/// and `GameLibrary.scan` runs it for every GOG / Epic game each time a
/// bottle is opened.
///
/// ## Behaviour kept, and the one difference
///
/// - Counts the same thing the old loops did: the `st_size` of every
///   non-directory entry, with symlinks counted as the link itself
///   (`FTS_PHYSICAL`, never followed - important, because every prefix
///   has `dosdevices/z:` pointing at `/`).
/// - Skips dot-files and dot-directories (and everything under them),
///   like `.skipsHiddenFiles`. The one difference is that
///   `.skipsHiddenFiles` also honours macOS's `UF_HIDDEN` flag, which
///   `fts` does not see. Nothing in a Wine prefix or a game folder
///   carries that flag; the totals above match to the byte.
/// - Entries that cannot be read are skipped, as before.
enum TreeSize {
    /// Sum of file sizes under `url`.
    ///
    /// - Parameter budgetSeconds: when non-nil, gives up and returns
    ///   `nil` once this much wall-clock time has passed (checked every
    ///   256 entries, as `BottleImporter.sizeWithBudget` always did), so
    ///   a prefix with a million files reports "unknown" rather than
    ///   stalling its caller.
    /// - Returns: `nil` if `url` cannot be opened at all, or the budget
    ///   ran out.
    static func totalFileSize(of url: URL, budgetSeconds: Double? = nil) -> Int64? {
        guard let rootPath = strdup(url.path) else { return nil }
        defer { free(rootPath) }
        var paths: [UnsafeMutablePointer<CChar>?] = [rootPath, nil]
        // FTS_NOCHDIR: never change the process-wide working directory,
        // which would race with every other thread in the app.
        guard let stream = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { return nil }
        defer { fts_close(stream) }

        let deadline = budgetSeconds.map { Date().addingTimeInterval($0) }
        var total: Int64 = 0
        var visited = 0
        var openedRoot = false

        while let entry = fts_read(stream) {
            visited += 1
            if let deadline, visited % 256 == 0, Date() > deadline { return nil }

            let info = Int32(entry.pointee.fts_info)
            let isRoot = entry.pointee.fts_level == 0
            if isRoot {
                // `url` itself must be a readable directory/file, else
                // the old `enumerator(at:)` returned nil too.
                openedRoot = info != FTS_NS && info != FTS_ERR && info != FTS_DNR
            } else if let path = entry.pointee.fts_path,
                      let slash = strrchr(path, 47), slash.pointee != 0, slash[1] == 46 {
                // Hidden (leading dot) - skip it and, for a directory,
                // everything beneath it.
                if info == FTS_D { fts_set(stream, entry, FTS_SKIP) }
                continue
            }

            switch info {
            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                total += Int64(entry.pointee.fts_statp.pointee.st_size)
            default:
                break // directories (pre/post order), errors
            }
        }
        return openedRoot ? total : nil
    }
}
