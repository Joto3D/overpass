import Foundation

/// Which store a discovered `InstalledGame` came from — drives the row's
/// muted "Steam · 42.1 GB" subtitle and the store-filter menu in
/// `GamesView`.
enum Store: String, Codable, CaseIterable, Sendable, Identifiable {
    case steam, gog, epic
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .steam: return "Steam"
        case .gog: return "GOG Galaxy"
        case .epic: return "Epic Games"
        }
    }
}

/// A game found already installed inside a bottle, via `GameLibrary.scan`.
/// Distinct from `PinnedProgram` — a game isn't something the user
/// launched-and-thereby-pinned, it's discovered live from a store client's
/// own on-disk manifests every time `GamesView` scans, so it always
/// reflects what's actually installed right now (uninstall a Steam game
/// and it stops appearing without any pin cleanup needed).
struct InstalledGame: Identifiable, Hashable, Sendable {
    /// Stable across rescans for a given store+identity, so SwiftUI list
    /// diffing doesn't treat every rescan as an all-new list: `"steam:<appid>"`,
    /// or `"<store>:<installDir path>"` for GOG/Epic, which have no numeric id
    /// this scanner parses out.
    var id: String
    var name: String
    var store: Store
    /// Steam's numeric app id, e.g. `"440"`. `nil` for GOG/Epic.
    var appID: String?
    var installDir: URL?
    var sizeBytes: Int64?
    /// The executable to hand to `AppState.run(exe:args:in:)`: Steam's own
    /// `Steam.exe` (which then `-applaunch`es the game), or the game's own
    /// main exe for GOG/Epic.
    var launchExe: URL?
    var launchArgs: String

    /// "Steam · 42.1 GB" / "GOG Galaxy" (no size known).
    var subtitle: String {
        var parts = [store.displayName]
        if let sizeBytes, sizeBytes > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file))
        }
        return parts.joined(separator: " \u{00b7} ")
    }
}

/// Discovers games already installed inside a bottle through whichever
/// store clients (Steam, GOG Galaxy, Epic Games) are present, so
/// `GamesView` can offer them as directly-launchable rows instead of
/// making the user open the store client and find the game themselves.
///
/// Every store's scan is independently best-effort: a missing directory,
/// an unreadable/malformed manifest, or a store that simply isn't
/// installed all just contribute zero games rather than throwing — the
/// only thing that can make `scan` itself throw is the synthetic
/// self-test below, which deliberately checks the parser in isolation.
enum GameLibrary {
    /// Scans every store this bottle has installed and returns the
    /// union, sorted by name. Runs off the main actor (each store's scan
    /// walks the filesystem, which can be slow on a cold cache).
    static func scan(bottle: Bottle) async -> [InstalledGame] {
        await scan(driveC: bottle.driveC)
    }

    /// The real scan, keyed off a bare `drive_c` rather than a `Bottle` —
    /// `Bottle.driveC` is derived from `Paths.bottleDir(id)`, which can't
    /// point at a scratch directory, so `DebugGamesCheck`'s synthetic-tree
    /// self-test calls this directly instead of `scan(bottle:)`.
    static func scan(driveC: URL) async -> [InstalledGame] {
        await Task.detached(priority: .utility) {
            var games: [InstalledGame] = []
            games.append(contentsOf: scanSteam(driveC: driveC))
            games.append(contentsOf: scanGOG(driveC: driveC))
            games.append(contentsOf: scanEpic(driveC: driveC))
            return games.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }.value
    }

    // MARK: - Steam

    /// Appids that are Steam's own tooling rather than a game — always
    /// skipped regardless of name.
    private static let steamToolAppIDs: Set<String> = [
        "228980", // Steamworks Common Redistributables
        "1070560", // Steam Linux Runtime
        "1391110", // Steam Linux Runtime - Soldier
        "1628350", // Steam Linux Runtime - Sniper
    ]

    /// Name fragments that mark an appmanifest as a redistributable/tool
    /// entry rather than a real game, in case a future tool ships under an
    /// appid not in `steamToolAppIDs` above.
    private static let steamToolNameFragments = ["redistributable", "steamworks", "steam linux runtime"]

