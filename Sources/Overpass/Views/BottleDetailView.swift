import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// A bottle's detail screen: a header (identity, Run/Stop, tools menu), then
/// either the bottle's LIBRARY or its CONFIGURATION. The whole view is a
/// drop target for `.exe`/`.msi`/`.bat` files.
///
/// Why two modes instead of the old six flat tabs (Programs / Games /
/// Config / Performance / Extras / Logs): this is a game launcher, and a
/// bottle is opened to play something. Four of those six tabs are tuning
/// (Config, Performance, Extras) or diagnostics (Logs) — a System
/// Preferences idiom that put the artwork grid a tab away from where the
/// user lands. So the top level now holds only the things you PLAY from —
/// Games (cover art) and Programs (the raw `.exe` list) — and everything
/// else sits behind one "Configure" button, in its own sub-mode with a way
/// back. It is a mode swap inside the detail pane rather than a sheet on
/// purpose: Extras installs DXVK/D3DMetal/winetricks, which can fail
/// through `AppState.report`, and an alert raised under a sheet is queued
/// invisibly (see `SheetPresence` in Components.swift). Nothing here
/// presents a sheet, so the root alert in `MainWindow` still covers every
/// failure; Logs also keeps its live refresh, which a modal would block.
///
/// The destination views are ProgramsGridView, GamesView, BottleConfigView,
/// PerformanceView, ExtrasView and LogViewerView; none of them is edited
/// here, only where they are mounted.
struct BottleDetailView: View {
    let bottleID: UUID
    @Environment(AppState.self) private var appState
    @Environment(ThemeStore.self) private var themeStore
    @State private var isConfiguring = false
    @State private var shelf: Shelf = .programs
    @State private var tuning: Tuning = .config
    @State private var isDropTargeted = false
    /// Cached `GameLibrary.scan` result, used only to decide whether the
    /// Games shelf exists and which shelf to land on — `GamesView` itself
    /// re-scans independently once shown. `nil` means the first scan has
    /// not finished: the library area shows a spinner meanwhile rather than
    /// defaulting to Programs, because landing on the executable list for a
    /// moment and then jumping to Games is exactly the flash this layout
    /// exists to remove. `MainWindow` gives this view `.id(bottleID)`, so
    /// every bottle starts from `nil`/library/landing-shelf state instead of
    /// inheriting the previous bottle's tab (this view used to keep its
    /// identity across bottle switches, which is why the scan was keyed
    /// on `.task(id:)`; that still holds as a second line of defence).
    @State private var hasGames: Bool?
    /// True while the tools menu's "Rescan programs" is running. The
    /// Programs shelf's own Rescan button disables itself while scanning, but
    /// this menu item had no such guard, so a second click started an
    /// overlapping scan whose merge could overwrite the first's result.
    @State private var isRescanning = false

    /// What you play from. `games` is only offered once a scan found one.
    enum Shelf: String, CaseIterable, Identifiable {
        case games = "Games"
        case programs = "Programs"
        var id: String { rawValue }
    }

    /// Everything you go and find rather than land on. Same four screens, same
    /// names as before the regroup.
    enum Tuning: String, CaseIterable, Identifiable {
        case config = "Config"
        case performance = "Performance"
        case extras = "Extras"
        case logs = "Logs"
        var id: String { rawValue }
    }

    private var bottle: Bottle? {
        appState.bottles.first { $0.id == bottleID }
    }

    private var isRunning: Bool {
        appState.runs.contains { $0.bottleID == bottleID && $0.isRunning }
    }

