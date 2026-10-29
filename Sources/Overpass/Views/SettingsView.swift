import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Theme picker, a shortcut to the data folder, and a short About block.
struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeStore.self) private var themeStore
    @State private var isGeneratingReport = false
    @State private var diagnosticsStatus: String?

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: Theme.Spacing.s)]
    }

    var body: some View {
        @Bindable var themeStore = themeStore
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    SectionHeader(title: "Appearance", systemImage: "paintpalette")
                    LazyVGrid(columns: columns, spacing: Theme.Spacing.s) {
                        ForEach(ThemePalette.all) { palette in
                            themeSwatch(palette)
                        }
                    }
                }
                .padding(Theme.Spacing.l)
                .overpassCard()

                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    SectionHeader(title: "Data", systemImage: "externaldrive")
                    HStack {
                        Text(Paths.root.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(Paths.root.path)
                            .textSelection(.enabled)
                        Spacer()
                        Button("Open data folder") {
                            NSWorkspace.shared.open(Paths.root)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(Theme.Spacing.l)
                .overpassCard()

                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    SectionHeader(title: "Diagnostics", systemImage: "stethoscope")
                    Text("A plain-text snapshot of your setup — versions, engines, bottles, and the tail of the most recent log — useful when something's not working and you want to compare notes or ask for help.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        if let diagnosticsStatus {
                            // Spinner only while the report is being built
                            // (the status also carries the final "Copied"
                            // / "Saved" / "Couldn't save: ..." results,
                            // which are selectable so a failure can be
                            // pasted out).
                            if isGeneratingReport {
                                InlineProgress(text: diagnosticsStatus)
                            } else {
                                Text(diagnosticsStatus)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        Spacer()
                        Button("Save report…") {
                            saveReport()
                        }
                        .buttonStyle(.bordered)
                        .disabled(isGeneratingReport)
                        Button("Copy report to clipboard") {
                            copyReport()
                        }
                        .buttonStyle(.bordered)
                        .disabled(isGeneratingReport)
                    }
                }
                .padding(Theme.Spacing.l)
                .overpassCard()

                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    SectionHeader(title: "About", systemImage: "info.circle")
                    Text("Overpass \(appVersion)")
                        .font(.subheadline.weight(.medium))
                        .textSelection(.enabled)
                    Text("Wine engines (Game Porting Toolkit, Wine Staging) run as x86_64 binaries under Rosetta 2. Apple is expected to remove most of Rosetta 2 in macOS 28 — engine selection stays behind an abstraction so a native build can be added later.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("Run setup wizard again") {
                            appState.showSetupWizard = true
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(Theme.Spacing.l)
                .overpassCard()
            }
            .padding(Theme.Spacing.outer)
            .frame(maxWidth: Theme.Metrics.contentMaxWidth, alignment: .leading)
            // Same as Engines: the capped column is stated to sit centred in
            // a wide window instead of depending on the ScrollView's default.
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func themeSwatch(_ palette: ThemePalette) -> some View {
        let isSelected = palette.id == themeStore.current.id
        Button {
            withAnimation(Theme.settle) { themeStore.current = palette }
        } label: {
            HStack(spacing: Theme.Spacing.s) {
                Circle()
                    .fill(palette.accentGradient)
                    .frame(width: 18, height: 18)
                    .overlay(Circle().strokeBorder(palette.secondaryAccent, lineWidth: 1))
                Text(palette.displayName)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(Theme.Spacing.s)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .fill(isSelected ? palette.badgeTint.opacity(Theme.Opacity.wash) : Color.clear)
            }
        }
        .buttonStyle(.plain)
        // The checkmark is the visible "selected" marker; this is the
        // spoken one, so VoiceOver reads "Dusk, selected" instead of
        // leaving the current theme undiscoverable.
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(palette.summary)
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        if let build = info?["CFBundleVersion"] as? String, build != short {
            return "\(short) (\(build))"
        }
        return short
    }

    // MARK: - Diagnostics actions

    private func copyReport() {
        guard !isGeneratingReport else { return }
        isGeneratingReport = true
        diagnosticsStatus = "Generating report…"
        Task {
            let report = await Diagnostics.report()
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(report, forType: .string)
            isGeneratingReport = false
            diagnosticsStatus = "Copied to clipboard."
        }
    }

    private func saveReport() {
        guard !isGeneratingReport else { return }
        isGeneratingReport = true
        diagnosticsStatus = "Generating report…"
        Task {
            let report = await Diagnostics.report()
            isGeneratingReport = false

            let panel = NSSavePanel()
            panel.title = "Save Diagnostics Report"
            panel.nameFieldStringValue = "Overpass Diagnostics.txt"
            panel.allowedContentTypes = [.plainText]
            panel.canCreateDirectories = true

            guard panel.runModal() == .OK, let url = panel.url else {
                diagnosticsStatus = nil
                return
            }
            do {
                try report.write(to: url, atomically: true, encoding: .utf8)
                diagnosticsStatus = "Saved to \(url.lastPathComponent)."
            } catch {
                diagnosticsStatus = "Couldn't save: \(error.localizedDescription)"
            }
        }
    }
}
