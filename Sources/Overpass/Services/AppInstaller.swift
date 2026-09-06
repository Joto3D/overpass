import Foundation
import Observation

/// Live progress for whatever `AppCatalog` install is currently running.
/// A single shared instance (there's only ever one install in flight at a
/// time) rather than a field on `AppState`, since this feature owns its
/// own files and must not touch `AppState.swift`.
@MainActor
@Observable
final class AppInstallState {
    static let shared = AppInstallState()

    /// `CatalogApp.id` currently installing, or `nil` when idle.
    var activeAppID: String?
    var phase: String = ""
    /// 0...1, or `nil` while a step has no meaningful fraction (e.g.
    /// running the installer itself).
    var progress: Double = 0
    /// Trailing installer/log output, oldest first. The view shows the
    /// last 15 lines.
    var output: [String] = []
    var lastError: String?

    private init() {}

    fileprivate func begin(_ appID: String) {
        activeAppID = appID
        phase = "Starting…"
        progress = 0
        output = []
        lastError = nil
    }

    fileprivate func set(phase newPhase: String, progress newProgress: Double? = nil) {
        phase = newPhase
        if let newProgress { progress = newProgress }
    }

    fileprivate func log(_ line: String) {
        guard !line.isEmpty else { return }
        for piece in line.split(separator: "\n", omittingEmptySubsequences: true) {
            output.append(String(piece))
        }
        if output.count > 500 {
            output.removeFirst(output.count - 500)
        }
    }

    fileprivate func finish(error: String?) {
        if let error {
            lastError = error
            phase = "Failed"
        } else {
            phase = "Done"
            progress = 1
        }
    }
}

/// Downloads and silently installs a `CatalogApp` into a bottle: applies
/// the app's recommended Windows version, runs any prerequisite winetricks
/// verbs, downloads the installer, runs it, waits for every process it
/// spawned to settle back down, then rescans the bottle's programs and
/// pins the app's launcher. All progress goes through
/// `AppInstallState.shared`; every failure is also surfaced through
/// `appState.report(_:)` so it isn't silent.
enum AppInstaller {
    struct InstallError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Process names that are normal, idle Wine housekeeping — once only
    /// these remain under a bottle's prefix, the installer (and whatever
    /// it spawned/detached) is considered finished.
    private static let idleProcessNames: Set<String> = [
        "wineserver", "services.exe", "explorer.exe", "plugplay.exe", "winedevice.exe", "rpcss.exe",
    ]

    @MainActor
    static func install(_ app: CatalogApp, into bottle: Bottle, engine: InstalledEngine, appState: AppState) async {
        let state = AppInstallState.shared
        state.begin(app.id)

        do {
            var bottle = bottle
            try await applyRecommendedWindowsIfNeeded(app, bottle: &bottle, engine: engine, appState: appState, state: state)

            for verb in app.winetricksVerbs {
                state.set(phase: "Installing prerequisite \(verb)…")
                try await Winetricks.run(verb: verb, bottle: bottle, engine: engine) { line in
                    Task { @MainActor in state.log(line) }
                }
            }

            if let installerURL = app.installerURL {
                state.set(phase: "Downloading \(app.name)…", progress: 0)
                let localURL = try await downloadInstaller(from: installerURL, fileName: app.installerFileName, state: state)

                state.set(phase: "Running installer…", progress: nil)
                let logURL = LogStore.newLogURL(bottleID: bottle.id, exeName: app.installerFileName.isEmpty ? "\(app.id)-install" : app.installerFileName)
                try await runInstaller(app, localURL: localURL, bottle: bottle, engine: engine, logURL: logURL, state: state)

                state.set(phase: "Waiting for installer to finish…", progress: nil)
                await waitForInstallerToSettle(bottle: bottle)
            }

            state.set(phase: "Scanning installed programs…", progress: nil)
            await rescanAndPin(app, bottle: &bottle, appState: appState)

            state.finish(error: nil)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            state.finish(error: message)
            appState.report(error, context: "Installing \(app.name)")
        }
    }

    // MARK: - Windows version

    @MainActor
    private static func applyRecommendedWindowsIfNeeded(
        _ app: CatalogApp,
        bottle: inout Bottle,
        engine: InstalledEngine,
        appState: AppState,
        state: AppInstallState
    ) async throws {
        guard app.recommendedWindows != bottle.windowsVersion else { return }
        state.set(phase: "Switching bottle to \(app.recommendedWindows.displayName)…")
        bottle.windowsVersion = app.recommendedWindows
        appState.updateBottle(bottle)
        try await WineRunner.applyWindowsVersion(app.recommendedWindows, bottle: bottle, engine: engine)
        state.log("Set Windows version to \(app.recommendedWindows.displayName) for \(app.name).")
    }

    // MARK: - Download

