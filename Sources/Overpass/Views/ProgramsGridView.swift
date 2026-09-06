import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// A bottle's "Programs" tab: a full-width list of launchable pins
/// (scanned from the bottle's Desktop/Start Menu/Program Files, plus
/// anything the user has added by hand), a compact search + filter +
/// rescan/add toolbar, and — via a filter menu — the option to reveal
/// system and helper pins that are hidden by default.
struct ProgramsGridView: View {
    let bottleID: UUID
    @Environment(AppState.self) private var appState

    @State private var searchText = ""
    @State private var isScanning = false
    @State private var editingPin: PinnedProgram?
    @State private var editingArgs = ""

    @AppStorage("overpass.programs.showSystem") private var showSystem = false
    @AppStorage("overpass.programs.showHelpers") private var showHelpers = false

    private var bottle: Bottle? {
        appState.bottles.first { $0.id == bottleID }
    }

    private var visiblePins: [PinnedProgram] {
        guard let bottle else { return [] }
        return bottle.pins.filter { pin in
            if pin.isSystem && !showSystem { return false }
            if pin.isHelper && !showHelpers { return false }
            return true
        }
    }

    private var filteredPins: [PinnedProgram] {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return visiblePins }
        return visiblePins.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        if let bottle {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                toolbar(bottle)

                if bottle.pins.isEmpty {
                    emptyState(message: "No programs found yet.", detail: "Install something with Run .exe\u{2026} or Rescan.")
                } else if filteredPins.isEmpty {
                    emptyState(
                        message: "No programs match \u{201c}\(searchText)\u{201d}.",
                        detail: nil
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filteredPins) { pin in
                                ProgramRow(pin: pin, bottle: bottle, onEditArgs: { beginEditingArgs(pin) })
                                if pin.id != filteredPins.last?.id {
                                    Divider()
                                }
                            }
                        }
                        .overpassCard(cornerRadius: Theme.Radius.card)
                    }
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
            .frame(maxWidth: .infinity)
            .overpassCard(cornerRadius: Theme.Radius.row)

            if isScanning {
                ProgressView().controlSize(.small)
            }

            Menu {
                Toggle("Show system programs", isOn: $showSystem)
                Toggle("Show helper executables", isOn: $showHelpers)
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Filter programs")

            IconToolbarButton(systemImage: "arrow.clockwise", help: "Rescan") {
                Task { await rescan(bottle) }
            }
            .disabled(isScanning)

            IconToolbarButton(systemImage: "plus", help: "Add program\u{2026}") {
                addProgram(bottle)
            }
        }
    }

    private func emptyState(message: String, detail: String?) -> some View {
        VStack(spacing: 4) {
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Spacing.xl * 2)
    }

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

// MARK: - Program row

private struct ProgramRow: View {
    @Environment(AppState.self) private var appState
    let pin: PinnedProgram
    let bottle: Bottle
    let onEditArgs: () -> Void

    private var subtitle: String {
        pathRelativeToDriveC(pin.exePath, bottle: bottle)
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.regularMaterial)
                Image(systemName: pin.isSystem ? "gearshape" : "app.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(pin.name)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    if pin.isSystem {
                        Chip(text: "System", tint: .secondary)
                    }
                }
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: Theme.Spacing.m)

            Button("Run") { run() }
                .buttonStyle(.quiet)
                .controlSize(.small)
                .fixedSize()
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.s)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { run() }
        .contextMenu {
            Button("Run") { run() }
            Button("Edit Arguments\u{2026}") { onEditArgs() }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: pin.exePath)])
            }
            Divider()
            Button("Remove", role: .destructive) { removePin() }
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
