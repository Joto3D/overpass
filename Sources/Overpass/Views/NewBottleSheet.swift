import SwiftUI

/// Sheet for creating a bottle: name, installed-engine picker, Windows
/// version, and a Create button that shows `AppState.bottleCreationStatus`
/// while `wineboot -i` / `winecfg -v` run.
struct NewBottleSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = "Default"
    @State private var engineID: String = ""
    @State private var windowsVersion: WindowsVersion = .win10
    @State private var isCreating = false

    private var canCreate: Bool {
        !isCreating && !engineID.isEmpty && !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var selectedEngineKind: EngineKind? {
        appState.installedEngines.first { $0.id == engineID }?.kind
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            Text("New Bottle")
                .font(Theme.titleFont(18))

            if appState.installedEngines.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    Text("No engines are installed yet. Install one from the Engines screen first.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Go to Engines") {
                        appState.selection = .engines
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                Form {
                    TextField("Name", text: $name)
                    Picker("Engine", selection: $engineID) {
                        ForEach(appState.installedEngines) { engine in
                            Text(engine.displayName).tag(engine.id)
                        }
                    }
                    Picker("Windows Version", selection: $windowsVersion) {
                        ForEach(WindowsVersion.allCases) { version in
                            Text(version.displayName).tag(version)
                        }
                    }
                }
                .formStyle(.grouped)

                if let selectedEngineKind {
                    Text(engineTradeoffCaption(for: selectedEngineKind))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Theme.Spacing.s)
                }

                if isCreating {
                    HStack(spacing: Theme.Spacing.s) {
                        ProgressView().controlSize(.small)
                        Text(appState.bottleCreationStatus.values.first ?? "Creating…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .disabled(isCreating)
                if !appState.installedEngines.isEmpty {
                    Button("Create") { create() }
                        .buttonStyle(.accent)
                        .fixedSize()
                        .disabled(!canCreate)
                }
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 460)
        .onAppear {
            if engineID.isEmpty {
                engineID = appState.installedEngines.first?.id ?? ""
            }
        }
    }

    private func create() {
        isCreating = true
        Task {
            await appState.createBottle(name: name, engineID: engineID, windowsVersion: windowsVersion)
            isCreating = false
            dismiss()
        }
    }
}
