import Foundation

/// Errors surfaced by `DXVKInstaller`, all with a user-facing description
/// suitable for `AppState.report(_:context:)`.
enum DXVKInstallerError: LocalizedError {
    case noAssetFound
    case httpStatus(Int)
    case extractionFailed(String)
    case x64FolderNotFound

    var errorDescription: String? {
        switch self {
        case .noAssetFound:
            return "Couldn't find a DXVK-macOS release asset to download."
        case .httpStatus(let code):
            return "Downloading DXVK failed (server returned HTTP \(code))."
        case .extractionFailed(let detail):
            return "Failed to extract the DXVK archive: \(detail)"
        case .x64FolderNotFound:
            return "The DXVK archive didn't contain the expected \"x64\" folder of DLLs."
        }
    }
}

/// Installs/removes Gcenx's DXVK-macOS build (DirectX 10/11 over
/// MoltenVK/Vulkan) into a bottle's `system32`. Only meaningful for
/// Wine-staging bottles — GPTK already provides DirectX via D3DMetal
/// (`EngineKind.supportsDXVK == false`), so `ExtrasView` disables the
/// toggle there.
enum DXVKInstaller {
    /// The dll names DXVK-macOS has shipped across releases. Not every
    /// release includes all four (the 2023 "repack" build, the newest as
    /// of writing, only ships `d3d10core.dll`/`d3d11.dll`), so install and
    /// backup both operate on whichever of these are actually present in
    /// a given release's `x64` folder rather than assuming all four.
    private static let candidateDLLs = ["d3d9.dll", "d3d10core.dll", "d3d11.dll", "dxgi.dll"]

    private static let backupSuffix = ".overpass-bak"

    /// Hardcoded fallback in case the GitHub API call fails (rate limit,
    /// no network at the moment of checking, API shape change) — the
    /// newest DXVK-macOS release as of September 2026. Verified reachable
    /// with `curl -sIL <url>`.
    private static let fallbackAssetURL = URL(
        string: "https://github.com/Gcenx/DXVK-macOS/releases/download/v1.10.3-20230507-repack/dxvk-macOS-async-v1.10.3-20230507-repack.tar.gz"
    )!

    // MARK: - Latest release lookup

    /// Asks the GitHub API for the newest DXVK-macOS release and returns
    /// the `.tar.gz` asset that lays its DLLs out under an `x64/` folder
    /// (as opposed to the "-builtin" asset, which uses `x86_64-windows/`
    /// and isn't what `install` looks for). Falls back to
    /// `fallbackAssetURL` if the API call fails or its shape is
    /// unexpected, rather than failing the whole install over a
    /// transient API hiccup.
    static func latestReleaseURL() async throws -> URL {
        let apiURL = URL(string: "https://api.github.com/repos/Gcenx/DXVK-macOS/releases/latest")!
        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Overpass", forHTTPHeaderField: "User-Agent")

        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            let http = response as? HTTPURLResponse,
            (200...299).contains(http.statusCode),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let assets = json["assets"] as? [[String: Any]]
        else {
            return fallbackAssetURL
        }

        let tarballAssets = assets.compactMap { asset -> (name: String, url: URL)? in
            guard
                let name = asset["name"] as? String,
                name.hasSuffix(".tar.gz"),
                let urlString = asset["browser_download_url"] as? String,
                let url = URL(string: urlString)
            else { return nil }
            return (name, url)
        }

        // Prefer the plain (non "-builtin") asset — it's the one with an
        // "x64" top-level folder that `extractX64Folder` looks for.
        if let plain = tarballAssets.first(where: { !$0.name.lowercased().contains("builtin") }) {
            return plain.url
        }
        return tarballAssets.first?.url ?? fallbackAssetURL
    }

    // MARK: - Install

