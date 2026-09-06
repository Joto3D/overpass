import SwiftUI
import AppKit

@main
struct OverpassApp: App {
    @NSApplicationDelegateAdaptor(OverpassAppDelegate.self) private var appDelegate
    @State private var appState = AppState()
    @State private var themeStore = ThemeStore()

    init() {
        // SPM executables have no app bundle at dev time, so AppKit doesn't
        // automatically switch us into a regular foreground app with a menu
        // bar and a real window. Do that manually so `swift run` behaves
        // like a normal macOS app during development.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("Overpass", id: "main") {
            MainWindow()
                .environment(appState)
                .environment(themeStore)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear { appDelegate.appState = appState }
        }
        .defaultSize(width: 980, height: 640)
        .windowResizability(.contentMinSize)
    }
}

/// Receives Finder "Open With" / dock-drop file events and hands them to
/// `AppState.pendingOpenFiles`; the UI decides which bottle runs them.
final class OverpassAppDelegate: NSObject, NSApplicationDelegate {
    weak var appState: AppState?
    private var queued: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            if let appState {
                appState.pendingOpenFiles.append(contentsOf: urls)
            } else {
                queued.append(contentsOf: urls)
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in
            guard let appState, !queued.isEmpty else { return }
            appState.pendingOpenFiles.append(contentsOf: queued)
            queued.removeAll()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
