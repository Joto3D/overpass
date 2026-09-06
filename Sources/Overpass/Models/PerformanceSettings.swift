import Foundation

/// Graphics/runtime tuning layered on top of a bottle's base settings.
/// `Bottle.esync`/`msync`/`metalHUD` stay on `Bottle` itself (the Config
/// tab already surfaces them, and `WineRunner.environment(for:engine:)`
/// already reads them) — `PerformanceView` shows them too, bound straight
/// to `Bottle`, without duplicating a copy here.
///
/// Every field below is cited to a primary source in its doc comment.
/// Several knobs the implementation brief asked to "verify or drop" did not
/// check out against a primary source and were dropped rather than guessed
/// at — see the note at the bottom of this file.
///
/// `PerformanceSettings.environment(for:bottle:engine:)` returns only the
/// environment variables implied by these fields (`WineRunner` merges them
/// into the bottle's base environment); `PerformanceTuner.applyRegistry`
/// applies the registry-backed fields via `wine reg add`/`reg delete`.
struct PerformanceSettings: Codable, Hashable, Sendable {
    // MARK: - Preset

    enum Preset: String, Codable, CaseIterable, Sendable, Identifiable {
        case balanced, maxPerformance, compatibility, custom
        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .balanced: return "Balanced"
            case .maxPerformance: return "Max Performance"
            case .compatibility: return "Compatibility"
            case .custom: return "Custom"
            }
        }

        var summary: String {
            switch self {
            case .balanced:
                return "A safe default: sync primitives on, nothing exotic enabled. Good starting point for most games."
            case .maxPerformance:
                return "Chases frame rate: MetalFX + raytracing where supported, async shader compilation, large address aware. Can be less stable in fussy titles."
            case .compatibility:
                return "Trades speed for stability: CSMT and DXVK async shader compilation off, no raytracing. Try this if a game crashes, hangs, or renders garbage."
            case .custom:
                return "You've changed a setting since the last preset was applied."
            }
        }
    }

    /// `DXVK_HUD` value. See DXVK's README:
    /// https://github.com/doitsujin/dxvk/blob/master/README.md
    enum DXVKHudLevel: String, Codable, CaseIterable, Sendable, Identifiable {
        case none, fps, full
        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .none: return "Off"
            case .fps: return "FPS + Frame Time"
            case .full: return "Full (everything)"
            }
        }

        /// `nil` means "don't set `DXVK_HUD`".
        var envValue: String? {
            switch self {
            case .none: return nil
            case .fps: return "fps,frametimes"
            case .full: return "full"
            }
        }
    }

    /// `HKCU\Software\Wine\Direct3D\renderer`. WineHQ forums / wined3d
    /// registry documentation: https://forum.winehq.org/viewtopic.php?t=3974
    /// ("gl" default OpenGL, "vulkan" Wine's newer Vulkan-backed wined3d).
    /// `gdi`/`no3d` (software) is intentionally not exposed — it's a
    /// debugging fallback, never a performance choice.
    enum WineD3DRenderer: String, Codable, CaseIterable, Sendable, Identifiable {
        case gl, vulkan
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .gl: return "OpenGL"
            case .vulkan: return "Vulkan"
            }
        }
    }

    var preset: Preset = .balanced

    // MARK: - GPTK / D3DMetal (env vars)

    /// `D3DM_ENABLE_METALFX=1`. GPTK 3.0 converts a game's NVIDIA DLSS
    /// calls to Apple MetalFX upscaling where supported. Source:
    /// AppleGamingWiki "Game Porting Toolkit"
    /// (https://www.applegamingwiki.com/wiki/Game_Porting_Toolkit) and
    /// https://mybyways.com/blog/updating-crossover-to-gameporting-toolkit-3-0.
    /// Only helps titles that query DLSS; requires the game's MetalFX
    /// shim DLLs to be present in system32 (a separate one-time setup step,
    /// out of scope here — this only sets the env var).
    var metalFX: Bool = false

    /// `D3DM_ENABLE_LOGGING=1`. Verbose D3DMetal messages to the run log
    /// and Console.app, prefixed "D3DM". Source: AppleGamingWiki "Game
    /// Porting Toolkit". Diagnostic only — adds overhead, off by default.
    var d3dmLogging: Bool = false

    /// `D3DM_SUPPORT_DXR=1`. Reports DirectX Raytracing support through
    /// D3DMetal's DX12 layer. Defaults off on M1/M2, on for M3+ per Apple;
    /// exposed here so it can be forced either way. Source:
    /// AppleGamingWiki "Game Porting Toolkit".
    var raytracing: Bool = false

    // MARK: - DXVK (env vars, Wine-staging + `bottle.dxvk` only)

    /// `DXVK_ASYNC=1`. Compiles shaders on a background thread instead of
    /// stalling the frame — removes most traversal stutter, at the cost of
    /// occasionally showing a not-yet-compiled shader's placeholder for a
    /// frame or two. Source: DXVK README / community docs,
    /// https://github.com/doitsujin/dxvk/blob/master/README.md.
    var dxvkAsync: Bool = true

    /// `DXVK_HUD`. See `DXVKHudLevel`.
    var dxvkHud: DXVKHudLevel = .none

    /// `DXVK_FRAME_RATE=<n>`. Caps rendering to reduce heat/fan noise or
    /// smooth frame pacing; `nil`/`0` leaves it uncapped. Source: DXVK
    /// README, https://github.com/doitsujin/dxvk/blob/master/README.md.
    var frameRateCap: Int? = nil

    // MARK: - Wine core (env var)

    /// `WINE_LARGE_ADDRESS_AWARE=1`. Lets a 32-bit game use up to 4GB
    /// instead of 2GB, avoiding out-of-memory crashes in older
    /// memory-hungry titles. Documented as working on Lutris/GE-patched
    /// Wine builds; it is a no-op (silently ignored) on Wine builds that
    /// don't implement the flag, including the vanilla Gcenx builds this
    /// app ships, so treat it as "try it, verify in-game" rather than a
    /// guaranteed win. Source: Lutris issue #2364 and WineHQ bug 47883
    /// ("Enable explicit large address aware override").
    var largeAddressAware: Bool = false

    // MARK: - Registry: HKCU\Software\Wine\Direct3D

    /// `csmt` DWORD. Command Stream Multi-Threading batches D3D calls onto
    /// one render thread; on by default since Wine 2.6 and usually faster,
    /// but a handful of older/finicky titles render corrupted or hang with
    /// it on. This toggle writes `csmt=0` to disable it, or deletes the
    /// value (reverting to the build default) when off. Source: WineHQ
    /// forums, https://forum.winehq.org/viewtopic.php?f=8&t=28729.
    var disableCSMT: Bool = false

    /// `VideoMemorySize` (REG_SZ, megabytes). Reported VRAM for wined3d's
    /// own D3D9/10/11 implementation — only matters when DXVK isn't
    /// overriding it. `nil`/empty deletes the key, letting Wine
    /// auto-detect. Source: WineHQ forums,
    /// https://forum.winehq.org/viewtopic.php?t=19729.
    var videoMemorySize: String? = nil

    /// `renderer` (REG_SZ). See `WineD3DRenderer`. `nil` deletes the key
    /// (build default, "gl").
    var renderer: WineD3DRenderer? = nil

    // MARK: - Registry: HKCU\Software\Wine\Mac Driver

    /// `RetinaMode` = "Y"/"N". Renders at full display pixel density
    /// instead of a scaled logical resolution — sharper text and UI, but
    /// substantially more pixels to render on a Retina display, and some
    /// games' windows appear tiny until their in-game resolution is
    /// adjusted. Source: multiple WineHQ forum threads, e.g.
    /// https://forum.winehq.org/viewtopic.php?t=31793, and
    /// https://www.robin.eu.org/mac/wine-mac-enabling-high-resolution-mode-retina/.
    var retinaMode: Bool = false

    /// `LeftOptionIsAlt`/`RightOptionIsAlt` = "Y"/"N" (written together).
    /// Makes both Option keys act as Alt inside the bottle, matching PC
    /// shortcuts (Alt+Tab, Alt+F4, weapon-wheel binds). Source: CodeWeavers
    /// support, https://support.codeweavers.com/miscellanous/Remap%20the%20Option%20key%20to%20be%20the%20Alt%20key.
    var optionAsAlt: Bool = true

    /// `UsePreciseScrolling` = "Y"/"N". Smoother scroll deltas from
    /// trackpads/Magic Mouse; some games show exaggerated zoom or repaint
    /// glitches with it on, so it can be turned off for those. Source:
    /// CodeWeavers compatibility tips,
    /// https://www.codeweavers.com/compatibility/crossover/tips/splan-80/trackpad-behavior-zoom-or-scroll,
    /// and https://gist.github.com/plavjanik/81b1fee8258f925a0dfb0cff17ce865e.
    var preciseScrolling: Bool = true

    // MARK: - Advanced

    /// Free-form environment variables, merged in last (highest priority)
    /// by `environment(for:bottle:engine:)` — used for the Custom preset
    /// or any one-off engine-specific variable not modeled above.
    var extraEnv: [String: String] = [:]

    init() {}

    // MARK: - Presets

    /// Canonical field values for each non-custom preset. `.custom` isn't
    /// included — it's not a fixed profile, it's the marker
    /// `applyingPreset`/the UI sets once the user edits after applying one
    /// of these.
    static let presets: [Preset: PerformanceSettings] = {
        var balanced = PerformanceSettings()
        balanced.preset = .balanced

        var maxPerformance = PerformanceSettings()
        maxPerformance.preset = .maxPerformance
        maxPerformance.metalFX = true
        maxPerformance.raytracing = true
        maxPerformance.dxvkAsync = true
        maxPerformance.dxvkHud = .fps
        maxPerformance.largeAddressAware = true

        var compatibility = PerformanceSettings()
        compatibility.preset = .compatibility
        compatibility.metalFX = false
        compatibility.raytracing = false
        compatibility.dxvkAsync = false
        compatibility.disableCSMT = true
        compatibility.renderer = .gl

        return [.balanced: balanced, .maxPerformance: maxPerformance, .compatibility: compatibility]
    }()

    /// Returns a copy of `self` with `preset`'s canonical field values
    /// applied, preserving `extraEnv` (custom variables always survive a
    /// preset switch). Applying `.custom` just marks `self` as custom
    /// without changing any other field — there's no fixed "custom"
    /// profile to apply.
    func applyingPreset(_ preset: Preset) -> PerformanceSettings {
        guard preset != .custom, var next = PerformanceSettings.presets[preset] else {
            var same = self
            same.preset = .custom
            return same
        }
        next.extraEnv = extraEnv
        return next
    }

    // MARK: - Environment

    /// Only the environment variables implied by `settings` — `WineRunner`
    /// merges this into the bottle's base environment
    /// (`WineRunner.environment(for:engine:)`), so nothing here duplicates
    /// what that function already sets (`WINEESYNC`, `MTL_HUD_ENABLED`,
    /// `WINEDLLOVERRIDES`, ...).
    static func environment(for settings: PerformanceSettings, bottle: Bottle, engine: InstalledEngine) -> [String: String] {
        var env: [String: String] = [:]

        switch engine.kind {
        case .gptk:
            if settings.metalFX { env["D3DM_ENABLE_METALFX"] = "1" }
            if settings.raytracing { env["D3DM_SUPPORT_DXR"] = "1" }
            if settings.d3dmLogging { env["D3DM_ENABLE_LOGGING"] = "1" }

        case .wineStaging:
            // DXVK vars only mean anything once DXVK's DLLs are actually
            // installed in system32 (`bottle.dxvk`); setting them
            // otherwise is inert but needlessly noisy in the env preview.
            if bottle.dxvk {
                if settings.dxvkAsync { env["DXVK_ASYNC"] = "1" }
                if let hud = settings.dxvkHud.envValue { env["DXVK_HUD"] = hud }
                if let cap = settings.frameRateCap, cap > 0 { env["DXVK_FRAME_RATE"] = String(cap) }
            }
        }

        if settings.largeAddressAware { env["WINE_LARGE_ADDRESS_AWARE"] = "1" }

        for (key, value) in settings.extraEnv { env[key] = value }
        return env
    }
}

