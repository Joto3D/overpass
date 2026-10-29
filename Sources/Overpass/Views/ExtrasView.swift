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
                if let bottle, let engine {
                    dxvkSection(bottle: bottle, engine: engine)
                    // The D3DMetal overlay section is intentionally not shown:
                    // stock Wine Staging ignores WINEDLLPATH for builtin DLLs, so
                    // Apple's D3DMetal libraries cannot be layered onto it the way
                    // CrossOver does with its own patched Wine. See
                    // Services/D3DMetalOverlay.swift for the full investigation.
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
            // No padding here and left-aligned, to match Performance and the
            // list tabs: `BottleDetailView` already insets the tab area by
            // `Theme.Spacing.outer`, and the extra 24pt (plus centering on
            // wide windows) put this tab's content out of line with them.
            // Cards draw their border inside their own bounds, so nothing is
            // clipped at the scroll view's edge. The second frame is what
            // actually pins the capped column to the left: a ScrollView
            // centres content narrower than itself, so with only the first
            // frame this tab sat in the middle of a wide window. Same pair
            // as Config's form.
            .frame(maxWidth: Theme.Metrics.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
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
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
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
                    InlineProgress(text: runner.statusLine ?? "Working…")
                }
            }
        }
        .padding(Theme.Spacing.l)
        .overpassCard()
    }

    private func dxvkExplanation(engine: InstalledEngine) -> String {
        if engine.kind.supportsDXVK {
            return "Installs upstream DXVK into this bottle's system32, translating DirectX 8/9/10/11 over Vulkan instead of Wine's built-in translation. Safe to toggle at any time; the original DLLs are backed up and restored."
        } else {
            return "\(engine.kind.displayName) already includes Apple's D3DMetal, which translates DirectX 11/12 straight to Metal — DXVK isn't needed here."
        }
    }

    // MARK: - D3DMetal overlay

    private func d3dMetalOverlaySection(bottle: Bottle, engine: InstalledEngine) -> some View {
        let gptk = D3DMetalOverlay.sourceEngine(from: appState.installedEngines)

        return VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            SectionHeader(title: "D3DMetal (Apple Game Porting Toolkit)", systemImage: "cpu")

            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Toggle(isOn: Binding(
                    get: { bottle.d3dMetalOverlay },
                    set: { newValue in
                        guard let gptk else { return }
                        Task { await runner.setD3DMetalOverlay(newValue, bottle: bottle, gptk: gptk, appState: appState) }
                    }
                )) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Text("Layer D3DMetal onto this bottle")
                            .font(Theme.headingFont(14))
                        Text("Apple's DirectX 11/12 to Metal translation, layered onto modern Wine — the same approach CrossOver uses.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Experimental: on the current Wine Staging build, this Mac's Wine doesn't actually pick up the overlay's DLLs (see D3DMetalOverlay.swift for the investigation), so this currently has no real effect — safe to toggle, but don't expect a rendering change yet.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if gptk == nil {
                            Text("Install the Game Porting Toolkit engine first — it's where the D3DMetal files come from.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .disabled(gptk == nil || runner.isBusy)

                if runner.isBusy, runner.currentOperation == "D3DMetal" {
                    InlineProgress(text: runner.statusLine ?? "Working…")
                }
            }
        }
        .padding(Theme.Spacing.l)
        .overpassCard()
    }

    // MARK: - Winetricks

    private var verbColumns: [GridItem] {
        [GridItem(.flexible(), spacing: Theme.Spacing.l), GridItem(.flexible(), spacing: Theme.Spacing.l)]
    }

    private func winetricksSection(bottle: Bottle, engine: InstalledEngine) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            SectionHeader(title: "Winetricks", systemImage: "shippingbox")

            LazyVGrid(columns: verbColumns, alignment: .leading, spacing: Theme.Spacing.m) {
                ForEach(Winetricks.curated, id: \.verb) { item in
                    verbCell(item, bottle: bottle, engine: engine)
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

    private func verbCell(_ item: (verb: String, title: String, blurb: String), bottle: Bottle, engine: InstalledEngine) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Button(item.title) {
                Task {
                    await runner.runVerb(item.verb, title: item.title, bottle: bottle, engine: engine, appState: appState)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(runner.isBusy)

            // Was `.lineLimit(1)` with tail truncation, which cut longer
            // blurbs off mid-sentence with no way to read the rest. It
            // wraps now; the two-column grid tolerates uneven cell heights.
            Text(item.blurb)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func installOtherVerb(bottle: Bottle, engine: InstalledEngine) {
        let verb = otherVerb.trimmingCharacters(in: .whitespaces)
        guard !verb.isEmpty else { return }
        Task {
            await runner.runVerb(verb, title: verb, bottle: bottle, engine: engine, appState: appState)
        }
    }

    private var outputBox: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.xs) {
                if runner.isBusy {
                    ProgressView().controlSize(.small)
                }
                Text(runner.isBusy ? "Running \(runner.currentOperation ?? "winetricks")…" : "Last run output")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            OutputBox(lines: runner.outputLines, height: 160)
        }
    }

    // MARK: - Notes

    private var cabextractNote: some View {
        InlineNote(
            systemImage: "info.circle",
            text: "Several Winetricks verbs (the Visual C++ and .NET runtimes, corefonts) need cabextract to unpack their downloads. If it's missing you'll be told to run \"brew install cabextract\"."
        )
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
    ///
    /// DXVK and the D3DMetal overlay both replace the same DirectX DLLs
    /// (`d3d11`, `dxgi`, ...), so they're mutually exclusive: turning DXVK
    /// on first uninstalls the overlay (if present) and clears
    /// `bottle.d3dMetalOverlay`, mirroring what `setD3DMetalOverlay` does
    /// in the other direction.
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
            if enabled, bottle.d3dMetalOverlay {
                statusLine = "Turning off D3DMetal overlay…"
                try D3DMetalOverlay.uninstall(from: bottle)
            }
            if enabled {
                try await DXVKInstaller.install(into: bottle) { [weak self] message in
                    Task { @MainActor in self?.statusLine = message }
                }
            } else {
                try DXVKInstaller.uninstall(from: bottle)
            }
            var updated = bottle
            updated.dxvk = enabled
            if enabled { updated.d3dMetalOverlay = false }
            appState.updateBottle(updated)
        } catch {
            appState.report(error, context: enabled ? "Installing DXVK" : "Removing DXVK")
        }
    }

    /// Installs or removes the `D3DMetalOverlay`, then — only on success —
    /// flips `bottle.d3dMetalOverlay` and persists it. Mutually exclusive
    /// with DXVK for the same reason `setDXVK` turns this overlay off when
    /// DXVK is enabled: both replace `d3d11`/`dxgi`/etc for the bottle.
    func setD3DMetalOverlay(_ enabled: Bool, bottle: Bottle, gptk: InstalledEngine, appState: AppState) async {
        guard !isBusy else { return }
        isBusy = true
        currentOperation = "D3DMetal"
        statusLine = enabled ? "Installing D3DMetal overlay…" : "Removing D3DMetal overlay…"
        defer {
            isBusy = false
            currentOperation = nil
            statusLine = nil
        }

        do {
            if enabled, bottle.dxvk {
                statusLine = "Turning off DXVK…"
                try DXVKInstaller.uninstall(from: bottle)
            }
            if enabled {
                try D3DMetalOverlay.install(into: bottle, from: gptk) { [weak self] message in
                    Task { @MainActor in self?.statusLine = message }
                }
            } else {
                try D3DMetalOverlay.uninstall(from: bottle)
            }
            var updated = bottle
            updated.d3dMetalOverlay = enabled
            if enabled { updated.dxvk = false }
            appState.updateBottle(updated)
        } catch {
            appState.report(error, context: enabled ? "Installing D3DMetal overlay" : "Removing D3DMetal overlay")
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
