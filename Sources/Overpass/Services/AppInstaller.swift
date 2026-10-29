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
/// `AppInstallState.shared`.
///
/// The actual step-by-step logic lives in `run(_:bottle:engine:persist:)`,
/// which has no `AppState` dependency — only `AppInstallState.shared` (for
/// UI progress) and a `persist` callback for writing the bottle's updated
/// metadata as it changes. `install(_:into:engine:appState:)` is a thin
/// wrapper around it for the UI (`AppCatalogView`); `DebugInstallCheck`
/// calls `run` directly so the headless `--check-install` smoke test
/// doesn't need to construct a full `AppState`.
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

    /// UI entry point. Failures are routed through `appState.report(_:context:)`
    /// so nothing fails silently; `AppInstallState.shared.lastError` also
    /// carries the message for the detail sheet.
    @MainActor
    static func install(_ app: CatalogApp, into bottle: Bottle, engine: InstalledEngine, appState: AppState) async {
        do {
            _ = try await run(app, bottle: bottle, engine: engine) { updated in
                appState.updateBottle(updated)
            }
        } catch {
            appState.report(error, context: "Installing \(app.name)")
        }
    }

    /// The install steps themselves — Windows-version switch, winetricks
    /// prerequisites, download, run, wait-for-settle, rescan+pin — with no
    /// `AppState` dependency. Owns the full `AppInstallState.shared`
    /// lifecycle (`begin`/`finish`) so any caller, UI or headless, gets
    /// consistent progress reporting for free. `persist` is called every
    /// time the bottle's metadata changes (Windows version switch, final
    /// pins) so the caller can save it — `appState.updateBottle` for the
    /// UI, `BottleStore.save` for a headless caller — and the final,
    /// fully-updated `Bottle` is also returned so the caller isn't forced
    /// to rely on `persist` alone. Rethrows on failure after recording the
    /// error on `AppInstallState.shared`.
    @MainActor
    @discardableResult
    static func run(
        _ app: CatalogApp,
        bottle: Bottle,
        engine: InstalledEngine,
        persist: (Bottle) -> Void = { _ in }
    ) async throws -> Bottle {
        let state = AppInstallState.shared
        state.begin(app.id)

        do {
            var bottle = bottle
            // Exit status and log of the installer process, kept for the
            // "nothing was installed" check after the rescan below. `nil`
            // when this app has no installer download (winetricks-only).
            var installerStatus: Int32?
            var installerLogURL: URL?
            try await applyRecommendedWindowsIfNeeded(app, bottle: &bottle, engine: engine, persist: persist, state: state)

            for verb in app.winetricksVerbs {
                state.set(phase: "Installing prerequisite \(verb)…")
                state.log("$ /bin/bash <winetricks> -q \(verb)")
                try await Winetricks.run(verb: verb, bottle: bottle, engine: engine) { line in
                    Task { @MainActor in state.log(line) }
                }
            }

            if let installerURL = app.installerURL {
                state.set(phase: "Downloading \(app.name)…", progress: 0)
                let localURL = try await downloadInstaller(from: installerURL, fileName: app.installerFileName, state: state)

                state.set(phase: "Running installer…", progress: nil)
                let logURL = LogStore.newLogURL(bottleID: bottle.id, exeName: app.installerFileName.isEmpty ? "\(app.id)-install" : app.installerFileName)
                installerStatus = try await runInstaller(app, localURL: localURL, bottle: bottle, engine: engine, logURL: logURL, state: state)
                installerLogURL = logURL

                state.set(phase: "Waiting for installer to finish…", progress: nil)
                await waitForInstallerToSettle(bottle: bottle)
            }

            if let tweak = app.tweak {
                state.set(phase: "Applying \(app.name) fixes…", progress: nil)
                do {
                    try await AppTweak.apply(tweak, to: bottle, engine: engine) { line in
                        Task { @MainActor in state.log(line) }
                    }
                } catch {
                    // A tweak failing shouldn't fail the whole install —
                    // the app itself is already installed at this point;
                    // just surface it in the log and move on to the
                    // rescan below.
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    state.log("Warning: \(app.name) fix-up failed: \(message)")
                }
            }

            state.set(phase: "Scanning installed programs…", progress: nil)
            let pinned: Bool
            (bottle, pinned) = await rescanAndPin(app, bottle: bottle)
            persist(bottle)

            // A finished installer process is not a finished install: a
            // wrong-architecture or corrupt installer, a silent flag it
            // doesn't understand, or one the user cancelled all exit
            // having put nothing on disk, and the catalog's own hint
            // (`launchExeHints`) is the one thing that says what a good
            // install must have produced. Before this check the card went
            // green "Done" and offered a Launch button for a program that
            // was never there. Only apps that *have* hints can be judged
            // this way (runtimes like the VC++ redistributable install
            // DLLs, not an exe to pin), and only when an installer
            // actually ran. The rescan result is still persisted above, so
            // anything else the installer did drop into the bottle shows
            // up in Programs.
            if !app.launchExeHints.isEmpty, !pinned, let installerStatus {
                let logName = installerLogURL.map { LogFileName.displayName(for: $0) } ?? "the installer log"
                throw InstallError(message: "\(app.name) doesn't appear to have installed: the installer finished (exit status \(installerStatus)) but its program wasn't found in the bottle. Open the Logs tab and read \"\(logName)\" to see what the installer said, then try Retry Install.")
            }

            state.finish(error: nil)
            return bottle
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            state.finish(error: message)
            throw error
        }
    }

    // MARK: - Windows version

    @MainActor
    private static func applyRecommendedWindowsIfNeeded(
        _ app: CatalogApp,
        bottle: inout Bottle,
        engine: InstalledEngine,
        persist: (Bottle) -> Void,
        state: AppInstallState
    ) async throws {
        guard app.recommendedWindows != bottle.windowsVersion else { return }
        state.set(phase: "Switching bottle to \(app.recommendedWindows.displayName)…")
        bottle.windowsVersion = app.recommendedWindows
        persist(bottle)
        state.log("$ \(engine.wineBinary.path) winecfg -v \(app.recommendedWindows.winecfgValue)")
        try await WineRunner.applyWindowsVersion(app.recommendedWindows, bottle: bottle, engine: engine)
        state.log("Set Windows version to \(app.recommendedWindows.displayName) for \(app.name).")
    }

    // MARK: - Download

    /// Downloads `url` to `Paths.downloads/<fileName>` with progress
    /// reported through `state.progress`. If a file already exists there
    /// and is over 1 MB (large enough to rule out a truncated/failed
    /// previous attempt) *and* starts with a Windows installer's magic
    /// bytes (`looksLikeWindowsInstaller`), it's reused as-is without
    /// re-downloading. Size alone isn't enough: a large HTML error page or
    /// a half-written file from an older build that lacked the HTTP status
    /// check below would otherwise be handed to Wine on every retry,
    /// forever.
    @MainActor
    private static func downloadInstaller(from url: URL, fileName: String, state: AppInstallState) async throws -> URL {
        try Paths.ensureAll()
        let destination = Paths.downloads.appendingPathComponent(fileName.isEmpty ? url.lastPathComponent : fileName)

        if let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path),
           let size = attributes[.size] as? Int, size > 1_000_000 {
            if looksLikeWindowsInstaller(at: destination) {
                state.log("Reusing already-downloaded \(destination.lastPathComponent).")
                return destination
            }
            state.log("Ignoring cached \(destination.lastPathComponent): it isn't a Windows installer. Downloading it again.")
        }

        let progressHandler: @Sendable (Double) -> Void = { fraction in
            Task { @MainActor in state.set(phase: "Downloading…", progress: fraction) }
        }
        let tempURL = try await DownloadProgressFetcher.download(url: url, progress: progressHandler)

        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)

        // Same check the cache shortcut above applies, for the same reason
        // but a different cause. The HTTP status check in
        // `DownloadProgressFetcher` catches a 404 or 403; it cannot catch a
        // 200 whose body isn't the installer — a captive portal's sign-in
        // page, an interstitial "your download will begin shortly" page, or
        // a vendor that quietly serves HTML once a pinned version is
        // retired. Without this the HTML lands as `Setup.exe` and gets
        // handed to Wine, which is exactly the path that used to end in a
        // green "Done" with nothing installed.
        guard looksLikeWindowsInstaller(at: destination) else {
            try? FileManager.default.removeItem(at: destination)
            throw InstallError(
                message: "The download from \(url.host ?? "the server") wasn't a Windows installer — "
                    + "the server returned a web page instead of \(destination.lastPathComponent). "
                    + "The download link may have moved, or a network sign-in page may be in the way."
            )
        }

        state.log("Downloaded \(destination.lastPathComponent).")
        return destination
    }

    /// True when the file at `url` begins with the signature of something
    /// Wine can run as an installer: `MZ` (a PE executable, i.e. every
    /// `.exe` in the catalog) or `D0 CF 11 E0` (an OLE compound document,
    /// which is what an `.msi` is). Reads only the first four bytes. A file
    /// that can't be opened or is shorter than the signature is "no".
    static func looksLikeWindowsInstaller(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4) else { return false }
        return hasWindowsInstallerSignature(head)
    }

    /// The byte test behind `looksLikeWindowsInstaller`, split out so it
    /// can be checked without touching the disk.
    static func hasWindowsInstallerSignature(_ head: Data) -> Bool {
        let bytes = [UInt8](head)
        if bytes.count >= 2, bytes[0] == 0x4D, bytes[1] == 0x5A { return true }
        if bytes.count >= 4, bytes[0] == 0xD0, bytes[1] == 0xCF, bytes[2] == 0x11, bytes[3] == 0xE0 { return true }
        return false
    }

    // MARK: - Running the installer

    private static func runInstaller(
        _ app: CatalogApp,
        localURL: URL,
        bottle: Bottle,
        engine: InstalledEngine,
        logURL: URL,
        state: AppInstallState
    ) async throws -> Int32 {
        let arguments: [String]
        if app.isMSI {
            arguments = ["msiexec", "/i", localURL.path] + app.silentArgs
        } else {
            arguments = [localURL.path] + app.silentArgs
        }

        let commandLine = (["$", engine.wineBinary.path] + arguments).joined(separator: " ")
        await MainActor.run { state.log(commandLine) }

        // Stream the log file into `state.output` while the installer runs,
        // since `WineRunner.runTool` only hands back full stdout/stderr
        // once the process exits.
        //
        // Only text appended since the previous poll is emitted, tracked
        // by a `LogStore.Cursor`. This used to re-read the last 4,000 bytes
        // and append all of them every second the length changed, so each
        // line was shown again on every poll until it scrolled out of the
        // window — the install log repeated itself. (`logURL` is created
        // fresh for this install by `LogStore.newLogURL`, so starting the
        // cursor at the top of the file does not replay an older run.)
        //
        // When the task is cancelled (the installer exited, or the install
        // threw) it does one last read with `flushPartial`, because a
        // final line without a trailing newline would otherwise be held
        // back forever. `tailTask.value` is awaited below so that flush
        // lands before the "Installer exited" line rather than after it.
        let tailTask = Task.detached { @Sendable in
            var cursor = LogStore.Cursor()
            while !Task.isCancelled {
                let fresh = cursor.advance(logURL)
                if !fresh.isEmpty {
                    await MainActor.run { AppInstallState.shared.log(fresh) }
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            let rest = cursor.advance(logURL, flushPartial: true)
            if !rest.isEmpty {
                await MainActor.run { AppInstallState.shared.log(rest) }
            }
        }
        defer { tailTask.cancel() }

        let result = try await WineRunner.runTool(engine.wineBinary, arguments, bottle: bottle, engine: engine, logURL: logURL)
        tailTask.cancel()
        await tailTask.value
        if !app.silentArgs.isEmpty, result.status != 0 {
            // A non-zero exit from a *silent* install is worth surfacing;
            // an interactive installer's exit code is meaningless (it
            // reflects however the user closed the window), so only flag
            // this for installers we told to run unattended.
            await MainActor.run {
                state.log("Installer exited with status \(result.status).")
            }
        }
        return result.status
    }

    /// Polls `pgrep -fl <prefix>` every 2s (up to 2 minutes) until only
    /// idle Wine housekeeping processes remain — silent installers
    /// frequently spawn a second process and let the first exit, so
    /// "the process we launched exited" doesn't mean installation is done.
    /// Two consecutive idle polls are required before returning, so a
    /// process that briefly disappears while re-executing itself (common
    /// for self-extracting installers that unpack to a temp dir and
    /// relaunch from there) doesn't cause an early "done".
    ///
    /// The deadline is 2 minutes, not 10 — `runInstaller` has already
    /// awaited the top-level installer process to exit by the time this
    /// runs, so this is only catching a *second*, detached process the
    /// installer spawned before exiting; every silent installer in the
    /// catalog is documented to finish in well under a minute, so 10
    /// minutes of polling after that is dead time on any interactive
    /// installer (no silent flags) that simply never spawns a second
    /// process — this used to make `waitForInstallerToSettle` sit through
    /// the full deadline for e.g. Battle.net/EA app before falling
    /// through to the (equally long) rescan.
    private static func waitForInstallerToSettle(bottle: Bottle) async {
        let deadline = Date().addingTimeInterval(2 * 60)
        var consecutiveIdle = 0
        while Date() < deadline {
            guard let result = try? await ShellRunner.run("/usr/bin/pgrep", ["-fl", bottle.prefixDir.path]) else { return }
            let lines = result.stdout.split(separator: "\n").map(String.init)
            let stillBusy = lines.contains { line in
                !idleProcessNames.contains { name in line.lowercased().contains(name) }
            }
            if stillBusy {
                consecutiveIdle = 0
            } else {
                consecutiveIdle += 1
                if consecutiveIdle >= 2 { return }
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
    }

    // MARK: - Post-install: rescan + pin

    /// Rescans `bottle` and pins `app`'s launcher. `pinned` is true when one
    /// of the app's `launchExeHints` resolved to a real file (and so the
    /// app's pin now exists); false when none did — `run` treats that as
    /// "the installer didn't actually install anything".
    @MainActor
    private static func rescanAndPin(_ app: CatalogApp, bottle: Bottle) async -> (bottle: Bottle, pinned: Bool) {
        var bottle = bottle
        var pinned = false
        let scanned = await ProgramScanner.scan(bottle: bottle)
        bottle.pins = ProgramScanner.merge(scanned: scanned, existing: bottle.pins)

        for hint in app.launchExeHints {
            guard let candidate = resolveHint(hint, driveC: bottle.driveC) else { continue }
            if let existingIndex = bottle.pins.firstIndex(where: { $0.exePath == candidate.path }) {
                // `ProgramScanner.scan` above already finds every bare
                // `.exe` under Program Files on its own, including this
                // one — it would have just pinned it under its own
                // filename (e.g. "7zFM") with no launch args. Upgrade
                // that generic pin to the catalog's app name (and launch
                // args, e.g. Steam's steamwebhelper workaround flags) so
                // `AppCatalogDetailSheet.launchPin`'s `pins.first {
                // $0.name == app.name }` lookup — and the "Launch <App>"
                // button it drives — actually finds this pin. Skip a pin
                // the user has since customized (renamed, or added their
                // own args) rather than clobbering it.
                if !bottle.pins[existingIndex].isUserAdded {
                    bottle.pins[existingIndex].name = app.name
                    if bottle.pins[existingIndex].args.isEmpty {
                        bottle.pins[existingIndex].args = app.launchArgs
                    }
                }
            } else {
                bottle.pins.append(PinnedProgram(name: app.name, exePath: candidate.path, args: app.launchArgs, isUserAdded: false))
            }
            pinned = true
            break
        }

        return (bottle, pinned)
    }

    /// Resolves a catalog hint like `"Program Files/7-Zip/7zFM.exe"`
    /// (forward slashes, as written in `CatalogApp.launchExeHints`)
    /// against `driveC`. Tries the exact-case join first, then falls back
    /// to `ShellLink.windowsPathToUnix`'s case-insensitive component walk
    /// — some installers create folders with different casing than the
    /// hint (e.g. "Program Files (x86)" written by an installer as
    /// "Program Files (X86)"), and Wine prefixes are case-sensitive on
    /// disk even though Windows paths are nominally case-insensitive.
    private static func resolveHint(_ hint: String, driveC: URL) -> URL? {
        let direct = driveC.appendingPathComponent(hint)
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        let windowsPath = "C:\\" + hint.replacingOccurrences(of: "/", with: "\\")
        return ShellLink.windowsPathToUnix(windowsPath, driveC: driveC)
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
        // `URLSession` treats a 404/500 as a *successful* download of the
        // error page's body, so without this check an HTML "not found" page
        // is saved as `Setup.exe` and handed to Wine. (`EngineManager` and
        // `DXVKInstaller` make the same check for the same reason.) The
        // temp file at `location` is deleted by the system as soon as this
        // callback returns, so there is nothing to clean up here.
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            continuation.resume(throwing: AppInstaller.InstallError(
                message: "Downloading the installer failed (server returned HTTP \(http.statusCode)). The download link may have moved. Try again later; if it keeps happening, this app's catalog entry needs a new link."
            ))
            session.finishTasksAndInvalidate()
            return
        }
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