    /// Downloads `url` to `Paths.downloads/<fileName>` with progress
    /// reported through `state.progress`. If a file already exists there
    /// and is over 1 MB (large enough to rule out a truncated/failed
    /// previous attempt), it's reused as-is without re-downloading.
    @MainActor
    private static func downloadInstaller(from url: URL, fileName: String, state: AppInstallState) async throws -> URL {
        try Paths.ensureAll()
        let destination = Paths.downloads.appendingPathComponent(fileName.isEmpty ? url.lastPathComponent : fileName)

        if let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path),
           let size = attributes[.size] as? Int, size > 1_000_000 {
            state.log("Reusing already-downloaded \(destination.lastPathComponent).")
            return destination
        }

        let progressHandler: @Sendable (Double) -> Void = { fraction in
            Task { @MainActor in state.set(phase: "Downloading…", progress: fraction) }
        }
        let tempURL = try await DownloadProgressFetcher.download(url: url, progress: progressHandler)

        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)
        state.log("Downloaded \(destination.lastPathComponent).")
        return destination
    }

    // MARK: - Running the installer

    private static func runInstaller(
        _ app: CatalogApp,
        localURL: URL,
        bottle: Bottle,
        engine: InstalledEngine,
        logURL: URL,
        state: AppInstallState
    ) async throws {
        let arguments: [String]
        if app.isMSI {
            arguments = ["msiexec", "/i", localURL.path] + app.silentArgs
        } else {
            arguments = [localURL.path] + app.silentArgs
        }

        // Tail the log file into `state.output` while the installer runs,
        // since `WineRunner.runTool` only hands back full stdout/stderr
        // once the process exits.
        let tailTask = Task.detached { @Sendable in
            var lastLength = 0
            while !Task.isCancelled {
                let text = LogStore.tail(logURL, maxBytes: 4_000)
                if text.count != lastLength {
                    lastLength = text.count
                    let tail = text
                    await MainActor.run { AppInstallState.shared.log(tail) }
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        defer { tailTask.cancel() }

        let result = try await WineRunner.runTool(engine.wineBinary, arguments, bottle: bottle, engine: engine, logURL: logURL)
        if !app.silentArgs.isEmpty, result.status != 0 {
            // A non-zero exit from a *silent* install is worth surfacing;
            // an interactive installer's exit code is meaningless (it
            // reflects however the user closed the window), so only flag
            // this for installers we told to run unattended.
            await MainActor.run {
                state.log("Installer exited with status \(result.status).")
            }
        }
    }

    /// Polls `pgrep -fl <prefix>` every 2s (up to 10 minutes) until only
    /// idle Wine housekeeping processes remain — silent installers
    /// frequently spawn a second process and let the first exit, so
    /// "the process we launched exited" doesn't mean installation is done.
    private static func waitForInstallerToSettle(bottle: Bottle) async {
        let deadline = Date().addingTimeInterval(10 * 60)
        while Date() < deadline {
            guard let result = try? await ShellRunner.run("/usr/bin/pgrep", ["-fl", bottle.prefixDir.path]) else { return }
            let lines = result.stdout.split(separator: "\n").map(String.init)
            let stillBusy = lines.contains { line in
                !idleProcessNames.contains { name in line.lowercased().contains(name) }
            }
            if !stillBusy { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    // MARK: - Post-install: rescan + pin

    @MainActor
    private static func rescanAndPin(_ app: CatalogApp, bottle: inout Bottle, appState: AppState) async {
        let scanned = await ProgramScanner.scan(bottle: bottle)
        bottle.pins = ProgramScanner.merge(scanned: scanned, existing: bottle.pins)

        for hint in app.launchExeHints {
            let candidate = bottle.driveC.appendingPathComponent(hint)
            guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
            if !bottle.pins.contains(where: { $0.exePath == candidate.path }) {
                bottle.pins.append(PinnedProgram(name: app.name, exePath: candidate.path, args: app.launchArgs, isUserAdded: false))
            }
            break
        }

        appState.updateBottle(bottle)
    }
}

/// A tiny `URLSessionDownloadDelegate` wrapper so `AppInstaller` can report
/// fractional download progress without pulling in a third-party
/// networking helper.
private final class DownloadProgressFetcher: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Double) -> Void
    private let continuation: CheckedContinuation<URL, Error>
    /// The delegate callback hands us a temp file that's deleted the
    /// moment the callback returns, so we copy it to our own temp path
    /// before resuming the continuation.
    private let stagingURL: URL

    private init(progress: @escaping @Sendable (Double) -> Void, continuation: CheckedContinuation<URL, Error>) {
        self.progress = progress
        self.continuation = continuation
        self.stagingURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    static func download(url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let delegate = DownloadProgressFetcher(progress: progress, continuation: continuation)
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            let task = session.downloadTask(with: url)
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            try FileManager.default.moveItem(at: location, to: stagingURL)
            continuation.resume(returning: stagingURL)
        } catch {
            continuation.resume(throwing: error)
        }
        session.finishTasksAndInvalidate()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            continuation.resume(throwing: error)
            session.finishTasksAndInvalidate()
        }
    }
}
