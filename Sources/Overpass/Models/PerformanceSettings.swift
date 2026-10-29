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
    /// Only helps titles that actually query DLSS — but, contrary to what
    /// this comment claimed until October 2026, it needs **no** separate
    /// setup step on a GPTK bottle. GPTK ships the shim itself at
    /// `wine/lib/wine/x86_64-windows/{nvngx,nvngx-on-metalfx}.dll`, each
    /// paired with an `x86_64-unix/*.so` symlink to
    /// `external/libd3dshared.dylib`, and that directory is exactly where
    /// this Wine build's builtin-dll resolver looks. Verified on this
    /// machine with a `WINEDEBUG=+loaddll` probe against the GPTK bottle:
    /// `Loaded L"C:\windows\system32\nvngx.dll" ...: builtin` — resolved
    /// straight from the engine, nothing copied into system32. (The
    /// DXVK-style system32 copy that `D3DMetalOverlay` documents is a
    /// Wine-staging problem; `metalFX` only emits on `.gptk` anyway.)
    ///
    /// Still unverified: that DLSS→MetalFX actually engages in a running
    /// game. The probe proves the shim loads, not that a DLSS title drives
    /// it. D3DMetal also reads `D3DM_NVNGX_PATH` to point at a specific
    /// nvngx build; Overpass leaves it unset, so the default resolution
    /// above applies.
    var metalFX: Bool = false

    /// `D3DM_ENABLE_LOGGING=1`. Verbose D3DMetal messages to the run log
    /// and Console.app, prefixed "D3DM". Source: AppleGamingWiki "Game
    /// Porting Toolkit". Diagnostic only — adds overhead, off by default.
    var d3dmLogging: Bool = false

    /// Frame counter diagnostic: injects `libfgshim.dylib` (built from
    /// `Shim/fgshim.m` by `scripts/bundle.sh`) into the bottle's Wine
    /// processes via `DYLD_INSERT_LIBRARIES`, so every Metal present the
    /// game makes is counted and logged as `fgshim:` lines in the per-run
    /// log (`~/Library/Application Support/Overpass/Logs/`, the same file
    /// Wine's stderr already streams into via `ProcessRunner`).
    ///
    /// **Counter only.** It observes presents and calls straight through;
    /// there is no frame generation, interpolation, MetalFX or present
    /// thread behind this switch. It exists to prove the hook catches
    /// frames from a real Windows game under Wine before anything is built
    /// on top of it. Deliberately engine-independent (unlike the D3DM_* /
    /// DXVK_* fields): D3DMetal and MoltenVK both end in Metal, and the
    /// shim hooks all seven present selectors they use between them — see
    /// `Shim/fgshim.m` for why each is needed, and in particular that
    /// MoltenVK's present fires on a different thread from `nextDrawable`.
    ///
    /// Off by default and off in every preset: a diagnostic, not a feature,
    /// and injecting a dylib into every Wine child process is not something
    /// to do unasked. A no-op (no env var at all) when the dylib is missing
    /// — i.e. a `swift build` dev run, where it exists only inside the
    /// .app; see `FrameCounterShim.dylibURL`. Decodes via `decodeIfPresent`
    /// so `metadata.json` written before this field existed still loads.
    var frameCounter: Bool = false

    /// `D3DM_SUPPORT_DXR=1`. Reports DirectX Raytracing support through
    /// D3DMetal's DX12 layer. Defaults off on M1/M2, on for M3+ per Apple;
    /// exposed here so it can be forced either way. Source:
    /// AppleGamingWiki "Game Porting Toolkit".
    var raytracing: Bool = false

    // MARK: - DXVK (env vars, Wine-staging + `bottle.dxvk` only)

    /// `DXVK_HUD`. See `DXVKHudLevel`.
    var dxvkHud: DXVKHudLevel = .none

    /// The frame rate limiter, delivered as `dxgi.maxFrameRate` /
    /// `d3d9.maxFrameRate` through `DXVK_CONFIG` (see `environment`).
    /// Caps rendering to reduce heat/fan noise or smooth frame pacing;
    /// `nil`/`0` leaves it uncapped. Was `DXVK_FRAME_RATE` while Overpass
    /// shipped the old Gcenx 1.10.3 build — that variable does not exist
    /// in upstream DXVK 3.x.
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

    // MARK: - Codable

    // Custom, rather than synthesized, so a field added after this type
    // shipped (`frameCounter`) can default when absent instead of failing
    // the decode — a synthesized `init(from:)` throws `keyNotFound` for any
    // non-Optional property missing from an older `metadata.json`, which
    // would take the bottle's whole `performance` block down with it. Every
    // field uses `decodeIfPresent` with its declared default, so the next
    // addition is safe too. `encode(to:)` stays synthesized.
    private enum CodingKeys: String, CodingKey {
        case preset, metalFX, d3dmLogging, frameCounter, raytracing, dxvkHud, frameRateCap
        case largeAddressAware, disableCSMT, videoMemorySize, renderer
        case retinaMode, optionAsAlt, preciseScrolling, extraEnv
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preset = try c.decodeIfPresent(Preset.self, forKey: .preset) ?? .balanced
        metalFX = try c.decodeIfPresent(Bool.self, forKey: .metalFX) ?? false
        d3dmLogging = try c.decodeIfPresent(Bool.self, forKey: .d3dmLogging) ?? false
        frameCounter = try c.decodeIfPresent(Bool.self, forKey: .frameCounter) ?? false
        raytracing = try c.decodeIfPresent(Bool.self, forKey: .raytracing) ?? false
        dxvkHud = try c.decodeIfPresent(DXVKHudLevel.self, forKey: .dxvkHud) ?? .none
        frameRateCap = try c.decodeIfPresent(Int.self, forKey: .frameRateCap)
        largeAddressAware = try c.decodeIfPresent(Bool.self, forKey: .largeAddressAware) ?? false
        disableCSMT = try c.decodeIfPresent(Bool.self, forKey: .disableCSMT) ?? false
        videoMemorySize = try c.decodeIfPresent(String.self, forKey: .videoMemorySize)
        renderer = try c.decodeIfPresent(WineD3DRenderer.self, forKey: .renderer)
        retinaMode = try c.decodeIfPresent(Bool.self, forKey: .retinaMode) ?? false
        optionAsAlt = try c.decodeIfPresent(Bool.self, forKey: .optionAsAlt) ?? true
        preciseScrolling = try c.decodeIfPresent(Bool.self, forKey: .preciseScrolling) ?? true
        extraEnv = try c.decodeIfPresent([String: String].self, forKey: .extraEnv) ?? [:]
    }

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
        maxPerformance.dxvkHud = .fps
        maxPerformance.largeAddressAware = true

        var compatibility = PerformanceSettings()
        compatibility.preset = .compatibility
        compatibility.metalFX = false
        compatibility.raytracing = false
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
                if let hud = settings.dxvkHud.envValue { env["DXVK_HUD"] = hud }
                if let cap = settings.frameRateCap, cap > 0 {
                    // Upstream DXVK has no `DXVK_FRAME_RATE`; the limiter
                    // is a config option now, so it goes through
                    // `DXVK_CONFIG` (inline dxvk.conf syntax, `;`
                    // separated). Both keys are set so the cap applies
                    // whichever API the game renders with — `dxgi` covers
                    // D3D10/11, `d3d9` covers D3D8/9.
                    env["DXVK_CONFIG"] = "dxgi.maxFrameRate = \(cap); d3d9.maxFrameRate = \(cap)"
                }
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
// - `DXVK_ASYNC` (async shader compilation), dropped October 2026 when
//   the DXVK pin moved from Gcenx/DXVK-macOS 1.10.3 to upstream 3.1.1:
//   async was never an upstream feature, it came from the third-party
//   patch that fork carried ("dxvk-macOS-async"). Verified absent from
//   upstream 3.1.1 by running `strings` over its `x64/d3d11.dll` — no
//   `DXVK_ASYNC` string exists, and the only "async" matches are
//   `ID3D11Asynchronous` C++ symbol names. DXVK 2.0+ instead builds
//   pipelines ahead of time via `dxvk.enableGraphicsPipelineLibrary`,
//   which it auto-detects per driver; forcing that on where DXVK chose
//   not to can regress, so the toggle was removed rather than rewired.
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
