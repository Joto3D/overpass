import Foundation

/// Errors surfaced by `Winetricks`, all with a user-facing description
/// suitable for `AppState.report(_:context:)`.
enum WinetricksError: LocalizedError {
    case httpStatus(Int)
    case missingCabextract
    case verbFailed(String)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code):
            return "Downloading winetricks failed (server returned HTTP \(code))."
        case .missingCabextract:
            return "This verb needs cabextract, which isn't installed. Run \"brew install cabextract\" and try again."
        case .verbFailed(let detail):
            return "winetricks failed: \(detail)"
        }
    }
}

/// Downloads and runs the upstream `winetricks` script against a bottle.
/// The script itself is a single self-contained shell script fetched from
/// GitHub — Overpass doesn't reimplement any of its verb logic, only
/// supplies the environment (`WINE`, `WINESERVER`, ...) it expects.
enum Winetricks {
    /// A short, curated set of verbs shown as one-click buttons in
    /// `ExtrasView`. `dxvk` is deliberately not included here — that's a
    /// dedicated toggle backed by `DXVKInstaller`, not a winetricks verb.
    static let curated: [(verb: String, title: String, blurb: String)] = [
        ("vcrun2022", "Visual C++ 2022", "Microsoft Visual C++ 2015-2022 redistributable — the most commonly needed runtime for modern installers."),
        ("vcrun2019", "Visual C++ 2019", "Visual C++ 2015-2019 redistributable, for programs built against the older runtime."),
        ("dotnet48", ".NET Framework 4.8", "The classic .NET Framework, still required by many Windows installers and utilities."),
        ("dotnet6", ".NET 6", "Modern .NET 6 runtime, for programs built against it."),
        ("corefonts", "Core Fonts", "Arial, Times New Roman, and the other Microsoft core web fonts many apps assume are present."),
        ("tahoma", "Tahoma Font", "The Tahoma font, still assumed present by some older UI toolkits."),
        ("d3dcompiler_47", "D3D Compiler 47", "Direct3D shader compiler DLL many DirectX 11 games need at runtime."),
        ("xact", "XACT", "Microsoft's audio engine, used by a number of older Xbox-ported games."),
        ("faudio", "FAudio", "Open-source XAudio2 reimplementation some modern game ports rely on instead of XACT."),
        ("physx", "PhysX", "NVIDIA PhysX runtime, needed by games that ship PhysX-accelerated effects."),
        ("msxml6", "MSXML 6", "Microsoft XML Core Services, a dependency of a number of older installers."),
    ]

    /// Verbs known to shell out to `cabextract` to unpack a Microsoft
    /// cabinet file. Not exhaustive of every verb winetricks might ever
    /// need it for, but covers the curated list plus the common general
    /// case (anything starting with "dotnet" or "vcrun" extracts cabs).
    private static func needsCabextract(_ verb: String) -> Bool {
        verb.hasPrefix("dotnet") || verb.hasPrefix("vcrun") || verb == "corefonts" || verb == "tahoma"
    }

    private static var cabextractPath: String { "/opt/homebrew/bin/cabextract" }
    private static var cabextractInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: cabextractPath)
    }

    // MARK: - Script management

    private static var scriptURL: URL { Paths.tools.appendingPathComponent("winetricks") }
    private static let sourceURL = URL(string: "https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks")!

    /// Downloads the winetricks script into `Paths.tools/winetricks` if
    /// it's missing or older than 30 days, then makes sure it's
    /// executable. Returns its path either way.
    @discardableResult
    static func ensureScript() async throws -> URL {
        try Paths.ensureAll()

        let fm = FileManager.default
        var needsDownload = true
        if fm.fileExists(atPath: scriptURL.path) {
            let attrs = try? fm.attributesOfItem(atPath: scriptURL.path)
            if let modified = attrs?[.modificationDate] as? Date {
                let age = Date().timeIntervalSince(modified)
                needsDownload = age > 30 * 24 * 60 * 60
            } else {
                needsDownload = false
            }
        }

        if needsDownload {
            let (data, response) = try await URLSession.shared.data(from: sourceURL)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw WinetricksError.httpStatus(http.statusCode)
            }
            try data.write(to: scriptURL, options: .atomic)
        }

        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    // MARK: - Running a verb

    /// Runs `/bin/bash <script> -q <verb>` (or, when `verb` is empty, the
    /// script with no verb at all — winetricks' own GUI picker) against
    /// `bottle`, streaming combined stdout+stderr to both `log` and a log
    /// file. Throws with the tail of the process's output on a non-zero
    /// exit.
    static func run(
        verb: String,
        bottle: Bottle,
        engine: InstalledEngine,
        log: @escaping @Sendable (String) -> Void
    ) async throws {
        if !verb.isEmpty, needsCabextract(verb), !cabextractInstalled {
            throw WinetricksError.missingCabextract
        }

        let script = try await ensureScript()

        var env = WineRunner.environment(for: bottle, engine: engine)
        env["WINE"] = engine.wineBinary.path
        env["WINESERVER"] = engine.wineserverBinary.path
        env["WINETRICKS_DOWNLOADER"] = "curl"
        if cabextractInstalled {
            let existingPath = env["PATH"] ?? "/usr/bin:/bin"
            env["PATH"] = "/opt/homebrew/bin:\(existingPath)"
        }

        let logExeName = verb.isEmpty ? "winetricks-gui" : "winetricks-\(verb)"
        // LogStore.newLogURL creates the bottle's log directory but not the
        // file itself; runStreaming's FileHandle needs it to already exist.
        let logURL = LogStore.newLogURL(bottleID: bottle.id, exeName: logExeName)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)

        // "-q" is an argument *to* winetricks, so it goes after the
        // script path on the bash command line: `bash <script> -q <verb>`.
        var args = [script.path]
        if !verb.isEmpty {
            args += ["-q", verb]
        }

        let result = try await Self.runStreaming(
            executable: "/bin/bash",
            arguments: args,
            environment: env,
            currentDirectory: bottle.prefixDir,
            logURL: logURL,
            log: log
        )

        guard result.status == 0 else {
            throw WinetricksError.verbFailed(Self.lastLines(of: result.stderr.isEmpty ? result.stdout : result.stderr))
        }
    }

    private static func lastLines(of text: String, count: Int = 20) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "(no output)" }
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(count).joined(separator: "\n")
    }

    // MARK: - Streaming process runner

    /// A `Process` runner in the same shape as `WineRunner.runTool`, but
    /// also forwards each output chunk to `log` live (for `ExtrasView`'s
    /// output box) in addition to appending it to a log file. Kept local
    /// to this file since it needs both a custom environment (like
    /// `WineRunner.runTool`) and a live per-chunk callback (which
    /// `WineRunner.runTool` doesn't offer).
    private static func runStreaming(
        executable: String,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL,
        logURL: URL,
        log: @escaping @Sendable (String) -> Void
    ) async throws -> ProcessRunner.Result {
        try await ProcessRunner.run(
            URL(fileURLWithPath: executable), arguments,
            environment: environment, currentDirectory: currentDirectory,
            logURL: logURL, onLine: log
        )
    }
}