    /// Downloads the latest DXVK-macOS release, extracts it, and copies
    /// whichever of `candidateDLLs` it ships into `bottle`'s
    /// `system32`, backing up any file it's about to overwrite first
    /// (skipped if a backup already exists from a previous install, so
    /// re-running install never clobbers the *original* Wine DLL).
    /// `bottle.dxvk` itself is not touched here — the caller flips it and
    /// calls `appState.updateBottle` once this returns.
    static func install(into bottle: Bottle, progress: @escaping @Sendable (String) -> Void) async throws {
        try Paths.ensureAll()

        progress("Looking up latest DXVK release…")
        let assetURL = try await latestReleaseURL()

        progress("Downloading DXVK…")
        let (tempURL, response) = try await URLSession.shared.download(from: assetURL)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: tempURL)
            throw DXVKInstallerError.httpStatus(http.statusCode)
        }
        let archiveURL = Paths.downloads.appendingPathComponent("dxvk-macos.tar.gz")
        if FileManager.default.fileExists(atPath: archiveURL.path) {
            try? FileManager.default.removeItem(at: archiveURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: archiveURL)
        defer { try? FileManager.default.removeItem(at: archiveURL) }

        progress("Extracting DXVK…")
        let extractDir = Paths.downloads.appendingPathComponent("dxvk-macos-extract", isDirectory: true)
        if FileManager.default.fileExists(atPath: extractDir.path) {
            try? FileManager.default.removeItem(at: extractDir)
        }
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: extractDir) }

        let tarResult = try await ShellRunner.run("/usr/bin/tar", ["-xzf", archiveURL.path, "-C", extractDir.path])
        guard tarResult.status == 0 else {
            throw DXVKInstallerError.extractionFailed(
                tarResult.stderr.isEmpty ? "tar exited with status \(tarResult.status)" : tarResult.stderr
            )
        }

        guard let x64Dir = findX64Folder(in: extractDir) else {
            throw DXVKInstallerError.x64FolderNotFound
        }

        progress("Installing DLLs…")
        let system32 = bottle.driveC.appendingPathComponent("windows/system32", isDirectory: true)
        try FileManager.default.createDirectory(at: system32, withIntermediateDirectories: true)

        let fm = FileManager.default
        for dll in candidateDLLs {
            let source = x64Dir.appendingPathComponent(dll)
            guard fm.fileExists(atPath: source.path) else { continue }

            let target = system32.appendingPathComponent(dll)
            let backup = system32.appendingPathComponent(dll + backupSuffix)
            if fm.fileExists(atPath: target.path), !fm.fileExists(atPath: backup.path) {
                try fm.copyItem(at: target, to: backup)
            }
            if fm.fileExists(atPath: target.path) {
                try fm.removeItem(at: target)
            }
            try fm.copyItem(at: source, to: target)
        }

        progress("DXVK installed.")
    }

    // MARK: - Uninstall

    /// Restores every `<dll>.overpass-bak` found in `system32` over its
    /// DXVK counterpart and removes the backup. DLLs with no backup (the
    /// bottle never had a stock copy, or DXVK never shipped that DLL) are
    /// left alone.
    static func uninstall(from bottle: Bottle) throws {
        let system32 = bottle.driveC.appendingPathComponent("windows/system32", isDirectory: true)
        let fm = FileManager.default

        for dll in candidateDLLs {
            let target = system32.appendingPathComponent(dll)
            let backup = system32.appendingPathComponent(dll + backupSuffix)
            guard fm.fileExists(atPath: backup.path) else { continue }

            if fm.fileExists(atPath: target.path) {
                try fm.removeItem(at: target)
            }
            try fm.moveItem(at: backup, to: target)
        }
    }

    // MARK: - State

    /// True when at least one `.overpass-bak` file exists in the bottle's
    /// `system32` — i.e. `install` has run and `uninstall` hasn't
    /// restored it since.
    static func isInstalled(in bottle: Bottle) -> Bool {
        let system32 = bottle.driveC.appendingPathComponent("windows/system32", isDirectory: true)
        return candidateDLLs.contains { dll in
            FileManager.default.fileExists(atPath: system32.appendingPathComponent(dll + backupSuffix).path)
        }
    }

    // MARK: - Locating the extracted layout

    /// Walks the extracted tree for a directory literally named `x64`
    /// (DXVK-macOS's 64-bit DLL folder — see the doc comment on
    /// `latestReleaseURL` for why the "-builtin" asset, which uses
    /// `x86_64-windows` instead, is avoided).
    private static func findX64Folder(in root: URL) -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles],
            errorHandler: nil
        ) else { return nil }

        for case let candidate as URL in enumerator {
            guard candidate.lastPathComponent == "x64" else { continue }
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            return candidate
        }
        return nil
    }
}
