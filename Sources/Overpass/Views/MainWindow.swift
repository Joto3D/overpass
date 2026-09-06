import SwiftUI

/// Top-level split view: bottles + Engines + Settings in the sidebar, the
/// selected item's detail on the right. Detail views are provided by the
/// feature files (BottleDetailView, EnginesView, SettingsView).
struct MainWindow: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        NavigationSplitView {
            List(selection: $appState.selection) {
                Section("Bottles") {
                    ForEach(appState.bottles) { bottle in
                        Label(bottle.name, systemImage: "cylinder")
                            .tag(AppState.SidebarItem.bottle(bottle.id))
                    }
                }
                Section("Overpass") {
                    Label("Engines", systemImage: "gearshape.2")
                        .tag(AppState.SidebarItem.engines)
                    Label("Settings", systemImage: "slider.horizontal.3")
                        .tag(AppState.SidebarItem.settings)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            switch appState.selection {
            case .bottle(let id):
                if let bottle = appState.bottles.first(where: { $0.id == id }) {
                    BottleDetailView(bottleID: bottle.id)
                } else {
                    ContentUnavailableView("Bottle not found", systemImage: "questionmark.circle")
                }
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
    }
}
