import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// A bottle's "Programs" tab: a grid of launchable pins (scanned from the
/// bottle's Desktop/Start Menu/Program Files, plus anything the user has
/// added by hand), a search field, Rescan/Add toolbar, and a "System"
/// section for the built-in Wine tools that don't live inside `drive_c`
/// at all (Notepad, WordPad, Explorer, Task Manager, Control Panel).
struct ProgramsGridView: View {
    let bottleID: UUID
    @Environment(AppState.self) private var appState

    @State private var searchText = ""
    @State private var isScanning = false
    @State private var isSystemExpanded = false
    @State private var editingPin: PinnedProgram?
    @State private var editingArgs = ""

    private let columns = [GridItem(.adaptive(minimum: 148, maximum: 180), spacing: Theme.Spacing.m)]

    private var bottle: Bottle? {
        appState.bottles.first { $0.id == bottleID }
    }

    private var filteredPins: [PinnedProgram] {
        guard let bottle else { return [] }
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return bottle.pins }
        return bottle.pins.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        if let bottle {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                toolbar(bottle)

                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                        if bottle.pins.isEmpty {
                            emptyState
                        } else if filteredPins.isEmpty {
                            Text("No programs match \u{201c}\(searchText)\u{201d}.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.top, Theme.Spacing.xl)
                        } else {
                            LazyVGrid(columns: columns, spacing: Theme.Spacing.m) {
                                ForEach(filteredPins) { pin in
                                    ProgramCard(pin: pin, bottle: bottle, onEditArgs: { beginEditingArgs(pin) })
                                }
                            }
                        }

                        systemSection(bottle)
                    }
                    .padding(.bottom, Theme.Spacing.xl)
                }
            }
            .sheet(item: $editingPin) { pin in
                editArgsSheet(pin: pin, bottle: bottle)
            }
        } else {
            ContentUnavailableView("Bottle not found", systemImage: "questionmark.circle")
        }
    }

    // MARK: - Toolbar

    private func toolbar(_ bottle: Bottle) -> some View {
        HStack(spacing: Theme.Spacing.s) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search programs", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, Theme.Spacing.s)
            .padding(.vertical, 6)
            .frame(maxWidth: 240)
            .overpassCard(cornerRadius: Theme.Radius.row)

            Spacer()

            if isScanning {
                ProgressView().controlSize(.small)
            }

            Button {
                Task { await rescan(bottle) }
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.quiet)
            .disabled(isScanning)

            Button {
                addProgram(bottle)
            } label: {
                Label("Add program\u{2026}", systemImage: "plus")
            }
            .buttonStyle(.bordered)
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.s) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("No programs found yet.")
                .font(Theme.headingFont(15))
            Text("Install something with Run .exe\u{2026} or Rescan.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Spacing.xl * 2)
    }

    // MARK: - System tools section

    private func systemSection(_ bottle: Bottle) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            DisclosureGroup(isExpanded: $isSystemExpanded) {
                LazyVGrid(columns: columns, spacing: Theme.Spacing.m) {
                    ForEach(Self.systemTools, id: \.toolName) { tool in
                        SystemToolCard(name: tool.displayName, symbol: tool.symbol) {
                            appState.runTool(name: tool.toolName, in: bottle)
                        }
                    }
                }
                .padding(.top, Theme.Spacing.s)
            } label: {
                SectionHeader(title: "System", systemImage: "wrench.and.screwdriver")
            }
        }
    }

    private static let systemTools: [(toolName: String, displayName: String, symbol: String)] = [
        ("notepad", "Notepad", "note.text"),
        ("wordpad", "WordPad", "doc.richtext"),
        ("explorer", "Explorer", "folder"),
        ("taskmgr", "Task Manager", "chart.bar"),
        ("control", "Control Panel", "slider.horizontal.3"),
    ]

    // MARK: - Actions

    private func rescan(_ bottle: Bottle) async {
        isScanning = true
        defer { isScanning = false }
        let scanned = await ProgramScanner.scan(bottle: bottle)
        let merged = ProgramScanner.merge(scanned: scanned, existing: bottle.pins)
        var updated = bottle
        updated.pins = merged
        appState.updateBottle(updated)
    }

    private func addProgram(_ bottle: Bottle) {
        let panel = NSOpenPanel()
        panel.title = "Choose a Windows program"
        panel.allowedContentTypes = [UTType(filenameExtension: "exe") ?? .item]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = bottle.driveC

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let pin = PinnedProgram(name: url.deletingPathExtension().lastPathComponent, exePath: url.path, isUserAdded: true)
        var updated = bottle
        updated.pins.append(pin)
        appState.updateBottle(updated)
    }

    private func beginEditingArgs(_ pin: PinnedProgram) {
        editingArgs = pin.args
        editingPin = pin
    }

    private func editArgsSheet(pin: PinnedProgram, bottle: Bottle) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            Text("Arguments for \(pin.name)")
                .font(Theme.titleFont(16))
            TextField("Command-line arguments", text: $editingArgs)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { editingPin = nil }
                Button("Save") {
                    var updated = bottle
                    if let index = updated.pins.firstIndex(where: { $0.id == pin.id }) {
                        updated.pins[index].args = editingArgs
                    }
                    appState.updateBottle(updated)
                    editingPin = nil
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 380)
    }
}

// MARK: - Program card

private struct ProgramCard: View {
    @Environment(AppState.self) private var appState
    let pin: PinnedProgram
    let bottle: Bottle
    let onEditArgs: () -> Void

    private var pathTail: String {
        let components = pin.exePath.split(separator: "/")
        return components.suffix(2).joined(separator: "/")
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.s) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.icon, style: .continuous)
                    .fill(.regularMaterial)
                Image(systemName: "app.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 56, height: 56)

            Text(pin.name)
                .font(Theme.headingFont(13))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity)

            Text(pathTail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Button("Run") {
                run()
            }
            .buttonStyle(.quiet)
            .controlSize(.small)
        }
        .padding(Theme.Spacing.m)
        .overpassCard()
        .contextMenu {
            Button("Run") { run() }
            Button("Edit arguments\u{2026}") { onEditArgs() }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: pin.exePath)])
            }
            Divider()
            Button("Remove pin", role: .destructive) { removePin() }
        }
    }

    private func run() {
        Task { await appState.run(exe: URL(fileURLWithPath: pin.exePath), args: pin.args, in: bottle) }
    }

    private func removePin() {
        var updated = bottle
        updated.pins.removeAll { $0.id == pin.id }
        appState.updateBottle(updated)
    }
}

// MARK: - System tool card

private struct SystemToolCard: View {
    let name: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: Theme.Spacing.s) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.Radius.icon, style: .continuous)
                        .fill(.regularMaterial)
                    Image(systemName: symbol)
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 56, height: 56)

                Text(name)
                    .font(Theme.headingFont(13))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .padding(Theme.Spacing.m)
            .overpassCard()
        }
        .buttonStyle(.plain)
    }
}
