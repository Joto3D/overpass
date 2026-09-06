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

    private var isBottleRunning: Bool {
        appState.runs.contains { $0.bottleID == bottleID && $0.isRunning }
    }

    var body: some View {
        HStack(spacing: 0) {
            List(logFiles, id: \.self, selection: $selected) { url in
                Text(url.lastPathComponent)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .tag(url)
            }
            .frame(width: 220)
            .listStyle(.sidebar)

            Divider()

            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                HStack {
                    Text(selected?.lastPathComponent ?? "No log selected")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Reveal in Finder") { reveal() }
                        .disabled(selected == nil)
                    Button("Clear Logs") { clearLogs() }
                        .disabled(logFiles.isEmpty)
                }

                ScrollView {
                    Text(content.isEmpty ? "No output yet." : content)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(content.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Theme.Spacing.s)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overpassCard(cornerRadius: Theme.Radius.row)
            }
            .padding(Theme.Spacing.m)
        }
        .task { refresh() }
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

    private func clearLogs() {
        let dir = Paths.logs.appendingPathComponent(bottleID.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        selected = nil
        content = ""
        refresh()
    }
}
