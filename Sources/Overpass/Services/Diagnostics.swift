import Foundation

/// Parses `LogStore`'s `<yyyyMMdd-HHmmss>-<exe>.log` filename into a
/// program name and a `Date` for friendly display, used by both
/// `LogViewerView` (the log list) and `Diagnostics` (the "most recent log"
/// section). Kept as a small standalone, pure enum — no filesystem access —
/// so it's cheap to unit-test via `--self-test` and safe to call from any
/// context.
enum LogFileName {
    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// Splits `<stamp>-<exe>.log` into `(program, date)`. `nil` for
    /// anything that doesn't match `LogStore.newLogURL`'s naming — callers
    /// fall back to the raw filename rather than failing.
    static func parse(_ url: URL) -> (program: String, date: Date)? {
        let base = url.deletingPathExtension().lastPathComponent
        let parts = base.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        guard let date = stampFormatter.date(from: "\(parts[0])-\(parts[1])") else { return nil }
        let program = String(parts[2])
        return (program.isEmpty ? "run" : program, date)
    }

    /// "`<program>` — `<medium date, short time>`", e.g. "notepad — Sep 7,
    /// 2026 at 3:04 PM". Falls back to the raw filename when `parse` can't
    /// make sense of it.
    static func displayName(for url: URL) -> String {
        guard let parsed = parse(url) else { return url.lastPathComponent }
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return "\(parsed.program) — \(df.string(from: parsed.date))"
    }
}

/// Builds a plain-text diagnostics report: app/OS/engine versions, every
/// bottle's configuration, third-party tooling, disk space, and the tail of
/// the most recently written log. Nothing here is secret — home-directory
/// paths are left as-is since the report is for the user's own use (a bug
/// report, a support request, comparing two machines), not for sharing with
/// a third party automatically.
enum Diagnostics {
    static func report() async -> String {
        var lines: [String] = []
        lines.append("Overpass Diagnostics Report")
        lines.append("Generated: \(isoTimestamp(Date()))")

        lines.append("")
        lines.append(contentsOf: systemSection())

        let engines = await EngineManager.shared.installedEngines()
        lines.append("")
        lines.append(contentsOf: enginesSection(engines))

        lines.append("")
        lines.append(contentsOf: await bottlesSection(engines: engines))

        lines.append("")
        lines.append(contentsOf: toolingSection())

        lines.append("")
        lines.append(contentsOf: diskSection())

        lines.append("")
        lines.append(contentsOf: await recentLogSection())

        return lines.joined(separator: "\n")
    }

    // MARK: - Sections

    private static func systemSection() -> [String] {
        var lines = ["## System"]
        lines.append("Overpass: \(appVersion())")
        lines.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("Arch: \(buildArch())")
        lines.append("Rosetta 2 installed: \(AppState.rosettaInstalled() ? "yes" : "no")")
        return lines
    }

    private static func enginesSection(_ engines: [InstalledEngine]) -> [String] {
        var lines = ["## Installed Engines (\(engines.count))"]
        if engines.isEmpty {
            lines.append("(none installed)")
        }
        for engine in engines {
            let verified = engine.checksumVerified ?? true
            lines.append("- \(engine.id) — \(engine.kind.displayName) \(engine.version)")
            lines.append("    wine --version: \(engine.versionString)")
            lines.append("    path: \(engine.rootDir.path)")
            lines.append("    checksum verified: \(verified ? "yes" : "no")")
            if let d3dm = engine.d3dmetalVersion {
                lines.append("    D3DMetal: \(d3dm)")
            }
        }
        return lines
    }

    private static func bottlesSection(engines: [InstalledEngine]) async -> [String] {
        let bottles = BottleStore.loadAll()
        var lines = ["## Bottles (\(bottles.count))"]
        if bottles.isEmpty {
            lines.append("(none created)")
        }
        for bottle in bottles {
            let engineName = engines.first { $0.id == bottle.engineID }?.displayName ?? "\(bottle.engineID) (not installed)"
            lines.append("- \(bottle.name)")
            lines.append("    engine: \(engineName)")
            lines.append("    windows version: \(bottle.windowsVersion.displayName)")
            lines.append("    toggles: " + toggleSummary(bottle))
            lines.append("    pins: \(bottle.pins.count)")
            if let size = await prefixSizeIfCheap(bottle.prefixDir) {
                lines.append("    prefix size: \(formatBytes(size))")
            }
        }
        return lines
    }

