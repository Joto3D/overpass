import SwiftUI

/// The "Install App" screen: search/browse the curated `AppCatalog`, pick a
/// bottle (or create one), and download+install silently through
/// `AppInstaller`. Progress lives in `AppInstallState.shared` so the
/// detail sheet stays live while the install runs in the background.
struct AppCatalogView: View {
    @Environment(AppState.self) private var appState
    @State private var query = ""
    @State private var selectedCategory: AppCategory?
    @State private var selectedApp: CatalogApp?

    private var filteredApps: [CatalogApp] {
        let base = AppCatalog.search(query)
        guard let selectedCategory else { return base }
        return base.filter { $0.category == selectedCategory }
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: Theme.Spacing.l)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                if appState.installedEngines.isEmpty {
                    noEngineNotice
                }

                searchField

                categoryChips

                if filteredApps.isEmpty {
                    EmptyStateMessage(query.isEmpty ? "No apps in this category." : "No apps match \u{201c}\(query)\u{201d}.")
                } else {
                    LazyVGrid(columns: columns, spacing: Theme.Spacing.l) {
                        ForEach(filteredApps) { app in
                            Button {
                                selectedApp = app
                            } label: {
                                AppCatalogCard(app: app)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(Theme.Spacing.outer)
        }
        .sheet(item: $selectedApp) { app in
            AppCatalogDetailSheet(app: app)
        }
    }

    private var noEngineNotice: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.s) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("No engine installed yet")
                    .font(Theme.headingFont(13))
                Text("Install a Wine engine before installing an app — Overpass needs one to run any installer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Go to Engines") {
                appState.selection = .engines
            }
            // Compact: the full-width quiet style would stretch across this
            // row and squeeze the notice text beside it.
            .buttonStyle(.quietCompact)
        }
        .padding(Theme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overpassCard(cornerRadius: Theme.Radius.row)
    }

    private var searchField: some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search apps (Steam, 7-Zip, VLC…)", text: $query)
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .frame(width: Theme.Metrics.iconButton, height: Theme.Metrics.iconButton)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.s)
        .overpassCard(cornerRadius: Theme.Radius.pill)
    }

    private var categoryChips: some View {
        FlowLayout(spacing: Theme.Spacing.s) {
            categoryChip(nil, label: "All")
            ForEach(AppCategory.allCases) { category in
                categoryChip(category, label: category.rawValue)
            }
        }
    }

    private func categoryChip(_ category: AppCategory?, label: String) -> some View {
        Button {
            selectedCategory = category
        } label: {
            Chip(
                text: label,
                systemImage: category?.systemImage,
                tint: .secondary,
                prominent: selectedCategory == category
            )
        }
        .buttonStyle(.plain)
        // The selected category is shown only by the chip's gradient fill;
        // this is the non-visual equivalent.
        .accessibilityAddTraits(selectedCategory == category ? .isSelected : [])
    }
}

// MARK: - Catalog card

private struct AppCatalogCard: View {
    @Environment(ThemeStore.self) private var themeStore
    let app: CatalogApp

    /// At most one badge per card, in priority order: an engine
    /// requirement matters most, then a non-default Windows version, then
    /// silent-install as a "nice to know" fallback. Each carries a `help`
    /// tooltip so the badge's short label isn't the only explanation a
    /// newcomer gets of what it means.
    private var badge: (text: String, systemImage: String, tint: Color, help: String)? {
        if app.preferredEngine == .gptk {
            return ("GPTK recommended", "bolt.fill", .blue, "Works best with the Game Porting Toolkit engine — installing into a Wine Staging bottle may run worse or not at all.")
        }
        if app.recommendedWindows != .win10 {
            return ("Needs \(app.recommendedWindows.displayName)", "macwindow", .orange, "This installer expects a bottle set to \(app.recommendedWindows.displayName).")
        }
        if app.hasSilentInstall {
            return ("Silent install", "checkmark.seal", .green, "Overpass runs this installer with its unattended flags — no dialogs to click through.")
        }
        return nil
    }

