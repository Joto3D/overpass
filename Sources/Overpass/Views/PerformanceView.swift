import SwiftUI

/// A bottle's Performance tab: a preset picker, engine-appropriate tuning
/// sections (GPTK vs DXVK), Wine/registry knobs, display & input tweaks,
/// the Metal HUD toggle, a free-form advanced-env table, and a live
/// read-only preview of the resulting launch environment.
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
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    header
                    statusRow
                    presetSection

                    if let engine {
                        switch engine.kind {
                        case .gptk:
                            gptkSection
                        case .wineStaging:
                            if bottle.dxvk {
                                dxvkSection
                            } else {
                                dxvkUnavailableNote
                            }
                        }
                    }

                    wineSection(bottle)
                    displayInputSection
                    metalHUDSection(bottle)
                    advancedEnvSection

                    resultingEnvFooter(bottle, engine)

                    Text("Changes take effect on the next launch — a running program keeps the environment it started with.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(Theme.Spacing.xl)
                .frame(maxWidth: 640, alignment: .leading)
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

    // MARK: - Header / status

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Performance")
                .font(Theme.titleFont())
            Text("Graphics and runtime tuning for this bottle.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        if isApplyingRegistry || registryError != nil {
            HStack(spacing: Theme.Spacing.s) {
                if isApplyingRegistry {
                    ProgressView().controlSize(.small)
                    Text("Applying…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let registryError {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    Text(registryError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
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

            HStack {
                if settings.preset == .custom {
                    Chip(text: "Custom", systemImage: "pencil", tint: .orange)
                }
                Spacer()
                Button("Apply Preset") { applyPreset() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(Theme.Spacing.l)
        .overpassCard()
    }

    private func applyPreset() {
        guard let bottle else { return }
        let updated = settings.applyingPreset(pendingPreset)
        settings = updated
        videoMemoryDraft = updated.videoMemorySize ?? ""
        frameRateDraft = updated.frameRateCap.map(String.init) ?? ""
        persist(updated, in: bottle, applyRegistry: true)
    }

    // MARK: - GPTK

    private var gptkSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            SectionHeader(title: "Game Porting Toolkit", systemImage: "cpu")

            toggleRow(
                "MetalFX upscaling",
                "D3DM_ENABLE_METALFX — converts a game's NVIDIA DLSS calls to Apple MetalFX upscaling. Only helps titles that support DLSS, and needs their MetalFX shim DLLs installed in system32 first.",
                isOn: binding(\.metalFX)
            )
            toggleRow(
                "Raytracing (DXR)",
                "D3DM_SUPPORT_DXR — reports DirectX Raytracing support through D3DMetal. Off by default on M1/M2, on for M3+. Can crash titles with buggy RT paths.",
                isOn: binding(\.raytracing)
            )
            toggleRow(
                "D3DMetal logging",
                "D3DM_ENABLE_LOGGING — verbose D3DMetal messages in the run log and Console.app. Useful when diagnosing a graphics crash; adds overhead otherwise.",
                isOn: binding(\.d3dmLogging)
            )
        }
        .padding(Theme.Spacing.l)
        .overpassCard()
    }

    // MARK: - DXVK

    private var dxvkSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            SectionHeader(title: "DXVK", systemImage: "bolt")

            toggleRow(
                "Async shader compilation",
                "DXVK_ASYNC — compiles shaders on a background thread instead of stalling the frame. Removes most traversal stutter in open-world games; can briefly show a not-yet-compiled shader's placeholder.",
                isOn: binding(\.dxvkAsync)
            )

            VStack(alignment: .leading, spacing: 2) {
                Picker("HUD overlay", selection: binding(\.dxvkHud)) {
                    ForEach(PerformanceSettings.DXVKHudLevel.allCases) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                Text("DXVK_HUD — an in-game overlay of FPS/frame time (and, on Full, GPU memory and pipeline counts) for comparing presets.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Frame rate cap")
                    TextField("Uncapped", text: $frameRateDraft)
                        .frame(width: 80)
                        .onSubmit { commitFrameRateCap() }
                    Text("fps").foregroundStyle(.secondary)
                    Button("Set") { commitFrameRateCap() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Text("DXVK_FRAME_RATE — caps rendering to reduce heat/fan noise or smooth frame pacing. Leave blank to uncap.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Theme.Spacing.l)
        .overpassCard()
    }

    private var dxvkUnavailableNote: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            SectionHeader(title: "DXVK", systemImage: "bolt.slash")
            Text("Install DXVK for this bottle (Config tab) to unlock async shader compilation, the HUD overlay, and a frame rate cap.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(Theme.Spacing.l)
        .overpassCard()
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
                "Fast userspace event-synchronization primitives. Large win for multi-threaded games; on by default.",
                isOn: bottleBinding(\.esync, in: bottle)
            )
            toggleRow(
                "MSync",
                "Kernel-assisted sync, newer than ESync and often faster where the engine build supports it.",
                isOn: bottleBinding(\.msync, in: bottle)
            )
            toggleRow(
                "Large address aware",
                "WINE_LARGE_ADDRESS_AWARE — lets a 32-bit game use up to 4GB instead of 2GB, avoiding out-of-memory crashes. Only takes effect on Wine builds that implement the flag (Lutris/GE-patched forks); a no-op otherwise, so treat it as worth trying rather than guaranteed.",
                isOn: binding(\.largeAddressAware)
            )
            toggleRow(
                "Disable CSMT",
                "HKCU\\Software\\Wine\\Direct3D\\csmt=0 — turns off Command Stream Multi-Threading. On (faster) by default; disabling it can fix rendering corruption or hangs in a handful of older, finicky titles.",
                isOn: binding(\.disableCSMT, registryBacked: true)
            )

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Video memory")
                    TextField("Auto", text: $videoMemoryDraft)
                        .frame(width: 80)
                        .onSubmit { commitVideoMemory() }
                    Text("MB").foregroundStyle(.secondary)
                    Button("Set") { commitVideoMemory() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Text("HKCU\\Software\\Wine\\Direct3D\\VideoMemorySize — reported VRAM for wined3d's own renderer. Only matters when DXVK isn't handling the game; leave blank to auto-detect.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Picker("wined3d backend", selection: binding(\.renderer, registryBacked: true)) {
                    Text("Default (OpenGL)").tag(PerformanceSettings.WineD3DRenderer?.none)
                    ForEach(PerformanceSettings.WineD3DRenderer.allCases) { renderer in
                        Text(renderer.displayName).tag(Optional(renderer))
                    }
                }
                Text("HKCU\\Software\\Wine\\Direct3D\\renderer — the backend wined3d's own D3D9/10/11 implementation targets when DXVK isn't overriding it. OpenGL is the most compatible; Vulkan is newer and often faster but less battle-tested.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
                "Mac Driver\\RetinaMode=Y — renders at full display pixel density instead of a scaled logical resolution. Sharper text and UI, but real GPU cost on 4K/5K/6K Retina displays, and some games' windows appear tiny until their in-game resolution is adjusted.",
                isOn: binding(\.retinaMode, registryBacked: true)
            )
            toggleRow(
                "Option key is Alt",
                "Mac Driver\\Left/RightOptionIsAlt=Y — makes both Option keys act as Alt inside the bottle, matching PC shortcuts (Alt+Tab, Alt+F4, weapon-wheel binds).",
                isOn: binding(\.optionAsAlt, registryBacked: true)
            )
            toggleRow(
                "Precise trackpad scrolling",
                "Mac Driver\\UsePreciseScrolling — smoother scroll deltas from trackpads/Magic Mouse. Turn off if a game shows exaggerated zoom or repaint glitches on scroll input.",
                isOn: binding(\.preciseScrolling, registryBacked: true)
            )
        }
        .padding(Theme.Spacing.l)
        .overpassCard()
    }

    // MARK: - Metal HUD

    private func metalHUDSection(_ bottle: Bottle) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            SectionHeader(title: "Metal HUD", systemImage: "gauge.with.dots.needle.67percent")
            Toggle("Show Metal HUD", isOn: bottleBinding(\.metalHUD, in: bottle))
            Text("MTL_HUD_ENABLED — Apple's built-in overlay: live FPS and frame time in the corner of the window.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(PerformanceTuner.benchmarkHint)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(Theme.Spacing.l)
        .overpassCard()
    }

    // MARK: - Advanced env

    private var advancedEnvSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            SectionHeader(title: "Advanced Environment", systemImage: "terminal")
            Text("Merged in last, so these override every toggle above. Use this for the Custom preset or a one-off engine variable not modeled here.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            ForEach(settings.extraEnv.keys.sorted(), id: \.self) { key in
                HStack {
                    Text(key)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                    Text("=").foregroundStyle(.secondary)
                    Text(settings.extraEnv[key] ?? "")
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        mutate { $0.extraEnv.removeValue(forKey: key) }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
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
        .padding(Theme.Spacing.l)
        .overpassCard()
    }

    private func addEnvVar() {
        let key = newEnvKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        let value = newEnvValue
        mutate { $0.extraEnv[key] = value }
        newEnvKey = ""
        newEnvValue = ""
    }

    // MARK: - Resulting environment footer

    @ViewBuilder
    private func resultingEnvFooter(_ bottle: Bottle, _ engine: InstalledEngine?) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            SectionHeader(title: "What This Bottle Will Launch With", systemImage: "list.bullet.rectangle")

            if let engine {
                let base = WineRunner.environment(for: bottle, engine: engine)
                let perf = PerformanceSettings.environment(for: settings, bottle: bottle, engine: engine)
                let merged = base.merging(perf) { _, new in new }

                VStack(alignment: .leading, spacing: 2) {
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
        .padding(Theme.Spacing.l)
        .overpassCard()
    }

    // MARK: - Bindings / persistence

    @ViewBuilder
    private func toggleRow(_ title: String, _ caption: String, isOn: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(title, isOn: isOn)
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

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
        guard let bottle else { return }
        var updated = settings
        transform(&updated)
        if updated.preset != .custom { updated.preset = .custom }
        settings = updated
        persist(updated, in: bottle, applyRegistry: registryBacked)
    }

    private func persist(_ updated: PerformanceSettings, in bottle: Bottle, applyRegistry: Bool) {
        var savedBottle = bottle
        savedBottle.performance = updated
        appState.updateBottle(savedBottle)

        guard applyRegistry, let engine else { return }
        registryError = nil
        isApplyingRegistry = true
        Task {
            do {
                try await PerformanceTuner.applyRegistry(settings: updated, bottle: savedBottle, engine: engine)
            } catch {
                registryError = error.localizedDescription
                appState.report(error, context: "Applying performance settings")
            }
            isApplyingRegistry = false
        }
    }
}
