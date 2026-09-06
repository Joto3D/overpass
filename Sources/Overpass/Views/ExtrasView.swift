import SwiftUI

/// DXVK toggle + Winetricks verbs for one bottle. Embedded as a tab inside
/// `BottleDetailView` (owned by another part of the app); this file only
/// needs `bottleID` and reads the bottle/engine live from `AppState`.
///
/// All per-operation UI state (busy flag, live output) lives in
/// `ExtrasRunner` below rather than on `AppState` itself — Extras has no
/// need for that state to be visible outside this screen, so it mirrors
/// the `EngineManager+AppState.swift` progress-closure pattern locally
/// instead of adding properties to the shared root state.
struct ExtrasView: View {
    let bottleID: UUID
    @Environment(AppState.self) private var appState
    @State private var runner = ExtrasRunner()
    @State private var otherVerb = ""

    private var bottle: Bottle? { appState.bottles.first { $0.id == bottleID } }
    private var engine: InstalledEngine? { bottle.flatMap { appState.engine(for: $0) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                header

                if let bottle, let engine {
                    dxvkSection(bottle: bottle, engine: engine)
                    winetricksSection(bottle: bottle, engine: engine)
                } else {
                    ContentUnavailableView(
                        "No engine installed",
                        systemImage: "exclamationmark.triangle",
                        description: Text("Install an engine for this bottle before using Extras.")
                    )
                }

                cabextractNote
            }
            .padding(Theme.Spacing.xl)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("Extras")
                .font(Theme.titleFont())
            Text("Optional runtime pieces some Windows programs expect: DXVK for better DirectX support, and Winetricks for redistributables, fonts, and other dependencies.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - DXVK

    private func dxvkSection(bottle: Bottle, engine: InstalledEngine) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            SectionHeader(title: "DXVK", systemImage: "bolt.square")

            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Toggle(isOn: Binding(
                    get: { bottle.dxvk },
                    set: { newValue in
                        Task { await runner.setDXVK(newValue, bottle: bottle, engine: engine, appState: appState) }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use DXVK for DirectX 9/10/11")
                            .font(Theme.headingFont(14))
                        Text(dxvkExplanation(engine: engine))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .disabled(!engine.kind.supportsDXVK || runner.isBusy)

                if runner.isBusy, runner.currentOperation == "DXVK" {
                    HStack(spacing: Theme.Spacing.s) {
                        ProgressView().controlSize(.small)
                        Text(runner.statusLine ?? "Working…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(Theme.Spacing.l)
        .overpassCard()
    }

    private func dxvkExplanation(engine: InstalledEngine) -> String {
        if engine.kind.supportsDXVK {
            return "Installs Gcenx's DXVK-macOS build into this bottle's system32, translating DirectX 9/10/11 over Vulkan instead of Wine's built-in translation. Safe to toggle at any time; the original DLLs are backed up and restored."
        } else {
            return "\(engine.kind.displayName) already includes Apple's D3DMetal, which translates DirectX 11/12 straight to Metal — DXVK isn't needed here."
        }
    }

    // MARK: - Winetricks

    private func winetricksSection(bottle: Bottle, engine: InstalledEngine) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            SectionHeader(title: "Winetricks", systemImage: "shippingbox")

            VStack(spacing: 0) {
                ForEach(Array(Winetricks.curated.enumerated()), id: \.offset) { index, item in
                    if index > 0 { Divider() }
                    verbRow(item, bottle: bottle, engine: engine)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                HStack(spacing: Theme.Spacing.s) {
                    TextField("Other verb (e.g. quartz2d)", text: $otherVerb)
                        .textFieldStyle(.roundedBorder)
                        .disabled(runner.isBusy)
                        .onSubmit { installOtherVerb(bottle: bottle, engine: engine) }
                    Button("Install") {
                        installOtherVerb(bottle: bottle, engine: engine)
                    }
                    .buttonStyle(.bordered)
                    .disabled(runner.isBusy || otherVerb.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                HStack {
                    Button("Winetricks GUI") {
                        Task {
                            await runner.runVerb("", title: "Winetricks GUI", bottle: bottle, engine: engine, appState: appState)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(runner.isBusy)
                    Spacer()
                }
                Text("Opens winetricks' own verb picker. It needs zenity inside the bottle and may not work on every setup — safe to try.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if runner.isBusy || !runner.outputLines.isEmpty {
                outputBox
            }
        }
        .padding(Theme.Spacing.l)
        .overpassCard()
    }

    private func verbRow(_ item: (verb: String, title: String, blurb: String), bottle: Bottle, engine: InstalledEngine) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(Theme.headingFont(14))
                Text(item.blurb)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Spacing.m)
            Button("Install") {
                Task {
                    await runner.runVerb(item.verb, title: item.title, bottle: bottle, engine: engine, appState: appState)
                }
            }
            .buttonStyle(.bordered)
            .disabled(runner.isBusy)
        }
        .padding(.vertical, Theme.Spacing.s)
    }

    private func installOtherVerb(bottle: Bottle, engine: InstalledEngine) {
        let verb = otherVerb.trimmingCharacters(in: .whitespaces)
        guard !verb.isEmpty else { return }
        Task {
            await runner.runVerb(verb, title: verb, bottle: bottle, engine: engine, appState: appState)
        }
    }

    private var outputBox: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Theme.Spacing.xs) {
                if runner.isBusy {
                    ProgressView().controlSize(.small)
                }
                Text(runner.isBusy ? "Running \(runner.currentOperation ?? "winetricks")…" : "Last run output")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                Text(runner.outputLines.isEmpty ? " " : runner.outputLines.joined(separator: "\n"))
                    .font(.system(.caption2, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(Theme.Spacing.s)
            }
            .frame(height: 160)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            }
        }
    }

    // MARK: - Notes

    private var cabextractNote: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.s) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text("Several Winetricks verbs (the Visual C++ and .NET runtimes, corefonts) need cabextract to unpack their downloads. If it's missing you'll be told to run \"brew install cabextract\".")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(Theme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overpassCard(cornerRadius: Theme.Radius.row)
    }
}

// MARK: - ExtrasRunner

/// Owns the busy flag and live output for whatever single Extras
/// operation (a Winetricks verb, or the DXVK toggle) is currently
/// running. One instance per `ExtrasView`; every entry point guards on
/// `isBusy` so at most one operation runs at a time, per the spec.
@MainActor
@Observable
final class ExtrasRunner {
    private(set) var isBusy = false
    private(set) var currentOperation: String?
    private(set) var statusLine: String?
    private(set) var outputLines: [String] = []

    private let maxOutputLines = 30

    /// Installs or removes DXVK, then — only on success — flips
    /// `bottle.dxvk` and persists it via `appState.updateBottle`. On
    /// failure the bottle is left untouched, so the toggle in
    /// `ExtrasView` (bound straight to `bottle.dxvk`) naturally snaps
    /// back to its prior state.
    func setDXVK(_ enabled: Bool, bottle: Bottle, engine: InstalledEngine, appState: AppState) async {
        guard !isBusy else { return }
        isBusy = true
        currentOperation = "DXVK"
        statusLine = enabled ? "Installing DXVK…" : "Restoring original DLLs…"
        defer {
            isBusy = false
            currentOperation = nil
            statusLine = nil
        }

        do {
            if enabled {
                try await DXVKInstaller.install(into: bottle) { [weak self] message in
                    Task { @MainActor in self?.statusLine = message }
                }
            } else {
                try DXVKInstaller.uninstall(from: bottle)
            }
            var updated = bottle
            updated.dxvk = enabled
            appState.updateBottle(updated)
        } catch {
            appState.report(error, context: enabled ? "Installing DXVK" : "Removing DXVK")
        }
    }

    /// Runs one winetricks verb (or, when `verb` is empty, the script's
    /// own GUI picker), streaming output into `outputLines` as it goes.
    func runVerb(_ verb: String, title: String, bottle: Bottle, engine: InstalledEngine, appState: AppState) async {
        guard !isBusy else { return }
        isBusy = true
        currentOperation = title
        outputLines = []
        defer {
            isBusy = false
            currentOperation = nil
        }

        do {
            try await Winetricks.run(verb: verb, bottle: bottle, engine: engine) { [weak self] chunk in
                Task { @MainActor in self?.appendOutput(chunk) }
            }
        } catch {
            appState.report(error, context: "Running \(title.isEmpty ? "winetricks" : title)")
        }
    }

    private func appendOutput(_ chunk: String) {
        let newLines = chunk
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !newLines.isEmpty else { return }
        outputLines.append(contentsOf: newLines)
        if outputLines.count > maxOutputLines {
            outputLines.removeFirst(outputLines.count - maxOutputLines)
        }
    }
}