    /// Fixed so every card in the grid is the same height regardless of
    /// whether a badge is present or how long the name/blurb run.
    private static let cardHeight: CGFloat = 182

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack(alignment: .top, spacing: Theme.Spacing.m) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.Radius.icon, style: .continuous)
                        .fill(themeStore.current.accentGradient.opacity(0.85))
                    Image(systemName: app.iconSymbol)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white)
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(app.name)
                        .font(Theme.headingFont(15))
                        .lineLimit(2)
                    Text(app.publisher)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            // Two lines is a deliberate cap (every card in the grid is the
            // same fixed height); the full blurb is one hover away and is
            // shown in full at the top of the detail sheet.
            Text(app.blurb)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(app.blurb)

            Spacer(minLength: 0)

            if let badge {
                Chip(text: badge.text, systemImage: badge.systemImage, tint: badge.tint)
                    .help(badge.help)
            }
        }
        .padding(Theme.Spacing.l)
        .frame(maxWidth: .infinity, minHeight: Self.cardHeight, maxHeight: Self.cardHeight, alignment: .topLeading)
        .overpassCard()
    }
}

// MARK: - Detail + install sheet

private struct AppCatalogDetailSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let app: CatalogApp

    private enum BottleChoice: Hashable {
        case existing(UUID)
        case newBottle
    }

    @State private var bottleChoice: BottleChoice?
    /// The bottle an install actually targeted, resolved once the install
    /// starts (for `.newBottle`, only known after `createBottle` returns).
    @State private var targetBottleID: UUID?
    @State private var isLogExpanded = false

    private let installState = AppInstallState.shared

    private var isActive: Bool { installState.activeAppID == app.id }
    private var isDone: Bool { isActive && installState.phase == "Done" }
    private var isFailed: Bool { isActive && installState.phase == "Failed" }
    private var isInstalling: Bool { isActive && !isDone && !isFailed }

    /// True while a *different* catalog app is mid-install. `AppInstallState`
    /// is one shared instance: a second `begin()` would take over
    /// `activeAppID`, and when the first install finished, its
    /// `finish(error:)` would mark the second app as done or failed. So the
    /// Install button stays disabled until the running install ends.
    /// `activeAppID` is left set after an install finishes (the card keeps
    /// showing its result), so "Done"/"Failed" count as no longer running.
    private var anotherInstallRunning: Bool {
        guard let activeID = installState.activeAppID, activeID != app.id else { return false }
        return installState.phase != "Done" && installState.phase != "Failed"
    }

    private var launchPin: PinnedProgram? {
        guard isDone, let targetBottleID, let bottle = appState.bottles.first(where: { $0.id == targetBottleID }) else { return nil }
        return bottle.pins.first { $0.name == app.name }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                header
                if let notes = app.postInstallNotes {
                    notesBlock(notes)
                }
                if !app.winetricksVerbs.isEmpty {
                    prerequisitesBlock
                }
                installSection
            }
            .padding(Theme.Spacing.xl)
        }
        .frame(width: Theme.Metrics.sheetWidth, height: 560)
        // Starting an install can fail through `AppState.report` (no engine,
        // bottle creation failed, the installer errored) while this sheet is
        // open; the root alert would sit behind it.
        .hostsErrorAlert()
        .onAppear {
            if bottleChoice == nil {
                bottleChoice = appState.bottles.first.map { .existing($0.id) } ?? .newBottle
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack {
                Text(app.name)
                    .font(Theme.sheetTitleFont)
                    .lineLimit(2)
                Spacer()
                SheetCloseButton { dismiss() }
            }
            Text(app.publisher)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(app.blurb)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if app.installerURL == nil {
                Chip(text: "Installed via winetricks only", systemImage: "shippingbox", tint: .secondary)
                    .help("No separate download — this runs entirely through Winetricks, the same verb installer as the Extras tab.")
            }
        }
    }

    private func notesBlock(_ notes: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            SectionHeader(title: "Notes", systemImage: "info.circle")
            Text(notes)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overpassCard(cornerRadius: Theme.Radius.row)
    }

    private var prerequisitesBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            SectionHeader(title: "Prerequisites", systemImage: "list.bullet")
            FlowLayout {
                ForEach(app.winetricksVerbs, id: \.self) { verb in
                    Chip(text: verb, systemImage: "shippingbox")
                }
            }
        }
    }

    @ViewBuilder
    private var installSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            SectionHeader(title: "Install", systemImage: "arrow.down.circle")

            if appState.installedEngines.isEmpty {
                Text("Install a Wine engine first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Go to Engines") {
                    dismiss()
                    appState.selection = .engines
                }
                .buttonStyle(.quiet)
            } else if !isActive || isFailed {
                bottlePicker
                Button(isFailed ? "Retry install" : "Install") {
                    Task { await performInstall() }
                }
                .buttonStyle(.aurora)
                .disabled(bottleChoice == nil || anotherInstallRunning)
                if anotherInstallRunning {
                    Text("Another app is installing right now. Wait for it to finish, then come back to install \(app.name).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = installState.lastError, isFailed {
                    ErrorText(error)
                }
            } else {
                progressBlock
            }
        }
    }

    private var bottlePicker: some View {
        Picker("Bottle", selection: $bottleChoice) {
            ForEach(appState.bottles) { bottle in
                Text(bottle.name).tag(BottleChoice.existing(bottle.id) as BottleChoice?)
            }
            Text("New bottle named \"\(app.name)\"").tag(BottleChoice.newBottle as BottleChoice?)
        }
        .pickerStyle(.menu)
        .labelsHidden()
    }

    private var progressBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            if isDone {
                Label("Done", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(Theme.headingFont(14))
                if let pin = launchPin, let bottle = appState.bottles.first(where: { $0.id == targetBottleID }) {
                    Button("Launch \(app.name)") {
                        Task { await appState.run(exe: URL(fileURLWithPath: pin.exePath), args: pin.args, in: bottle) }
                    }
                    .buttonStyle(.aurora)
                }
            } else {
                ProgressView(value: installState.progress)
                Text(installState.phase)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup("Log", isExpanded: $isLogExpanded) {
                OutputBox(lines: Array(installState.output.suffix(15)), height: 120)
                    .padding(.top, Theme.Spacing.xs)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func performInstall() async {
        guard let bottleChoice, !anotherInstallRunning else { return }

        let resolvedBottle: Bottle?
        switch bottleChoice {
        case .existing(let id):
            resolvedBottle = appState.bottles.first { $0.id == id }
        case .newBottle:
            let engineID = app.preferredEngine
                .flatMap { kind in appState.installedEngines.first { $0.kind == kind }?.id }
                ?? appState.installedEngines.first?.id
            guard let engineID else {
                appState.report("No installed engine to create a bottle with.")
                return
            }
            // Use the bottle `createBottle` hands back, never a lookup by
            // name or by `selection`: those could match a leftover bottle
            // from an earlier attempt and silently install into it. On nil
            // creation failed and `createBottle` has already reported the
            // real error; reporting again here would overwrite it with a
            // vaguer message.
            guard let created = await appState.createBottle(name: app.name, engineID: engineID, windowsVersion: app.recommendedWindows) else {
                return
            }
            resolvedBottle = created
        }

        guard let bottle = resolvedBottle, let engine = appState.engine(for: bottle) else {
            appState.report("Couldn't find a bottle with an installed engine to install \(app.name) into.")
            return
        }

        targetBottleID = bottle.id
        await AppInstaller.install(app, into: bottle, engine: engine, appState: appState)
    }
}
