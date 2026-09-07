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
                        Spacer()
                        Button("Open Data Folder") {
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
                            Text(diagnosticsStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Save Report…") {
                            saveReport()
                        }
                        .buttonStyle(.bordered)
                        .disabled(isGeneratingReport)
                        Button("Copy Report to Clipboard") {
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
                    Text("Wine engines (Game Porting Toolkit, Wine Staging) run as x86_64 binaries under Rosetta 2. Apple is expected to remove most of Rosetta 2 in macOS 28 — engine selection stays behind an abstraction so a native build can be added later.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("Run Setup Wizard Again") {
                            appState.showSetupWizard = true
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(Theme.Spacing.l)
                .overpassCard()
            }
            .padding(Theme.Spacing.xl)
            .frame(maxWidth: 760, alignment: .leading)
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
                    .fill(isSelected ? palette.badgeTint.opacity(0.16) : Color.clear)
            }
        }
        .buttonStyle(.plain)
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
