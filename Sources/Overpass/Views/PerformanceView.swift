import SwiftUI

/// A bottle's Performance tab: a preset picker, at most three settings
/// cards (Graphics, Wine, Display & Input — each toggle carrying a short
/// caption with the long explanation moved into a hover tooltip), and a
/// collapsed "Advanced" disclosure holding the free-form env-var table and
/// a live read-only preview of the resulting launch environment.
///
/// Every env-var change saves immediately via `appState.updateBottle`;
/// every registry-backed change also re-runs `PerformanceTuner.applyRegistry`
/// (shown via a small "Applying…" state, errors routed through
/// `appState.report` and shown inline). Editing anything after applying a
/// preset marks the bottle `.custom`.
struct PerformanceView: View {
    let bottleID: UUID
    @Environment(AppState.self) private var appState
    @Environment(ThemeStore.self) private var themeStore

    @State private var settings = PerformanceSettings()
    @State private var pendingPreset: PerformanceSettings.Preset = .balanced
    @State private var isApplyingRegistry = false
    @State private var registryError: String?
    @State private var isAdvancedExpanded = false

    @State private var videoMemoryDraft = ""
    @State private var frameRateDraft = ""
    @State private var newEnvKey = ""
    @State private var newEnvValue = ""

    private var bottle: Bottle? {
        appState.bottles.first { $0.id == bottleID }
    }

    private var engine: InstalledEngine? {
        bottle.flatMap { appState.engine(for: $0) }
    }

