import SwiftUI

/// Presented when `AppState.pendingOpenFiles` is non-empty (Finder
/// "Open With" / dock drop) and more than one bottle exists — with exactly
/// one bottle, `MainWindow` runs the files there directly and this sheet
/// never appears.
struct BottlePickerSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var selectedBottleID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            Text("Open with Overpass")
                .font(Theme.titleFont(18))
            Text(fileListDescription)
                .font(.callout)
                .foregroundStyle(.secondary)

            List(appState.bottles, selection: $selectedBottleID) { bottle in
                HStack {
                    Label(bottle.name, systemImage: "cylinder")
                    Spacer()
                    if let engine = appState.engine(for: bottle) {
                        Text(engine.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(bottle.id)
            }
            .frame(minHeight: 160)

            HStack {
                Spacer()
                Button("Cancel") {
                    appState.pendingOpenFiles.removeAll()
                    dismiss()
                }
                Button("Run") { runSelected() }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedBottleID == nil)
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 420)
        .onAppear {
            selectedBottleID = appState.bottles
                .sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
                .first?.id
        }
    }

    private var fileListDescription: String {
        let names = appState.pendingOpenFiles.map(\.lastPathComponent).joined(separator: ", ")
        return "Run \(names) in:"
    }

    private func runSelected() {
        guard let id = selectedBottleID, let bottle = appState.bottles.first(where: { $0.id == id }) else { return }
        let files = appState.pendingOpenFiles
        appState.pendingOpenFiles.removeAll()
        Task {
            for file in files {
                await appState.run(exe: file, in: bottle)
            }
        }
        dismiss()
    }
}