    private static func scanSteam(driveC: URL) -> [InstalledGame] {
        let fm = FileManager.default
        let steamDir = driveC.appendingPathComponent("Program Files (x86)/Steam", isDirectory: true)
        guard fm.fileExists(atPath: steamDir.path) else { return [] }
        let steamExe = steamDir.appendingPathComponent("Steam.exe")

        var steamappsDirs = [steamDir.appendingPathComponent("steamapps", isDirectory: true)]
        let libraryFoldersVDF = steamappsDirs[0].appendingPathComponent("libraryfolders.vdf")
        if let text = readText(libraryFoldersVDF), let root = try? KeyValues.parse(text) {
            // "libraryfolders" { "0" { "path" "C:\\Program Files (x86)\\Steam" } "1" { "path" "D:\\SteamLibrary" } ... }
            if case .dict(let libraryFolders)? = root["libraryfolders"] ?? root["LibraryFolders"] {
                for (_, value) in libraryFolders {
                    guard case .dict(let entry) = value,
                          let pathString = entry["path"]?.stringValue ?? entry["Path"]?.stringValue,
                          let libraryRoot = ShellLink.windowsPathToUnix(pathString, driveC: driveC)
                    else { continue }
                    let candidate = libraryRoot.appendingPathComponent("steamapps", isDirectory: true)
                    steamappsDirs.append(candidate)
                }
            }
        }

        var seen = Set<String>() // resolved steamapps dir paths, so a library folder pointing back at the primary one isn't scanned twice
        var games: [InstalledGame] = []
        for dir in steamappsDirs {
            let resolved = dir.resolvingSymlinksInPath().path.lowercased()
            guard !seen.contains(resolved) else { continue }
            seen.insert(resolved)
            games.append(contentsOf: scanSteamappsDir(dir, steamExe: steamExe))
        }
        return games
    }

