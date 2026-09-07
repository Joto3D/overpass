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
    @Environment(\.dismiss) private var dismiss

    @State private var sources: [BottleImporter.Source] = []
    @State private var selectedSourceID: URL?
    @State private var name: String = ""
    @State private var engineID: String = ""
    @State private var windowsVersion: WindowsVersion = .win10
    @State private var chooseError: String?

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
                    .font(Theme.titleFont(18))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
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
                    Text(chooseError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if selectedSource != nil {
                    form
                }
                if let error = importState.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
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
        .frame(width: 620)
        .onAppear(perform: refresh)
        .onChange(of: selectedSourceID) { _, _ in prefillForSelection() }
    }

    // MARK: - Source list

    private var sourceList: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            SectionHeader(title: "Found Bottles", systemImage: "shippingbox")

            if sources.isEmpty {
                Text("No CrossOver, Whisky, or Wine bottles were found in their usual locations.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(sources) { source in
                        sourceRow(source)
                    }
                }
            }

            Button("Choose Folder…") { chooseFolder() }
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
                VStack(alignment: .leading, spacing: 1) {
                    Text(source.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(pathTail(source.prefixDir))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
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
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04))
            }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1.5)
            }
        }
        .buttonStyle(.plain)
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
                Picker("Windows Version", selection: $windowsVersion) {
                    ForEach(WindowsVersion.allCases) { version in
                        Text(version.displayName).tag(version)
                    }
                }
            }
            .formStyle(.grouped)

            if let kind = appState.installedEngines.first(where: { $0.id == engineID })?.kind {
                Text(engineTradeoffCaption(for: kind))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.Spacing.s)
            }
        }
    }

    private var progressBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack(spacing: Theme.Spacing.s) {
                ProgressView().controlSize(.small)
                Text(importState.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, Theme.Spacing.s)
    }

    // MARK: - Actions

    private func refresh() {
        sources = BottleImporter.discover()
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
