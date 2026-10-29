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
    /// Id of the derived engine being removed, so only that row spins.
    @State private var removingUserEngineID: String?

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

                gptk4Section

                updateStatusNote
                rosettaNote
            }
            .padding(Theme.Spacing.outer)
            .frame(maxWidth: Theme.Metrics.contentMaxWidth, alignment: .leading)
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
                        Label("Check for updates", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(isCheckingUpdates)
                // While the spinner replaces the label, the button would
                // otherwise have no name at all for VoiceOver or a tooltip.
                .help(isCheckingUpdates ? "Checking for updates…" : "Check for updates")
                .accessibilityLabel(isCheckingUpdates ? "Checking for updates" : "Check for updates")
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

    @ViewBuilder
    private var updateStatusNote: some View {
        if let updateCheckError {
            InlineNote(
                systemImage: "exclamationmark.triangle",
                tint: .orange,
                text: "Couldn't check for updates: \(updateCheckError)"
            )
        } else if let lastCheckedAt {
            Text("Checked for updates \(lastCheckedAt.formatted(date: .abbreviated, time: .shortened)).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // Both notes below were `.lineLimit(1)`, which silently cut the end of
    // the sentence off whenever the window was narrower than the text
    // (the GPTK note is ~115 characters). They wrap instead.
    private var rosettaNote: some View {
        Text("Engines run under Rosetta 2, which Apple plans to remove most of in macOS 28 (2027).")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Game Porting Toolkit 4 (user-supplied)

    /// Engines derived from a GPTK 4 download the user provided. The rest of
    /// this screen iterates `EngineCatalog.releases`, so without this these
    /// engines would be installed, selectable in every bottle picker, and
    /// invisible on the one screen that manages engines.
    private var userSuppliedEngines: [InstalledEngine] {
        appState.installedEngines
            .filter(EngineCatalog.isUserSupplied)
            .sorted { $0.id < $1.id }
    }

    private var gptk4Progress: Double? {
        appState.engineInstallProgress[EngineCatalog.userSuppliedGPTKProgressKey]
    }

    private var gptk4Status: String? {
        appState.engineInstallStatus[EngineCatalog.userSuppliedGPTKProgressKey]
    }

    /// The only route to `AppState.installGPTKFromUserFile`. Apple keeps the
    /// GPTK 4 download behind a developer sign-in and its licence forbids
    /// redistribution, so Overpass cannot fetch it the way it fetches catalog
    /// engines — the user has to supply the file. Stating that here is the
    /// point of the section: the capability is otherwise undiscoverable.
    private var gptk4Section: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            SectionHeader(title: "Game Porting Toolkit 4", systemImage: "wand.and.stars")

            Text("Apple's GPTK 4 sits behind an Apple Developer sign-in and may not be redistributed, so Overpass can't download it for you. Point it at the .dmg you downloaded, or the redist/lib folder inside it, and Overpass clones one of your installed Wine engines and overlays the new files onto the copy — the original is left untouched.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            InlineNote(
                systemImage: "exclamationmark.triangle",
                tint: .orange,
                text: "Experimental. The GPTK 4 files do load on Wine-staging 11.20, but regsvr32 d3d11.dll hangs and no game has been confirmed rendering on a derived engine."
            )

            if let gptk4Progress {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    ProgressView(value: gptk4Progress)
                    if let gptk4Status {
                        Text(gptk4Status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(Theme.Spacing.l)
                .overpassCard()
            } else {
                Button {
                    pickGPTK4Download()
                } label: {
                    Label("Use my GPTK 4 download…", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.accentCompact)
                .help("Choose Apple's GPTK 4 .dmg, or the redist/lib folder from inside it")
            }

            ForEach(userSuppliedEngines) { engine in
                userSuppliedRow(engine)
            }

            Text("The engines above come from Gcenx's published builds; this section is only for Apple's own GPTK 4 download.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One derived engine: what it was built from, and a way to remove it.
    /// Shows `sourceName` rather than a path because `UserSuppliedOrigin`
    /// deliberately keeps only the name — a path can carry a username and is
    /// useless once the download is deleted.
    private func userSuppliedRow(_ engine: InstalledEngine) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack(spacing: Theme.Spacing.s) {
                    Text(engine.displayName)
                        .font(Theme.headingFont(16))
                    Chip(text: "Your download", systemImage: "person.crop.circle", tint: .accentColor)
                }
                if let origin = engine.userSupplied {
                    Text("Built from \(origin.sourceName) on \(origin.baseVersionString).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !origin.signatureVerified {
                        Text("Apple's code signature was not verified for this install.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer(minLength: Theme.Spacing.s)
            if removingUserEngineID == engine.id {
                ProgressView().controlSize(.small)
            } else {
                Button("Remove") { removeUserSupplied(engine) }
                    .buttonStyle(.quietCompact)
            }
        }
        .padding(Theme.Spacing.l)
        .overpassCard()
    }

    /// Mirrors `importD3DMetal`'s panel, but also accepts a directory: the
    /// payload Overpass needs is `redist/lib`, and a user who has already
    /// mounted the dmg and copied that folder out has nothing to point a
    /// file-only panel at.
    private func pickGPTK4Download() {
        let panel = NSOpenPanel()
        panel.title = "Choose Apple's GPTK 4 .dmg or its redist/lib folder"
        panel.prompt = "Use This"
        panel.allowedContentTypes = [UTType(filenameExtension: "dmg") ?? .item, .folder]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task { await appState.installGPTKFromUserFile(url) }
    }

    private func removeUserSupplied(_ engine: InstalledEngine) {
        guard removingUserEngineID == nil else { return }
        removingUserEngineID = engine.id
        Task {
            await appState.removeEngine(engine.id)
            removingUserEngineID = nil
        }
    }
}

/// One catalog entry: its description, install state, progress while
/// installing, and the relevant action buttons.
private struct EngineRow: View {
    @Environment(AppState.self) private var appState
    let release: EngineRelease

    @State private var d3dmetalStatus: String?
    @State private var isImportingD3DMetal = false
    /// True while "Restore previous D3DMetal" is running. Restore used to
    /// have no in-flight state at all, so it could be clicked twice, or
    /// while an import was swapping the same files.
    @State private var isRestoringD3DMetal = false
    /// True while "Remove" is deleting the engine's folder, so the button
    /// can't be clicked again against a directory that is already going.
    @State private var isRemoving = false
    /// True while the "Remove" confirmation is on screen. Removal used to be
    /// one click, and nothing stopped it while bottles still pointed at the
    /// engine — those bottles then failed to launch with "No engine
    /// installed".
    @State private var showRemoveConfirmation = false

    /// How many bottles are set to use this engine. Shown in the removal
    /// confirmation so the cost of the click is visible before it happens.
    private var bottlesUsingEngine: Int {
        appState.bottles.filter { $0.engineID == release.id }.count
    }

    /// The confirmation's body text: what removal does, plus, when any
    /// bottle depends on this engine, how many will stop launching and
    /// how to fix that. Built here so the dialog closure stays readable.
    private var removeConfirmationMessage: String {
        let count = bottlesUsingEngine
        let effect = "This removes the engine from this Mac (it is moved to the Trash when possible). You can install it again from this screen."
        guard count > 0 else { return effect }
        let noun = count == 1 ? "bottle uses" : "bottles use"
        let pronoun = count == 1 ? "It" : "They"
        return "\(count) \(noun) this engine. \(pronoun) won't be able to launch programs until you choose another engine in Config or reinstall this one.\n\n" + effect
    }

    private var isBusyWithD3DMetal: Bool { isImportingD3DMetal || isRestoringD3DMetal }

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
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
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
                    Text(engineCaveat(for: release.kind))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Theme.Spacing.m)
                if installed != nil, !installing {
                    Chip(text: "Installed", systemImage: "checkmark.circle.fill", tint: .green)
                }
            }

            if installing {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    ProgressView(value: progress ?? 0)
                    Text(status ?? "Working…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let installed {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(installed.versionString)
                        .font(.system(.caption, design: .monospaced).weight(.medium))
                        .textSelection(.enabled)
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
        // Same shape as the bottle delete confirmation in MainWindow:
        // titled question, destructive confirm, Cancel, explanatory message.
        .confirmationDialog(
            "Remove \"\(release.displayName)\"?",
            isPresented: $showRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                guard let installed else { return }
                isRemoving = true
                Task {
                    await appState.removeEngine(installed.id)
                    isRemoving = false
                }
            }
            Button("Cancel", role: .cancel) { showRemoveConfirmation = false }
        } message: {
            Text(removeConfirmationMessage)
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        if installing {
            EmptyView()
        } else if let installed {
            HStack(spacing: Theme.Spacing.s) {
                // Compact quiet style: the full-width one stretched this
                // button across the row at ~46pt tall beside the bordered
                // Remove button.
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([installed.rootDir])
                }
                .buttonStyle(.quietCompact)

                Button("Remove", role: .destructive) {
                    showRemoveConfirmation = true
                }
                .buttonStyle(.bordered)
                .disabled(isRemoving || isBusyWithD3DMetal)
            }
        } else {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Button("Install") {
                    Task { await appState.installEngine(release) }
                }
                .buttonStyle(.bordered)
                Text("Downloads and unpacks in the background — usually a few minutes, depending on your connection.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
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
                    .buttonStyle(.quietCompact)
                    .disabled(isBusyWithD3DMetal || isRemoving)

                    if hasD3DMetalBackup {
                        Button(isRestoringD3DMetal ? "Restoring…" : "Restore previous D3DMetal") {
                            restoreD3DMetal(installed)
                        }
                        .buttonStyle(.quietCompact)
                        .disabled(isBusyWithD3DMetal || isRemoving)
                    }
                }
                if let d3dmetalStatus {
                    Text(d3dmetalStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
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
        guard !isBusyWithD3DMetal else { return }
        isRestoringD3DMetal = true
        Task {
            defer { isRestoringD3DMetal = false }
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
