import Foundation
import CryptoKit

/// Errors surfaced by `EngineManager`, all with a user-facing description
/// suitable for `AppState.report(_:context:)`.
enum EngineManagerError: LocalizedError {
    case httpStatus(Int)
    case hashMismatch(expected: String, actual: String)
    case extractionFailed(String)
    case layoutNotFound
    case versionCheckFailed(String)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code):
            return "Download failed (server returned HTTP \(code))."
        case .hashMismatch(let expected, let actual):
            return "Downloaded file's checksum didn't match. Expected \(expected), got \(actual). The download may be corrupt, or the release changed upstream — try again, and if it keeps happening please update the catalog hash."
        case .extractionFailed(let detail):
            return "Failed to extract the engine archive: \(detail)"
        case .layoutNotFound:
            return "Couldn't find a wine64 or wine executable inside the extracted engine. The archive's internal layout may have changed."
        case .versionCheckFailed(let detail):
            return "Installed the engine but couldn't run its wine binary to read a version string: \(detail)"
        }
    }
}

/// Downloads, verifies, extracts, and removes Wine engines under
/// `Paths.engines`. One folder per `EngineRelease.id`, each holding the
/// extracted tree plus an `installed.json` describing it (`InstalledEngine`).
///
/// An actor because installs involve several await points (network, tar,
/// version-check) touching no other shared mutable state than the
/// filesystem itself, and callers (`AppState`) hop across the actor
/// boundary with `await` anyway.
actor EngineManager {
    /// Shared instance — `AppState` (via `EngineManager+AppState.swift`)
    /// talks to engines through this single instance rather than each
    /// screen owning its own.
    static let shared = EngineManager()

    private init() {}

    // MARK: - Reading installed engines

    /// Reads `installed.json` from every folder under `Paths.engines`.
    /// Folders without a valid `installed.json` (a half-finished install
    /// that crashed before this file was written, for example) are
    /// silently skipped — they read as "not installed".
    func installedEngines() -> [InstalledEngine] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: Paths.engines, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var result: [InstalledEngine] = []
        for entry in entries {
            let jsonURL = entry.appendingPathComponent("installed.json")
            guard let data = try? Data(contentsOf: jsonURL),
                  let engine = try? decoder.decode(InstalledEngine.self, from: data) else { continue }
            result.append(engine)
        }
        return result.sorted { $0.id < $1.id }
    }

    // MARK: - Install

    /// Downloads `release`'s tarball, verifies its SHA-256, extracts it
    /// into `Paths.engineDir(release.id)`, strips quarantine, locates the
    /// wine binaries, runs `wine64 --version` to prove it actually works,
    /// and writes `installed.json`. `progress` is called repeatedly with a
    /// 0...1 fraction and a short human-readable status line; it may be
    /// called from any thread/actor, hence `@Sendable`.
    ///
    /// On any failure the partial engine folder (and any leftover
    /// tarball) is removed before rethrowing, so a retry starts clean.
    func install(
        _ release: EngineRelease,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> InstalledEngine {
        try Paths.ensureAll()

        let engineDir = Paths.engineDir(release.id)
        let tarballURL = Paths.downloads.appendingPathComponent("\(release.id).tar.xz")

        do {
            // Reuse a previously downloaded tarball when its hash still
            // matches (a failed extract, or a reinstall) instead of
            // pulling a few hundred MB again.
            var reusedExisting = false
            if FileManager.default.fileExists(atPath: tarballURL.path),
               let existingHash = try? Self.sha256Hex(of: tarballURL),
               existingHash.caseInsensitiveCompare(release.sha256) == .orderedSame {
                reusedExisting = true
                progress(0.8, "Using previously downloaded archive…")
            }

            if !reusedExisting {
                progress(0, "Starting download…")
                let downloadedTemp = try await Self.downloadFile(from: release.url) { fraction in
                    progress(fraction * 0.8, "Downloading \(release.displayName)…")
                }

                if FileManager.default.fileExists(atPath: tarballURL.path) {
                    try? FileManager.default.removeItem(at: tarballURL)
                }
                try FileManager.default.moveItem(at: downloadedTemp, to: tarballURL)
            }

            progress(0.8, "Verifying checksum…")
            let actualHash = try Self.sha256Hex(of: tarballURL)
            guard actualHash.caseInsensitiveCompare(release.sha256) == .orderedSame else {
                throw EngineManagerError.hashMismatch(expected: release.sha256, actual: actualHash)
            }

            if FileManager.default.fileExists(atPath: engineDir.path) {
                try? FileManager.default.removeItem(at: engineDir)
            }
            try FileManager.default.createDirectory(at: engineDir, withIntermediateDirectories: true)

            progress(0.82, "Extracting \(release.displayName)…")
            let tarResult = try await ShellRunner.run("/usr/bin/tar", ["-xJf", tarballURL.path, "-C", engineDir.path])
            guard tarResult.status == 0 else {
                throw EngineManagerError.extractionFailed(
                    tarResult.stderr.isEmpty ? "tar exited with status \(tarResult.status)" : tarResult.stderr
                )
            }

            progress(0.9, "Removing quarantine flag…")
            // Best-effort: a fresh download always carries com.apple.quarantine,
            // but xattr can fail harmlessly on files that don't have it
            // (some entries inside .app bundles). Never fails the install.
            _ = try? await ShellRunner.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", engineDir.path])

            progress(0.92, "Locating wine binaries…")
            let binDir = try Self.findBinDirectory(in: engineDir)
            let libDir = binDir.deletingLastPathComponent().appendingPathComponent("lib", isDirectory: true)
            guard FileManager.default.fileExists(atPath: libDir.path) else {
                throw EngineManagerError.layoutNotFound
            }

            progress(0.95, "Checking wine version…")
            let versionString = try await Self.wineVersion(binDir: binDir, libDir: libDir)

            let installed = InstalledEngine(
                id: release.id,
                kind: release.kind,
                version: release.version,
                rootDir: engineDir,
                binDir: binDir,
                libDir: libDir,
                versionString: versionString,
                installedAt: Date()
            )

            progress(0.98, "Writing metadata…")
            try Self.writeInstalledJSON(installed, to: engineDir)

            try? FileManager.default.removeItem(at: tarballURL)

            progress(1.0, "Installed \(installed.displayName).")
            return installed
        } catch {
            try? FileManager.default.removeItem(at: engineDir)
            try? FileManager.default.removeItem(at: tarballURL)
            throw error
        }
    }

    // MARK: - Remove

    /// Moves an engine's folder to the Trash (falling back to a permanent
    /// delete if that fails, e.g. no Trash available for the volume).
    func remove(_ id: String) throws {
        let dir = Paths.engineDir(id)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        do {
            try FileManager.default.trashItem(at: dir, resultingItemURL: nil)
        } catch {
            try FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: - Download

    /// Streams `url` to a temporary file via a `URLSessionDownloadTask`
    /// delegate, so `progress` reflects real bytes-written/bytes-expected
    /// rather than an estimate. Returns the temp file's location; the
    /// caller is responsible for moving it into place.
    nonisolated private static func downloadFile(
        from url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let delegate = EngineDownloadDelegate(progress: progress, continuation: continuation)
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            let task = session.downloadTask(with: url)
            delegate.session = session
            task.resume()
        }
    }

    // MARK: - Checksum

    /// SHA-256 of a file, computed in bounded-size chunks via `FileHandle`
    /// so a ~200MB tarball never has to be loaded into memory at once.
    nonisolated private static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunkSize = 1 << 20 // 1MB
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Locating the extracted layout

    /// Walks the extracted tree looking for a directory named `bin` that
    /// contains a `wine64` or `wine` executable. The tarball's top-level
    /// folder name (and nesting depth) isn't fixed — GPTK ships
    /// `Game Porting Toolkit.app/Contents/Resources/wine/bin`, plain Wine
    /// builds ship `Wine Staging.app/Contents/Resources/wine/bin` — so this
    /// is discovered rather than assumed.
    nonisolated private static func findBinDirectory(in root: URL) throws -> URL {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles],
            errorHandler: nil
        ) else {
            throw EngineManagerError.layoutNotFound
        }
        for case let candidate as URL in enumerator {
            guard candidate.lastPathComponent == "bin" else { continue }
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let wine64 = candidate.appendingPathComponent("wine64")
            let wine = candidate.appendingPathComponent("wine")
            if fm.isExecutableFile(atPath: wine64.path) || fm.isExecutableFile(atPath: wine.path) {
                return candidate
            }
        }
        throw EngineManagerError.layoutNotFound
    }

    // MARK: - Version check

    /// Runs `wine64 --version` (falling back to `wine`) with the
    /// environment GPTK's D3DMetal needs to even load
    /// (`DYLD_FALLBACK_LIBRARY_PATH` pointing at `lib` and `lib/external`).
    /// This both proves the binary actually runs under Rosetta and gives
    /// us the version string shown in the UI.
    ///
    /// Note: `ShellRunner` (owned by another part of the app) has no way to
    /// pass a custom environment, so this uses a small private process
    /// runner below that mirrors its non-blocking pipe-draining pattern.
    nonisolated private static func wineVersion(binDir: URL, libDir: URL) async throws -> String {
        let fm = FileManager.default
        let wine64 = binDir.appendingPathComponent("wine64")
        let wine = binDir.appendingPathComponent("wine")
        let binaryPath = fm.isExecutableFile(atPath: wine64.path) ? wine64.path : wine.path
        guard fm.isExecutableFile(atPath: binaryPath) else {
            throw EngineManagerError.layoutNotFound
        }

        let environment: [String: String] = [
            "WINEDEBUG": "-all",
            "DYLD_FALLBACK_LIBRARY_PATH": "\(libDir.path):\(libDir.appendingPathComponent("external").path)",
            "PATH": "/usr/bin:/bin",
            "HOME": NSHomeDirectory(),
        ]

        let result = try await runProcess(binaryPath, ["--version"], environment: environment)
        guard result.status == 0 else {
            throw EngineManagerError.versionCheckFailed(
                result.stderr.isEmpty ? "exited with status \(result.status)" : result.stderr
            )
        }
        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw EngineManagerError.versionCheckFailed("no output")
        }
        return trimmed
    }

    /// Minimal environment-aware sibling of `ShellRunner.run` — needed
    /// only because that type doesn't expose an `environment` parameter
    /// and lives in a file this feature doesn't own. Same non-blocking
    /// pipe-draining approach: both pipes are read continuously via
    /// `readabilityHandler`, and the continuation resumes only once the
    /// process has terminated and both pipes have hit EOF.
    nonisolated private static func runProcess(
        _ executable: String,
        _ args: [String],
        environment: [String: String]
    ) async throws -> (status: Int32, stdout: String, stderr: String) {
        let r = try await ProcessRunner.run(URL(fileURLWithPath: executable), args, environment: environment)
        return (r.status, r.stdout, r.stderr)
    }

    /// Persists `installed.json` next to the extracted engine so
    /// `installedEngines()` can find it on the next launch.
    nonisolated private static func writeInstalledJSON(_ engine: InstalledEngine, to dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(engine)
        try data.write(to: dir.appendingPathComponent("installed.json"), options: .atomic)
    }
}

/// `URLSessionDownloadDelegate` that reports fractional progress and
/// resumes a continuation with the finished download's temp file location
/// (moved to a fresh temp path immediately, since the URL Loading System
/// deletes its own temp file the instant this delegate method returns).
private final class EngineDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    /// Held only so the session isn't deallocated before its delegate
    /// callbacks fire; cleared once we resume.
    var session: URLSession?

    init(progress: @escaping @Sendable (Double) -> Void, continuation: CheckedContinuation<URL, Error>) {
        self.progress = progress
        self.continuation = continuation
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return }
        switch result {
        case .success(let url): pending.resume(returning: url)
        case .failure(let error): pending.resume(throwing: error)
        }
        session?.finishTasksAndInvalidate()
        session = nil
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finish(.failure(EngineManagerError.httpStatus(http.statusCode)))
            return
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("overpass-download-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
        }
    }
}