    var body: some View {
        if let bottle {
            VStack(alignment: .leading, spacing: 0) {
                header(bottle)

                modeBar
                    .padding(.top, Theme.Spacing.l)
                    .padding(.bottom, Theme.Spacing.outer)

                Group {
                    if isConfiguring {
                        switch tuning {
                        case .config:
                            BottleConfigView(bottleID: bottle.id)
                        case .performance:
                            PerformanceView(bottleID: bottle.id)
                        case .extras:
                            ExtrasView(bottleID: bottle.id)
                        case .logs:
                            LogViewerView(bottleID: bottle.id)
                        }
                    } else if let hasGames {
                        switch hasGames ? shelf : .programs {
                        case .games:
                            GamesView(bottleID: bottle.id)
                        case .programs:
                            ProgramsGridView(bottleID: bottle.id)
                        }
                    } else {
                        InlineProgress(text: "Loading library\u{2026}")
                            .padding(.top, Theme.Spacing.s)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(Theme.Spacing.outer)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .task(id: bottleID) {
                await refreshHasGames(bottle, landing: true)
            }
            // A game installed through a running installer only exists once
            // that run ends; without this the Games shelf stayed hidden until
            // the bottle was re-selected. Landing is untouched: a user already
            // on Programs is not yanked across the screen.
            .onChange(of: isRunning) { _, nowRunning in
                guard !nowRunning, let bottle = self.bottle else { return }
                Task { await refreshHasGames(bottle, landing: false) }
            }
            .background {
                if isDropTargeted {
                    Rectangle()
                        .fill(themeStore.current.badgeTint.opacity(0.08))
                }
            }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: Theme.Radius.card)
                        .strokeBorder(themeStore.current.accentGradient, lineWidth: 2)
                        .padding(Theme.Spacing.s)
                        .allowsHitTesting(false)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let target = urls.first(where: { isRunnableFile($0) }) else { return false }
                Task { await appState.run(exe: target, in: bottle) }
                return true
            } isTargeted: { targeted in
                isDropTargeted = targeted
            }
        } else {
            ContentUnavailableView("Bottle not found", systemImage: "questionmark.circle")
        }
    }

    /// Scans for games and, when `landing`, picks the shelf to open on:
    /// Games if the bottle has any, otherwise Programs. The bottle is
    /// re-checked after the await so a slow scan for the bottle just left
    /// cannot overwrite the one now showing.
    private func refreshHasGames(_ bottle: Bottle, landing: Bool) async {
        let found = !(await GameLibrary.scan(bottle: bottle).isEmpty)
        guard bottle.id == bottleID else { return }
        hasGames = found
        if landing {
            shelf = found ? .games : .programs
        } else if !found, shelf == .games {
            shelf = .programs
        }
    }

    /// The strip between the header and the content. Library mode: the
    /// Games/Programs picker (just a "Programs" label while the bottle has
    /// no games — a one-segment picker is a control with nothing to choose)
    /// and the Configure button on the far side. Configure mode: a way back
    /// that names where it goes, and the four configuration screens.
    @ViewBuilder
    private var modeBar: some View {
        HStack(spacing: Theme.Spacing.m) {
            if isConfiguring {
                Button {
                    isConfiguring = false
                } label: {
                    Label(shelf == .games && hasGames == true ? "Games" : "Programs", systemImage: "chevron.left")
                }
                .buttonStyle(.quietCompact)
                // Escape leaves configuration, the way it dismisses any
                // other secondary screen on the Mac.
                .keyboardShortcut(.cancelAction)
                .help("Back to this bottle's \(shelf == .games && hasGames == true ? "games" : "programs")")

                Picker("Configuration", selection: $tuning) {
                    ForEach(Tuning.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                // Sized to its labels rather than capped at a fixed width:
                // "Performance" was truncated in a 320pt control.
                .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
            } else {
                if hasGames == true {
                    Picker("Library", selection: $shelf) {
                        ForEach(Shelf.allCases) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize(horizontal: true, vertical: false)
                } else if hasGames == false {
                    SectionHeader(title: "Programs", systemImage: "list.bullet")
                }
                Spacer(minLength: 0)
                Button {
                    isConfiguring = true
                } label: {
                    Label("Configure", systemImage: "gearshape")
                }
                .buttonStyle(.quietCompact)
                .help("Config, Performance, Extras and Logs for this bottle")
            }
        }
    }

    private func isRunnableFile(_ url: URL) -> Bool {
        ["exe", "msi", "bat"].contains(url.pathExtension.lowercased())
    }

    /// Identity on the left, actions on the right. The hierarchy is: a glyph
    /// tile and the bottle's name (the only large type on the screen), then
    /// its facts as quiet chips, then the one accent control. The tile uses
    /// the same cylinder glyph as the sidebar row so the two read as the
    /// same object.
    @ViewBuilder
    private func header(_ bottle: Bottle) -> some View {
        HStack(alignment: .center, spacing: Theme.Spacing.m) {
            RoundedRectangle(cornerRadius: Theme.Radius.icon, style: .continuous)
                .fill(themeStore.current.badgeTint.opacity(Theme.Opacity.wash))
                .frame(width: Theme.Metrics.listRow, height: Theme.Metrics.listRow)
                .overlay {
                    Image(systemName: "cylinder")
                        .font(Theme.headingFont(18))
                        // `ink`, not the gradient: a glyph is thin, and
                        // `ink` is the palette colour that is safe as one.
                        .foregroundStyle(themeStore.current.ink)
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Theme.Spacing.compact) {
                Text(bottle.name)
                    .font(Theme.titleFont(24, weight: .semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.9)
                // Chips wrap (FlowLayout) instead of clipping when the
                // engine name is long. The full text stays in the tooltip.
                // (The old subtitle was selectable text; chips are not.)
                FlowLayout(spacing: Theme.Spacing.compact) {
                    if let engine = appState.engine(for: bottle) {
                        Chip(text: engine.displayName, systemImage: "gearshape.2")
                    } else {
                        // Warning wording and glyph, not colour alone.
                        Chip(text: "Engine missing", systemImage: "exclamationmark.triangle",
                             tint: Theme.Tone.warning.ink)
                    }
                    Chip(text: bottle.windowsVersion.displayName, systemImage: "macwindow")
                    if isRunning {
                        Chip(text: "Running", systemImage: "play.fill", tint: Theme.Tone.success.ink)
                    }
                }
                .help(subtitle(bottle))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(subtitle(bottle))
            }
            Spacer()
            HStack(spacing: Theme.Spacing.s) {
                // The one accent control on this screen — everything else
                // beside it (Stop, Configure, the tools menu) stays
                // quiet/bordered, in both modes: the header is shared, so
                // "Run .exe…" is one click away even inside Configure.
                Button("Run .exe…") { pickAndRun(bottle) }
                    .buttonStyle(.accentCompact)
                Button("Stop") {
                    Task { await appState.stopAll(in: bottle) }
                }
                .buttonStyle(.bordered)
                .disabled(!isRunning)
                toolsMenu(bottle)
            }
        }
    }

    /// The facts line as plain text — the chips' tooltip and VoiceOver label.
    private func subtitle(_ bottle: Bottle) -> String {
        var parts: [String] = []
        if let engine = appState.engine(for: bottle) {
            parts.append(engine.displayName)
        } else {
            parts.append("Engine missing")
        }
        parts.append(bottle.windowsVersion.displayName)
        if isRunning { parts.append("Running") }
        return parts.joined(separator: " \u{00b7} ")
    }

    @ViewBuilder
    private func toolsMenu(_ bottle: Bottle) -> some View {
        Menu {
            Button("winecfg") { appState.runTool(name: "winecfg", in: bottle) }
                .help("Wine's own settings window for this bottle — Windows version, drives, graphics, and virtual desktop.")
            Button("regedit") { appState.runTool(name: "regedit", in: bottle) }
                .help("Windows Registry Editor for this bottle.")
            Button("explorer") { appState.runTool(name: "explorer", in: bottle) }
                .help("A Windows-style file browser for this bottle's C: drive.")
            Button("Task Manager") { appState.runTool(name: "taskmgr", in: bottle) }
                .help("See or force-quit the Windows processes currently running in this bottle.")
            Divider()
            Button("Open C: drive in Finder") { appState.openDriveC(bottle) }
                .help("Reveal this bottle's C: drive as a normal Finder folder.")
            Divider()
            Button("Rescan programs") { Task { await rescanPrograms(bottle) } }
                .disabled(isRescanning)
                .help("Scan this bottle's Desktop, Start Menu, and Program Files again for newly installed programs.")
        } label: {
            Image(systemName: "ellipsis.circle")
                .frame(width: Theme.Metrics.iconButton, height: Theme.Metrics.iconButton)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("More tools")
        .accessibilityLabel("More tools")
    }

    private func rescanPrograms(_ bottle: Bottle) async {
        guard !isRescanning else { return }
        isRescanning = true
        defer { isRescanning = false }
        let scanned = await ProgramScanner.scan(bottle: bottle)
        let excluding = Set(bottle.removedPinPaths ?? [])
        let merged = ProgramScanner.merge(scanned: scanned, existing: bottle.pins, excluding: excluding)
        var updated = bottle
        updated.pins = merged
        updated.pinsSchemaVersion = ProgramScanner.schemaVersion
        appState.updateBottle(updated)
    }

    private func pickAndRun(_ bottle: Bottle) {
        let panel = NSOpenPanel()
        panel.title = "Choose a Windows program"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = runnableContentTypes()
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await appState.run(exe: url, in: bottle) }
        }
    }
}

/// Content types accepted by the "Run .exe…" and "Add program…" open
/// panels: the Windows-executable/MSI UTIs where the system recognizes
/// them, plus a plain extension fallback since those UTIs usually aren't
/// registered anywhere on a Mac that has never installed a matching app.
func runnableContentTypes() -> [UTType] {
    var types: [UTType] = []
    for identifier in ["com.microsoft.windows-executable", "com.microsoft.msi"] {
        if let type = UTType(identifier) { types.append(type) }
    }
    for ext in ["exe", "msi", "bat"] {
        if let type = UTType(filenameExtension: ext) { types.append(type) }
    }
    return types
}
