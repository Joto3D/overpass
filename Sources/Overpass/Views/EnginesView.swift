import SwiftUI
import AppKit

/// The Engines screen: lists the fixed catalog (`EngineCatalog.releases`),
/// each with its install state, and lets the user install/remove them.
/// Bottles are created against whichever engines are installed here.
struct EnginesView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                header

                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    SectionHeader(title: "Available Engines", systemImage: "gearshape.2")
                    VStack(spacing: Theme.Spacing.l) {
                        ForEach(EngineCatalog.releases) { release in
                            EngineRow(release: release)
                        }
                    }
                }

                rosettaNote
            }
            .padding(Theme.Spacing.xl)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task { appState.loadEngines() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("Engines")
                .font(Theme.titleFont())
            Text("Wine builds that run your Windows programs. Install at least one before creating a bottle.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var rosettaNote: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.s) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text("Engines run under Rosetta 2. Apple plans to remove most of Rosetta 2 in macOS 28 (2027).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(Theme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overpassCard(cornerRadius: Theme.Radius.row)
    }
}

/// One catalog entry: its description, install state, progress while
/// installing, and the relevant action buttons.
private struct EngineRow: View {
    @Environment(AppState.self) private var appState
    let release: EngineRelease

    private var installed: InstalledEngine? {
        appState.installedEngines.first { $0.id == release.id }
    }
    private var progress: Double? { appState.engineInstallProgress[release.id] }
    private var status: String? { appState.engineInstallStatus[release.id] }
    private var installing: Bool { progress != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack(alignment: .top, spacing: Theme.Spacing.m) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: Theme.Spacing.s) {
                        Text(release.displayName)
                            .font(Theme.headingFont(16))
                        if release.id == EngineCatalog.defaultRelease.id {
                            Chip(text: "Default", systemImage: "star.fill", tint: .yellow)
                        }
                    }
                    Text(release.notes)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Theme.Spacing.m)
                if installed != nil, !installing {
                    Chip(text: "Installed", systemImage: "checkmark.circle.fill", tint: .green)
                }
            }

            if installing {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress ?? 0)
                    Text(status ?? "Working…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let installed {
                VStack(alignment: .leading, spacing: 2) {
                    Text(installed.versionString)
                        .font(.system(.caption, design: .monospaced).weight(.medium))
                    Text("Installed \(installed.installedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            actionRow
        }
        .padding(Theme.Spacing.l)
        .overpassCard()
    }

    @ViewBuilder
    private var actionRow: some View {
        if installing {
            EmptyView()
        } else if let installed {
            HStack(spacing: Theme.Spacing.s) {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([installed.rootDir])
                }
                .buttonStyle(.quiet)

                Button("Remove", role: .destructive) {
                    Task { await appState.removeEngine(installed.id) }
                }
                .buttonStyle(.quiet)
            }
        } else {
            Button("Install") {
                Task { await appState.installEngine(release) }
            }
            .buttonStyle(.aurora)
        }
    }
}
