import SwiftUI

/// Top-level split view: bottles + Engines + Settings in the sidebar, the
/// selected item's detail on the right. Detail views are provided by the
/// feature files (BottleDetailView, EnginesView, SettingsView). Also owns
/// startup loading, the New Bottle sheet, the first-run setup wizard, and
/// routing Finder/drop "open files" to a bottle.
struct MainWindow: View {
    @Environment(AppState.self) private var appState
    @State private var showNewBottleSheet = false
    @State private var showImportBottleSheet = false
    @State private var bottlePendingDelete: Bottle?

    var body: some View {
        @Bindable var appState = appState
        NavigationSplitView {
            List(selection: $appState.selection) {
                Section {
                    // An empty Bottles section was just a header over
                    // nothing. This untagged row is not selectable (only
                    // tagged rows are), says what the section is for, and
                    // offers the same sheet as the toolbar's Add menu.
                    if appState.bottles.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                            Text("No bottles yet")
                                .font(Theme.rowSubtitleFont)
                                .foregroundStyle(.secondary)
                            Button("New bottle\u{2026}") { showNewBottleSheet = true }
                                .buttonStyle(.quietCompact)
                        }
                        .padding(.vertical, Theme.Spacing.s)
                    }
                    ForEach(appState.bottles) { bottle in
                        BottleSidebarRow(bottle: bottle, engine: appState.engine(for: bottle))
                            .tag(AppState.SidebarItem.bottle(bottle.id))
                            .contextMenu {
                                Button("Delete…", role: .destructive) {
                                    bottlePendingDelete = bottle
                                }
                            }
                    }
                } header: {
                    SidebarSectionHeader(
                        title: "Bottles",
                        info: "A bottle is a private Windows environment — its own C: drive, installed programs, and engine. Programs in one bottle can't see another bottle's files."
                    )
                }
                Section {
                    Label("Install app", systemImage: "square.and.arrow.down.on.square")
                        .frame(height: Theme.Metrics.row)
                        .tag(AppState.SidebarItem.installApps)
                    Label("Engines", systemImage: "gearshape.2")
                        .frame(height: Theme.Metrics.row)
                        .tag(AppState.SidebarItem.engines)
                    Label("Settings", systemImage: "slider.horizontal.3")
                        .frame(height: Theme.Metrics.row)
                        .tag(AppState.SidebarItem.settings)
                } header: {
                    SidebarSectionHeader(title: "Library")
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("New bottle…") { showNewBottleSheet = true }
                        Button("Import bottle…") { showImportBottleSheet = true }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .help("Create or import a bottle")
                }
            }
        } detail: {
            switch appState.selection {
            case .bottle(let id):
                if let bottle = appState.bottles.first(where: { $0.id == id }) {
                    BottleDetailView(bottleID: bottle.id)
                } else {
                    ContentUnavailableView("Bottle not found", systemImage: "questionmark.circle")
                }
            case .installApps:
                AppCatalogView()
            case .engines:
                EnginesView()
            case .settings:
                SettingsView()
            case nil:
                if appState.bottles.isEmpty {
                    // Nothing to select yet, so "Select a bottle" pointed at
                    // nothing. Same wording as before for what a bottle is
                    // for, but with the two ways to get one right here
                    // (the same two sheets as the sidebar's Add menu).
                    ContentUnavailableView {
                        Label("No bottles yet", systemImage: "cylinder")
                    } description: {
                        Text("Create a bottle to run Windows programs.")
                    } actions: {
                        HStack(spacing: Theme.Spacing.s) {
                            Button("New bottle\u{2026}") { showNewBottleSheet = true }
                                .buttonStyle(.accentCompact)
                            Button("Import bottle\u{2026}") { showImportBottleSheet = true }
                                .buttonStyle(.quietCompact)
                        }
                    }
                } else {
                    ContentUnavailableView("Select a bottle", systemImage: "cylinder",
                                           description: Text("Create a bottle to run Windows programs."))
                }
            }
        }
        // The window's default/min size is declared on the `Window` scene
        // in OverpassApp.swift (owned by another agent this pass); this
        // frame enforces the spec's 960×640 floor from our side too so the
        // split view never collapses below it regardless of what the scene
        // declares.
        .frame(minWidth: 960, minHeight: 640)
        // Not a plain `.alert`: this one stands down while a sheet is open
        // (every sheet below opts in) so an error is never queued invisibly
        // behind the setup wizard. See `SheetPresence` in Components.swift.
        .rootErrorAlert()
        .confirmationDialog(
            "Delete \"\(bottlePendingDelete?.name ?? "")\"?",
            isPresented: Binding(
                get: { bottlePendingDelete != nil },
                set: { if !$0 { bottlePendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let bottle = bottlePendingDelete {
                    Task { await appState.deleteBottle(bottle) }
                }
                bottlePendingDelete = nil
            }
            Button("Cancel", role: .cancel) { bottlePendingDelete = nil }
        } message: {
            Text("This moves the bottle's Wine prefix to the Trash. This can't be undone from within Overpass.")
        }
        .sheet(isPresented: $showNewBottleSheet) {
            NewBottleSheet()
        }
        .sheet(isPresented: $showImportBottleSheet) {
            ImportBottleSheet()
        }
        .sheet(isPresented: $appState.showSetupWizard) {
            SetupWizardView()
        }
        .sheet(isPresented: Binding(
            get: { appState.bottles.count > 1 && !appState.pendingOpenFiles.isEmpty },
            set: { if !$0 { appState.pendingOpenFiles.removeAll() } }
        )) {
            BottlePickerSheet()
        }
        .task {
            try? Paths.ensureAll()
            // Await the engine load directly (rather than firing it off and
            // polling `installedEngines` on a timer) so the setup-wizard
            // decision below is made from a value that has actually
            // finished loading — deterministic, and a normal relaunch with
            // everything already installed never flashes the wizard.
            await appState.loadEnginesNow()
            appState.loadBottles()
            if appState.installedEngines.isEmpty || appState.bottles.isEmpty {
                appState.showSetupWizard = true
            } else if appState.selection == nil {
                appState.selection = appState.bottles.first.map { .bottle($0.id) }
            }
        }
        .onChange(of: appState.pendingOpenFiles) { _, files in
            guard !files.isEmpty else { return }
            // Exactly one bottle: skip the picker sheet and run directly.
            guard appState.bottles.count == 1, let bottle = appState.bottles.first else { return }
            appState.pendingOpenFiles.removeAll()
            Task {
                for file in files {
                    await appState.run(exe: file, in: bottle)
                }
            }
        }
    }
}
