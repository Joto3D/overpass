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
    /// The card or row the user last clicked. Selection exists so a game
    /// keeps its Play button on screen without the pointer parked on it
    /// (a hover-only affordance vanishes the moment you move to read the
    /// title); it changes nothing about what Play does.
    @State private var selectedGameID: InstalledGame.ID?
    /// Compatibility per game id, filled once per scan. `Compatibility`
    /// is a catalog lookup; doing it in each card's `body` would redo it
    /// on every hover flip of every card.
    @State private var ratings: [InstalledGame.ID: Compatibility] = [:]

    @AppStorage("overpass.games.viewMode") private var viewMode: GamesViewMode = .grid

    private var bottle: Bottle? {
        appState.bottles.first { $0.id == bottleID }
    }

    private var storesPresent: [Store] {
        Store.allCases.filter { store in games.contains { $0.store == store } }
    }

    /// The store filter actually in force: `storeFilter`, unless a rescan
    /// has since found no games from that store. The filter menu is hidden
    /// once only one store is left (`storesPresent.count > 1`), so a stale
    /// filter would otherwise leave an empty list with no control anywhere
    /// to clear it.
    private var activeStoreFilter: Store? {
        storeFilter.flatMap { storesPresent.contains($0) ? $0 : nil }
    }

    private var filteredGames: [InstalledGame] {
        var result = games
        if let activeStoreFilter {
            result = result.filter { $0.store == activeStoreFilter }
        }
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return result }
        return result.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    /// How far a hovered card's scale and shadow reach past its resting
    /// frame (see the grid's padding).
    private let gridBleed = Theme.Spacing.m

    var body: some View {
        if let bottle {
            // Evaluated once per render: filtering runs a substring search
            // over every game, and the list loop below used to ask for the
            // last element again for every row.
            let shownGames = filteredGames
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                // The search/filter/view-mode strip only earns its place
                // once there is a library to search. Over an empty library
                // (still scanning for the first time, or nothing found) it
                // was four dead controls above a message; the empty states
                // below carry the one control that matters, Rescan.
                if !games.isEmpty {
                    toolbar(bottle, shown: shownGames.count)
                }

                if !hasScannedOnce && isScanning {
                    EmptyStateMessage("Scanning for games\u{2026}", showsProgress: true)
                } else if games.isEmpty {
                    LibraryEmptyState(
                        systemImage: "gamecontroller",
                        title: "No games found",
                        message: "Overpass looks for games installed by Steam, GOG Galaxy or Epic inside this bottle. Install a launcher, add a game through it, then rescan."
                    ) {
                        if isScanning {
                            InlineProgress(text: "Scanning for games\u{2026}")
                        }
                        Button("Rescan games") { Task { await rescan(bottle) } }
                            .buttonStyle(.accentCompact)
                            .disabled(isScanning)
                        Button("Install a launcher\u{2026}") { appState.selection = .installApps }
                            .buttonStyle(.quietCompact)
                    }
                } else if shownGames.isEmpty {
                    // The search box can be empty here (the store filter alone
                    // emptied the list), where "No games match “”." read as a
                    // bug.
                    if searchText.trimmingCharacters(in: .whitespaces).isEmpty, let activeStoreFilter {
                        EmptyStateMessage("No \(activeStoreFilter.displayName) games found.")
                    } else {
                        EmptyStateMessage("No games match \u{201c}\(searchText)\u{201d}.")
                    }
                } else if viewMode == .grid {
                    ScrollView {
                        // Alignment `.top` on the column: rows are as tall
                        // as their tallest card, and the default (.center)
                        // floated a shorter card's cover down by half the
                        // difference, so covers in one row did not share a
                        // top edge. (The title also reserves two lines now,
                        // so heights normally match anyway; this is the
                        // belt to that pair of braces.)
                        //
                        // `maximum` caps the card width: with an unbounded
                        // adaptive column a wide window made a handful of
                        // games into a few enormous 2:3 covers. Leading
                        // alignment keeps a short last row against the left
                        // edge instead of centring it under the others.
                        //
                        // 176...240 (was 150...190): the cover is the
                        // content of this screen, so it gets room to read as
                        // art. At 176 wide a cover is 264 tall, and every
                        // badge label still fits on it without `glyphOnly`.
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 176, maximum: 240), spacing: Theme.Spacing.l, alignment: .top)],
                            alignment: .leading,
                            spacing: Theme.Spacing.l
                        ) {
                            ForEach(shownGames) { game in
                                GameCard(
                                    game: game,
                                    bottle: bottle,
                                    compatibility: ratings[game.id] ?? .untested,
                                    isSelected: selectedGameID == game.id,
                                    onSelect: { selectedGameID = game.id }
                                )
                            }
                        }
                        // Headroom for the hover treatment. A ScrollView clips
                        // to its bounds, and a hovered card grows 3.5% and
                        // casts a 10pt shadow (offset 5pt down), so edge cards
                        // were shaved on the left, right and top, and the last
                        // row on the bottom. 12pt covers the side and top
                        // overhang; the bottom takes 16 for the offset shadow.
                        .padding(.horizontal, gridBleed)
                        .padding(.top, gridBleed)
                        .padding(.bottom, Theme.Spacing.l)
                    }
                    // The padding above would push the covers 12pt in from the
                    // search field's edge. Widening the scroll view by the same
                    // amount (it just extends into the screen's 20pt outer
                    // padding) puts the first card flush with the toolbar and
                    // the scroller at the window edge. The top is pulled up into
                    // the 12pt gap under the toolbar, so the net gap stays at
                    // 16 rather than doubling up.
                    .padding(.horizontal, -gridBleed)
                    .padding(.top, -Theme.Spacing.s)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(shownGames) { game in
                                GameRow(
                                    game: game,
                                    bottle: bottle,
                                    compatibility: ratings[game.id] ?? .untested,
                                    isSelected: selectedGameID == game.id,
                                    onSelect: { selectedGameID = game.id }
                                )
                                if game.id != shownGames.last?.id {
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

    private func toolbar(_ bottle: Bottle, shown: Int) -> some View {
        HStack(spacing: Theme.Spacing.s) {
            // Capped: stretched across the whole window the field was the
            // widest, heaviest thing on a screen whose subject is the
            // covers. The spacer + count then push the view controls to
            // the trailing edge, where they read as controls, not content.
            ToolbarSearchField(prompt: "Search games", text: $searchText)
                .frame(maxWidth: 280)

            Spacer(minLength: Theme.Spacing.m)

            // A quiet library total, so the grid below has a sense of scale
            // ("3 of 12" also explains a filter that is hiding games).
            Text(countCaption(shown: shown, total: games.count, noun: "game"))
                .font(Theme.rowSubtitleFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if isScanning {
                ProgressView().controlSize(.small)
            }

            if storesPresent.count > 1 {
                // The current choice is marked with a checkmark: the menu
                // used to give no sign of which store (if any) was filtering
                // the list.
                Menu {
                    Button {
                        storeFilter = nil
                    } label: {
                        if activeStoreFilter == nil {
                            Label("All stores", systemImage: "checkmark")
                        } else {
                            Text("All stores")
                        }
                    }
                    Divider()
                    ForEach(storesPresent) { store in
                        Button {
                            storeFilter = store
                        } label: {
                            if activeStoreFilter == store {
                                Label(store.displayName, systemImage: "checkmark")
                            } else {
                                Text(store.displayName)
                            }
                        }
                    }
                } label: {
                    // Filled glyph + accent when a store is filtering, to
                    // match the Programs filter menu — the checkmark inside
                    // the menu is only visible once it is open.
                    Image(systemName: activeStoreFilter == nil
                          ? "line.3.horizontal.decrease.circle"
                          : "line.3.horizontal.decrease.circle.fill")
                        .foregroundStyle(activeStoreFilter == nil ? Color.secondary : Color.accentColor)
                        .frame(width: Theme.Metrics.toolbarControl, height: Theme.Metrics.toolbarControl)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Filter by store")
                .accessibilityLabel("Filter by store")
            }

            // Icon-only segments: each is named for VoiceOver and gets a
            // tooltip, since neither glyph says "grid" or "list" in words.
            Picker("View mode", selection: $viewMode) {
                Image(systemName: "square.grid.2x2")
                    .help("Grid")
                    .accessibilityLabel("Grid")
                    .tag(GamesViewMode.grid)
                Image(systemName: "list.bullet")
                    .help("List")
                    .accessibilityLabel("List")
                    .tag(GamesViewMode.list)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 76, height: Theme.Metrics.toolbarControl)

            IconToolbarButton(systemImage: "arrow.clockwise", help: "Rescan games") {
                Task { await rescan(bottle) }
            }
            .disabled(isScanning)
        }
    }

    // MARK: - Actions

    private func rescan(_ bottle: Bottle) async {
        isScanning = true
        defer {
            isScanning = false
            hasScannedOnce = true
        }
        let scanned = await GameLibrary.scan(bottle: bottle)
        games = scanned
        ratings = Dictionary(scanned.map { ($0.id, Compatibility.forGame($0)) }, uniquingKeysWith: { first, _ in first })
    }
}

/// "12 games", or "3 of 12 games" while a search/filter is hiding some —
/// the quiet total beside a library toolbar. Shared with Programs.
func countCaption(shown: Int, total: Int, noun: String) -> String {
    let plural = total == 1 ? noun : noun + "s"
    return shown == total ? "\(total) \(plural)" : "\(shown) of \(total) \(plural)"
}

// MARK: - Library empty state

/// What a library screen shows when it has nothing at all (as opposed to
/// nothing *matching*, which stays the quiet `EmptyStateMessage`): a glyph,
/// a one-line title, a sentence on what will fill the screen, and the
/// actions that get the user there. Centred in the space below the header
/// rather than hung from the top, so a new bottle's first Games/Programs
/// view looks designed instead of unfinished.
///
/// Built only from existing tokens. The caller supplies the buttons (it
/// owns the actions) — conventionally an `.accentCompact` primary first,
/// then `.quietCompact` alternatives.
struct LibraryEmptyState<Actions: View>: View {
    @Environment(ThemeStore.self) private var themeStore
    private let systemImage: String
    private let title: String
    private let message: String
    private let actions: Actions

    // Explicit: a memberwise init would be private because of the private
    // properties, and would not apply @ViewBuilder to `actions`.
    init(systemImage: String, title: String, message: String, @ViewBuilder actions: () -> Actions) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            Image(systemName: systemImage)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(themeStore.current.accentGradient)
                .accessibilityHidden(true)
            Text(title)
                .font(Theme.headingFont(17))
            Text(message)
                .font(Theme.rowTitleFont)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                // Narrow measure: a two-line paragraph reads better than a
                // 700pt run of text in a wide window.
                .frame(maxWidth: 380)
            HStack(spacing: Theme.Spacing.s) {
                actions
            }
            .padding(.top, Theme.Spacing.xs)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Optical centre: true centre of a tall pane looks low.
        .padding(.bottom, Theme.Spacing.xl * 2)
        .accessibilityElement(children: .contain)
    }
}

/// Grid vs. list, remembered via `@AppStorage("overpass.games.viewMode")`.
enum GamesViewMode: String {
    case grid, list
}

// MARK: - Shared presentation

/// What a game's rating changes about how it is shown, in one place so the
/// card and the row cannot disagree.
private extension Compatibility {
    /// True only for the rating that says the launch will fail. It is the
    /// one rating that changes how the whole card looks (a greyed cover and
    /// a de-emphasised Play button), because it is the one worth noticing
    /// before waiting on a launch that cannot succeed.
    var isBlocking: Bool { self == .wontRun }

    /// The tooltip for a card or row. Plain `help` on the badge only fires
    /// while the pointer is exactly on the badge; this puts the sentence on
    /// the whole item. Empty for `.untested` (nothing to say).
    func help(for name: String, subtitle: String) -> String {
        var parts = [name]
        if !subtitle.isEmpty { parts[0] += " \u{2014} \(subtitle)" }
        if isNoteworthy { parts.append("\(label): \(detail)") }
        return parts.joined(separator: "\n")
    }
}

// MARK: - Game card (grid mode)

/// One library card, art first: a 2:3 portrait cover (real Steam art when
/// available, otherwise a generated monogram placeholder) that carries the
/// card, with the name and a muted store/size line quietly beneath it.
///
/// - A compatibility badge sits on the cover's top-left corner, but only
///   for a noteworthy rating. `.untested` is the common case and gets no
///   badge at all: a clean cover means "nothing known".
/// - A `.wontRun` game has its cover desaturated as well as badged, so it
///   reads as unavailable at a glance, before anyone clicks Play.
/// - Hovering or selecting raises the card and shows a labelled Play pill
///   along the cover's bottom edge. Double-clicking the card (or the pill)
///   launches. Single-clicking selects, which keeps the pill showing after
///   the pointer moves away.
private struct GameCard: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeStore.self) private var themeStore
    let game: InstalledGame
    let bottle: Bottle
    let compatibility: Compatibility
    let isSelected: Bool
    let onSelect: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: NSImage?
    @State private var isHovering = false

    private var coverShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
    }

    /// The pill shows while pointed at or selected.
    private var showsPlay: Bool { isHovering || isSelected }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.compact) {
            cover
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                // Greyed out, not hidden or faded: still recognisable as the
                // game, plainly not a candidate to launch. Saturation only,
                // so the art keeps its contrast and the red badge is the one
                // saturated thing left on the card.
                .saturation(compatibility.isBlocking ? 0.2 : 1)
                .clipShape(coverShape)
                .overlay {
                    coverShape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                }
                .overlay(alignment: .topLeading) {
                    // Noteworthy ratings only. Never `glyphOnly` here: the
                    // narrowest cover is 176pt, which holds every label, and
                    // "Won't run" in particular has to be a word, not a glyph.
                    if compatibility.isNoteworthy {
                        CompatibilityBadge(compatibility: compatibility, style: .overlay)
                            .padding(Theme.Spacing.s)
                    }
                }
                .overlay(alignment: .bottom) {
                    if showsPlay {
                        playPill
                    }
                }
                .overlay {
                    // Selection ring on top of the cover edge. The theme's
                    // `ink` is the accent tuned to read as a thin stroke.
                    if isSelected {
                        coverShape.strokeBorder(themeStore.current.ink, lineWidth: 2)
                    }
                }
                .shadow(color: .black.opacity(showsPlay ? 0.32 : 0.14), radius: showsPlay ? 10 : 4, y: showsPlay ? 5 : 2)
                // The shadow and the play pill already say "this one"; the
                // grow is dropped for people who asked the system for less
                // motion. Hover only: a selected card that grew would
                // keep jostling its neighbours.
                .scaleEffect(isHovering && !reduceMotion ? 1.035 : 1)
                .animation(Theme.settle, value: isHovering)
                .animation(Theme.settle, value: isSelected)

            // Subordinate to the cover: the name in the standard row size and
            // the store line a step quieter, so the art is read first.
            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                Text(game.name)
                    .font(Theme.rowTitleFont)
                    // Always two lines tall, tail-truncated beyond that (the
                    // tooltip below has the full name). The old
                    // `minimumScaleFactor(0.75)` shrank only the long names, so
                    // one grid showed titles at two different sizes; and a
                    // one-line title left its card shorter than its row
                    // neighbours. Reserving the space keeps every cover in a
                    // row the same size and the same distance from its title.
                    .lineLimit(2, reservesSpace: true)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // A game that will not run also reads as dimmer in text.
                    .foregroundStyle(compatibility.isBlocking ? .secondary : .primary)
                Text(game.subtitle)
                    .font(Theme.rowSubtitleFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(compatibility.help(for: game.name, subtitle: game.subtitle))
        }
        .contentShape(Rectangle())
        // Double first: SwiftUI resolves a count-2 and a count-1 tap on the
        // same view only when the double is declared before the single.
        .onTapGesture(count: 2) { play() }
        .onTapGesture(count: 1) { onSelect() }
        .onHover { isHovering = $0 }
        // The hovered card grows and throws a shadow over its neighbours;
        // later siblings in a grid draw on top by default, so the right and
        // lower neighbours were painted over the raised card's edge.
        .zIndex(isHovering ? 1 : 0)
        .task(id: game.id) { await loadArt() }
        // The play pill only exists while hovered or selected, so it is
        // unreachable from the keyboard or VoiceOver; this exposes the same
        // action on the card itself.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: "Play") { play() }
        .contextMenu {
            Button("Play") { play() }
                .disabled(game.launchExe == nil)
            Button("Reveal in Finder") { reveal() }
                .disabled(revealTarget == nil)
            Button("Copy launch command") { copyLaunchCommand() }
                .disabled(game.launchExe == nil)
        }
    }

    /// The card's primary action: a labelled pill along the cover's bottom
    /// edge over a soft scrim. A word beats the old lone glyph circle for
    /// "what do I click", and the bottom edge leaves the middle of the art
    /// (and the badge in the corner) unobstructed.
    ///
    /// For a `.wontRun` game it is deliberately demoted: neutral dark fill
    /// instead of the accent, and worded "Play anyway", so the choice to
    /// launch is still there but is visibly an override. The action is
    /// unchanged.
    private var playPill: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(
                colors: [.clear, .black.opacity(0.62)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 84)
            .allowsHitTesting(false)

            Button(action: play) {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .bold))
                    Text(compatibility.isBlocking ? "Play anyway" : "Play")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.vertical, Theme.Spacing.s)
                .background {
                    if compatibility.isBlocking {
                        Capsule().fill(Color.black.opacity(0.7))
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
                    } else {
                        // `accentButtonFill`, not `accentGradient`: the
                        // label is white, and only the button stops are
                        // guaranteed 4.8:1 against it along the whole width.
                        Capsule().fill(themeStore.current.accentButtonFill)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(game.launchExe == nil)
            .padding(.bottom, Theme.Spacing.m)
            .help(compatibility.isBlocking ? "Play anyway \u{2014} \(compatibility.detail)" : "Play")
            .accessibilityLabel("Play \(game.name)")
        }
        .transition(.opacity)
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
                .font(Theme.titleFont(34, weight: .bold))
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

/// The list-mode counterpart of `GameCard`, kept coherent with it: same
/// selection model, same rule that only a noteworthy rating is shown (as an
/// inline badge beside the name, the way Programs shows its "System" chip),
/// and the same demotion of Play for a `.wontRun` game.
private struct GameRow: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeStore.self) private var themeStore
    let game: InstalledGame
    let bottle: Bottle
    let compatibility: Compatibility
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            // A will-not-run game swaps the controller glyph for the same
            // symbol its badge uses, in the danger ink, so the problem is
            // visible down the left edge of a long list, not only in a badge
            // that may be scanned past.
            Image(systemName: compatibility.isBlocking ? compatibility.systemImage : "gamecontroller.fill")
                .font(Theme.rowTitleFont)
                .foregroundStyle(compatibility.isBlocking ? Theme.Tone.danger.ink : Color.secondary)
                .frame(width: 16)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                HStack(spacing: Theme.Spacing.compact) {
                    Text(game.name)
                        .font(Theme.rowTitleFont)
                        .foregroundStyle(compatibility.isBlocking ? .secondary : .primary)
                        .lineLimit(1)
                    if compatibility.isNoteworthy {
                        CompatibilityBadge(compatibility: compatibility, style: .inline)
                    }
                }
                Text(game.subtitle)
                    .font(Theme.rowSubtitleFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(compatibility.help(for: game.name, subtitle: game.subtitle))

            Spacer(minLength: Theme.Spacing.m)

            if isHovering || isSelected {
                Button(action: play) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11))
                        .frame(width: Theme.Metrics.iconButton, height: Theme.Metrics.iconButton)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .fixedSize()
                .disabled(game.launchExe == nil)
                .help(compatibility.isBlocking ? "Play anyway \u{2014} \(compatibility.detail)" : "Play")
                .accessibilityLabel("Play \(game.name)")
            }
        }
        .padding(.horizontal, Theme.Spacing.m)
        .frame(height: Theme.Metrics.listRow)
        // Selection tint, then a faint hover wash (matches the Programs
        // rows). Selection wins over hover so the accent stays the one
        // strong signal. 0.05 is the same primary-colour wash the quiet
        // button style uses for its resting fill.
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .fill(themeStore.current.badgeTint.opacity(Theme.Opacity.wash))
            } else if isHovering {
                // Rounded like the Programs rows' wash, so it does not poke
                // out of the list card's corners on the first and last row.
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { play() }
        .onTapGesture(count: 1) { onSelect() }
        .onHover { isHovering = $0 }
        // Hover-only play button: same keyboard/VoiceOver route as GameCard.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: "Play") { play() }
        .contextMenu {
            Button("Play") { play() }
                .disabled(game.launchExe == nil)
            Button("Reveal in Finder") { reveal() }
                .disabled(revealTarget == nil)
            Button("Copy launch command") { copyLaunchCommand() }
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
