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

    enum Tab: String, CaseIterable, Identifiable {
        case programs = "Programs"
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
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                header(bottle)

                Picker("View", selection: $selectedTab) {
                    ForEach(Tab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 320)

                Group {
                    switch selectedTab {
                    case .programs:
                        ProgramsGridView(bottleID: bottle.id)
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
            .padding(Theme.Spacing.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            VStack(alignment: .leading, spacing: 6) {
                Text(bottle.name)
                    .font(Theme.titleFont())
                HStack(spacing: 8) {
                    if let engine = appState.engine(for: bottle) {
                        Chip(text: engine.displayName, systemImage: "gearshape.2")
                    } else {
                        Chip(text: "Engine missing", systemImage: "exclamationmark.triangle", tint: .orange)
                    }
                    Chip(text: bottle.windowsVersion.displayName, systemImage: "macwindow")
                    if isRunning {
                        Chip(text: "Running", systemImage: "play.fill", tint: .green)
                    }
                }
            }
            Spacer()
            HStack(spacing: Theme.Spacing.s) {
                toolsMenu(bottle)
                Button("Stop") {
                    Task { await appState.stopAll(in: bottle) }
                }
                .disabled(!isRunning)
                Button("Run .exe…") { pickAndRun(bottle) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private func toolsMenu(_ bottle: Bottle) -> some View {
        Menu {
            Button("winecfg") { appState.runTool(name: "winecfg", in: bottle) }
            Button("regedit") { appState.runTool(name: "regedit", in: bottle) }
            Button("explorer") { appState.runTool(name: "explorer", in: bottle) }
            Button("Task Manager") { appState.runTool(name: "taskmgr", in: bottle) }
            Divider()
            Button("Open C: Drive in Finder") { appState.openDriveC(bottle) }
        } label: {
            Label("Tools", systemImage: "wrench.and.screwdriver")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
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
