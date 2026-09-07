import SwiftUI
import AppKit

/// A bottle's "Games" tab: installed titles discovered by `GameLibrary.scan`
/// across Steam/GOG Galaxy/Epic, styled to match `ProgramsGridView`'s rows
/// so the two tabs read as one family — full-width rows, a roundel, a
/// hover-only play button, double-click to launch, and a matching
/// search/rescan toolbar.
///
/// `BottleDetailView` only shows this tab once a scan has found at least
/// one game; this view itself re-scans on its own `.task(id:)` (and via
/// the toolbar's Rescan button) so it always reflects what's actually
/// installed right now rather than a cached pin list.
struct GamesView: View {
    let bottleID: UUID
    @Environment(AppState.self) private var appState

    @State private var games: [InstalledGame] = []
    @State private var isScanning = false
    @State private var hasScannedOnce = false
    @State private var searchText = ""
    @State private var storeFilter: Store?

    private var bottle: Bottle? {
        appState.bottles.first { $0.id == bottleID }
    }

    private var storesPresent: [Store] {
        Store.allCases.filter { store in games.contains { $0.store == store } }
    }

    private var filteredGames: [InstalledGame] {
        var result = games
        if let storeFilter {
            result = result.filter { $0.store == storeFilter }
        }
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return result }
        return result.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        if let bottle {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                toolbar(bottle)

                if !hasScannedOnce && isScanning {
                    emptyState("Scanning for games\u{2026}")
                } else if games.isEmpty {
                    emptyState("No games found — install one through Steam, GOG Galaxy or Epic in this bottle.")
                } else if filteredGames.isEmpty {
                    emptyState("No games match \u{201c}\(searchText)\u{201d}.")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filteredGames) { game in
                                GameRow(game: game, bottle: bottle)
                                if game.id != filteredGames.last?.id {
                                    Divider()
                                }
                            }
                        }
                        .overpassCard(cornerRadius: Theme.Radius.card)
                    }
                }
            }
            // Plain `.task` doesn't refire when the bottle switches — this
            // view keeps its SwiftUI identity across bottles (only
            // `bottleID` changes), so the scan would silently keep showing
            // the *previous* bottle's games. Keying on `bottleID` forces a
            // fresh task (and thus a fresh scan) every time the selected
            // bottle changes. (Same fix `ProgramsGridView` already applies
            // to its own migration task.)
            .task(id: bottleID) {
                await rescan(bottle)
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
                TextField("Search games", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, Theme.Spacing.s)
            .frame(maxWidth: .infinity)
            .frame(height: Theme.Metrics.toolbarControl)
            .overpassCard(cornerRadius: Theme.Radius.row)

            if isScanning {
                ProgressView().controlSize(.small)
            }

            if storesPresent.count > 1 {
                Menu {
                    Button("All stores") { storeFilter = nil }
                    Divider()
                    ForEach(storesPresent) { store in
                        Button(store.displayName) { storeFilter = store }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .frame(width: Theme.Metrics.toolbarControl, height: Theme.Metrics.toolbarControl)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Filter by store")
            }

            IconToolbarButton(systemImage: "arrow.clockwise", help: "Rescan") {
                Task { await rescan(bottle) }
            }
            .disabled(isScanning)
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

    private func rescan(_ bottle: Bottle) async {
        isScanning = true
        defer {
            isScanning = false
            hasScannedOnce = true
        }
        games = await GameLibrary.scan(bottle: bottle)
    }
}

// MARK: - Game row

private struct GameRow: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeStore.self) private var themeStore
    let game: InstalledGame
    let bottle: Bottle
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(game.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Text(game.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: Theme.Spacing.m)

            if isHovering {
                Button(action: play) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .fixedSize()
                .disabled(game.launchExe == nil)
                .help("Play")
            }
        }
        .padding(.horizontal, Theme.Spacing.m)
        .frame(height: Theme.Metrics.listRow)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { play() }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Play") { play() }
                .disabled(game.launchExe == nil)
            Button("Reveal in Finder") { reveal() }
                .disabled(revealTarget == nil)
            Button("Copy Launch Command") { copyLaunchCommand() }
                .disabled(game.launchExe == nil)
        }
    }

    private func play() {
        guard let launchExe = game.launchExe else { return }
        Task { await appState.run(exe: launchExe, args: game.launchArgs, in: bottle) }
    }

    private var revealTarget: URL? {
        game.installDir ?? game.launchExe
    }

    private func reveal() {
        guard let revealTarget else { return }
        NSWorkspace.shared.activateFileViewerSelecting([revealTarget])
    }

    private func copyLaunchCommand() {
        guard let launchExe = game.launchExe else { return }
        let command = game.launchArgs.isEmpty ? launchExe.path : "\(launchExe.path) \(game.launchArgs)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }
}