    var body: some View {
        if let bottle {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    statusRow
                    presetSection
                    graphicsSection(bottle)
                    wineSection(bottle)
                    displayInputSection
                    advancedDisclosure(bottle, engine)

                    Text("Changes take effect on the next launch — a running program keeps the environment it started with.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                // No padding here: `BottleDetailView` already insets the tab
                // area by `Theme.Spacing.outer`, and the extra 24pt that used
                // to sit here pushed this tab's content further in than
                // Programs, Games and Logs. The cards draw their border
                // inside their own bounds, so nothing is clipped at the
                // scroll view's edge (Programs' list sits flush the same way).
                // The second frame pins the capped column to the left: a
                // ScrollView centres content narrower than itself, so with
                // only the first frame this tab sat in the middle of a wide
                // window. Same pair as Config's form.
                .frame(maxWidth: Theme.Metrics.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .task(id: bottleID) { load(bottle) }
        } else {
            ContentUnavailableView("Bottle not found", systemImage: "questionmark.circle")
        }
    }

    // MARK: - Load

    private func load(_ bottle: Bottle) {
        settings = bottle.performance ?? PerformanceSettings()
        pendingPreset = settings.preset == .custom ? .balanced : settings.preset
        videoMemoryDraft = settings.videoMemorySize ?? ""
        frameRateDraft = settings.frameRateCap.map(String.init) ?? ""
        registryError = nil
    }

    // MARK: - Status

    @ViewBuilder
    private var statusRow: some View {
        if isApplyingRegistry || registryError != nil {
            HStack(spacing: Theme.Spacing.s) {
                if isApplyingRegistry {
                    InlineProgress(text: "Applying…")
                }
                // No line limit: the old two-line cap clipped the end of a
                // long registry error, which is the part that says why.
                if let registryError {
                    ErrorText(registryError)
                }
            }
        }
    }

    // MARK: - Preset

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            SectionHeader(title: "Preset", systemImage: "slider.horizontal.3")

            Picker("Preset", selection: $pendingPreset) {
                ForEach(PerformanceSettings.Preset.allCases.filter { $0 != .custom }) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(pendingPreset.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if settings.preset == .custom {
                    Chip(text: "Custom", systemImage: "pencil", tint: .orange)
                }
                Spacer()
                Button("Apply preset") { applyPreset() }
                    .buttonStyle(.bordered)
                    // `applyPreset` already refuses to run mid-apply; the
                    // disabled state says so instead of silently doing
                    // nothing.
                    .disabled(isApplyingRegistry)
            }
        }
        .padding(Theme.Spacing.l)
        .overpassCard()
    }

    private func applyPreset() {
        // One registry apply at a time: see `mutate`.
        guard let bottle, !isApplyingRegistry else { return }
        let previous = settings
        let updated = settings.applyingPreset(pendingPreset)
        settings = updated
        videoMemoryDraft = updated.videoMemorySize ?? ""
        frameRateDraft = updated.frameRateCap.map(String.init) ?? ""
        persist(updated, previous: previous, in: bottle, applyRegistry: true)
    }

    // MARK: - Graphics (engine-specific + Metal HUD)

    @ViewBuilder
    private func graphicsSection(_ bottle: Bottle) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            SectionHeader(title: "Graphics", systemImage: "sparkles.tv")

            if let engine {
                switch engine.kind {
                case .gptk:
                    gptkToggles
                case .wineStaging:
                    if bottle.dxvk {
                        dxvkToggles
                    } else {
                        Text("Install DXVK (Extras tab) to unlock async shader compilation, an FPS overlay, and a frame rate cap.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Divider()
            }

            toggleRow(
                "Show Metal HUD",
                caption: "Apple's built-in FPS/frame time overlay.",
                help: "MTL_HUD_ENABLED — Apple's built-in overlay: live FPS and frame time in the corner of the window.",
                isOn: bottleBinding(\.metalHUD, in: bottle)
            )

            // Engine-independent diagnostic, so it sits here beside the
            // Metal HUD rather than in the GPTK-only block with D3DMetal
            // logging: the shim hooks Metal itself, which both D3DMetal and
            // MoltenVK (DXVK) end in. Counter only — no on-screen display.
            toggleRow(
                "Frame counter (diagnostic)",
                caption: "Writes frame timings to the run log.",
                help: "Injects a Metal present hook that counts frames and logs \"fgshim:\" lines (present count, frame time, fps) to this program's run log. Diagnostic only — it changes nothing on screen and adds a little overhead. Takes effect only in the packaged app, which contains the hook library.",
                isOn: binding(\.frameCounter)
            )
        }
        .padding(Theme.Spacing.l)
        .overpassCard()
    }

    @ViewBuilder
    private var gptkToggles: some View {
        toggleRow(
            "MetalFX upscaling",
            caption: "Converts DLSS calls to Apple MetalFX upscaling.",
            help: "D3DM_ENABLE_METALFX — converts a game's NVIDIA DLSS calls to Apple MetalFX upscaling. Only affects titles that support DLSS; no extra setup is needed, since the engine ships the shim itself.",
            isOn: binding(\.metalFX)
        )
        toggleRow(
            "Raytracing (DXR)",
            caption: "Reports DirectX Raytracing support through D3DMetal.",
            help: "D3DM_SUPPORT_DXR — reports DirectX Raytracing support through D3DMetal. Off by default on M1/M2, on for M3+. Can crash titles with buggy RT paths.",
            isOn: binding(\.raytracing)
        )
        toggleRow(
            "D3DMetal logging",
            caption: "Verbose D3DMetal messages in the run log.",
            help: "D3DM_ENABLE_LOGGING — verbose D3DMetal messages in the run log and Console.app. Useful when diagnosing a graphics crash; adds overhead otherwise.",
            isOn: binding(\.d3dmLogging)
        )
    }

    @ViewBuilder
    private var dxvkToggles: some View {
        pickerRow(
            "HUD overlay",
            caption: "In-game FPS/frame time overlay for comparing presets.",
            help: "DXVK_HUD — an in-game overlay of FPS/frame time (and, on Full, GPU memory and pipeline counts) for comparing presets."
        ) {
            Picker("HUD overlay", selection: binding(\.dxvkHud)) {
                ForEach(PerformanceSettings.DXVKHudLevel.allCases) { level in
                    Text(level.displayName).tag(level)
                }
            }
            .labelsHidden()
        }

        fieldRow(
            "Frame rate cap",
            caption: "Caps rendering to reduce heat, fan noise, or stutter.",
            help: "Caps rendering to reduce heat/fan noise or smooth frame pacing. Leave blank to uncap. Applied as dxgi.maxFrameRate / d3d9.maxFrameRate through DXVK_CONFIG."
        ) {
            TextField("Uncapped", text: $frameRateDraft)
                .frame(width: 80)
                .onSubmit { commitFrameRateCap() }
            Text("fps").foregroundStyle(.secondary)
            Button("Set") { commitFrameRateCap() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private func commitFrameRateCap() {
        let trimmed = frameRateDraft.trimmingCharacters(in: .whitespaces)
        let value = Int(trimmed).flatMap { $0 > 0 ? $0 : nil }
        frameRateDraft = value.map(String.init) ?? ""
        mutate { $0.frameRateCap = value }
    }

    // MARK: - Wine / registry

    private func wineSection(_ bottle: Bottle) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            SectionHeader(title: "Wine", systemImage: "wineglass")

            toggleRow(
                "ESync",
                caption: "Fast sync primitives; a large win for multi-threaded games.",
                help: "Fast userspace event-synchronization primitives. Large win for multi-threaded games; on by default.",
                isOn: bottleBinding(\.esync, in: bottle)
            )
            toggleRow(
                "MSync",
                caption: "Newer kernel-assisted sync, often faster where supported.",
                help: "Kernel-assisted sync, newer than ESync and often faster where the engine build supports it.",
                isOn: bottleBinding(\.msync, in: bottle)
            )
            toggleRow(
                "Large address aware",
                caption: "Lets 32-bit games use up to 4GB instead of 2GB.",
                help: "WINE_LARGE_ADDRESS_AWARE — lets a 32-bit game use up to 4GB instead of 2GB, avoiding out-of-memory crashes. Only takes effect on Wine builds that implement the flag (Lutris/GE-patched forks); a no-op otherwise.",
                isOn: binding(\.largeAddressAware)
            )
            toggleRow(
                "Disable CSMT",
                caption: "Can fix rendering glitches in a few older titles.",
                help: "HKCU\\Software\\Wine\\Direct3D\\csmt=0 — turns off Command Stream Multi-Threading. On (faster) by default; disabling it can fix rendering corruption or hangs in a handful of older, finicky titles.",
                isOn: binding(\.disableCSMT, registryBacked: true),
                isDisabled: isApplyingRegistry
            )

            fieldRow(
                "Video memory",
                caption: "Reported VRAM for Wine's own D3D renderer.",
                help: "HKCU\\Software\\Wine\\Direct3D\\VideoMemorySize — reported VRAM for wined3d's own renderer. Only matters when DXVK isn't handling the game; leave blank to auto-detect."
            ) {
                TextField("Auto", text: $videoMemoryDraft)
                    .frame(width: 80)
                    .onSubmit { commitVideoMemory() }
                Text("MB").foregroundStyle(.secondary)
                Button("Set") { commitVideoMemory() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .disabled(isApplyingRegistry)

            pickerRow(
                "wined3d backend",
                caption: "Backend used only when DXVK isn't handling rendering.",
                help: "HKCU\\Software\\Wine\\Direct3D\\renderer — the backend wined3d's own D3D9/10/11 implementation targets when DXVK isn't overriding it. OpenGL is the most compatible; Vulkan is newer and often faster but less battle-tested."
            ) {
                Picker("wined3d backend", selection: binding(\.renderer, registryBacked: true)) {
                    Text("Default (OpenGL)").tag(PerformanceSettings.WineD3DRenderer?.none)
                    ForEach(PerformanceSettings.WineD3DRenderer.allCases) { renderer in
                        Text(renderer.displayName).tag(Optional(renderer))
                    }
                }
                .labelsHidden()
                .disabled(isApplyingRegistry)
            }
        }
        .padding(Theme.Spacing.l)
        .overpassCard()
    }

    private func commitVideoMemory() {
        let trimmed = videoMemoryDraft.trimmingCharacters(in: .whitespaces)
        videoMemoryDraft = trimmed
        mutate(registryBacked: true) { $0.videoMemorySize = trimmed.isEmpty ? nil : trimmed }
    }

    // MARK: - Display & input

    private var displayInputSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            SectionHeader(title: "Display & Input", systemImage: "display")

            toggleRow(
                "Retina mode",
                caption: "Sharper text, but heavier on 4K/5K/6K displays.",
                help: "Mac Driver\\RetinaMode=Y — renders at full display pixel density instead of a scaled logical resolution. Sharper text and UI, but real GPU cost on 4K/5K/6K Retina displays, and some games' windows appear tiny until their in-game resolution is adjusted.",
                isOn: binding(\.retinaMode, registryBacked: true),
                isDisabled: isApplyingRegistry
            )
            toggleRow(
                "Option key is Alt",
                caption: "Matches PC shortcuts like Alt+Tab and Alt+F4.",
                help: "Mac Driver\\Left/RightOptionIsAlt=Y — makes both Option keys act as Alt inside the bottle, matching PC shortcuts (Alt+Tab, Alt+F4, weapon-wheel binds).",
                isOn: binding(\.optionAsAlt, registryBacked: true),
                isDisabled: isApplyingRegistry
            )
            toggleRow(
                "Precise trackpad scrolling",
                caption: "Smoother scroll deltas from trackpads and Magic Mouse.",
                help: "Mac Driver\\UsePreciseScrolling — smoother scroll deltas from trackpads/Magic Mouse. Turn off if a game shows exaggerated zoom or repaint glitches on scroll input.",
                isOn: binding(\.preciseScrolling, registryBacked: true),
                isDisabled: isApplyingRegistry
            )
        }
        .padding(Theme.Spacing.l)
        .overpassCard()
    }

    // MARK: - Advanced (env table + resulting environment)

    @ViewBuilder
    private func advancedDisclosure(_ bottle: Bottle, _ engine: InstalledEngine?) -> some View {
        DisclosureGroup(isExpanded: $isAdvancedExpanded) {
            // Only built while open: `resultingEnvList` assembles the full
            // launch environment (and looks up the frame-counter shim on
            // disk), which is wasted work on every render of a tab where the
            // disclosure is almost always collapsed.
            if isAdvancedExpanded {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    advancedEnvTable
                    Divider()
                    resultingEnvList(bottle, engine)
                }
                .padding(.top, Theme.Spacing.m)
            }
        } label: {
            SectionHeader(title: "Advanced", systemImage: "terminal")
        }
        .padding(Theme.Spacing.l)
        .overpassCard()
    }

    private var advancedEnvTable: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Text("Custom environment variables, merged in last so they override every toggle above.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            ForEach(settings.extraEnv.keys.sorted(), id: \.self) { key in
                HStack {
                    Text(key)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .help(key)
                        .textSelection(.enabled)
                    Text("=").foregroundStyle(.secondary)
                    // Middle-truncated to keep the row to one line; the
                    // tooltip and selection give the full value back.
                    Text(settings.extraEnv[key] ?? "")
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(settings.extraEnv[key] ?? "")
                        .textSelection(.enabled)
                    Spacer()
                    RemoveRowButton(name: key) {
                        mutate { $0.extraEnv.removeValue(forKey: key) }
                    }
                }
            }

            HStack {
                TextField("KEY", text: $newEnvKey)
                    .frame(width: 140)
                    .font(.system(.body, design: .monospaced))
                TextField("value", text: $newEnvValue)
                    .font(.system(.body, design: .monospaced))
                Button("Add") { addEnvVar() }
                    .buttonStyle(.bordered)
                    .disabled(newEnvKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func addEnvVar() {
        let key = newEnvKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        let value = newEnvValue
        mutate { $0.extraEnv[key] = value }
        newEnvKey = ""
        newEnvValue = ""
    }

    @ViewBuilder
    private func resultingEnvList(_ bottle: Bottle, _ engine: InstalledEngine?) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text("What this bottle will launch with")
                .font(Theme.headingFont(12))
                .foregroundStyle(.secondary)

            if let engine {
                let base = WineRunner.environment(for: bottle, engine: engine)
                let perf = PerformanceSettings.environment(for: settings, bottle: bottle, engine: engine)
                let merged = base.merging(perf) { _, new in new }

                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    ForEach(merged.keys.sorted(), id: \.self) { key in
                        Text("\(key)=\(merged[key] ?? "")")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            } else {
                Text("Install an engine for this bottle to preview its launch environment.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Row builders

    /// A toggle with a short (≤ 12 word) caption underneath and the full
    /// explanation moved into a hover tooltip via `.help`.
    ///
    /// `isDisabled` is for the registry-backed toggles: `mutate` ignores a
    /// registry-backed change made while another is still being applied, so
    /// the toggle used to flip, snap back, and give no reason. Disabling it
    /// for the duration says why (the "Applying…" row is showing).
    @ViewBuilder
    private func toggleRow(_ title: String, caption: String, help: String, isOn: Binding<Bool>, isDisabled: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Toggle(title, isOn: isOn)
                .disabled(isDisabled)
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .help(help)
    }

    /// A labeled control (Picker) with the same short-caption/tooltip
    /// treatment as `toggleRow`.
    @ViewBuilder
    private func pickerRow<Content: View>(_ title: String, caption: String, help: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            HStack {
                Text(title)
                Spacer()
                content()
            }
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .help(help)
    }

    /// A labeled row with free-form trailing controls (a text field + unit
    /// + Set button), same short-caption/tooltip treatment.
    @ViewBuilder
    private func fieldRow<Content: View>(_ title: String, caption: String, help: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            HStack {
                Text(title)
                content()
            }
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .help(help)
    }

    // MARK: - Bindings / persistence

    /// A binding into `settings` that, on every write, marks the bottle
    /// `.custom` (unless the write came from `applyPreset`, which sets
    /// `settings` directly) and persists — via `mutate`, optionally
    /// re-running `applyRegistry` for registry-backed fields.
    private func binding<T>(_ keyPath: WritableKeyPath<PerformanceSettings, T>, registryBacked: Bool = false) -> Binding<T> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { newValue in mutate(registryBacked: registryBacked) { $0[keyPath: keyPath] = newValue } }
        )
    }

    /// A binding straight into `Bottle` for the fields that live there
    /// (esync/msync/metalHUD) rather than in `PerformanceSettings` — saved
    /// immediately, no registry action, no preset/custom implication.
    private func bottleBinding(_ keyPath: WritableKeyPath<Bottle, Bool>, in bottle: Bottle) -> Binding<Bool> {
        Binding(
            get: { bottle[keyPath: keyPath] },
            set: { newValue in
                var updated = bottle
                updated[keyPath: keyPath] = newValue
                appState.updateBottle(updated)
            }
        )
    }

    private func mutate(registryBacked: Bool = false, _ transform: (inout PerformanceSettings) -> Void) {
        // A registry-backed change made while another is still being
        // applied is ignored (the control snaps back to its current value
        // and the "Applying…" row is showing). Two overlapping applies
        // can't each know what to roll back to if one fails.
        guard let bottle, !(registryBacked && isApplyingRegistry) else { return }
        let previous = settings
        var updated = settings
        transform(&updated)
        if updated.preset != .custom { updated.preset = .custom }
        settings = updated
        persist(updated, previous: previous, in: bottle, applyRegistry: registryBacked)
    }

    /// Records `updated` on the bottle. For registry-backed changes the
    /// bottle is saved only AFTER `PerformanceTuner.applyRegistry`
    /// succeeds: the saved settings are what the Performance tab shows
    /// next time, so saving first meant a failed registry write left the
    /// bottle claiming settings the prefix never got. On failure (or no
    /// engine to apply with) nothing is saved, and the on-screen
    /// `settings` (and the two text drafts, which `applyPreset` also
    /// rewrites) go back to `previous` so the controls show what is true.
    /// Changes that touch no registry key are saved straight away.
    private func persist(_ updated: PerformanceSettings, previous: PerformanceSettings, in bottle: Bottle, applyRegistry: Bool) {
        var savedBottle = bottle
        savedBottle.performance = updated

        guard applyRegistry else {
            appState.updateBottle(savedBottle)
            return
        }

        guard let engine else {
            // Used to save and return silently: the settings were kept, and
            // never applied to the prefix.
            revert(to: previous, ifShowing: updated)
            appState.report("Couldn't apply the performance settings: this bottle's engine isn't installed. Install it from the Engines screen, or pick a different engine for this bottle, then try again.")
            return
        }

        registryError = nil
        isApplyingRegistry = true
        let bottleID = bottle.id
        Task {
            do {
                try await PerformanceTuner.applyRegistry(settings: updated, bottle: savedBottle, engine: engine)
                // Re-read the bottle now rather than saving the snapshot
                // taken before the await, which would undo anything else
                // changed on it in the meantime (ESync, Metal HUD, ...).
                var live = appState.bottles.first(where: { $0.id == bottleID }) ?? savedBottle
                live.performance = updated
                appState.updateBottle(live)
            } catch {
                revert(to: previous, ifShowing: updated)
                registryError = error.localizedDescription
                appState.report(error, context: "Applying performance settings")
            }
            isApplyingRegistry = false
        }
    }

    /// Puts the on-screen settings back to `previous`, but only if they
    /// still show `attempted`: if the user has since switched to another
    /// bottle (`load` replaced `settings`), rolling back would overwrite
    /// that bottle's values with this one's.
    private func revert(to previous: PerformanceSettings, ifShowing attempted: PerformanceSettings) {
        guard settings == attempted else { return }
        settings = previous
        videoMemoryDraft = previous.videoMemorySize ?? ""
        frameRateDraft = previous.frameRateCap.map(String.init) ?? ""
    }
}
