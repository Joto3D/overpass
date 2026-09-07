import SwiftUI
import AppKit

/// Log files for one bottle: a list of runs (newest first) and the
/// selected file's tail in a monospaced, selectable text view. Auto-
/// refreshes every second while a run is active for this bottle.
struct LogViewerView: View {
    let bottleID: UUID
    @Environment(AppState.self) private var appState
    @State private var logFiles: [URL] = []
    @State private var selected: URL?
    @State private var content: String = ""
    @State private var showTroubleshooting = false

    private var isBottleRunning: Bool {
        appState.runs.contains { $0.bottleID == bottleID && $0.isRunning }
    }

    var body: some View {
        HStack(spacing: 0) {
            List(logFiles, id: \.self, selection: $selected) { url in
                Text(LogFileName.displayName(for: url))
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .tag(url)
            }
            .frame(width: 220)
            .padding(.trailing, Theme.Spacing.s)
            // `.sidebar` pulls in the system's vibrant sidebar material,
            // which is meant for the outermost window sidebar — nested
            // inside a detail view it renders with a tint that doesn't
            // track Theme's dark surface, so it visibly clashes with the
            // rest of the app. `.plain` (with the system list background
            // hidden) keeps it flush with Theme's own background instead.
            .listStyle(.plain)
            .scrollContentBackground(.hidden)

            Divider()

            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                HStack {
                    Text(selected.map { LogFileName.displayName(for: $0) } ?? "No log selected")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Program won't start?") { showTroubleshooting = true }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .popover(isPresented: $showTroubleshooting) {
                            troubleshootingContent
                        }
                    Button("Copy Log") { copyLog() }
                        .buttonStyle(.quiet)
                        .fixedSize()
                        .disabled(selected == nil || content.isEmpty)
                    Button("Reveal in Finder") { reveal() }
                        .buttonStyle(.quiet)
                        .fixedSize()
                        .disabled(selected == nil)
                    Button("Clear Logs") { clearLogs() }
                        .buttonStyle(.quiet)
                        .fixedSize()
                        .disabled(logFiles.isEmpty)
                }

                ScrollView {
                    Text(content.isEmpty ? "No output yet." : content)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(content.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Theme.Spacing.m)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overpassCard(cornerRadius: Theme.Radius.row)
            }
            .padding(Theme.Spacing.m)
        }
        // Keyed on `bottleID` (not a bare `.task { }`) so switching the
        // sidebar selection while already on the Logs tab re-runs this —
        // `BottleDetailView` reuses the same `LogViewerView` instance
        // across bottles (its identity doesn't change, only the
        // `bottleID` parameter does), so without this the list/content
        // silently kept showing the previous bottle's logs.
        .task(id: bottleID) { refresh() }
        .onChange(of: selected) { _, _ in loadSelectedContent() }
        .task(id: isBottleRunning) {
            guard isBottleRunning else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                refresh()
            }
        }
    }

    /// The troubleshooting the app's owner has actually needed, collected
    /// in one place next to the tab where the evidence (the log) lives —
    /// rather than as a wall of text nobody reads until something breaks.
    private var troubleshootingContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            troubleshootingItem(
                "Black or invisible window",
                "Try a virtual desktop (⋯ menu → winecfg → Graphics), turn DXVK off (Extras tab), or switch engines (Engines screen)."
            )
            troubleshootingItem(
                "Program won't start at all",
                "Check the log on the left for the last error line — it usually names the missing DLL or the crash."
            )
            troubleshootingItem(
                "Fonts or installers failing",
                "Several Winetricks verbs and installers need cabextract. If it's missing, run in Terminal: brew install cabextract"
            )
        }
        .frame(width: 300, alignment: .leading)
        .padding(Theme.Spacing.m)
    }

    private func troubleshootingItem(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
            Text(body)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func refresh() {
        logFiles = LogStore.logs(for: bottleID)
        if selected == nil || !logFiles.contains(where: { $0 == selected }) {
            selected = logFiles.first
        }
        loadSelectedContent()
    }

    private func loadSelectedContent() {
        guard let selected else {
            content = ""
            return
        }
        content = LogStore.tail(selected)
    }

    private func reveal() {
        guard let selected else { return }
        NSWorkspace.shared.activateFileViewerSelecting([selected])
    }

    private func copyLog() {
        guard !content.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(content, forType: .string)
    }

    private func clearLogs() {
        let dir = Paths.logs.appendingPathComponent(bottleID.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        selected = nil
        content = ""
        refresh()
    }
}