    private static func scanSteamappsDir(_ steamappsDir: URL, steamExe: URL) -> [InstalledGame] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: steamappsDir, includingPropertiesForKeys: nil) else { return [] }

        var games: [InstalledGame] = []
        for fileURL in entries {
            let filename = fileURL.lastPathComponent
            guard filename.lowercased().hasPrefix("appmanifest_"), filename.lowercased().hasSuffix(".acf") else { continue }
            guard let text = readText(fileURL), let root = try? KeyValues.parse(text) else { continue }
            guard case .dict(let appState)? = root["AppState"] ?? root["appstate"] else { continue }

            guard let appID = appState["appid"]?.stringValue,
                  let name = appState["name"]?.stringValue,
                  !appID.isEmpty, !name.isEmpty
            else { continue }

            guard !steamToolAppIDs.contains(appID) else { continue }
            let lowerName = name.lowercased()
            guard !steamToolNameFragments.contains(where: { lowerName.contains($0) }) else { continue }

            // StateFlags bit 0x4 = fully installed (Valve's
            // AppUpdateStateFlags). Anything else (update pending, only
            // partially downloaded, uninstalling, …) isn't launchable yet.
            let stateFlags = Int(appState["StateFlags"]?.stringValue ?? "") ?? 0
            guard stateFlags & 4 != 0 else { continue }

            let installDirName = appState["installdir"]?.stringValue ?? name
            let installDir = steamappsDir.appendingPathComponent("common", isDirectory: true)
                .appendingPathComponent(installDirName, isDirectory: true)
            let sizeBytes = appState["SizeOnDisk"]?.stringValue.flatMap(Int64.init)

            games.append(InstalledGame(
                id: "steam:\(appID)",
                name: name,
                store: .steam,
                appID: appID,
                installDir: fm.fileExists(atPath: installDir.path) ? installDir : nil,
                sizeBytes: sizeBytes,
                launchExe: steamExe,
                launchArgs: "-applaunch \(appID)"
            ))
        }
        return games
    }

    // MARK: - GOG Galaxy

    private static func scanGOG(driveC: URL) -> [InstalledGame] {
        let fm = FileManager.default
        var roots: [URL] = [
            driveC.appendingPathComponent("Program Files (x86)/GOG Galaxy/Games", isDirectory: true),
            driveC.appendingPathComponent("GOG Games", isDirectory: true),
        ]
        roots = roots.filter { fm.fileExists(atPath: $0.path) }

        var games: [InstalledGame] = []
        for root in roots {
            guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for gameDir in entries {
                guard (try? gameDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                guard let mainExe = findMainExecutable(in: gameDir) else { continue }
                let name = gameDir.lastPathComponent
                games.append(InstalledGame(
                    id: "gog:\(gameDir.path.lowercased())",
                    name: name,
                    store: .gog,
                    appID: nil,
                    installDir: gameDir,
                    sizeBytes: directorySize(gameDir),
                    launchExe: mainExe,
                    launchArgs: ""
                ))
            }
        }
        return games
    }

    // MARK: - Epic Games

    private static func scanEpic(driveC: URL) -> [InstalledGame] {
        let fm = FileManager.default
        let root = driveC.appendingPathComponent("Program Files/Epic Games", isDirectory: true)
        guard fm.fileExists(atPath: root.path) else { return [] }
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }

        var games: [InstalledGame] = []
        for gameDir in entries {
            guard (try? gameDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            // The Epic launcher itself lives at "Epic Games/Launcher" —
            // not a game.
            guard gameDir.lastPathComponent.caseInsensitiveCompare("Launcher") != .orderedSame else { continue }
            guard let mainExe = findMainExecutable(in: gameDir) else { continue }
            let name = gameDir.lastPathComponent
            games.append(InstalledGame(
                id: "epic:\(gameDir.path.lowercased())",
                name: name,
                store: .epic,
                appID: nil,
                installDir: gameDir,
                sizeBytes: directorySize(gameDir),
                launchExe: mainExe,
                launchArgs: ""
            ))
        }
        return games
    }

    // MARK: - Main-exe heuristic (GOG/Epic)

    /// Name fragments that mark an `.exe` as installer/updater/helper
    /// scaffolding rather than the game itself — a small local echo of
    /// `ProgramScanner`'s own (private) `helperNameFragments`, since that
    /// list isn't exposed for reuse here.
    private static let helperNameFragments: Set<String> = [
        "uninstall", "unins", "setup", "install", "vcredist", "dxsetup", "redist",
        "crash", "handler", "helper", "update", "updater", "report",
        "service", "daemon", "launcher", "eac", "battleye", "easyanticheat",
        "config", "editor", "dedicated",
    ]

    /// Finds the game's main executable inside `gameDir`: the largest
    /// `.exe` (searched up to 2 levels deep — some games nest the real
    /// binary in `bin/` or `Win64/`) whose name doesn't look like an
    /// installer/updater/helper. Returns `nil` if nothing qualifies.
    private static func findMainExecutable(in gameDir: URL) -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: gameDir,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }

        let rootDepth = gameDir.standardizedFileURL.pathComponents.count
        var best: (url: URL, size: Int)?
        for case let fileURL as URL in enumerator {
            let isDirectory = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let depth = fileURL.standardizedFileURL.pathComponents.count - rootDepth
            if isDirectory {
                if depth >= 3 { enumerator.skipDescendants() }
                continue
            }
            guard fileURL.pathExtension.lowercased() == "exe" else { continue }
            let baseName = fileURL.deletingPathExtension().lastPathComponent.lowercased()
            guard !helperNameFragments.contains(where: { baseName.contains($0) }) else { continue }
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if best == nil || size > best!.size {
                best = (fileURL, size)
            }
        }
        return best?.url
    }

    /// Sum of file sizes under `dir`, best-effort (used only for the
    /// GOG/Epic subtitle since those stores don't publish a manifest size
    /// like Steam's `SizeOnDisk`). `nil` if the directory can't be walked
    /// at all.
    private static func directorySize(_ dir: URL) -> Int64? {
        TreeSize.totalFileSize(of: dir)
    }

    private static func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }
}

// MARK: - KeyValues (Valve's VDF/ACF text format)

