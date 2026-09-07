import Foundation
import AppKit

/// Fetches and caches portrait cover art for `InstalledGame`s so
/// `GamesView`'s grid can look like a real storefront library (Heroic/
/// CrossOver-style) instead of a plain list.
///
/// Steam games get real cover art from Valve's public CDN, keyed only by
/// the numeric app id already parsed out of that bottle's own
/// `appmanifest_*.acf` — nothing else about the game or the user is ever
/// sent anywhere, and nothing is fetched at all for GOG/Epic titles or when
/// there's no network. Every result — real art or "no art" — is cached to
/// disk under `Paths.tools/artwork/`, so a rescan/relaunch never re-hits
/// the network for a game it's already resolved.
///
/// An `actor` rather than a `@MainActor @Observable` cache: every bit of
/// this file's work (disk reads/writes, `URLSession` requests) wants to run
/// off the main actor, and callers just `await art(for:)` from a `Task` in
/// the view — no published state to observe.
actor GameArtwork {
    static let shared = GameArtwork()

    /// The bare minimum of a JPEG's magic bytes — used to sanity-check a
    /// download before trusting it (Valve's CDN serves a tiny placeholder
    /// GIF/HTML error page for a 404 on some paths rather than a real HTTP
    /// 404 status, so a status-code check alone isn't reliable).
    private static let jpegMagic: [UInt8] = [0xFF, 0xD8, 0xFF]

    private let session: URLSession
    /// In-memory de-dupe so concurrent requests for the same game (grid
    /// scrolling fast, or a rescan while art is still loading) share one
    /// disk read / network fetch instead of racing separate ones.
    private var inFlight: [String: Task<Data?, Never>] = [:]

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 15
        session = URLSession(configuration: config)
    }

    /// Returns cached/fetched cover art bytes for `game`, or `nil` if none
    /// is available (GOG/Epic with no local icon, a Steam title whose art
    /// isn't on the CDN, or no network) — callers fall back to
    /// `PlaceholderArt` in that case.
    func art(for game: InstalledGame) async -> Data? {
        let key = cacheKey(for: game)

        if let existing = inFlight[key] {
            return await existing.value
        }

        let task = Task<Data?, Never> { [weak self] in
            await self?.resolve(game: game, key: key)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    private func cacheKey(for game: InstalledGame) -> String {
        "\(game.store.rawValue)-\(game.appID ?? game.id)"
    }

    private func cacheFileURL(key: String) -> URL {
        artworkDir.appendingPathComponent("\(key).jpg")
    }

    private var artworkDir: URL {
        Paths.tools.appendingPathComponent("artwork", isDirectory: true)
    }

    /// A sibling "no art" marker so a game confirmed to have no art (a
    /// Steam appid whose CDN paths all failed, or a GOG/Epic title with no
    /// local icon) isn't re-fetched from the network — or re-globbed from
    /// its (potentially large) install directory — on every subsequent
    /// scan/launch.
    private func noArtMarkerURL(key: String) -> URL {
        artworkDir.appendingPathComponent("\(key).noart")
    }

    private func resolve(game: InstalledGame, key: String) async -> Data? {
        let fm = FileManager.default
        let cacheFile = cacheFileURL(key: key)

        if fm.fileExists(atPath: cacheFile.path), let data = try? Data(contentsOf: cacheFile), !data.isEmpty {
            return data
        }
        if fm.fileExists(atPath: noArtMarkerURL(key: key).path) {
            return nil
        }

        var art: Data?
        if game.store == .steam, let appID = game.appID {
            art = await fetchSteamArt(appID: appID)
        } else {
            art = localIconArt(for: game)
        }

        try? fm.createDirectory(at: artworkDir, withIntermediateDirectories: true)
        if let art {
            try? art.write(to: cacheFile, options: .atomic)
        } else {
            fm.createFile(atPath: noArtMarkerURL(key: key).path, contents: nil)
        }
        return art
    }

    // MARK: - Steam CDN

    /// Portrait cover first, falling back to progressively less-ideal
    /// Steam CDN images if the portrait doesn't exist for this appid.
    /// Every one of these paths only ever gets *this bottle's own* appid
    /// substituted in — never anything derived from user input or another
    /// source.
    private func fetchSteamArt(appID: String) async -> Data? {
        let filenames = ["library_600x900.jpg", "header.jpg", "capsule_231x87.jpg"]
        for filename in filenames {
            guard let url = URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)/\(filename)") else { continue }
            if let data = await download(url), looksLikeJPEG(data) {
                return data
            }
        }
        return nil
    }

    private func download(_ url: URL) async -> Data? {
        guard let (data, response) = try? await session.data(from: url) else { return nil }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty else { return nil }
        return data
    }

    private func looksLikeJPEG(_ data: Data) -> Bool {
        guard data.count >= Self.jpegMagic.count else { return false }
        return data.prefix(Self.jpegMagic.count).elementsEqual(Self.jpegMagic)
    }

    // MARK: - GOG/Epic local icon

    /// Best-effort local art for stores with no public CDN: an obvious
    /// `.ico`/`.png` sitting beside a GOG `goggame-*.info` manifest, or a
    /// same-named icon next to the main executable. Never walks the whole
    /// install tree — only the top level and the exe's own folder — so a
    /// large game directory doesn't turn every scan into a slow crawl.
    private func localIconArt(for game: InstalledGame) -> Data? {
        let fm = FileManager.default
        var candidates: [URL] = []

        if let installDir = game.installDir,
           let entries = try? fm.contentsOfDirectory(at: installDir, includingPropertiesForKeys: nil) {
            // GOG ships "goggame-<id>.info" beside a matching
            // "goggame-<id>.ico" (or a generic icon.png/icon.ico) at the
            // install root.
            for entry in entries {
                let name = entry.lastPathComponent.lowercased()
                if name.hasSuffix(".ico") || name == "icon.png" {
                    candidates.append(entry)
                }
            }
        }
        if let launchExe = game.launchExe {
            let base = launchExe.deletingPathExtension().lastPathComponent
            let dir = launchExe.deletingLastPathComponent()
            candidates.append(dir.appendingPathComponent("\(base).ico"))
            candidates.append(dir.appendingPathComponent("\(base).png"))
        }

        for candidate in candidates {
            guard fm.fileExists(atPath: candidate.path) else { continue }
            // `.ico` isn't a format `NSImage`/`Data` consumers here treat
            // uniformly, but `NSImage(contentsOf:)` can decode common `.ico`
            // files directly (AppKit's ICNS/ICO reader), so re-render
            // through it into a PNG we can hand back like any other art.
            guard let image = NSImage(contentsOf: candidate) else { continue }
            guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { continue }
            if let png = rep.representation(using: .png, properties: [:]) {
                return png
            }
        }
        return nil
    }
}

// MARK: - Placeholder art

/// A generated stand-in cover for a game with no downloadable/local art:
/// the game name's first letter(s) centered over the current theme's
/// accent gradient, styled to look like a deliberate design choice rather
/// than a broken image (the same idea as a contact's initials avatar).
enum PlaceholderArt {
    /// One or two-letter monogram from `name`: the first letter of up to
    /// the first two words, uppercased ("Portal 2" → "P2", "Doom" → "D").
    static func monogram(for name: String) -> String {
        let words = name
            .split(separator: " ")
            .filter { $0.first?.isLetter == true || $0.first?.isNumber == true }
        let letters = words.prefix(2).compactMap { $0.first }
        let monogram = String(letters).uppercased()
        return monogram.isEmpty ? "?" : monogram
    }
}
