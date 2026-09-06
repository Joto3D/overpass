import Foundation

/// Errors surfaced by `EngineUpdateChecker`.
enum EngineUpdateCheckerError: LocalizedError {
    case httpStatus(Int, String)
    case decodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code, let body):
            return "GitHub API returned HTTP \(code)\(body.isEmpty ? "" : ": \(body.prefix(200))")"
        case .decodingFailed(let detail):
            return "Couldn't parse GitHub's release JSON: \(detail)"
        }
    }
}

/// Queries GitHub's public releases API for the two Gcenx repos Overpass's
/// engines come from — `Gcenx/game-porting-toolkit` (GPTK: Wine +
/// D3DMetal) and `Gcenx/macOS_Wine_builds` (plain Wine-staging) — and turns
/// their tarball assets into `EngineRelease`s shaped exactly like
/// `EngineCatalog.releases`'s built-in entries, so a freshly-tagged Gcenx
/// build shows up in the UI without an Overpass update.
///
/// Unauthenticated (GitHub's ~60 requests/hour/IP limit) — this is meant
/// for a manual "Check for updates" button, never polled automatically.
enum EngineUpdateChecker {
    // MARK: - GitHub API response shapes

    private struct GHAsset: Decodable {
        let name: String
        let browser_download_url: String
    }

