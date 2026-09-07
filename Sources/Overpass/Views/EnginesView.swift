import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The Engines screen: lists the fixed catalog (`EngineCatalog.releases`),
/// each with its install state, and lets the user install/remove them.
/// Bottles are created against whichever engines are installed here.
///
/// Also offers a live "Check for updates" pass (`EngineUpdateChecker`)
/// that surfaces newer Gcenx releases under an "Available" section, and —
/// for installed GPTK engines — a way to drop in Apple's own D3DMetal from
/// a GPTK `.dmg` (`D3DMetalImporter`) ahead of Gcenx publishing a matching
/// build.
struct EnginesView: View {
    @Environment(AppState.self) private var appState

    @State private var availableReleases: [EngineRelease] = []
    @State private var isCheckingUpdates = false
    @State private var updateCheckError: String?
    @State private var lastCheckedAt: Date?

    /// Fetched releases not already covered by the built-in catalog or an
    /// installed engine — these get their own "Available" section below.
    private var newReleases: [EngineRelease] {
        let knownIDs = Set(EngineCatalog.releases.map(\.id))
        let installedIDs = Set(appState.installedEngines.map(\.id))
        return availableReleases.filter { !knownIDs.contains($0.id) && !installedIDs.contains($0.id) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                header

                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    SectionHeader(title: "Available Engines", systemImage: "gearshape.2")
                    VStack(spacing: Theme.Spacing.l) {
                        ForEach(EngineCatalog.releases) { release in
                            EngineRow(release: release)
                        }
                    }
                }

                if !newReleases.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                        SectionHeader(title: "Available", systemImage: "arrow.down.circle")
                        VStack(spacing: Theme.Spacing.l) {
                            ForEach(newReleases) { release in
                                EngineRow(release: release)
                            }
                        }
                    }
                }

                updateStatusNote
                rosettaNote
                gptk4Note
            }
            .padding(Theme.Spacing.xl)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task {
            appState.loadEngines()
            if availableReleases.isEmpty, let cached = EngineUpdateChecker.cachedReleases() {
                availableReleases = cached
                lastCheckedAt = EngineUpdateChecker.cachedAt()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    checkForUpdates()
                } label: {
                    if isCheckingUpdates {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(isCheckingUpdates)
            }
        }
    }

    private func checkForUpdates() {
        guard !isCheckingUpdates else { return }
        isCheckingUpdates = true
        updateCheckError = nil
        Task {
            defer { isCheckingUpdates = false }
            do {
                availableReleases = try await EngineUpdateChecker.fetchLatest()
                lastCheckedAt = Date()
            } catch {
                updateCheckError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("Engines")
                .font(Theme.titleFont())
            Text("Wine builds that run your Windows programs. Install at least one before creating a bottle.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var updateStatusNote: some View {
        if let updateCheckError {
            HStack(alignment: .top, spacing: Theme.Spacing.s) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("Couldn't check for updates: \(updateCheckError)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(Theme.Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overpassCard(cornerRadius: Theme.Radius.row)
        } else if let lastCheckedAt {
            Text("Checked for updates \(lastCheckedAt.formatted(date: .abbreviated, time: .shortened)).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var rosettaNote: some View {
        Text("Engines run under Rosetta 2, which Apple plans to remove most of in macOS 28 (2027).")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private var gptk4Note: some View {
        Text("Newest redistributable GPTK is whatever Gcenx has published; Apple's GPTK 4 beta needs an Apple Developer download.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

/// One catalog entry: its description, install state, progress while
/// installing, and the relevant action buttons.
private struct EngineRow: View {
    @Environment(AppState.self) private var appState
    let release: EngineRelease

    @State private var d3dmetalStatus: String?
    @State private var isImportingD3DMetal = false

    private var installed: InstalledEngine? {
        appState.installedEngines.first { $0.id == release.id }
    }
    private var progress: Double? { appState.engineInstallProgress[release.id] }
    private var status: String? { appState.engineInstallStatus[release.id] }
    private var installing: Bool { progress != nil }
    private var hasD3DMetalBackup: Bool {
        installed.map { D3DMetalImporter.hasBackup(engine: $0) } ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack(alignment: .top, spacing: Theme.Spacing.m) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: Theme.Spacing.s) {
                        Text(release.displayName)
                            .font(Theme.headingFont(16))
                        if release.id == EngineCatalog.defaultRelease.id {
                            Chip(text: "Default", systemImage: "star.fill", tint: .yellow)
                        }
                        if !release.verified {
                            Chip(text: "Unverified checksum", systemImage: "questionmark.circle", tint: .orange)
                        }
                    }
                    Text(release.notes)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Theme.Spacing.m)
                if installed != nil, !installing {
                    Chip(text: "Installed", systemImage: "checkmark.circle.fill", tint: .green)
                }
            }

            if installing {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress ?? 0)
                    Text(status ?? "Working…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let installed {
                VStack(alignment: .leading, spacing: 2) {
                    Text(installed.versionString)
                        .font(.system(.caption, design: .monospaced).weight(.medium))
                    Text("Installed \(installed.installedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let d3dmetalVersion = installed.d3dmetalVersion {
                        Text("D3DMetal \(d3dmetalVersion)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if installed.checksumVerified == false {
                        Text("Installed with an unverified checksum.")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }

            actionRow

            if installed?.kind == .gptk, !installing {
                d3dmetalRow
            }
        }
        .padding(Theme.Spacing.l)
        .overpassCard()
    }

    @ViewBuilder
    private var actionRow: some View {
        if installing {
            EmptyView()
        } else if let installed {
            HStack(spacing: Theme.Spacing.s) {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([installed.rootDir])
                }
                .buttonStyle(.quiet)

                Button("Remove", role: .destructive) {
                    Task { await appState.removeEngine(installed.id) }
                }
                .buttonStyle(.quiet)
            }
        } else {
            Button("Install") {
                Task { await appState.installEngine(release) }
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var d3dmetalRow: some View {
        if let installed {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack(spacing: Theme.Spacing.s) {
                    Button(isImportingD3DMetal ? "Importing…" : "Update D3DMetal from Apple GPTK .dmg…") {
                        importD3DMetal(installed)
                    }
                    .buttonStyle(.quiet)
                    .disabled(isImportingD3DMetal)

                    if hasD3DMetalBackup {
                        Button("Restore previous D3DMetal") {
                            restoreD3DMetal(installed)
                        }
                        .buttonStyle(.quiet)
                        .disabled(isImportingD3DMetal)
                    }
                }
                if let d3dmetalStatus {
                    Text(d3dmetalStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func importD3DMetal(_ engine: InstalledEngine) {
        let panel = NSOpenPanel()
        panel.title = "Choose Apple's GPTK .dmg"
        panel.allowedContentTypes = [UTType(filenameExtension: "dmg") ?? .item]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        isImportingD3DMetal = true
        d3dmetalStatus = "Starting…"
        Task {
            defer { isImportingD3DMetal = false }
            do {
                let version = try await D3DMetalImporter.importFromDMG(url, into: engine) { status in
                    Task { @MainActor in d3dmetalStatus = status }
                }
                d3dmetalStatus = "Updated to D3DMetal \(version)."
                await appState.loadEnginesNow()
            } catch {
                appState.report(error, context: "Importing D3DMetal")
                d3dmetalStatus = nil
            }
        }
    }

    private func restoreD3DMetal(_ engine: InstalledEngine) {
        Task {
            do {
                guard try await D3DMetalImporter.restoreBackup(engine: engine) else {
                    d3dmetalStatus = "No previous D3DMetal backup found."
                    return
                }
                d3dmetalStatus = "Restored previous D3DMetal."
                await appState.loadEnginesNow()
            } catch {
                appState.report(error, context: "Restoring D3DMetal")
            }
        }
    }
}
