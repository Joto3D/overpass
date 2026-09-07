import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// A bottle's detail screen: header (name/engine/Windows version, Run/Stop,
/// tools menu), and a Programs / Config / Logs tab picker. The whole view
/// is a drop target for `.exe`/`.msi` files.
///
/// Tabs are provided by ProgramsGridView, BottleConfigView, PerformanceView,
/// ExtrasView and LogViewerView. (Historical note:
/// small and self-contained so another pass (program scanning, richer
/// config) can replace them without touching this file's layout.
struct BottleDetailView: View {
    let bottleID: UUID
    @Environment(AppState.self) private var appState
    @Environment(ThemeStore.self) private var themeStore
    @State private var selectedTab: Tab = .programs
    @State private var isDropTargeted = false
    /// Cached `GameLibrary.scan` result, used only to decide whether the
    /// Games tab appears at all — `GamesView` itself re-scans
    /// independently once shown. Rescanned on `.task(id: bottleID)`
    /// rather than a plain `.task`: this view keeps its SwiftUI identity
    /// across bottle switches (only `bottleID` changes), so a bare
    /// `.task` would never refire and the tab would keep reflecting
    /// whichever bottle was selected first.
    @State private var hasGames = false

    enum Tab: String, CaseIterable, Identifiable {
        case programs = "Programs"
        case games = "Games"
        case config = "Config"
        case performance = "Performance"
        case extras = "Extras"
        case logs = "Logs"
        var id: String { rawValue }
    }

    private var visibleTabs: [Tab] {
        Tab.allCases.filter { $0 != .games || hasGames }
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

                Picker("View", selection: $selectedTab) {
                    ForEach(visibleTabs) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 320, alignment: .leading)
                .padding(.top, Theme.Spacing.l)
                .padding(.bottom, Theme.Spacing.outer)

                Group {
                    switch selectedTab {
                    case .programs:
                        ProgramsGridView(bottleID: bottle.id)
                    case .games:
                        GamesView(bottleID: bottle.id)
                    case .config:
                        BottleConfigView(bottleID: bottle.id)
                    case .performance:
                        PerformanceView(bottleID: bottle.id)
                    case .extras:
                        ExtrasView(bottleID: bottle.id)
                    case .logs:
                        LogViewerView(bottleID: bottle.id)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(Theme.Spacing.outer)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .task(id: bottleID) {
                hasGames = !(await GameLibrary.scan(bottle: bottle).isEmpty)
                if !hasGames, selectedTab == .games {
                    selectedTab = .programs
                }
            }
            .background {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 0)
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

    private func isRunnableFile(_ url: URL) -> Bool {
        ["exe", "msi", "bat"].contains(url.pathExtension.lowercased())
    }

    @ViewBuilder
    private func header(_ bottle: Bottle) -> some View {
        HStack(alignment: .center, spacing: Theme.Spacing.m) {
            VStack(alignment: .leading, spacing: 3) {
                Text(bottle.name)
                    .font(Theme.titleFont(22, weight: .semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.9)
                Text(subtitle(bottle))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            HStack(spacing: Theme.Spacing.s) {
                // The one accent control on this screen — everything else
                // beside it (Stop, the tools menu) stays quiet/bordered.
                Button("Run .exe…") { pickAndRun(bottle) }
                    .buttonStyle(.accent)
                    .fixedSize()
                Button("Stop") {
                    Task { await appState.stopAll(in: bottle) }
                }
                .buttonStyle(.bordered)
                .disabled(!isRunning)
                toolsMenu(bottle)
            }
        }
    }

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
            Button("regedit") { appState.runTool(name: "regedit", in: bottle) }
            Button("explorer") { appState.runTool(name: "explorer", in: bottle) }
            Button("Task Manager") { appState.runTool(name: "taskmgr", in: bottle) }
            Divider()
            Button("Open C: drive in Finder") { appState.openDriveC(bottle) }
            Divider()
            Button("Rescan programs") { Task { await rescanPrograms(bottle) } }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("More tools")
    }

    private func rescanPrograms(_ bottle: Bottle) async {
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
