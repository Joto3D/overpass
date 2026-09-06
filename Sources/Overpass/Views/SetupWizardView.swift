import SwiftUI

/// First-run wizard shown as a sheet when `AppState.showSetupWizard` is
/// true: Rosetta check, install the default engine, create the first
/// bottle. Every step reflects live `AppState` — reopening the wizard
/// later (it won't, normally, since `MainWindow` only sets the flag once)
/// would just show whatever's still missing.
struct SetupWizardView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var bottleName: String = "Default"
    @State private var isInstallingEngine = false
    @State private var isCreatingBottle = false

    private var defaultRelease: EngineRelease { EngineCatalog.defaultRelease }

    private var rosettaInstalled: Bool { AppState.rosettaInstalled() }

    private var defaultEngineInstalled: Bool {
        appState.installedEngines.contains { $0.id == defaultRelease.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to Overpass")
                    .font(Theme.titleFont())
                Text("A few one-time steps to get Wine running.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                rosettaStep
                engineStep
                if defaultEngineInstalled {
                    bottleStep
                }
            }

            HStack {
                Spacer()
                Button("Finish") {
                    appState.showSetupWizard = false
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 460)
    }

    @ViewBuilder
    private var rosettaStep: some View {
        StatusPillCard(
            title: "Rosetta 2",
            ok: rosettaInstalled,
            subtitle: rosettaInstalled
                ? "Installed"
                : "Not installed. Run in Terminal: softwareupdate --install-rosetta --agree-to-license",
            systemImage: "cpu"
        )
    }

    @ViewBuilder
    private var engineStep: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            StatusPillCard(
                title: defaultRelease.displayName,
                ok: defaultEngineInstalled,
                subtitle: defaultEngineInstalled
                    ? "Installed"
                    : (appState.engineInstallStatus[defaultRelease.id] ?? "Not installed yet"),
                systemImage: "gearshape.2"
            )

            if !defaultEngineInstalled {
                if let progress = appState.engineInstallProgress[defaultRelease.id] {
                    ProgressView(value: progress)
                }
                Button("Install \(defaultRelease.displayName)") {
                    isInstallingEngine = true
                    Task {
                        await appState.installEngine(defaultRelease)
                        isInstallingEngine = false
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isInstallingEngine || appState.engineInstallProgress[defaultRelease.id] != nil)
            }
        }
    }

    @ViewBuilder
    private var bottleStep: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Divider()
            Text("Create your first bottle")
                .font(Theme.headingFont())

            if appState.bottles.isEmpty {
                HStack {
                    TextField("Bottle name", text: $bottleName)
                    Button("Create") {
                        isCreatingBottle = true
                        Task {
                            await appState.createBottle(name: bottleName, engineID: defaultRelease.id, windowsVersion: .win10)
                            isCreatingBottle = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isCreatingBottle || bottleName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if isCreatingBottle {
                    HStack(spacing: Theme.Spacing.s) {
                        ProgressView().controlSize(.small)
                        Text(appState.bottleCreationStatus.values.first ?? "Creating…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Label("Bottle \"\(appState.bottles[0].name)\" is ready.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            }
        }
    }
}
