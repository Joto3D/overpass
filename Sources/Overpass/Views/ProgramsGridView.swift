import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// A bottle's "Programs" tab: a full-width list of launchable pins
/// (scanned from the bottle's Desktop/Start Menu/Program Files, plus
/// anything the user has added by hand or launched at least once), a
/// compact search + filter + rescan/add toolbar, and — via a filter menu —
/// the option to reveal system and helper pins that are hidden by default.
///
/// On first appearance for a bottle whose `pinsSchemaVersion` predates
/// `ProgramScanner.schemaVersion`, this runs one background migration scan
/// (see `migrateIfNeeded`) so pins written by an older scanner — stale
/// case/bitness duplicates, unclassified system/helper entries — get
/// cleaned up without the user having to notice or ask for it.
struct ProgramsGridView: View {
    let bottleID: UUID
    @Environment(AppState.self) private var appState

    @State private var searchText = ""
    @State private var isScanning = false
    @State private var isMigrating = false
    @State private var editingPin: PinnedProgram?
    @State private var editingArgs = ""
    @State private var selectedPinID: PinnedProgram.ID?

    @AppStorage("overpass.programs.showAll") private var showAllPrograms = false
    @AppStorage("overpass.programs.showSystem") private var showSystem = false
    @AppStorage("overpass.programs.showHelpers") private var showHelpers = false

    private var bottle: Bottle? {
        appState.bottles.first { $0.id == bottleID }
    }

    /// Shortcut-backed-by-default (CrossOver/Heroic-style): only
    /// `.shortcut`/`.catalogApp`/`.user`-origin pins show unless "Show all
    /// programs" is on. See `ProgramScanner.defaultVisiblePins` — it also
    /// guarantees this never comes back empty while `bottle.pins` isn't.
    private var visiblePins: [PinnedProgram] {
        guard let bottle else { return [] }
        return ProgramScanner.defaultVisiblePins(bottle.pins, showSystem: showSystem, showHelpers: showHelpers, showAll: showAllPrograms)
    }

    private var filteredPins: [PinnedProgram] {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return visiblePins }
        return visiblePins.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        if let bottle {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                toolbar(bottle)

                if isMigrating {
                    Text("Updating program list\u{2026}")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if bottle.pins.isEmpty {
                    emptyState("Drop an .exe here, or use Run .exe\u{2026}, to pin your first program.")
                } else if filteredPins.isEmpty {
                    emptyState("No programs match \u{201c}\(searchText)\u{201d}.")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filteredPins) { pin in
                                ProgramRow(
                                    pin: pin,
                                    bottle: bottle,
                                    isSelected: selectedPinID == pin.id,
                                    onSelect: { selectedPinID = pin.id },
                                    onEditArgs: { beginEditingArgs(pin) }
                                )
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
            .task(id: bottleID) {
                await migrateIfNeeded(bottle)
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
            .frame(maxWidth: .infinity)
            .frame(height: Theme.Metrics.toolbarControl)
            .overpassCard(cornerRadius: Theme.Radius.row)

            if isScanning {
                ProgressView().controlSize(.small)
            }

            Menu {
                Toggle("Show all programs", isOn: $showAllPrograms)
                    .help("Skip the curated list below and show everything Overpass found, including entries normally hidden.")
                Divider()
                Toggle("Show system programs", isOn: $showSystem)
                    .help("Windows components like Control Panel and Registry Editor, not something you'd normally launch.")
                Toggle("Show helper executables", isOn: $showHelpers)
                    .help("Background/updater executables bundled with an app, not the app itself.")
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .frame(width: Theme.Metrics.toolbarControl, height: Theme.Metrics.toolbarControl)
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

    private func emptyState(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.top, Theme.Spacing.xl * 2)
    }

    // MARK: - Actions

    /// Runs once per bottle appearance: if `bottle.pinsSchemaVersion`
    /// doesn't match `ProgramScanner.schemaVersion` (including a bottle
    /// that predates the property entirely, decoding to `nil`), rescans
    /// and re-merges so every pin's classification/dedupe gets refreshed
    /// under the current rules, then stamps the bottle with the current
    /// schema version so this doesn't repeat on every visit.
    private func migrateIfNeeded(_ bottle: Bottle) async {
        guard bottle.pinsSchemaVersion != ProgramScanner.schemaVersion else { return }
        isMigrating = true
        defer { isMigrating = false }

        let scanned = await ProgramScanner.scan(bottle: bottle)
        let excluding = Set(bottle.removedPinPaths ?? [])
        let merged = ProgramScanner.merge(scanned: scanned, existing: bottle.pins, excluding: excluding)

        // Re-fetch in case something else updated the bottle while the
        // scan was running off the main actor.
        guard let current = appState.bottles.first(where: { $0.id == bottle.id }) else { return }
        var updated = current
        updated.pins = merged
        updated.pinsSchemaVersion = ProgramScanner.schemaVersion
        appState.updateBottle(updated)
    }

    private func rescan(_ bottle: Bottle) async {
        isScanning = true
        defer { isScanning = false }
        let scanned = await ProgramScanner.scan(bottle: bottle)
        let excluding = Set(bottle.removedPinPaths ?? [])
        let merged = ProgramScanner.merge(scanned: scanned, existing: bottle.pins, excluding: excluding)
        var updated = bottle
        updated.pins = merged
        updated.pinsSchemaVersion = ProgramScanner.schemaVersion
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

        var updated = bottle
        let key = ProgramScanner.dedupeKey(url.path)

        // "Add program…" is also how a previously-removed pin comes back.
        if let removed = updated.removedPinPaths, !removed.isEmpty {
            let filtered = removed.filter { ProgramScanner.dedupeKey($0) != key }
            if filtered.count != removed.count {
                updated.removedPinPaths = filtered
            }
        }

        guard !updated.pins.contains(where: { ProgramScanner.dedupeKey($0.exePath) == key }) else {
            appState.updateBottle(updated)
            selectedPinID = updated.pins.first { ProgramScanner.dedupeKey($0.exePath) == key }?.id
            return
        }

        var pin = PinnedProgram(
            name: ProgramScanner.derivedPinName(fromBaseName: url.deletingPathExtension().lastPathComponent),
            exePath: url.path,
            isUserAdded: true
        )
        pin = ProgramScanner.applyCatalogDefaults(to: pin)
        updated.pins.append(pin)
        appState.updateBottle(updated)
        selectedPinID = pin.id
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
    @Environment(ThemeStore.self) private var themeStore
    let pin: PinnedProgram
    let bottle: Bottle
    let isSelected: Bool
    let onSelect: () -> Void
    let onEditArgs: () -> Void
    @State private var isHovering = false

    private var subtitle: String {
        pathRelativeToDriveC(pin.exePath, bottle: bottle)
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: pin.isSystem ? "gearshape" : "app.fill")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 16)

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
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: Theme.Spacing.m)

            if isHovering {
                Button(action: run) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .fixedSize()
                .help("Run")
            }
        }
        .padding(.horizontal, Theme.Spacing.m)
        .frame(height: Theme.Metrics.listRow)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .fill(themeStore.current.badgeTint.opacity(0.14))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { run() }
        .onTapGesture(count: 1) { onSelect() }
        .onHover { isHovering = $0 }
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
        var removed = Set((updated.removedPinPaths ?? []).map { $0.lowercased() })
        removed.insert(pin.exePath.lowercased())
        updated.removedPinPaths = Array(removed)
        appState.updateBottle(updated)
    }
}
