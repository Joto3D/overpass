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

    private static let presetVirtualDesktopSizes = ["1280x800", "1600x900", "1920x1080"]
    private static let customVirtualDesktopSizeTag = "custom"

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
                    wineSection(local)
                    displaySection(local)
                    environmentSection(local)
                    advancedSection(local)
                }
                .formStyle(.grouped)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                emptyState
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

            Picker("Engine", selection: binding(\.engineID)) {
                ForEach(appState.installedEngines) { engine in
                    Text(engine.displayName).tag(engine.id)
                }
            }
            .onChange(of: bottle.engineID) { _, _ in save() }
            .help("Changing engine keeps the prefix; some programs may need reinstalling.")

            // Same trade-off wording the Engines screen and the new-bottle
            // sheet show, so the choice reads identically wherever it's made.
            if let engine {
                Text(engineTradeoffCaption(for: engine.kind))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

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

    private func wineSection(_ bottle: Bottle) -> some View {
        Section("Wine") {
            Toggle("ESync", isOn: binding(\.esync))
                .onChange(of: bottle.esync) { _, _ in save() }
                .help("Fast userspace event-synchronization primitives.")
            Toggle("MSync", isOn: binding(\.msync))
                .onChange(of: bottle.msync) { _, _ in save() }
                .help("Kernel-assisted sync, newer than ESync and often faster.")
        }
    }

    private func displaySection(_ bottle: Bottle) -> some View {
        Section("Display") {
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Run programs in a virtual desktop", isOn: binding(\.virtualDesktop))
                    .onChange(of: bottle.virtualDesktop) { _, _ in save() }
                Text("Fixes windows that render black or never appear.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .help("Runs the bottle's programs inside one bordered macOS window that Wine draws into directly, instead of handing individual windows to the Mac window server.")

            Picker("Desktop size", selection: virtualDesktopSizeSelection(bottle)) {
                ForEach(Self.presetVirtualDesktopSizes, id: \.self) { size in
                    Text(size.replacingOccurrences(of: "x", with: " \u{00d7} ")).tag(size)
                }
                Text("Custom\u{2026}").tag(Self.customVirtualDesktopSizeTag)
            }
            .disabled(!bottle.virtualDesktop)

            if isCustomVirtualDesktopSize(bottle) {
                TextField("Width x height", text: customVirtualDesktopSizeBinding())
                    .textFieldStyle(.roundedBorder)
                    .disabled(!bottle.virtualDesktop)
                    .onSubmit { commitVirtualDesktopSize() }
                    .help("A resolution such as 1280x800, between 640x480 and 7680x4320.")
            }
        }
    }

    private func environmentSection(_ bottle: Bottle) -> some View {
        Section("Environment") {
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

    private func advancedSection(_ bottle: Bottle) -> some View {
        Section("Advanced") {
            Toggle("Verbose logging", isOn: binding(\.verboseLog))
                .onChange(of: bottle.verboseLog) { _, _ in save() }
                .help("Adds fixme-level Wine debug output to run logs.")

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

            Button("Kill All Processes", role: .destructive) {
                Task { await appState.stopAll(in: bottle) }
            }
        }
    }

    private var emptyState: some View {
        Text("Bottle not found.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
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

    /// The picker's selection: one of the presets, or `customVirtualDesktopSizeTag`
    /// when `bottle.virtualDesktopSize` isn't one of them. Picking a preset
    /// writes it straight through; picking "Custom…" leaves the stored
    /// value alone (it's already whatever non-preset string got it here)
    /// so the text field beneath it appears pre-filled instead of blank.
    private func virtualDesktopSizeSelection(_ bottle: Bottle) -> Binding<String> {
        Binding(
            get: {
                let current = bottle.virtualDesktopSize ?? Bottle.defaultVirtualDesktopSize
                return Self.presetVirtualDesktopSizes.contains(current) ? current : Self.customVirtualDesktopSizeTag
            },
            set: { newValue in
                guard newValue != Self.customVirtualDesktopSizeTag else { return }
                local?.virtualDesktopSize = newValue
                save()
            }
        )
    }

    private func isCustomVirtualDesktopSize(_ bottle: Bottle) -> Bool {
        let current = bottle.virtualDesktopSize ?? Bottle.defaultVirtualDesktopSize
        return !Self.presetVirtualDesktopSizes.contains(current)
    }

    private func customVirtualDesktopSizeBinding() -> Binding<String> {
        Binding(
            get: { local?.virtualDesktopSize ?? Bottle.defaultVirtualDesktopSize },
            set: { local?.virtualDesktopSize = $0 }
        )
    }

    /// Runs the custom size field's raw text through the same validation
    /// `WineRunner.launch` applies at launch time, so what's persisted is
    /// always well-formed (falling back to `Bottle.defaultVirtualDesktopSize`
    /// for anything malformed) rather than saving a string that only turns
    /// out invalid the next time a program is run.
    private func commitVirtualDesktopSize() {
        guard var local else { return }
        local.virtualDesktopSize = Bottle.validatedVirtualDesktopSize(local.virtualDesktopSize)
        self.local = local
        save()
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
