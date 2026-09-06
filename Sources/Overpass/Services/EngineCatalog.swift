import Foundation

/// The fixed list of Wine engines Overpass knows how to download and
/// install. Nothing here is vendored in the repo — `EngineManager` fetches
/// the tarball for a chosen release at install time and verifies it against
/// the SHA-256 below before extracting it.
///
/// Hashes were computed by downloading each tarball with `curl -L` and
/// running `shasum -a 256` on it (September 2026). If a release is ever
/// replaced upstream, `EngineManager.install` will fail its checksum check
/// rather than silently installing a different build — update the hash
/// (and re-verify the on-disk layout) when that happens.
enum EngineCatalog {
    static let releases: [EngineRelease] = [
        EngineRelease(
            id: "gptk-3.0-3",
            kind: .gptk,
            version: "3.0-3",
            url: URL(string: "https://github.com/Gcenx/game-porting-toolkit/releases/download/Game-Porting-Toolkit-3.0-3/game-porting-toolkit-3.0-3.tar.xz")!,
            sha256: "d377683937340f914823dbb2e1252b329cbf834ff58907d0293db8cebf0e392e",
            notes: "Wine plus Apple's D3DMetal, which translates DirectX 11/12 straight to Metal. Best performance and compatibility for games. D3DMetal is distributed under Apple's non-commercial licence."
        ),
        EngineRelease(
            id: "wine-staging-11.16",
            kind: .wineStaging,
            version: "11.16",
            url: URL(string: "https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.16/wine-staging-11.16-osx64.tar.xz")!,
            sha256: "cd68f230c773a761b8a0423a08c51fbe49e89b6e52246f3866898d259a4988c6",
            notes: "The newest upstream Wine-staging build, fully open source. DirectX 9/10/11 titles can use DXVK (toggle per bottle) instead of Wine's built-in GL translation."
        ),
    ]

    /// GPTK is the default: best game compatibility out of the box.
    static var defaultRelease: EngineRelease {
        releases.first { $0.id == "gptk-3.0-3" }!
    }

    // MARK: - Live catalog

    /// The built-in list unioned with `fetched` (typically
    /// `EngineUpdateChecker.fetchLatest()`'s result, or `latestKnown`'s own
    /// cache read), deduped by id. The built-in entry wins on a collision —
    /// its checksum was hand-verified when this catalog shipped, and a
    /// same-id fetch from GitHub is otherwise identical (same tag, same
    /// asset) but usually can't be verified the same way, so preferring it
    /// would silently downgrade an already-trusted release to unverified.
    static func merged(with fetched: [EngineRelease]) -> [EngineRelease] {
        var byID: [String: EngineRelease] = [:]
        for release in fetched { byID[release.id] = release }
        for release in releases { byID[release.id] = release }
        return sortedByKindThenVersion(Array(byID.values))
    }

    /// The merged catalog as of the last `EngineUpdateChecker.fetchLatest()`
    /// call — this launch or an earlier one, via its on-disk cache under
    /// `Paths.tools`. Falls back to just the built-in list if nothing has
    /// ever been fetched.
    static var latestKnown: [EngineRelease] {
        guard let cached = EngineUpdateChecker.cachedReleases() else { return releases }
        return merged(with: cached)
    }

    /// Sorts by `EngineKind` (declaration order: gptk, then wineStaging),
    /// then newest version first within each kind.
    static func sortedByKindThenVersion(_ releases: [EngineRelease]) -> [EngineRelease] {
        let kindOrder = EngineKind.allCases
        return releases.sorted { a, b in
            if a.kind != b.kind {
                return kindOrder.firstIndex(of: a.kind)! < kindOrder.firstIndex(of: b.kind)!
            }
            return compareVersions(a.version, b.version) > 0
        }
    }

    /// Splits a version string like `"3.0-3"` or `"11.16"` into components
    /// on `.`/`-` and compares them numerically where possible, falling
    /// back to a string compare of any non-numeric component. Returns a
    /// positive number when `a` is newer than `b`, negative when older,
    /// zero when equal (as far as this heuristic can tell).
    private static func compareVersions(_ a: String, _ b: String) -> Int {
        let partsA = a.split(whereSeparator: { $0 == "." || $0 == "-" }).map(String.init)
        let partsB = b.split(whereSeparator: { $0 == "." || $0 == "-" }).map(String.init)
        for i in 0..<max(partsA.count, partsB.count) {
            let pa = i < partsA.count ? partsA[i] : "0"
            let pb = i < partsB.count ? partsB[i] : "0"
            if let na = Int(pa), let nb = Int(pb) {
                if na != nb { return na - nb }
            } else if pa != pb {
                return pa < pb ? -1 : 1
            }
        }
        return 0
    }
}