    private static func toggleSummary(_ bottle: Bottle) -> String {
        var on: [String] = []
        if bottle.esync { on.append("esync") }
        if bottle.msync { on.append("msync") }
        if bottle.metalHUD { on.append("metalHUD") }
        if bottle.verboseLog { on.append("verboseLog") }
        if bottle.dxvk { on.append("dxvk") }
        if bottle.d3dMetalOverlay { on.append("d3dMetalOverlay") }
        return on.isEmpty ? "(none)" : on.joined(separator: ", ")
    }

    private static func toolingSection() -> [String] {
        ["## Tooling", cabextractLine()]
    }

    private static func diskSection() -> [String] {
        ["## Disk", freeDiskSpaceLine()]
    }

    private static func recentLogSection() async -> [String] {
        var lines = ["## Most Recent Log"]
        guard let logURL = mostRecentLogURL() else {
            lines.append("(no logs yet)")
            return lines
        }
        lines.append(LogFileName.displayName(for: logURL))
        lines.append("")
        let tail = LogStore.tail(logURL, maxBytes: 40_000)
        let tailLines = tail.split(separator: "\n", omittingEmptySubsequences: false).suffix(40)
        if tailLines.isEmpty {
            lines.append("(empty)")
        } else {
            lines.append(contentsOf: tailLines.map(String.init))
        }
        return lines
    }

    // MARK: - Helpers

    private static func appVersion() -> String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        if let build = info?["CFBundleVersion"] as? String, build != short {
            return "\(short) (\(build))"
        }
        return short
    }

    private static func buildArch() -> String {
        #if arch(arm64)
        return "arm64 (Apple Silicon)"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private static func cabextractLine() -> String {
        let candidates = ["/opt/homebrew/bin/cabextract", "/usr/local/bin/cabextract"]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return "cabextract: found at \(found)"
        }
        return "cabextract: not found (some Winetricks verbs need it — \"brew install cabextract\")"
    }

    private static func freeDiskSpaceLine() -> String {
        do {
            let values = try Paths.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let capacity = values.volumeAvailableCapacityForImportantUsage {
                return "Free disk space: \(formatBytes(capacity))"
            }
        } catch {
            // fall through to "unknown" below
        }
        return "Free disk space: unknown"
    }

    /// `du -sk` against `url`. Cheap in practice — measured ~0.1-0.2s
    /// against a full Steam client install (~2GB, ~9.6k files), the
    /// largest bottle prefix on this machine — but still shelled out to
    /// rather than walked in-process, so a pathological prefix degrades
    /// gracefully (a failed/slow `du` just omits the size line) instead of
    /// blocking the whole report.
    private static func prefixSizeIfCheap(_ url: URL) async -> Int64? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let result = try? await ShellRunner.run("/usr/bin/du", ["-sk", url.path]),
              result.status == 0 else { return nil }
        let firstField = result.stdout.split(separator: "\t").first ?? result.stdout.split(separator: " ").first ?? ""
        guard let kilobytes = Int64(firstField.trimmingCharacters(in: .whitespaces)) else { return nil }
        return kilobytes * 1024
    }

    private static func mostRecentLogURL() -> URL? {
        let fm = FileManager.default
        guard let bottleDirs = try? fm.contentsOfDirectory(
            at: Paths.logs, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        var newest: (url: URL, date: Date)?
        for dir in bottleDirs {
            guard let files = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
            ) else { continue }
            for file in files where file.pathExtension.lowercased() == "log" {
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if newest == nil || date > newest!.date {
                    newest = (file, date)
                }
            }
        }
        return newest?.url
    }

    private static func isoTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: date)
    }

    /// Manual (locale-independent) byte formatting so it's deterministic
    /// under `--self-test` — `ByteCountFormatter`'s output depends on the
    /// user's locale/unit-style settings.
    static func formatBytes(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unitIndex = 0
        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        if unitIndex == 0 {
            return "\(Int(value)) B"
        }
        return String(format: "%.1f %@", value, units[unitIndex])
    }
}
