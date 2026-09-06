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
                header

                if appState.installedEngines.isEmpty {
                    noEngineNotice
                }

                searchField

                categoryChips

                if filteredApps.isEmpty {
                    ContentUnavailableView.search(text: query)
                        .frame(maxWidth: .infinity)
                        .padding(.top, Theme.Spacing.xl)
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
            .padding(Theme.Spacing.xl)
        }
        .sheet(item: $selectedApp) { app in
            AppCatalogDetailSheet(app: app)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("Install App")
                .font(Theme.titleFont())
            Text("Search for a Windows app and Overpass will download its installer and run it in a bottle, CrossOver-style.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var noEngineNotice: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.s) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
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
            .buttonStyle(.quiet)
        }
        .padding(Theme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overpassCard(cornerRadius: Theme.Radius.row)
    }

    private var searchField: some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search apps (Steam, 7-Zip, VLC…)", text: $query)
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
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
    }
}

// MARK: - Catalog card

private struct AppCatalogCard: View {
    @Environment(ThemeStore.self) private var themeStore
    let app: CatalogApp

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
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name)
                        .font(Theme.headingFont(15))
                        .lineLimit(1)
                    Text(app.publisher)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            Text(app.blurb)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            FlowLayout(spacing: 4) {
                if app.hasSilentInstall {
                    Chip(text: "Silent install", systemImage: "checkmark.seal", tint: .green)
                }
                if app.recommendedWindows != .win10 {
                    Chip(text: "Needs \(app.recommendedWindows.displayName)", systemImage: "macwindow", tint: .orange)
                }
                if app.preferredEngine == .gptk {
                    Chip(text: "GPTK recommended", systemImage: "bolt.fill", tint: .blue)
                }
            }
        }
        .padding(Theme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private let installState = AppInstallState.shared

    private var isActive: Bool { installState.activeAppID == app.id }
    private var isDone: Bool { isActive && installState.phase == "Done" }
    private var isFailed: Bool { isActive && installState.phase == "Failed" }
    private var isInstalling: Bool { isActive && !isDone && !isFailed }

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
        .frame(width: 460, height: 560)
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
                    .font(Theme.titleFont(20))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Text(app.publisher)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(app.blurb)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if app.installerURL == nil {
                Chip(text: "Installed via winetricks only", systemImage: "shippingbox", tint: .secondary)
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
            FlowLayout(spacing: 6) {
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
                Button(isFailed ? "Retry Install" : "Install") {
                    Task { await performInstall() }
                }
                .buttonStyle(.aurora)
                .disabled(bottleChoice == nil)
                if let error = installState.lastError, isFailed {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
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

            outputBox
        }
    }

    private var outputBox: some View {
        let lines = installState.output.suffix(15)
        return ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 140)
        .padding(Theme.Spacing.s)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(Color.black.opacity(0.25))
        }
    }

    private func performInstall() async {
        guard let bottleChoice else { return }

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
            await appState.createBottle(name: app.name, engineID: engineID, windowsVersion: app.recommendedWindows)
            if case .bottle(let newID)? = appState.selection {
                resolvedBottle = appState.bottles.first { $0.id == newID }
            } else {
                resolvedBottle = appState.bottles.first { $0.name == app.name }
            }
        }

        guard let bottle = resolvedBottle, let engine = appState.engine(for: bottle) else {
            appState.report("Couldn't find a bottle with an installed engine to install \(app.name) into.")
            return
        }

        targetBottleID = bottle.id
        await AppInstaller.install(app, into: bottle, engine: engine, appState: appState)
    }
}