    private struct GHRelease: Decodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let body: String?
        let assets: [GHAsset]
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        return URLSession(configuration: config)
    }()

    // MARK: - Fetching

    /// Fetches the last 10 releases of both repos, maps each one's tarball
    /// asset to an `EngineRelease` (skipping drafts/prereleases and
    /// releases with no matching asset), sorts the result (see
    /// `EngineCatalog.sortedByKindThenVersion`), caches it to
    /// `Paths.tools/engine-catalog.json`, and returns it.
    static func fetchLatest() async throws -> [EngineRelease] {
        async let gptkTask = fetchReleases(owner: "Gcenx", repo: "game-porting-toolkit")
        async let wineTask = fetchReleases(owner: "Gcenx", repo: "macOS_Wine_builds")
        let (gptkReleases, wineReleases) = try await (gptkTask, wineTask)

        var results: [EngineRelease] = []

        for release in gptkReleases where !release.draft && !release.prerelease {
            guard let asset = release.assets.first(where: { matchesGPTK($0.name) != nil }),
                  let version = matchesGPTK(asset.name),
                  let url = URL(string: asset.browser_download_url) else { continue }
            let (sha256, verified) = await checksum(for: asset.name, in: release.assets, body: release.body)
            results.append(EngineRelease(
                id: "gptk-\(version)",
                kind: .gptk,
                version: version,
                url: url,
                sha256: sha256,
                notes: "Wine plus Apple's D3DMetal, fetched live from Gcenx's \(release.tag_name) release.",
                verified: verified
            ))
        }

        for release in wineReleases where !release.draft && !release.prerelease {
            guard let asset = release.assets.first(where: { matchesWineStaging($0.name) != nil }),
                  let version = matchesWineStaging(asset.name),
                  let url = URL(string: asset.browser_download_url) else { continue }
            let (sha256, verified) = await checksum(for: asset.name, in: release.assets, body: release.body)
            results.append(EngineRelease(
                id: "wine-staging-\(version)",
                kind: .wineStaging,
                version: version,
                url: url,
                sha256: sha256,
                notes: "Upstream Wine-staging, fetched live from Gcenx's \(release.tag_name) release.",
                verified: verified
            ))
        }

        let sorted = EngineCatalog.sortedByKindThenVersion(results)
        try? cache(sorted)
        return sorted
    }

    private static func fetchReleases(owner: String, repo: String) async throws -> [GHRelease] {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases?per_page=10")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub's API rejects requests with no User-Agent header.
        request.setValue("Overpass-App", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? ""
            throw EngineUpdateCheckerError.httpStatus(code, body)
        }
        do {
            return try JSONDecoder().decode([GHRelease].self, from: data)
        } catch {
            throw EngineUpdateCheckerError.decodingFailed(error.localizedDescription)
        }
    }

    // MARK: - Asset name matching

    /// `game-porting-toolkit-<version>.tar.xz` → `<version>`.
    private static func matchesGPTK(_ name: String) -> String? {
        let prefix = "game-porting-toolkit-"
        let suffix = ".tar.xz"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let start = name.index(name.startIndex, offsetBy: prefix.count)
        let end = name.index(name.endIndex, offsetBy: -suffix.count)
        guard start < end else { return nil }
        return String(name[start..<end])
    }

    /// `wine-staging-<version>-osx64.tar.xz` → `<version>`.
    private static func matchesWineStaging(_ name: String) -> String? {
        let prefix = "wine-staging-"
        let suffix = "-osx64.tar.xz"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let start = name.index(name.startIndex, offsetBy: prefix.count)
        let end = name.index(name.endIndex, offsetBy: -suffix.count)
        guard start < end else { return nil }
        return String(name[start..<end])
    }

    // MARK: - Checksum discovery

    /// Looks for a trustworthy SHA-256 for `assetName`: first a companion
    /// asset whose name mentions both it and "sha256", then a 64-hex-char
    /// string on a release-body line that mentions `assetName`. Returns an
    /// empty, unverified hash if neither turns up anything — the release is
    /// still usable, `EngineManager.install` just skips the hash check.
    private static func checksum(for assetName: String, in assets: [GHAsset], body: String?) async -> (sha256: String, verified: Bool) {
        if let checksumAsset = assets.first(where: { isChecksumAsset($0.name, for: assetName) }),
           let url = URL(string: checksumAsset.browser_download_url),
           let hash = try? await fetchChecksumFile(url) {
            return (hash, true)
        }
        if let body, let hash = extractChecksum(fromBody: body, assetName: assetName) {
            return (hash, true)
        }
        return ("", false)
    }

    private static func isChecksumAsset(_ name: String, for assetName: String) -> Bool {
        let lower = name.lowercased()
        guard lower.contains("sha256") else { return false }
        return lower.contains(assetName.lowercased()) || lower == assetName.lowercased() + ".sha256"
    }

    private static func fetchChecksumFile(_ url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue("Overpass-App", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw EngineUpdateCheckerError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1, "")
        }
        guard let text = String(data: data, encoding: .utf8), let hash = firstHex64(in: text) else {
            throw EngineUpdateCheckerError.decodingFailed("no 64-character hex string found")
        }
        return hash.lowercased()
    }

    private static func extractChecksum(fromBody body: String, assetName: String) -> String? {
        for line in body.split(separator: "\n") {
            let lineStr = String(line)
            guard lineStr.localizedCaseInsensitiveContains(assetName) else { continue }
            if let hash = firstHex64(in: lineStr) { return hash.lowercased() }
        }
        return nil
    }

    /// First run of 64 contiguous hex digits in `text`, or `nil`.
    private static func firstHex64(in text: String) -> String? {
        let hexChars = Set("0123456789abcdefABCDEF")
        var current = ""
        for ch in text {
            if hexChars.contains(ch) {
                current.append(ch)
                if current.count == 64 { return current }
            } else {
                current = ""
            }
        }
        return nil
    }

    // MARK: - On-disk cache

    private struct CachePayload: Codable {
        let fetchedAt: Date
        let releases: [EngineRelease]
    }

    private static var cacheURL: URL { Paths.tools.appendingPathComponent("engine-catalog.json") }

    private static func cache(_ releases: [EngineRelease]) throws {
        try Paths.ensureAll()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let payload = CachePayload(fetchedAt: Date(), releases: releases)
        try encoder.encode(payload).write(to: cacheURL, options: .atomic)
    }

    /// The releases from the last successful `fetchLatest()` (this launch
    /// or an earlier one), read straight from disk with no network access.
    /// `nil` if nothing has ever been cached.
    static func cachedReleases() -> [EngineRelease]? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(CachePayload.self, from: data) else { return nil }
        return payload.releases
    }

    /// When the cache was last written, if ever.
    static func cachedAt() -> Date? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CachePayload.self, from: data).fetchedAt
    }
}
