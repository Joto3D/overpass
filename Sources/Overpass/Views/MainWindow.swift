import SwiftUI

/// Top-level split view: bottles + Engines + Settings in the sidebar, the
/// selected item's detail on the right. Detail views are provided by the
/// feature files (BottleDetailView, EnginesView, SettingsView). Also owns
/// startup loading, the New Bottle sheet, the first-run setup wizard, and
/// routing Finder/drop "open files" to a bottle.
struct MainWindow: View {
    @Environment(AppState.self) private var appState
    @State private var showNewBottleSheet = false
    @State private var bottlePendingDelete: Bottle?

    var body: some View {
        @Bindable var appState = appState
        NavigationSplitView {
            List(selection: $appState.selection) {
                Section("Bottles") {
                    ForEach(appState.bottles) { bottle in
                        Label(bottle.name, systemImage: "cylinder")
                            .tag(AppState.SidebarItem.bottle(bottle.id))
                            .contextMenu {
                                Button("Delete…", role: .destructive) {
                                    bottlePendingDelete = bottle
                                }
                            }
                    }
                }
                Section("Overpass") {
                    Label("Install App", systemImage: "square.and.arrow.down.on.square")
                        .tag(AppState.SidebarItem.installApps)
                    Label("Engines", systemImage: "gearshape.2")
                        .tag(AppState.SidebarItem.engines)
                    Label("Settings", systemImage: "slider.horizontal.3")
                        .tag(AppState.SidebarItem.settings)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showNewBottleSheet = true
                    } label: {
                        Label("New Bottle", systemImage: "plus")
                    }
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
                ContentUnavailableView("Select a bottle", systemImage: "cylinder",
                                       description: Text("Create a bottle to run Windows programs."))
            }
        }
        .alert("Overpass", isPresented: Binding(
            get: { appState.errorMessage != nil },
            set: { if !$0 { appState.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { appState.errorMessage = nil }
        } message: {
            Text(appState.errorMessage ?? "")
        }
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
            appState.loadEngines()
            appState.loadBottles()
            // `loadEngines()` refreshes `installedEngines` via an internal
            // detached `Task`, so it isn't necessarily populated yet on the
            // very next line. Give it a moment to land before deciding
            // whether to show the setup wizard, so a normal relaunch with
            // everything already installed doesn't flash it.
            for _ in 0..<20 {
                if !appState.installedEngines.isEmpty || appState.bottles.isEmpty { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
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
