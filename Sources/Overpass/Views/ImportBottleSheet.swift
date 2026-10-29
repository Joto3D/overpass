import SwiftUI
import AppKit

/// Sheet for importing a Wine prefix from another launcher (CrossOver,
/// Whisky, Wineskin) or a bare `~/.wine` as a new Overpass bottle. Lists
/// what `BottleImporter.discover()` finds plus a "Choose folder…" escape
/// hatch for anything not in a well-known location, then a small form
/// (name / engine / Windows version) and an Import button that streams
/// `BottleImportState.shared.status` while the copy/adopt/scan runs.
struct ImportBottleSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeStore.self) private var themeStore
    @Environment(\.dismiss) private var dismiss

    @State private var sources: [BottleImporter.Source] = []
    @State private var selectedSourceID: URL?
    @State private var name: String = ""
    @State private var engineID: String = ""
    @State private var windowsVersion: WindowsVersion = .win10
    @State private var chooseError: String?
    /// True while `refresh()` is scanning, so an empty list is not
    /// mistaken for "nothing found".
    @State private var isScanning = false

    private let importState = BottleImportState.shared

    private var selectedSource: BottleImporter.Source? {
        sources.first { $0.id == selectedSourceID }
    }

    private var canImport: Bool {
        !importState.isImporting
            && selectedSource != nil
            && !engineID.isEmpty
            && !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            HStack {
                Text("Import Bottle")
                    .font(Theme.sheetTitleFont)
                Spacer()
                SheetCloseButton { dismiss() }
                    .disabled(importState.isImporting)
            }

            if appState.installedEngines.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    Text("No engines are installed yet. Install one from the Engines screen first.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Go to Engines") {
                        appState.selection = .engines
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                }
            } else if importState.isImporting {
                progressBlock
            } else {
                sourceList
                if let chooseError {
                    ErrorText(chooseError)
                }
                if selectedSource != nil {
                    form
                }
                if let error = importState.lastError {
                    ErrorText(error)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .disabled(importState.isImporting)
                if !appState.installedEngines.isEmpty && !importState.isImporting {
                    Button("Import") { Task { await performImport() } }
                        .buttonStyle(.accent)
                        .fixedSize()
                        .disabled(!canImport)
                }
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(width: Theme.Metrics.wideSheetWidth)
        // Cancel and the close button are disabled during an import, but
        // Escape would still dismiss the sheet over a running copy; this
        // makes Escape agree with them.
        .interactiveDismissDisabled(importState.isImporting)
        // A failed import is also reported through `AppState`; show that
        // alert here rather than behind the sheet.
        .hostsErrorAlert()
        .task { await refresh() }
        .onChange(of: selectedSourceID) { _, _ in prefillForSelection() }
    }

    // MARK: - Source list

    private var sourceList: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            SectionHeader(title: "Found Bottles", systemImage: "shippingbox")

            if sources.isEmpty && isScanning {
                InlineProgress(text: "Looking for bottles…")
            } else if sources.isEmpty {
                Text("No CrossOver, Whisky, or Wine bottles were found in their usual locations.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: Theme.Spacing.compact) {
                    ForEach(sources) { source in
                        sourceRow(source)
                    }
                }
            }

            Button("Choose folder…") { chooseFolder() }
                .buttonStyle(.quiet)
        }
    }

    private func sourceRow(_ source: BottleImporter.Source) -> some View {
        let isSelected = source.id == selectedSourceID
        return Button {
            selectedSourceID = source.id
        } label: {
            HStack(spacing: Theme.Spacing.s) {
                Chip(text: source.kind.displayName, systemImage: kindIcon(source.kind), tint: .secondary)
                VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                    Text(source.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    // Only the last three path components fit; the tooltip
                    // carries the whole path.
                    Text(pathTail(source.prefixDir))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .help(source.prefixDir.path)
                }
                Spacer()
                if let sizeBytes = source.sizeBytes {
                    Text(ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(Theme.Spacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .fill(isSelected ? themeStore.current.badgeTint.opacity(Theme.Opacity.wash) : Color.primary.opacity(0.04))
            }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .strokeBorder(isSelected ? themeStore.current.badgeTint.opacity(0.6) : .clear, lineWidth: 1.5)
            }
        }
        .buttonStyle(.plain)
        // Selection is drawn only as a tint and outline.
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func kindIcon(_ kind: BottleImporter.Kind) -> String {
        switch kind {
        case .crossOver: return "arrow.triangle.2.circlepath"
        case .whisky: return "wineglass"
        case .wineskin: return "shippingbox"
        case .genericPrefix: return "folder"
        }
    }

    private func pathTail(_ url: URL, components: Int = 3) -> String {
        let parts = url.standardizedFileURL.pathComponents
        return "…/" + parts.suffix(components).joined(separator: "/")
    }

    // MARK: - Form

    private var form: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Form {
                TextField("Name", text: $name)
                Picker("Engine", selection: $engineID) {
                    ForEach(appState.installedEngines) { engine in
                        Text(engine.displayName).tag(engine.id)
                    }
                }
                Picker("Windows version", selection: $windowsVersion) {
                    ForEach(WindowsVersion.allCases) { version in
                        Text(version.displayName).tag(version)
                    }
                }
            }
            .formStyle(.grouped)

            if let kind = appState.installedEngines.first(where: { $0.id == engineID })?.kind {
                EngineTradeoffNote(kind: kind)
                    .padding(.horizontal, Theme.Spacing.s)
            }
        }
    }

    private var progressBlock: some View {
        InlineProgress(text: importState.status)
            .padding(.vertical, Theme.Spacing.s)
    }

    // MARK: - Actions

    /// Scans for importable bottles without blocking the main actor.
    ///
    /// This used to call the synchronous `BottleImporter.discover()`,
    /// which walks every prefix to size it: measured at 86 ms before the
    /// concurrency pass and 39 ms after, on a machine with only two small
    /// prefixes, and it grows with the number and size of CrossOver
    /// prefixes. That stalled the main thread while the sheet was
    /// animating in. `discoverAsync()` was added for exactly this and runs
    /// the same work on a detached task with an identical result.
    ///
    /// Loading state: the sheet has no spinner, and `sourceList` shows
    /// "No CrossOver, Whisky, or Wine bottles were found" whenever
    /// `sources` is empty, so awaiting would flash that false message for
    /// the duration of the scan. `isScanning` suppresses it and shows an
    /// `InlineProgress` instead. It is cleared in all cases, and the
    /// result is merged rather than assigned so a folder the user picked
    /// with "Choose folder…" while the scan was running is not dropped.
    /// The initial selection is only made if the user has not already
    /// chosen something.
    ///
    /// Not verified here: the visual timing of the spinner (no UI session
    /// available to the agent that made this change); the logic is
    /// straight-line and the build is clean.
    private func refresh() async {
        isScanning = true
        defer { isScanning = false }
        let found = await BottleImporter.discoverAsync()
        let chosen = sources
        sources = chosen + found.filter { f in !chosen.contains { $0.id == f.id } }
        if selectedSourceID == nil {
            selectedSourceID = sources.first?.id
        }
    }

    private func prefillForSelection() {
        guard let source = selectedSource else { return }
        name = source.name
        windowsVersion = source.windowsVersion ?? .win10
        if engineID.isEmpty {
            engineID = appState.installedEngines.first?.id ?? ""
        }
    }

    private func chooseFolder() {
        chooseError = nil
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a Wine prefix folder (contains drive_c and system.reg)."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let source = BottleImporter.validate(url) else {
            chooseError = "\"\(url.lastPathComponent)\" doesn't look like a Wine prefix (no drive_c/system.reg)."
            return
        }
        if !sources.contains(where: { $0.id == source.id }) {
            sources.insert(source, at: 0)
        }
        selectedSourceID = source.id
    }

    private func performImport() async {
        guard let source = selectedSource else { return }
        let importName = name.trimmingCharacters(in: .whitespaces)
        await appState.importBottle(from: source, name: importName, engineID: engineID, windowsVersion: windowsVersion)
        if BottleImportState.shared.lastError == nil {
            dismiss()
        }
    }
}
