import Foundation

/// The fixed list of Wine engines Overpass knows how to download and
/// install. Nothing here is vendored in the repo — `EngineManager` fetches
/// the tarball for a chosen release at install time and verifies it against
/// the SHA-256 below before extracting it.
///
/// Hashes were computed by downloading each tarball with `curl -L` and
/// running `shasum -a 256` on it (October 2026). If a release is ever
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
            id: "wine-staging-11.20",
            kind: .wineStaging,
            version: "11.20",
            url: URL(string: "https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.20/wine-staging-11.20-osx64.tar.xz")!,
            sha256: "4df858c5e72920deaf123cbc29fa2b9e64c23bcf2dea59e0a7047b879b9cd952",
            notes: "The newest upstream Wine-staging build, fully open source. DirectX 8/9/10/11 titles can use DXVK (toggle per bottle) instead of Wine's built-in GL translation."
        ),
    ]

    /// GPTK is the default: best game compatibility out of the box.
    static var defaultRelease: EngineRelease {
        releases.first { $0.id == "gptk-3.0-3" }!
    }

    // MARK: - Game Porting Toolkit 4 (user-supplied, deliberately not pinned)

    // Apple's Game Porting Toolkit 4 has **no entry in `releases`**, and
    // must not get one. Verified 2026-10-29: (1) Gcenx, the only source of
    // the pinned GPTK 3 build, has not repackaged it — newest release is
    // still 3.0-3 from 2026-03-03; (2) Apple's own download sits behind an
    // Apple Account sign-in (the URL 302s to `idmsa.apple.com`); (3) Apple's
    // licence limits any redistribution of the framework and `/redist` files
    // to non-commercial purposes under its own terms, and Overpass is not a
    // channel Apple has authorised, so it neither mirrors nor auto-fetches
    // them; and (4) the download is not a Wine build at all,
    // only D3DMetal libraries, so a pinned URL + SHA-256 would not yield an
    // engine even if it existed. The user supplies the file; see
    // `GPTKRedist` for the research record and
    // `EngineManager.installUserSuppliedGPTK` for the install.
    //
    // Keeping it out of `releases` also keeps `EnginesView`'s "known
    // engines" list, the update checker's `merged(with:)`, and the
    // self-test's catalog-shape assertions describing only things Overpass
    // can actually download.

    /// `AppState.engineInstallProgress` / `engineInstallStatus` key used
    /// while a user-supplied GPTK install runs. A fixed string rather than
    /// the eventual engine id because the id depends on the D3DMetal version
    /// and base engine, which are only known after validation has started.
    static let userSuppliedGPTKProgressKey = "user-supplied-gptk"

    /// The `InstalledEngine.id` (and folder name under `Paths.engines`) for
    /// D3DMetal `d3dmetalVersion` layered on installed engine `baseID`, e.g.
    /// `gptk-4.0b3-on-wine-staging-11.20`. Includes the base so installing the
    /// same download onto two different Wine builds yields two engines
    /// rather than one silently replacing the other, and so the id alone
    /// says what the engine is made of. Characters outside `[A-Za-z0-9._-]`
    /// are replaced with `-` because the id becomes a directory name.
    static func userSuppliedGPTKID(d3dmetalVersion: String, baseID: String) -> String {
        let raw = "gptk-\(d3dmetalVersion)-on-\(baseID)"
        return String(raw.map { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) ? $0 : "-" })
    }

    /// True for engines Overpass built from a user-supplied download rather
    /// than installed from `releases` — what a view should use to decide
    /// whether to show an installed engine that has no catalog card.
    static func isUserSupplied(_ engine: InstalledEngine) -> Bool {
        engine.userSupplied != nil
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
    static func compareVersions(_ a: String, _ b: String) -> Int {
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