/// A minimal, tolerant recursive-descent parser for Valve's "KeyValues"
/// text format — the format behind `appmanifest_*.acf` and
/// `libraryfolders.vdf`:
/// ```
/// "AppState"
/// {
///     "appid"        "440"
///     "name"         "Team Fortress 2"
///     "UserConfig"
///     {
///         "language"     "english"
///     }
/// }
/// ```
/// Deliberately not regex-based: values can contain arbitrary characters
/// (including braces/quotes-as-escapes), keys/blocks nest arbitrarily
/// deep, and `//` line comments are common in hand-edited files. Unknown
/// or malformed structure is skipped rather than treated as an error —
/// `parse` only throws on a completely empty input — so a truncated or
/// oddly-formatted manifest degrades to "fewer fields recovered" instead
/// of crashing the whole scan.
enum KeyValues {
    /// A parsed KeyValues node: either a leaf string value or a nested
    /// object. `indirect` since `.dict` holds more `Node`s.
    indirect enum Node {
        case string(String)
        case dict([String: Node])

        var stringValue: String? {
            if case .string(let value) = self { return value }
            return nil
        }
    }

    struct ParseError: Error { let message: String }

    /// Parses `text` and returns its top-level key/value pairs (normally
    /// exactly one root key, e.g. `"AppState"` or `"libraryfolders"`).
    /// Throws only when `text` is empty/whitespace-only; any structural
    /// oddity below that is tolerated by skipping the offending token.
    static func parse(_ text: String) throws -> [String: Node] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ParseError(message: "empty KeyValues text")
        }
        var scanner = Scanner(chars: Array(text))
        return scanner.parseObject(topLevel: true)
    }

    private struct Scanner {
        let chars: [Character]
        var index = 0

        init(chars: [Character]) { self.chars = chars }

        mutating func skipWhitespaceAndComments() {
            while index < chars.count {
                let c = chars[index]
                if c == " " || c == "\t" || c == "\n" || c == "\r" {
                    index += 1
                    continue
                }
                if c == "/" && index + 1 < chars.count && chars[index + 1] == "/" {
                    while index < chars.count && chars[index] != "\n" { index += 1 }
                    continue
                }
                break
            }
        }

        /// Parses a `"quoted string"` (with `\"`/`\\` escapes) starting at
        /// the current position, or returns `nil` (without advancing) if
        /// the next non-whitespace character isn't a `"`.
        mutating func parseQuotedString() -> String? {
            skipWhitespaceAndComments()
            guard index < chars.count, chars[index] == "\"" else { return nil }
            index += 1
            var result = ""
            while index < chars.count {
                let c = chars[index]
                if c == "\\" && index + 1 < chars.count {
                    result.append(chars[index + 1])
                    index += 2
                    continue
                }
                if c == "\"" {
                    index += 1
                    return result
                }
                result.append(c)
                index += 1
            }
            return result // unterminated string at EOF: return what we have
        }

        /// Parses key/value pairs until a matching `}` (or EOF, when
        /// `topLevel` is true — the file has no enclosing braces).
        /// Anything that doesn't look like `"key" "value"` or
        /// `"key" { ... }` is skipped one character at a time so a single
        /// malformed line can't derail the rest of the file.
        mutating func parseObject(topLevel: Bool) -> [String: Node] {
            var dict: [String: Node] = [:]
            while true {
                skipWhitespaceAndComments()
                guard index < chars.count else { break }
                if chars[index] == "}" {
                    if !topLevel { index += 1 }
                    break
                }
                guard let key = parseQuotedString() else {
                    index += 1 // tolerate stray token
                    continue
                }
                skipWhitespaceAndComments()
                guard index < chars.count else {
                    dict[key] = .string("")
                    break
                }
                if chars[index] == "{" {
                    index += 1
                    dict[key] = .dict(parseObject(topLevel: false))
                } else if chars[index] == "\"" {
                    dict[key] = .string(parseQuotedString() ?? "")
                } else {
                    // Unexpected token where a value was expected — skip
                    // it and keep going rather than aborting the parse.
                    index += 1
                }
            }
            return dict
        }
    }
}
