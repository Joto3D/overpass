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
    /// True while the "Clear logs" confirmation is on screen. Clearing
    /// deletes every log in the bottle's folder with no way back (they are
    /// removed, not moved to the Trash), so it must never be one stray
    /// click away — same reasoning as the bottle delete confirmation.
    @State private var showClearConfirmation = false
    /// Total size in bytes of the selected log file on disk, or nil when
    /// nothing is selected or it can't be read. Kept next to `content`
    /// because `LogStore.tail` returns only the text, not whether it cut
    /// anything off; comparing this against `tailLimitBytes` is how the
    /// view knows to show the truncation notice.
    @State private var selectedFileSize: UInt64?

    /// How much of the end of a log the viewer loads. Passed explicitly to
    /// `LogStore.tail` (rather than relying on its default) so the number
    /// shown in the truncation notice and the number actually read can't
    /// drift apart. Matches `LogStore.tail`'s own default.
    private static let tailLimitBytes = 200_000

    /// True when the selected log is bigger than what the viewer loads, so
    /// the text on screen starts part-way through the file. Without saying
    /// so, someone hunting for an error near the start of a long run would
    /// conclude it isn't there.
    private var isTruncated: Bool {
        guard let selectedFileSize else { return false }
        return selectedFileSize > UInt64(Self.tailLimitBytes)
    }

    /// Whether "Clear logs" may be used: there is something to delete and
    /// no run in this bottle is currently writing into the folder.
    private var canClearLogs: Bool { !logFiles.isEmpty && !isBottleRunning }

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
                    .help(LogFileName.displayName(for: url))
                    .tag(url)
            }
            // A bottle with no runs yet used to show a blank column beside
            // an unexplained "No log selected".
            .overlay {
                if logFiles.isEmpty {
                    Text("No logs yet — run a program in this bottle.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(Theme.Spacing.m)
                }
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
                // Two rows rather than one: the file name, "Program won't
                // start?" and three buttons side by side need ~440pt, and at
                // the smallest window the name was squeezed down to an
                // ellipsis. The name now has the full width of the pane.
                Text(selected.map { LogFileName.displayName(for: $0) } ?? "No log selected")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(selected.map { LogFileName.displayName(for: $0) } ?? "")
                    .textSelection(.enabled)

                HStack(spacing: Theme.Spacing.s) {
                    Button("Program won't start?") { showTroubleshooting = true }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .popover(isPresented: $showTroubleshooting) {
                            troubleshootingContent
                        }
                    Spacer()
                    // Compact quiet style: the full-width one made these
                    // 46pt-tall buttons that did not fit a header row.
                    Button("Copy log") { copyLog() }
                        .buttonStyle(.quietCompact)
                        .fixedSize()
                        .disabled(selected == nil || content.isEmpty)
                    Button("Reveal in Finder") { reveal() }
                        .buttonStyle(.quietCompact)
                        .fixedSize()
                        .disabled(selected == nil)
                    // Disabled while a run is active: that run holds its log
                    // open, so deleting the folder under it would leave the
                    // process writing to an unlinked file and its output
                    // would vanish from the viewer for good.
                    Button("Clear logs") { showClearConfirmation = true }
                        .buttonStyle(.quietCompact)
                        .fixedSize()
                        .disabled(!canClearLogs)
                        .help(isBottleRunning
                              ? "Logs can't be cleared while a program is running in this bottle."
                              : "Permanently delete this bottle's log files.")
                }

                if isTruncated, let selected, let selectedFileSize {
                    truncationNotice(for: selected, size: selectedFileSize)
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
        // Same shape as the bottle delete confirmation in MainWindow:
        // titled question, destructive confirm, Cancel, and a message that
        // says what happens and that it can't be undone.
        .confirmationDialog(
            "Clear all logs for this bottle?",
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear logs", role: .destructive) { clearLogs() }
            Button("Cancel", role: .cancel) { showClearConfirmation = false }
        } message: {
            Text("This permanently deletes \(logFiles.count) log \(logFiles.count == 1 ? "file" : "files") for this bottle. This can't be undone.")
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
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
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

    /// Tells the reader the text below is only the end of a longer file.
    /// The viewer reads just the last `tailLimitBytes` so a multi-megabyte
    /// log doesn't stall the UI, which is invisible unless said out loud.
    /// The full path is included (and selectable via `InlineNote`) so the
    /// whole file can be opened elsewhere; the "Reveal in Finder" button in
    /// the header above does the same in one click.
    private func truncationNotice(for url: URL, size: UInt64) -> some View {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let shown = formatter.string(fromByteCount: Int64(Self.tailLimitBytes))
        let total = formatter.string(fromByteCount: Int64(size))
        return InlineNote(
            systemImage: "scissors",
            tint: .orange,
            text: "Showing only the last \(shown) of this \(total) log — earlier output is not shown. Use Reveal in Finder to open the full file: \(url.path)"
        )
    }

    private func troubleshootingItem(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text(title)
                .font(.caption.weight(.semibold))
            Text(body)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
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
            selectedFileSize = nil
            return
        }
        content = LogStore.tail(selected, maxBytes: Self.tailLimitBytes)
        let size = (try? FileManager.default.attributesOfItem(atPath: selected.path)[.size]) as? NSNumber
        selectedFileSize = size?.uint64Value
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
