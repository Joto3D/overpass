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
}
