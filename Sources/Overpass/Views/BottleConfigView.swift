import SwiftUI
import AppKit

/// A bottle's "Config" tab: a form editing a local copy of the `Bottle`
/// that saves through `appState.updateBottle` whenever a field changes,
/// plus the tools row (winecfg/regedit/explorer/taskmgr/Open C: drive)
/// and a danger zone to kill everything running in the bottle.
struct BottleConfigView: View {
    let bottleID: UUID
    @Environment(AppState.self) private var appState

    @State private var local: Bottle?
    @State private var isApplyingWindowsVersion = false
    @State private var newEnvKey = ""
    @State private var newEnvValue = ""

    private var storedBottle: Bottle? {
        appState.bottles.first { $0.id == bottleID }
    }

    private var engine: InstalledEngine? {
        local.flatMap { bottle in appState.installedEngines.first { $0.id == bottle.engineID } }
    }

    var body: some View {
        Group {
            if let local {
                Form {
                    identitySection(local)
                    engineSection(local)
                    togglesSection(local)
                    environmentSection(local)
                    toolsSection(local)
                    dangerSection(local)
                }
                .formStyle(.grouped)
            } else {
                ContentUnavailableView("Bottle not found", systemImage: "questionmark.circle")
            }
        }
        .onAppear { local = storedBottle }
        .onChange(of: bottleID) { _, _ in local = storedBottle }
    }

    // MARK: - Sections

    private func identitySection(_ bottle: Bottle) -> some View {
        Section("Bottle") {
            TextField("Name", text: binding(\.name))
                .onSubmit { save() }

            LabeledContent("Prefix path") {
                HStack(spacing: Theme.Spacing.xs) {
                    Text(bottle.prefixDir.path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button {
                        copyToClipboard(bottle.prefixDir.path)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy prefix path")
                }
            }
        }
    }

    private func engineSection(_ bottle: Bottle) -> some View {
        Section("Engine") {
            Picker("Engine", selection: binding(\.engineID)) {
                ForEach(appState.installedEngines) { engine in
                    Text(engine.displayName).tag(engine.id)
                }
            }
            .onChange(of: bottle.engineID) { _, _ in save() }

            Text("Changing engine keeps the prefix; some programs may need reinstalling.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Windows Version", selection: binding(\.windowsVersion)) {
                ForEach(WindowsVersion.allCases) { version in
                    Text(version.displayName).tag(version)
                }
            }
            .onChange(of: bottle.windowsVersion) { _, newValue in
                save()
                applyWindowsVersion(newValue)
            }

            if isApplyingWindowsVersion {
                HStack(spacing: Theme.Spacing.s) {
                    ProgressView().controlSize(.small)
                    Text("Applying Windows version\u{2026}")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func togglesSection(_ bottle: Bottle) -> some View {
        Section("Runtime") {
            Toggle("ESync", isOn: binding(\.esync))
                .onChange(of: bottle.esync) { _, _ in save() }
            Toggle("MSync", isOn: binding(\.msync))
                .onChange(of: bottle.msync) { _, _ in save() }
            Toggle("Metal HUD", isOn: binding(\.metalHUD))
                .onChange(of: bottle.metalHUD) { _, _ in save() }
            Toggle("Verbose logging", isOn: binding(\.verboseLog))
                .onChange(of: bottle.verboseLog) { _, _ in save() }

            let dxvkSupported = engine?.kind.supportsDXVK ?? false
            Toggle("DXVK", isOn: binding(\.dxvk))
                .disabled(!dxvkSupported)
                .onChange(of: bottle.dxvk) { _, _ in save() }
                .help(dxvkSupported
                      ? "DXVK files are managed on the Extras tab."
                      : "DXVK is only available on Wine Staging engines.")
            Text("DXVK files are managed on the Extras tab.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func environmentSection(_ bottle: Bottle) -> some View {
        Section("Environment Variables") {
            ForEach(sortedEnvKeys(bottle), id: \.self) { key in
                HStack {
                    Text(key)
                        .font(.system(.body, design: .monospaced))
                    Spacer()
                    Text(bottle.env[key] ?? "")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button(role: .destructive) {
                        removeEnv(key)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }

            HStack {
                TextField("KEY", text: $newEnvKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 140)
                TextField("value", text: $newEnvValue)
                    .textFieldStyle(.roundedBorder)
                Button("Add") { addEnv() }
                    .disabled(newEnvKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func toolsSection(_ bottle: Bottle) -> some View {
        Section("Tools") {
            HStack(spacing: Theme.Spacing.s) {
                Button("winecfg") { appState.runTool(name: "winecfg", in: bottle) }
                Button("regedit") { appState.runTool(name: "regedit", in: bottle) }
                Button("explorer") { appState.runTool(name: "explorer", in: bottle) }
                Button("taskmgr") { appState.runTool(name: "taskmgr", in: bottle) }
                Button("Open C: drive") { appState.openDriveC(bottle) }
            }
            .buttonStyle(.bordered)
        }
    }

    private func dangerSection(_ bottle: Bottle) -> some View {
        Section("Danger Zone") {
            Button("Kill all processes", role: .destructive) {
                Task { await appState.stopAll(in: bottle) }
            }
        }
    }

    // MARK: - Helpers

    /// A two-way binding into `local` that writes back on every edit (so
    /// SwiftUI controls stay responsive) without saving to disk on every
    /// keystroke — callers pair this with an explicit `save()` from
    /// `.onSubmit`/`.onChange` for the fields that need it.
    private func binding<T>(_ keyPath: WritableKeyPath<Bottle, T>) -> Binding<T> {
        Binding(
            get: { local![keyPath: keyPath] },
            set: { local?[keyPath: keyPath] = $0 }
        )
    }

    private func save() {
        guard let local else { return }
        appState.updateBottle(local)
    }

    private func applyWindowsVersion(_ version: WindowsVersion) {
        guard let local, let engine else { return }
        isApplyingWindowsVersion = true
        Task {
            defer { isApplyingWindowsVersion = false }
            do {
                try await WineRunner.applyWindowsVersion(version, bottle: local, engine: engine)
            } catch {
                appState.report(error, context: "Applying \(version.displayName)")
            }
        }
    }

    private func sortedEnvKeys(_ bottle: Bottle) -> [String] {
        bottle.env.keys.sorted()
    }

    private func addEnv() {
        let key = newEnvKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, var local else { return }
        local.env[key] = newEnvValue
        self.local = local
        newEnvKey = ""
        newEnvValue = ""
        save()
    }

    private func removeEnv(_ key: String) {
        guard var local else { return }
        local.env.removeValue(forKey: key)
        self.local = local
        save()
    }

    private func copyToClipboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
