import SwiftUI
import AppKit

/// A bottle's "Games" tab: installed titles discovered by `GameLibrary.scan`
/// across Steam/GOG Galaxy/Epic, presented as a Heroic/CrossOver-style
/// library — a grid of portrait cover cards by default, with a List mode
/// (the original full-width-row layout) a click away via the toolbar's
/// segmented control. The chosen mode is remembered per-machine via
/// `@AppStorage`.
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

    @AppStorage("overpass.games.viewMode") private var viewMode: GamesViewMode = .grid

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
                } else if viewMode == .grid {
                    ScrollView {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 150), spacing: Theme.Spacing.l)],
                            spacing: Theme.Spacing.l
                        ) {
                            ForEach(filteredGames) { game in
                                GameCard(game: game, bottle: bottle)
                            }
                        }
                    }
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

            Picker("View mode", selection: $viewMode) {
                Image(systemName: "square.grid.2x2").tag(GamesViewMode.grid)
                Image(systemName: "list.bullet").tag(GamesViewMode.list)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 76, height: Theme.Metrics.toolbarControl)

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

/// Grid vs. list, remembered via `@AppStorage("overpass.games.viewMode")`.
enum GamesViewMode: String {
    case grid, list
}

// MARK: - Game card (grid mode)

/// One Heroic-style library card: a 2:3 portrait cover (real Steam art when
/// available, otherwise a generated monogram placeholder), the game's name
/// below in up to two lines, and a muted store/size line. Hovering raises
/// the card slightly and reveals a centered play button; double-clicking
/// the card (or the play button itself) launches the game.
private struct GameCard: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeStore.self) private var themeStore
    let game: InstalledGame
    let bottle: Bottle
    @State private var image: NSImage?
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            cover
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                }
                .overlay {
                    if isHovering {
                        ZStack {
                            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                                .fill(Color.black.opacity(0.28))
                            Button(action: play) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 42, height: 42)
                                    .background(Circle().fill(themeStore.current.accentGradient))
                            }
                            .buttonStyle(.plain)
                            .disabled(game.launchExe == nil)
                            .help("Play")
                        }
                    }
                }
                .shadow(color: .black.opacity(isHovering ? 0.32 : 0.14), radius: isHovering ? 10 : 4, y: isHovering ? 5 : 2)
                .scaleEffect(isHovering ? 1.035 : 1)
                .animation(Theme.settle, value: isHovering)

            VStack(alignment: .leading, spacing: 1) {
                Text(game.name)
                    .font(.system(size: 13))
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(game.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { play() }
        .onHover { isHovering = $0 }
        .task(id: game.id) { await loadArt() }
        .contextMenu {
            Button("Play") { play() }
                .disabled(game.launchExe == nil)
            Button("Reveal Install Folder in Finder") { reveal() }
                .disabled(revealTarget == nil)
            Button("Copy Launch Command") { copyLaunchCommand() }
                .disabled(game.launchExe == nil)
        }
    }

    @ViewBuilder
    private var cover: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            placeholder
        }
    }

    /// Shown while art is still loading and permanently for any game with
    /// no downloadable/local art — a monogram over the current theme's
    /// accent gradient, styled to look deliberate rather than broken.
    private var placeholder: some View {
        ZStack {
            themeStore.current.accentGradient
            Text(PlaceholderArt.monogram(for: game.name))
                .font(Theme.titleFont(26, weight: .bold))
                .foregroundStyle(.white.opacity(0.92))
        }
    }

    private func loadArt() async {
        guard let data = await GameArtwork.shared.art(for: game), let nsImage = NSImage(data: data) else { return }
        image = nsImage
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

// MARK: - Game row (list mode)

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