// MARK: - Dropped knobs (verified against a primary source and rejected)
//
// - `MTL_SHADER_VALIDATION`: a Metal *debugging* flag (Xcode-injected
//   shader validation, off by default outside Xcode) — setting it to 0 at
//   runtime changes nothing; not a real performance knob.
// - DXVK GPL-async (`DXVK_ASYNC` "graphics pipeline library" variant):
//   couldn't confirm the Gcenx DXVK-macOS build ships the GPL-based async
//   implementation rather than the plain shader-compile-thread one, so
//   there's no separate flag to expose beyond `dxvkAsync`/`DXVK_ASYNC`.
// - `AllowVerticalSync` (wined3d): no primary source found documenting
//   this key or its accepted values for current Wine.
// - `DisableMacVirtualDesktop`: doesn't exist — Wine's "emulate a virtual
//   desktop" only works under the X11 driver, which the macOS build
//   (winemac.drv) doesn't use, so there's nothing to disable.
// - `highPriority` (process): `taskpolicy -c utility/background` can only
//   *demote* a process's scheduling; without root there's no equivalent
//   "promote" call available to a launched-by-the-user Wine process, so
//   there's no safe way to implement this.
// - `fsyncless`, explicit `WINEDEBUG=-all` toggle: already the app's
//   default (`WineRunner.environment`), nothing to add here.
