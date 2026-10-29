import Foundation

/// The per-game fix database: Overpass's answer to Proton's
/// `protonfixes`. Built-in fixes ship in `builtIn`; anything dropped into
/// `Paths.fixes` as a `.json` file extends or overrides them by `id`,
/// with no rebuild.
///
/// The built-in/external split mirrors `EngineCatalog.merged(with:)`, but
/// resolves collisions the other way round. There, the compiled-in entry
/// wins because its checksum was hand-verified and a fetched duplicate
/// can't be. Here, the *user* entry wins — overriding a shipped fix with
/// a local one is the entire point of the directory, and a fix is a
/// recipe to re-run rather than a binary to trust.
///
/// ## File format
///
/// Each file in `Paths.fixes` holds either one `GameFix` object or an
/// array of them, so a single-game fix and an imported batch both drop in
/// unchanged:
///
/// ```json
/// [
///   {
///     "id": "example-game",
///     "name": "Example Game",
///     "executables": ["example.exe"],
///     "winetricks": ["vcrun2019"],
///     "registry": [
///       { "key": "HKCU\\Software\\Example", "name": "Windowed",
///         "type": "REG_DWORD", "data": "1" }
///     ],
///     "env": { "SOME_VAR": "1" },
///     "notes": "Crashes on startup without vcrun2019.",
///     "source": "tested on this machine, 2026-10-29"
///   }
/// ]
/// ```
///
/// A malformed file is skipped with its name reported rather than failing
/// the whole catalog — one bad import should not cost every other fix.
///
/// ## Licensing of the entries below
///
/// This file's *code* is GPL-3.0 like the rest of Overpass, but the fix
/// *data* — every field value in the `GameFix` literals below — is
/// dedicated to the public domain under CC0 1.0. See `LICENSE-FIXES` at
/// the repo root for the scope and the reasoning.
///
/// The practical consequence for anyone adding an entry here: do **not**
/// paste from umu-protonfixes, Bridgeplay, proton-ge or CrossOver's
/// profile database. Their expression is GPL or proprietary and cannot be
/// relicensed as public domain. Read the underlying fact from a public
/// source and write the entry yourself, citing that source in `source` —
/// which `DebugSelfTest` requires of every built-in fix.
enum GameFixCatalog {
    // MARK: - Built-in fixes

    /// The CrossOver-derived Steam recipe, migrated here from
    /// `AppTweaks.steam` (which now reads from this entry, so there is
    /// one copy). See `AppTweak`'s doc comment for the full CrossOver
    /// provenance and the by-hand verification behind `notes` below.
    static let steam = GameFix(
        id: "steam",
        name: "Steam",
        executables: ["steam.exe"],
        steamAppIDs: [],
        registry: [
            .init(key: "HKCU\\Software\\Valve\\Steam", name: "DWriteEnable", type: "REG_DWORD", data: "0"),
        ],
        winetricks: ["corefonts", "msxml3"],
        notes: """
        Does NOT fix the steamwebhelper crash — verified by hand against \
        Wine Staging 11.16 on 2026-09-07, along with every documented \
        fallback (GPUAccelWebViews=0, per-exe Windows 7 override, \
        LargeAddressAware, whole-bottle Windows 7, which made it worse). \
        Kept because every step is cheap and harmless, matches what \
        CrossOver ships, and may matter for other client or engine \
        combinations. Deliberately does not set windowsVersion.
        """,
        source: "CrossOver 26.3 profile com.codeweavers.c4.206, plus first-hand testing"
    )

    /// Eagle Dynamics' flight simulator — the best-evidenced fix in the
    /// catalog, and the only one here backed by the publisher's own
    /// documentation rather than community reports alone.
    ///
    /// Only `DCS.exe` is matched, deliberately. Standalone installs also
    /// ship `bin/DCS_updater.exe`, but `--no-launcher` is meaningless to
    /// the updater, and matching is per-fix rather than per-executable,
    /// so including it would push a useless argument at it.
    ///
    /// `windowsVersion` is `.win10`, which is already `Bottle`'s default —
    /// `AppTweak.apply` skips the `winecfg` call when they match, so this
    /// costs nothing on a default bottle and corrects a win7/win11 one.
    static let dcsWorld = GameFix(
        id: "dcs-world",
        name: "DCS World",
        executables: ["DCS.exe"],
        steamAppIDs: ["223750"],
        registry: [
            .init(key: "HKCU\\Software\\Wine\\DllOverrides", name: "wbemprox", type: "REG_SZ", data: "native"),
        ],
        winetricks: ["d3dcompiler_47"],
        windowsVersion: .win10,
        launchArgs: "--no-launcher",
        notes: """
        d3dcompiler_47 fixes the "fx_5_0" shader-compile failure and is \
        called for by Eagle Dynamics' own Steam Deck FAQ, the Hoggit wiki \
        and the DCS-on-Linux project. --no-launcher skips the Electron \
        launcher, which renders as a white or black window under Wine; \
        ED's own Steam launch entries pass it too. The wbemprox=native \
        override is listed as required by all three sources, though none \
        explains why. NOT VERIFIED ON macOS: every source is Linux, and \
        AppleGamingWiki's CrossOver rating was last tested against DCS \
        2.5.6/2.7.0 in 2021. Also note DCS-on-Linux reports that Wine \
        10.3-11.7 can fail the updater with a "debugger has been found \
        running" error — relevant to the Wine-staging engine's range.
        """,
        source: "Eagle Dynamics Steam Deck FAQ; wiki.hoggitworld.com/view/DCS_on_linux; github.com/ChaosRifle/DCS-on-Linux; applegamingwiki.com/wiki/DCS_World"
    )

    /// Blizzard's launcher. The Windows-10 prefix is the one genuinely
    /// macOS-sourced recommendation found for any launcher.
    ///
    /// Matches both executables because the installed layout has shifted:
    /// `Battle.net Launcher.exe` is the documented entry point, and
    /// Lutris' own docs tell users to run `Battle.net.exe` directly when
    /// it won't start.
    static let battleNet = GameFix(
        id: "battlenet",
        name: "Battle.net",
        executables: ["Battle.net Launcher.exe", "Battle.net.exe"],
        windowsVersion: .win10,
        notes: """
        A Windows 10 prefix is what AppleGamingWiki's Game Porting Toolkit \
        page calls for (last edited Nov 2025); win10 bottles are also what \
        the Whisky reports used. Deliberately NOT shipped: the \
        --in-process-gpu launch argument, which fixes a black CEF window \
        on Linux/Wayland (Wine bug 57635) but had no effect for one of two \
        reporters on wine-staging 11.6 (bug 59631) and was fixed upstream \
        in 11.10 — try it by hand on Battle.net.exe if the launcher is \
        black. Also not shipped: WINE_SIMULATE_WRITECOPY=1, a downstream \
        patch not in upstream Wine, so probably inert on Wine-staging. \
        The most-cited macOS fix is not expressible here at all — it is \
        the in-app "disable browser hardware acceleration" setting, a \
        Battle.net.config edit.
        """,
        source: "applegamingwiki.com/wiki/Game_Porting_Toolkit; lutris.net Battle.Net docs; github.com/Whisky-App/Whisky/issues/198"
    )

    /// Epic's launcher. Launch arguments only — they cost nothing at
    /// install time, which is the whole reason this entry is defensible
    /// when the evidence behind it is Linux-era.
    static let epicGamesLauncher = GameFix(
        id: "epic-games-launcher",
        name: "Epic Games Launcher",
        executables: ["EpicGamesLauncher.exe"],
        launchArgs: "-opengl -SkipBuildPatchPrereq",
        advisory: .init(
            severity: .degraded,
            message: """
            The Epic Games Launcher is reported to fail during install \
            under the Game Porting Toolkit. The launch arguments Overpass \
            applies are the documented Wine workarounds and cost nothing \
            to try, but if it will not install, Heroic Games Launcher is \
            the recommended route on macOS.
            """
        ),
        notes: """
        -SkipBuildPatchPrereq avoids prerequisites that fail under Wine \
        Mono; a Wine developer confirms on bug 48406 that it is still \
        needed. -opengl avoids a black launcher window, though the \
        reporter on bug 40376 calls it an avoidance rather than a fix. \
        Both are launch arguments, so they cost nothing to try. EXPECT \
        THIS TO FAIL ANYWAY: AppleGamingWiki's GPTK page says the \
        launcher fails to install under GPTK entirely and recommends \
        Heroic instead; CrossOver's own changelog shows Epic support \
        arriving as engine work in 25.0.0, which no prefix setting \
        reproduces. Deliberately not shipped: dotnet48 (flagged as \
        breaking other games) and the libglesv2=d override (inconsistent, \
        and hangs at the splash screen on staging 9.6 per bug 48068).
        """,
        source: "lutris.net/games/install/5835/view; bugs.winehq.org/show_bug.cgi?id=48406; applegamingwiki.com/wiki/Game_Porting_Toolkit"
    )

    /// GOG's launcher. One cheap font package, on the same reasoning as
    /// the Steam entry: ~30s, harmless when it doesn't help.
    static let gogGalaxy = GameFix(
        id: "gog-galaxy",
        name: "GOG Galaxy",
        executables: ["GalaxyClient.exe"],
        winetricks: ["corefonts"],
        notes: """
        corefonts is documented on Wine bug 50212 (2020) as fixing a black \
        GOG Galaxy window. Evidence is Linux-only and five years old, and \
        a white-window regression on Wine 11.0-rc1 (bug 59162) was fixed \
        upstream in 11.1 rather than by configuration — so the shipped \
        engine probably matters more than this verb does. Kept because it \
        is cheap and harmless, the same bar the Steam entry is held to. \
        Deliberately not shipped: mfc140/dotnet48/win10 from the Lutris \
        script (which pins an old GOG 2.1.6.29 installer, so its needs are \
        not today's), and /runWithoutUpdating /deelevated, which only make \
        sense alongside that pinned version.
        """,
        source: "bugs.winehq.org/show_bug.cgi?id=50212; bugs.winehq.org/show_bug.cgi?id=59162; lutris.net/games/install/39280/view"
    )

    // MARK: - Advisories
    //
    // Entries that change nothing and say something. Each one is a
    // compatibility fact no bottle setting can alter, researched
    // 2026-10-29 — the half of the database that stops a user spending
    // twenty minutes installing something that cannot work.

    static let ubisoftConnect = GameFix(
        id: "ubisoft-connect",
        name: "Ubisoft Connect",
        executables: ["UbisoftConnect.exe", "upc.exe"],
        advisory: .init(
            severity: .wontRun,
            message: """
            Ubisoft Connect does not run on Wine-staging or the Game \
            Porting Toolkit — only CodeWeavers' paid CrossOver, whose fix \
            is engine-level and cannot be reproduced by any bottle \
            setting. Nothing Overpass can configure will change this.
            """
        ),
        source: "Heroic Games Launcher wiki, 'How to install Ubisoft Connect on Linux and Mac' (edited Apr 2026)"
    )

    static let eaApp = GameFix(
        id: "ea-app",
        name: "EA app",
        executables: ["EADesktop.exe", "EALauncher.exe"],
        advisory: .init(
            severity: .wontRun,
            message: """
            The EA app is not currently working under the Game Porting \
            Toolkit. The recipes circulating for it are Linux ones, and \
            the only macOS guide was marked "does not work anymore" by \
            its own author in May 2025. Expect a black window.
            """
        ),
        source: "applegamingwiki.com/wiki/Game_Porting_Toolkit (Not working yet); github.com/seamonkey420/EA-App-Games-in-Heroic-on-MacOS"
    )

    /// Matched on `start_protected_game.exe` — the anti-cheat wrapper
    /// Steam actually launches — not on the Stingray engine binary under
    /// `bin/`. Verified against Steam's own launch configuration; the
    /// obvious guess ("helldivers2.exe") does not exist.
    ///
    /// KNOWN OVER-MATCH (found 2026-10-29): `start_protected_game.exe` is
    /// the standard Easy Anti-Cheat wrapper name, and Steam's appinfo
    /// shows ELDEN RING (app 1245620, launch entry
    /// `Game/start_protected_game.exe`) and Apex Legends' dev branches
    /// using it too. Matching is by basename and `GameFixService.prepare`
    /// passes no Steam app id, so launching Elden Ring through Overpass
    /// shows the Helldivers 2 advisory. Fixing it needs the launch path or
    /// app id to reach `matches(exe:steamAppID:)`; nothing in this file
    /// can. Narrowing is impossible, so the entry is instead *worded* for
    /// the shim rather than for one game. The advisory is true of every
    /// title behind it — EAC does not clear Wine on macOS whichever game
    /// it guards, and FX Steam Launcher's Proton-in-a-VM route serves them
    /// all equally — so the general case leads, and the Helldivers-specific
    /// history follows in its own paragraph, attributed. Showing a message
    /// headed "Helldivers 2" to someone launching ELDEN RING was the actual
    /// defect; the over-broad match is harmless once the text fits it.
    static let helldivers2 = GameFix(
        id: "helldivers-2",
        name: "Easy Anti-Cheat (Steam protected-game launcher)",
        executables: ["start_protected_game.exe"],
        steamAppIDs: ["553850"],
        advisory: .init(
            severity: .wontRun,
            message: """
            This is Steam's Easy Anti-Cheat launcher \
            (start_protected_game.exe), used by Helldivers 2, ELDEN RING \
            and others. EAC's Linux/Proton clearance does not extend to \
            Wine on macOS, so the anti-cheat fails at start whichever game \
            is behind it. The route that does work runs real Proton inside \
            a Linux VM, because Arrowhead opted into EAC's Proton runtime \
            and that clearance covers Linux. FX Steam Launcher's own \
            telemetry reports Helldivers 2 at a 100% launch rate over 130 \
            sessions and 37.1 hours of play, median 51.5 fps, last seen 29 \
            October 2026, on M4 Pro / M1 Max / M3 Pro / M1 Pro.

            Helldivers 2 in particular switched from nProtect GameGuard to \
            EAC on 20 October 2026 and has been reported crashing at \
            anti-cheat start on macOS 27 under both CrossOver and plain \
            Wine; guides saying it works on Mac predate that switch.
            """,
            // FX Steam Launcher is that Proton-in-a-VM route. Bundle id
            // read from the installed app's Info.plist on 2026-10-29.
            // Not verified: that Helldivers 2 actually reaches a mission
            // in it — the sentence in `message` above stays hedged.
            alternative: .init(
                name: "FX Steam Launcher",
                bundleIdentifier: "es.fxgam.steamac",
                // Upstream, verified 29 October 2026 via the GitHub API:
                // `fxgl/steamac` is the original (fork: false, no parent,
                // 813 stars, Apache-2.0). This previously pointed at
                // `StonkGuy/steamac`, which the API reports as a fork of it
                // with 10 stars — sending someone to a fork when the
                // upstream is right there is a worse answer, even though
                // the fork happened to be pushed more recently.
                url: URL(string: "https://github.com/fxgl/steamac")!
            )
        ),
        source: "gamingonlinux.com (EAC switch, 20 Oct 2026, and \"Steam Deck and Linux compatibility remains unchanged\"); github.com/gauthierpiarrette/highball/issues/439 (fails under Wine on macOS 27.0.1); fxgl.github.io/steamac/games.html read 29 Oct 2026 (the launch-rate and fps figures). Those figures come from 5 installs, so the sample is small, and the page states its fps is guest scanout rather than an in-game benchmark and is \"a useful comparison, not a guarantee of compatibility\"."
    )

    static let counterStrike2 = GameFix(
        id: "counter-strike-2",
        name: "Counter-Strike 2",
        executables: ["cs2.exe"],
        steamAppIDs: ["730"],
        advisory: .init(
            severity: .degraded,
            message: """
            Counter-Strike 2 launches and plays, but VAC keeps \
            compatibility-layer clients off its secure servers, so \
            matchmaking is unavailable. VAC does not ban for running \
            under Wine — it just won't let you onto protected servers.
            """
        ),
        source: "bridgeplay.dev compatibility notes; areweanticheatyet.com (VAC: Supported)"
    )

    /// Four games whose Windows build Overpass can run, and shouldn't.
    /// Collected rather than written out one by one because the finding
    /// and the wording are identical; only the names differ.
    ///
    /// `message` replaces the shared wording when given. The four original
    /// entries use the shared sentence, which asserts that Wine is "slower
    /// and more fragile"; that is a general claim, not something measured
    /// per title, and the 2026-10-29 additions (`cyberpunk2077` and
    /// friends) deliberately avoid repeating it - AppleGamingWiki rates
    /// Cyberpunk 2077 "Perfect" under CrossOver, so the sentence would be
    /// false for it. `notes` is optional for the same historical reason.
    private static func nativeBuildAdvisory(
        id: String, name: String, executables: [String], steamAppID: String, extra: String = "",
        message: String? = nil, notes: String? = nil, source: String
    ) -> GameFix {
        GameFix(
            id: id,
            name: name,
            executables: executables,
            steamAppIDs: [steamAppID],
            advisory: .init(
                severity: .info,
                message: message ?? ("\(name) has a native macOS build on Steam. "
                    + "Running the Windows version through Wine is slower and more fragile for no benefit."
                    + (extra.isEmpty ? "" : " " + extra))
            ),
            notes: notes,
            source: source
        )
    }

    static let noMansSky = nativeBuildAdvisory(
        id: "no-mans-sky", name: "No Man's Sky", executables: ["NMS.exe"], steamAppID: "275850",
        extra: """
        The Windows build renders with Vulkan, so D3DMetal cannot help it \
        at all — AppleGamingWiki rates CrossOver "Unplayable" against a \
        native rating of "Perfect".
        """,
        source: "nomanssky.com/2023/06/no-mans-sky-on-mac; applegamingwiki.com/wiki/No_Man's_Sky"
    )

    static let deadCells = nativeBuildAdvisory(
        id: "dead-cells", name: "Dead Cells", executables: ["deadcells.exe", "deadcells_gl.exe"], steamAppID: "588650",
        source: "Steam macOS launch entry; applegamingwiki.com/wiki/Dead_Cells (native: Perfect, verified 2024-01-10)"
    )

    static let riseOfTheTombRaider = nativeBuildAdvisory(
        id: "rise-of-the-tomb-raider", name: "Rise of the Tomb Raider",
        executables: ["ROTTR.exe", "ROTTR_prot.exe", "ROTTR_orig.exe"], steamAppID: "391220",
        source: "Steam macOS launch entry 'Rise of the Tomb Raider.app' (Feral port); applegamingwiki.com rates native Perfect"
    )

    static let mechabellum = nativeBuildAdvisory(
        id: "mechabellum", name: "Mechabellum", executables: ["Mechabellum.exe"], steamAppID: "669330",
        source: "Steam macOS launch entry 'Mechabellum.app'; macgamingdb.app/games/mechabellum (native, 'Works OOB')"
    )

    /// UNIGINE's three benchmarks (Heaven, Valley, Superposition) all
    /// ship a `GPUMonitor` plugin that reads GPU clocks and temperature
    /// through vendor libraries. On an AMD system that means
    /// `atiadlxx.dll`, the AMD Display Library. Wine ships a stub for it
    /// whose entry points are declared but not implemented, and calling
    /// an unimplemented stub entry point does not fail gracefully — Wine
    /// aborts the process:
    ///
    ///     wine: Call from 00000000003573A0 to unimplemented function
    ///           atiadlxx.dll.ADL_Adapter_Active_Get, aborting
    ///
    /// Disabling the dll outright is the fix: `LoadLibrary` then fails,
    /// which `GPUMonitor` handles (it simply reports no GPU telemetry)
    /// instead of calling into a stub that kills the process.
    ///
    /// Verified by hand on 29 October 2026 against Heaven 4.0 in a
    /// `gptk-3.0-3` bottle, with `-extern_plugin GPUMonitor` left enabled
    /// throughout so the override is the only variable:
    ///
    /// | `WINEDLLOVERRIDES`   | Result                   |
    /// |----------------------|--------------------------|
    /// | unset                | aborts on `atiadlxx`     |
    /// | `atiadlxx=d`         | engine runs              |
    /// | `atiadlxx=`          | engine runs              |
    /// | `atiadlxx=disabled`  | engine runs              |
    ///
    /// The registry form below was then verified the same way, with no
    /// environment override set at all: the engine ran and did not abort.
    /// Registry rather than `env` deliberately — a fix's `env` entries are
    /// merged by key, so setting `WINEDLLOVERRIDES` here would clobber the
    /// DXVK override list `WineRunner.environment` builds for a DXVK
    /// bottle. The registry key is additive and per-dll, so it composes.
    ///
    /// `data` is the empty string because that is Wine's *documented* way
    /// to disable a dll (it is what winecfg's "Disable" writes). All three
    /// environment spellings above work, but only because Wine parses
    /// anything that is not `native`/`builtin` into an empty override
    /// list; relying on that would be relying on a parser accident.
    static let unigineBenchmarks = GameFix(
        id: "unigine-benchmarks",
        name: "UNIGINE Benchmarks (Heaven / Valley / Superposition)",
        executables: [
            "heaven.exe",
            "valley.exe",
            "superposition.exe",
            "superposition_cli.exe",
        ],
        steamAppIDs: [],
        registry: [
            .init(key: "HKCU\\Software\\Wine\\DllOverrides", name: "atiadlxx", type: "REG_SZ", data: ""),
        ],
        notes: """
        Disables the Wine `atiadlxx.dll` stub, whose unimplemented \
        entry points abort the process when the bundled GPUMonitor \
        plugin queries AMD GPU telemetry. Isolated against Heaven 4.0 \
        with GPUMonitor enabled; see this entry's doc comment for the \
        full matrix. Not a performance fix and not a renderer fix — \
        Heaven and Valley are 32-bit and offer only DX9/DX11, so neither \
        can reach D3DMetal at all (GPTK translates 64-bit D3D11/D3D12 \
        only). Superposition is 64-bit D3D11 and does use D3DMetal.
        """,
        source: "First-hand testing on this machine, 29 October 2026"
    )

    // MARK: - Research of 2026-10-29 (second pass)
    //
    // Everything below was added in one research pass with a fixed rule:
    // `notes` says, entry by entry, what was OBSERVED on this machine and
    // what a source merely CLAIMS, because the two are very different
    // kinds of evidence and the catalog is only as trustworthy as that
    // line. "Verified" below means reproduced or read first-hand today;
    // "source-claimed" means the cited source says so and nothing here
    // contradicts it.
    //
    // The one hard constraint behind what was worth adding: GPTK's
    // D3DMetal translates 64-bit D3D11 and D3D12 only (see the measured
    // symbol counts in `FrameCounterShim.swift`). D3D9 is wined3d on both
    // architectures and so is 32-bit D3D11, so a fix for a 32-bit or
    // D3D9-only title can make it launch but cannot make it faster, and
    // its `notes` say so rather than implying otherwise.

    // MARK: Native macOS builds

    /// Shared provenance for the native-build advisories below, written
    /// once because it is identical and long.
    private static let steamNativeEvidence = """
        FIRST-HAND VERIFIED 2026-10-29: Steam's store API \
        (store.steampowered.com/api/appdetails) returns platforms.mac = \
        true, and the requirement text in the message is what its \
        mac_requirements field says. Steam's own appinfo, read through \
        api.steamcmd.net (a mirror of Steam's data), lists a macOS launch \
        entry for the app id and the Windows executable names matched \
        here. NOT verified: how the native build performs on this \
        machine, or how it compares with the Windows build under \
        D3DMetal. Overpass is Apple-silicon only, so "requires an Apple \
        processor" is not a restriction here.
        """

    static let cyberpunk2077 = nativeBuildAdvisory(
        id: "cyberpunk-2077", name: "Cyberpunk 2077",
        executables: ["Cyberpunk2077.exe", "REDprelauncher.exe"], steamAppID: "1091500",
        message: """
        Cyberpunk 2077 has a native macOS build on Steam, which Steam \
        lists as requiring an Apple processor and macOS 15.5 or later. \
        Use that instead of the Windows build under Wine.
        """,
        notes: steamNativeEvidence,
        source: "store.steampowered.com/api/appdetails?appids=1091500 (read 2026-10-29); Steam appinfo launch entries 'Cyberpunk2077.app' and 'redprelauncher.exe' via api.steamcmd.net"
    )

    /// `bg3.exe` is Larian's Vulkan binary and `bg3_dx11.exe` the D3D11
    /// one; Steam launches neither directly but `LariLauncher.exe`.
    static let baldursGate3 = nativeBuildAdvisory(
        id: "baldurs-gate-3", name: "Baldur's Gate 3",
        executables: ["LariLauncher.exe", "bg3.exe", "bg3_dx11.exe"], steamAppID: "1086940",
        message: """
        Baldur's Gate 3 has a native macOS build on Steam, which Steam \
        lists as requiring macOS 14.7.1 or newer on an Apple M1 or \
        better. Use that instead of the Windows build under Wine.
        """,
        notes: steamNativeEvidence + """
         The executable names bg3.exe and bg3_dx11.exe come from \
        PCGamingWiki's fix box (Steam itself only launches \
        LariLauncher.exe); that part is source-claimed.
        """,
        source: "store.steampowered.com/api/appdetails?appids=1086940 (read 2026-10-29); Steam appinfo via api.steamcmd.net; pcgamingwiki.com/wiki/Baldur%27s_Gate_3 (executable names)"
    )

    static let control = nativeBuildAdvisory(
        id: "control-ultimate-edition", name: "Control Ultimate Edition",
        executables: ["Control.exe"], steamAppID: "870780",
        message: """
        Control Ultimate Edition has a native macOS build on Steam, \
        which Steam lists as requiring an Apple processor. Use that \
        instead of the Windows build under Wine.
        """,
        notes: steamNativeEvidence,
        source: "store.steampowered.com/api/appdetails?appids=870780 (read 2026-10-29); Steam appinfo launch entries 'Control.exe' (windows) and 'Game.app' (macos) via api.steamcmd.net"
    )

    static let liesOfP = nativeBuildAdvisory(
        id: "lies-of-p", name: "Lies of P",
        executables: ["LOP.exe"], steamAppID: "1627720",
        message: """
        Lies of P has a native macOS build on Steam, which Steam lists \
        as requiring Apple silicon and macOS 13 or newer. Use that \
        instead of the Windows build under Wine.
        """,
        notes: steamNativeEvidence,
        source: "store.steampowered.com/api/appdetails?appids=1627720 (read 2026-10-29); Steam appinfo launch entries 'LOP.exe' (windows) and 'LiesofP.app' (macos) via api.steamcmd.net"
    )

    /// Both of Civ VII's Windows executables are listed. The Vulkan one
    /// can never reach D3DMetal whatever the bottle does.
    static let civilizationVII = nativeBuildAdvisory(
        id: "civilization-vii", name: "Sid Meier's Civilization VII",
        executables: ["Civ7_Win64_DX12_FinalRelease.exe", "Civ7_Win64_Vulkan_FinalRelease.exe"],
        steamAppID: "1295660",
        message: """
        Civilization VII has a native macOS build on Steam, which Steam \
        lists as requiring an Apple processor, an M1 or better and \
        macOS Sequoia. Use that instead of the Windows build under Wine.
        """,
        notes: steamNativeEvidence,
        source: "store.steampowered.com/api/appdetails?appids=1295660 (read 2026-10-29); Steam appinfo launch entries via api.steamcmd.net"
    )

    // MARK: Anti-cheat: titles that will not run
    //
    // None of these has a workaround and none will be given one. The only
    // honest answer is the advisory, per the project rule against
    // spoofing or hiding anti-cheat. Every claim here is SOURCE-CLAIMED:
    // nothing was launched, because there is nothing to observe - the
    // anti-cheat either loads or it does not, and the sources below are
    // the publishers' own statements or aggregators of them.
    //
    // "Supported" on areweanticheatyet.com means supported under Proton
    // on Linux, where publishers ship a Linux anti-cheat runtime. No
    // publisher ships one for Wine on macOS, so that status does NOT
    // carry over (the Helldivers 2 entry says the same). That is why
    // Elden Ring, Halo MCC and the other "Supported" titles are absent
    // from this list: this section only records titles whose own
    // publisher or a measured report says no.

    static let fortnite = GameFix(
        id: "fortnite",
        name: "Fortnite",
        executables: [
            "FortniteClient-Win64-Shipping.exe",
            "FortniteClient-Win64-Shipping_EAC.exe",
            "FortniteLauncher.exe",
        ],
        advisory: .init(
            severity: .wontRun,
            message: """
            Fortnite will not run. It is protected by Easy Anti-Cheat in \
            a configuration Epic has not enabled for Wine or Proton, and \
            nothing in a bottle changes that. AreWeAntiCheatYet lists it \
            as Denied; Whisky's compatibility list answers "No." and \
            AppleGamingWiki lists it Unplayable. Xbox Cloud Gaming in a \
            browser is the route that does work.
            """
        ),
        notes: """
        SOURCE-CLAIMED, not launched. areweanticheatyet.com status \
        Denied (Easy Anti-Cheat), citing a February 2022 post by Epic's \
        Tim Sweeney that AreWeAntiCheatYet labels "Not confident in \
        anti-cheat" - the post itself was not read. Whisky's game-support \
        page for Fortnite is the single word "No." with installs=No \
        opens=No. The executable names are Fortnite's long-standing \
        process names and were not re-checked against an install this \
        session.
        """,
        source: "areweanticheatyet.com games.json (fetched 2026-10-29); github.com/Whisky-App/whisky-book src/game-support/fortnite.md; applegamingwiki.com/wiki/Game_Porting_Toolkit"
    )

    static let valorant = GameFix(
        id: "valorant",
        name: "VALORANT",
        executables: ["VALORANT.exe", "VALORANT-Win64-Shipping.exe"],
        advisory: .init(
            severity: .wontRun,
            message: """
            VALORANT will not run. It requires Riot Vanguard, a \
            kernel-mode anti-cheat that exists for Windows only; Riot's \
            own system-requirements page lists nothing else. There is no \
            macOS or Linux build of the game and no bottle setting that \
            substitutes for the driver.
            """
        ),
        notes: """
        SOURCE-CLAIMED, not launched. playvalorant.com/en-gb/specs \
        lists only Windows 10 (build 19041+) or 11 64-bit, fetched \
        2026-10-29. areweanticheatyet.com lists it Denied (Vanguard). \
        win.gg (23 Aug 2024) reports Riot saying a native macOS VALORANT \
        is out of the question. Executable names are the standard ones \
        and were not re-checked against an install.
        """,
        source: "playvalorant.com/en-gb/specs (fetched 2026-10-29); areweanticheatyet.com games.json; win.gg/news/vanguard-2-arrives-on-mac-without-extra-installations"
    )

    static let destiny2 = GameFix(
        id: "destiny-2",
        name: "Destiny 2",
        executables: ["destiny2launcher.exe", "destiny2.exe"],
        steamAppIDs: ["1085660"],
        advisory: .init(
            severity: .wontRun,
            message: """
            Destiny 2 will not run. It uses BattlEye, and Bungie states \
            that the game is not supported on Steam Deck or on any \
            system using Proton. Wine on macOS is no different. Nothing \
            in a bottle changes that.
            """
        ),
        notes: """
        SOURCE-CLAIMED, not launched. Bungie's own help article \
        (help.bungie.net, Destiny 2 Steam Guide) is the primary source; \
        areweanticheatyet.com lists it Denied (BattlEye) and quotes the \
        March 2022 wording. destiny2launcher.exe is Steam's launch \
        entry (read via api.steamcmd.net 2026-10-29, first-hand); \
        destiny2.exe is the standard game binary and was not re-checked.
        """,
        source: "help.bungie.net/hc/en-us/articles/360049024592-Destiny-2-Steam-Guide; gamingonlinux.com/2022/03/bungie-say-a-big-fat-no-to-proton-and-steam-deck-for-destiny-2; areweanticheatyet.com games.json"
    )

    static let rainbowSixSiege = GameFix(
        id: "rainbow-six-siege",
        name: "Tom Clancy's Rainbow Six Siege",
        executables: ["RainbowSix.exe", "RainbowSix_BE.exe", "RainbowSix_Vulkan.exe"],
        steamAppIDs: ["359550"],
        advisory: .init(
            severity: .wontRun,
            message: """
            Rainbow Six Siege will not run. Its anti-cheat stack \
            (BattlEye and Ubisoft's ShieldGuard) is listed as Denied by \
            AreWeAntiCheatYet, Whisky's compatibility list rates it \
            unplayable and AppleGamingWiki lists it Unplayable. It also \
            needs Ubisoft Connect, which does not run here either.
            """
        ),
        notes: """
        SOURCE-CLAIMED, not launched. RainbowSix.exe is Steam's launch \
        entry (read via api.steamcmd.net 2026-10-29, first-hand). \
        RainbowSix_BE.exe and RainbowSix_Vulkan.exe are the standard \
        BattlEye and Vulkan variants and were not re-checked. The \
        Ubisoft Connect clause rests on this catalog's own \
        ubisoft-connect entry.
        """,
        source: "areweanticheatyet.com games.json (Siege X: Denied); github.com/Whisky-App/whisky-book src/game-support/tom-clancys-rainbow-six-siege.md; applegamingwiki.com/wiki/Game_Porting_Toolkit"
    )

    /// One entry for two games on purpose: Apex Legends and Battlefield 6
    /// both launch through `EAAntiCheat.GameServiceLauncher.exe` (verified
    /// in Steam's appinfo for both app ids today), so matching on that
    /// executable cannot tell them apart and a per-game message would be
    /// wrong half the time. The message is therefore about the shared
    /// anti-cheat. `r5apex.exe` / `bf6.exe` / `BF2042.exe` are listed so
    /// a direct launch of the game binary is covered too.
    static let eaJavelinGames = GameFix(
        id: "ea-javelin-anticheat",
        name: "Apex Legends / Battlefield (EA anti-cheat)",
        executables: [
            "EAAntiCheat.GameServiceLauncher.exe",
            "r5apex.exe", "r5apex_dx12.exe",
            "bf6.exe", "BF2042.exe",
        ],
        steamAppIDs: ["1172470", "2807960", "1517290"],
        advisory: .init(
            severity: .wontRun,
            message: """
            This game uses EA's Javelin anti-cheat, which does not run \
            under Wine or Proton. Respawn switched off Apex Legends' \
            Linux and Steam Deck support on 31 October 2024; Battlefield \
            6's Javelin runs at kernel level and relies on Secure Boot, \
            and players on Proton report a launch refusal saying Wine, \
            Proton and Steam Deck are not supported. AppleGamingWiki already \
            lists Apex as stuck at the anti-cheat under GPTK. A job \
            listing suggests EA is working on Linux and ARM support, but \
            nothing has been announced.
            """
        ),
        notes: """
        SOURCE-CLAIMED, not launched. areweanticheatyet.com lists Apex \
        Legends (update 'Linux support disabled', 31 Oct 2024, citing \
        Respawn's post), Battlefield 2042 and Battlefield 6 as Denied \
        (EA anticheat). The Secure Boot and launch-refusal details come \
        from press coverage of Battlefield 6 (TechSpot, GamingOnLinux), \
        and the Linux/ARM hint from a reported EA job listing - none \
        was read at the primary source. FIRST-HAND: Steam's appinfo \
        (api.steamcmd.net, 2026-10-29) lists \
        EAAntiCheat.GameServiceLauncher.exe as the launch executable for \
        both Apex Legends and Battlefield 6, and r5apex.exe is on \
        PCGamingWiki's Apex page. BF2042.exe is the standard binary and \
        was not re-checked (its Steam launch entry is a steam2ea:// \
        URL).
        """,
        source: "areweanticheatyet.com games.json (fetched 2026-10-29); gamingonlinux.com/2025/10/battlefield-6-releases-today-and-it-will-not-be-playable-on-any-linux-steamos-system; techspot.com/news/108925-battlefield-6-anti-cheat-system-requires-secure-boot.html; applegamingwiki.com/wiki/Game_Porting_Toolkit"
    )

    /// `.degraded`, not `.wontRun`: the Whisky page rates it Bronze with
    /// `opens=Yes`, so story mode is reported to run. It is the *online*
    /// half that BattlEye removes.
    static let grandTheftAutoV = GameFix(
        id: "grand-theft-auto-v",
        name: "Grand Theft Auto V",
        executables: ["PlayGTAV.exe", "GTA5.exe", "GTAVLauncher.exe"],
        steamAppIDs: ["271590"],
        advisory: .init(
            severity: .degraded,
            message: """
            Grand Theft Auto V is reported to run offline, but GTA Online \
            will not: Rockstar added BattlEye in 2024 and online servers \
            require it, which Wine on macOS cannot provide. The Rockstar \
            Games Launcher also fails with "failed to initialize" unless \
            DXVK is on (which brings visual glitches) or its Launcher.exe \
            is given Native-then-Builtin overrides for d3d10core, d3d11 \
            and dxgi in winecfg. Overpass cannot apply that per-program \
            override for you yet.
            """
        ),
        notes: """
        SOURCE-CLAIMED, not launched. Whisky's game-support page \
        (rated Bronze, installs=Yes opens=Yes) gives the BattlEye \
        statement and the launcher workaround, including that DXVK-on \
        causes invisible guns and green windows. areweanticheatyet.com \
        lists it Denied (BattlEye) with Rockstar's own BattlEye FAQ as \
        the 17 Sep 2024 reference; that FAQ was not read. PlayGTAV.exe \
        and GTA5.exe are Steam's launch entries (first-hand, \
        api.steamcmd.net 2026-10-29); GTAVLauncher.exe is from \
        PCGamingWiki. The same page also gives a `-nobattleye` launch \
        option; it is deliberately NOT shipped, because switching an \
        anti-cheat off is not something this catalog does.
        """,
        source: "github.com/Whisky-App/whisky-book src/game-support/grand-theft-auto-5.md; areweanticheatyet.com games.json; support.rockstargames.com Grand Theft Auto Online BattlEye FAQ (referenced, not read)"
    )

    /// No `alternative`: the native Roblox app is real, but its bundle id
    /// (`com.roblox.RobloxPlayer`) is known only from third-party
    /// databases and Roblox is not installed on this machine to read it
    /// from an Info.plist, and the project rule is that an alternative
    /// carries only a researched bundle id. The message names the app in
    /// words instead.
    static let roblox = GameFix(
        id: "roblox-player",
        name: "Roblox",
        executables: ["RobloxPlayerBeta.exe", "RobloxPlayerLauncher.exe"],
        advisory: .init(
            severity: .wontRun,
            message: """
            Roblox Player will not run under Wine: Roblox's Hyperion \
            anti-tamper blocks it, and the Vinegar project's FAQ says Wine \
            is blocked for Roblox Player and documents no working bypass. \
            Roblox ships a native macOS app; use that.
            """
        ),
        notes: """
        SOURCE-CLAIMED, not launched. vinegarhq.org/Home/rol_faq.html \
        (fetched 2026-10-29): it says Wine remains blocked for Roblox \
        Player, no Byfron bypass is documented, attempts can lead to \
        bans, and Roblox Studio is unaffected. areweanticheatyet.com lists it \
        Denied (Hyperion). That a native macOS app exists is established \
        by third-party app databases and Homebrew's cask (the player's \
        bundle id appears as com.roblox.RobloxPlayer); not re-checked \
        first-hand. RobloxPlayerBeta.exe and RobloxPlayerLauncher.exe \
        appear in Roblox DevForum threads as the client and bootstrapper.
        """,
        source: "vinegarhq.org/Home/rol_faq.html; areweanticheatyet.com games.json; devforum.roblox.com/t/robloxplayerbetaexe/2314196"
    )

    static let deadByDaylight = GameFix(
        id: "dead-by-daylight",
        name: "Dead by Daylight",
        executables: ["DeadByDaylight.exe", "DeadByDaylight-Win64-Shipping.exe"],
        steamAppIDs: ["381210"],
        advisory: .init(
            severity: .degraded,
            message: """
            Dead by Daylight is effectively unplayable here: Easy \
            Anti-Cheat fails to load under Wine on macOS, and online \
            matchmaking, which is the game, does not work. Its Linux \
            "Supported" status on AreWeAntiCheatYet rests on a Linux \
            anti-cheat runtime that has no macOS equivalent.
            """
        ),
        notes: """
        SOURCE-CLAIMED, not launched. Whisky's game-support page rates \
        it Bronze: "Fails to launch due to an error when loading Easy \
        Anti Cheat" and "Online matchmaking is non-functional". That page \
        also describes a workaround that depends on disconnecting from \
        the network at launch; it is not reproduced here because it \
        exists only to get past the anti-cheat's load error. \
        areweanticheatyet.com lists the game as Supported (Easy \
        Anti-Cheat) for Proton on Linux only. DeadByDaylight.exe is \
        Steam's launch entry (first-hand, api.steamcmd.net 2026-10-29).
        """,
        source: "github.com/Whisky-App/whisky-book src/game-support/dead-by-daylight.md; areweanticheatyet.com games.json"
    )

    // MARK: Rosetta AVX: a macOS-only switch with no Proton analogue

    /// Rosetta on macOS 15 and later can run AVX/AVX2 code, but it does
    /// not *advertise* it unless the process asks.
    ///
    /// Apple's Rosetta documentation says Rosetta translates AVX and AVX2
    /// (not AVX-512). It does not mention that the CPU feature bits stay
    /// off by default. A program that tests for AVX before using it - and
    /// many games refuse to start at all if the test fails - therefore
    /// sees a CPU without it, even though the instructions would work.
    /// `ROSETTA_ADVERTISE_AVX=1` flips the feature bits on.
    ///
    /// VERIFIED FIRST-HAND, 2026-10-29, macOS 27.0.1 (26A434): a small
    /// C program compiled for x86_64 and run under Rosetta reads CPUID
    /// itself:
    ///
    ///     variable unset:            AVX=0 OSXSAVE=0 F16C=0 FMA=0
    ///                                AVX2=0 BMI1=0 BMI2=0 AVX512F=0
    ///     ROSETTA_ADVERTISE_AVX=1:   AVX=1 OSXSAVE=1 F16C=1 FMA=1
    ///                                AVX2=1 BMI1=1 BMI2=1 AVX512F=0
    ///
    /// `sysctl hw.optional.avx2_0` reads 0 either way (Rosetta intercepts
    /// CPUID, not sysctl), so that is not a usable probe. This also
    /// corrects the common reading of AppleGamingWiki's note that
    /// Sequoia "supports AVX": it supports translating it, opt-in.
    ///
    /// Corroboration, source-claimed: a third-party GPTK launcher's pull
    /// request (EndofLineTech/gamekit #22) measures the same switch with
    /// native x86_64 and Windows x64 probes, and says Apple's GPTK 4 beta
    /// 2 documents `ROSETTA_ADVERTISE_AVX=1` as default-off. CodeWeavers
    /// exposes it as "Advertise AVX capabilities" in CrossOver. The
    /// Apple Developer Forums thread 769486 is where the variable name
    /// surfaced.
    ///
    /// NOT verified: that the variable survives through Wine to the
    /// game's own feature test. It is an environment variable on an
    /// x86_64 process tree, so it should, and gamekit's report says it
    /// does, but no Windows binary was run here.
    ///
    /// LIMIT: this is a launch environment, so it only reaches a game
    /// that Overpass itself launches. A game started from inside Steam
    /// inherits Steam's environment, which does not have it. A bottle-
    /// level switch would cover that case; this catalog cannot express
    /// one.
    private static func rosettaAVXFix(
        id: String, name: String, executables: [String], steamAppIDs: [String],
        claim: String, source: String
    ) -> GameFix {
        GameFix(
            id: id,
            name: name,
            executables: executables,
            steamAppIDs: steamAppIDs,
            env: ["ROSETTA_ADVERTISE_AVX": "1"],
            notes: """
            Sets ROSETTA_ADVERTISE_AVX=1 for this program. FIRST-HAND \
            VERIFIED 2026-10-29 on macOS 27.0.1: under Rosetta an x86_64 \
            test binary sees AVX, AVX2, F16C, FMA and BMI1/2 as absent by \
            default and present with the variable (AVX-512 stays absent). \
            SOURCE-CLAIMED for this title: \(claim) NOT verified: that \
            this game launches or runs better, and that the variable \
            survives through Wine to the game's own check. Launch-only \
            (no bottle change), applies only when Overpass launches this \
            executable itself, not when it is started from inside Steam. \
            See this file's doc comment on rosettaAVXFix for the full \
            measurement.
            """,
            source: source
        )
    }

    static let starfield = rosettaAVXFix(
        id: "starfield", name: "Starfield",
        executables: ["Starfield.exe"], steamAppIDs: ["1716740"],
        claim: "AppleGamingWiki's Game Porting Toolkit page lists Starfield among titles that fail on Rosetta without AVX/AVX2.",
        source: "applegamingwiki.com/wiki/Game_Porting_Toolkit (AVX section); developer.apple.com/documentation/apple-silicon/about-the-rosetta-translation-environment; developer.apple.com/forums/thread/769486; first-hand CPUID test 2026-10-29"
    )

    /// Both Steam editions use `ds.exe` (verified in appinfo for app ids
    /// 1190460 and 1850570).
    static let deathStranding = rosettaAVXFix(
        id: "death-stranding", name: "Death Stranding",
        executables: ["ds.exe"], steamAppIDs: ["1190460", "1850570"],
        claim: "AppleGamingWiki lists Death Stranding among the AVX-affected titles and as not working under GPTK.",
        source: "applegamingwiki.com/wiki/Game_Porting_Toolkit (AVX section); Steam appinfo via api.steamcmd.net (ds.exe, 2026-10-29); first-hand CPUID test 2026-10-29"
    )

    static let dyingLight2 = rosettaAVXFix(
        id: "dying-light-2", name: "Dying Light 2 Stay Human",
        executables: ["DyingLightGame_x64_rwdi.exe"], steamAppIDs: ["534380"],
        claim: "AppleGamingWiki lists Dying Light 2 among the AVX-affected titles and gives a file-rename workaround that avoids AVX instead (renaming runtime_dx11.dll under ph/work/bin/x64), which this fix makes unnecessary if the variable takes effect.",
        source: "applegamingwiki.com/wiki/Game_Porting_Toolkit; Steam appinfo via api.steamcmd.net (2026-10-29); first-hand CPUID test 2026-10-29"
    )

    static let sonicFrontiers = rosettaAVXFix(
        id: "sonic-frontiers", name: "Sonic Frontiers",
        executables: ["SonicFrontiers.exe"], steamAppIDs: ["1237320"],
        claim: "AppleGamingWiki lists Sonic Frontiers among the AVX-affected titles.",
        source: "applegamingwiki.com/wiki/Game_Porting_Toolkit (AVX section); Steam appinfo via api.steamcmd.net (2026-10-29); first-hand CPUID test 2026-10-29"
    )

    static let ratchetAndClankRiftApart = rosettaAVXFix(
        id: "ratchet-and-clank-rift-apart", name: "Ratchet & Clank: Rift Apart",
        executables: ["RiftApart.exe"], steamAppIDs: ["1895880"],
        claim: "AppleGamingWiki lists Ratchet & Clank: Rift Apart among the AVX-affected titles.",
        source: "applegamingwiki.com/wiki/Game_Porting_Toolkit (AVX section); Steam appinfo via api.steamcmd.net (2026-10-29); first-hand CPUID test 2026-10-29"
    )

    static let horizonForbiddenWest = rosettaAVXFix(
        id: "horizon-forbidden-west", name: "Horizon Forbidden West",
        executables: ["HorizonForbiddenWest.exe"], steamAppIDs: ["2420110"],
        claim: "AppleGamingWiki says Horizon Forbidden West requires F16C, one of the feature bits the variable turns on.",
        source: "applegamingwiki.com/wiki/Game_Porting_Toolkit (AVX section); Steam appinfo via api.steamcmd.net (2026-10-29); first-hand CPUID test 2026-10-29"
    )

    /// The only AVX entry whose evidence is a macOS user's working
    /// recipe rather than a list of affected titles.
    static let yakuza6 = rosettaAVXFix(
        id: "yakuza-6", name: "Yakuza 6: The Song of Life",
        executables: ["Yakuza6.exe"], steamAppIDs: ["1388590"],
        claim: "Whisky's game-support page (rated Silver) lists ROSETTA_ADVERTISE_AVX=1 as part of its setup, alongside setting Enhanced Sync to MSync - which is a bottle setting, not something this fix can apply, so turn MSync on in the bottle yourself.",
        source: "github.com/Whisky-App/whisky-book src/game-support/yakuza-6-song-of-life.md; first-hand CPUID test 2026-10-29"
    )

    // MARK: Other fixes

    /// Titles that ship AMD's AGS (`amd_ags_x64.dll`), which calls into
    /// `atiadlxx.dll`, which on a GPTK engine is a stub whose entry points
    /// abort the process - the same failure class as `unigineBenchmarks`,
    /// reached through a game instead of a benchmark's telemetry plugin.
    ///
    /// ## Why it happens
    ///
    /// GPTK presents the GPU to games as an AMD adapter (Whisky's
    /// maintainer said so in Whisky issue 234: "game-porting-toolkit
    /// presents as an AMD graphics card"). A game that sees AMD loads AGS
    /// and calls ADL entry points to ask about CrossFire and the like.
    /// GPTK's Wine carries an `atiadlxx.dll` that declares 1138 ADL
    /// exports (counted from its export table) of which only a subset are
    /// implemented; calling one of the rest aborts the process. Called
    /// bare through `rundll32` on `gptk-3.0-3`, `ADL2_Adapter_Active_Get`
    /// and `ADL2_Adapter_Crossfire_Caps` abort verbatim, while
    /// `ADL_Main_Control_Create`, `ADL2_Main_Control_Create`,
    /// `ADL2_Adapter_NumberOfAdapters_Get` and
    /// `ADL2_Graphics_VersionsX2_Get` do not - which shows they are not
    /// unimplemented stubs, not that they return anything sensible.
    /// Three Whisky reports show the abort, with identical stub
    /// backtraces:
    ///
    ///     Far Cry 5        ADL2_Adapter_Active_Get       (issue 1057)
    ///     Watch Dogs 2     ADL2_Adapter_Crossfire_Caps   (issue 234)
    ///     Crash Bandicoot  ADL2_Adapter_Active_Get       (issue 762)
    ///
    /// ## What was verified first-hand, 2026-10-29, on `gptk-3.0-3`
    ///
    /// In a throwaway prefix (not an Overpass bottle), `rundll32.exe
    /// atiadlxx.dll,ADL2_Adapter_Active_Get` with the module loaded
    /// builtin reproduces the abort verbatim (`Call from ... to
    /// unimplemented function atiadlxx.dll.ADL2_Adapter_Active_Get,
    /// aborting`). Then, loading the module with `WINEDEBUG=+loaddll`:
    ///
    ///     no override                          loaded builtin; aborts
    ///     AppDefaults\rundll32.exe\DllOverrides
    ///       atiadlxx = ""                      not loaded; clean error
    ///     AppDefaults\other.exe\DllOverrides
    ///       atiadlxx = ""   (control)          loaded builtin; aborts
    ///     global DllOverrides atiadlxx = ""    not loaded; clean error
    ///
    /// So the per-executable `AppDefaults` form is honoured and scoped
    /// exactly to the named program. It is used here instead of the
    /// bottle-wide key `unigineBenchmarks` uses, so the override does not
    /// reach other programs in the same bottle.
    ///
    /// The `wine-staging` engines do not contain `atiadlxx.dll` at all
    /// (checked in 11.16 and 11.20), so on those the entry is inert and
    /// harmless: Windows then reports the module missing, which is the
    /// behaviour this fix creates on GPTK.
    ///
    /// ## What was NOT verified
    ///
    /// None of the three games was launched, so "the game then runs" is
    /// not claimed. What is established is that the abort is real, that
    /// the override prevents it, and - from frankea/Whisky issue 276 on
    /// Red Dead Redemption 2, on a runtime with no `atiadlxx.dll` - that
    /// AGS copes with a missing library: `agsInit` returns an error
    /// code, the game shows a driver-version nag, and "OK continues".
    /// Far Cry 5 and Watch Dogs 2 also need Ubisoft Connect, which this
    /// catalog records as not running (`ubisoftConnect`); they got as far
    /// as the ADL call in those logs, which is why they are listed, but a
    /// working launch is not implied.
    ///
    /// Red Dead Redemption 2 is deliberately not in `executables`: its
    /// report ran on a runtime without the stub, so nobody has observed
    /// the abort for it on a GPTK engine, only inferred it.
    static let amdADLStubGames = GameFix(
        id: "amd-adl-stub-abort",
        name: "AMD ADL stub abort (Far Cry 5, Watch Dogs 2, Crash Bandicoot N. Sane Trilogy)",
        executables: ["FarCry5.exe", "WatchDogs2.exe", "CrashBandicootNSaneTrilogy.exe"],
        steamAppIDs: ["552520", "447040", "731490"],
        registry: [
            .init(key: "HKCU\\Software\\Wine\\AppDefaults\\FarCry5.exe\\DllOverrides", name: "atiadlxx", type: "REG_SZ", data: ""),
            .init(key: "HKCU\\Software\\Wine\\AppDefaults\\WatchDogs2.exe\\DllOverrides", name: "atiadlxx", type: "REG_SZ", data: ""),
            .init(key: "HKCU\\Software\\Wine\\AppDefaults\\CrashBandicootNSaneTrilogy.exe\\DllOverrides", name: "atiadlxx", type: "REG_SZ", data: ""),
        ],
        notes: """
        Disables the GPTK `atiadlxx.dll` stub for these three \
        executables only, because the AMD AGS library the games ship \
        calls into it and an unimplemented ADL entry point aborts the \
        process. FIRST-HAND VERIFIED 2026-10-29 on gptk-3.0-3: the abort \
        reproduces verbatim with rundll32, and a per-executable \
        AppDefaults override prevents the load while an override for a \
        different executable does not. SOURCE-CLAIMED: the three games \
        hit this on GPTK (Whisky issues 1057, 234, 762, each with the \
        stub backtrace). NOT verified: that any of the games then runs - \
        none was launched, and Far Cry 5 and Watch Dogs 2 also need \
        Ubisoft Connect. All three are 64-bit; Far Cry 5 and Watch Dogs \
        2 are D3D11 and could use D3DMetal, but this fix only removes a \
        crash and has no effect on performance. wine-staging engines \
        have no atiadlxx.dll, so there the entry does nothing.
        """,
        source: "First-hand reproduction on this machine, 29 October 2026; github.com/Whisky-App/Whisky issues 1057, 234, 762; github.com/frankea/Whisky issue 276 (AGS behaviour without the dll)"
    )

    /// Borderlands 3. Translated from the umu-protonfixes recipe for the
    /// Steam and Epic ids (it is the same two lines for both); the fix
    /// data below is written from the facts, not pasted.
    static let borderlands3 = GameFix(
        id: "borderlands-3",
        name: "Borderlands 3",
        executables: ["Borderlands3.exe"],
        steamAppIDs: ["397540"],
        winetricks: ["d3dcompiler_47", "vcrun2022"],
        notes: """
        SOURCE-CLAIMED, Linux-sourced, not verified on macOS. \
        umu-protonfixes applies d3dcompiler_47 with the comment "Fixes \
        the startup process" and vcrun2022 with "Fixes crash with BL \
        SDK" - the second is for the community modding SDK, not vanilla \
        play, so it is the optional half; it is kept because the recipe \
        ships both and each is cheap. The Linux-only parts of that \
        project's handling (esync/fsync tuning) were not copied. \
        PCGamingWiki lists Borderlands 3 as a 64-bit executable with \
        Direct3D 11 and 12, so unlike most entries in this section it \
        can use D3DMetal; this fix is about starting the game, not \
        speed. Steam's launch entry is \
        OakGame/Binaries/Win64/Borderlands3.exe (first-hand via \
        api.steamcmd.net 2026-10-29); PCGamingWiki agrees.
        """,
        source: "umu-protonfixes gamefixes-steam/397540.py and gamefixes-egs/umu-397540.py (read 2026-10-29); Steam appinfo via api.steamcmd.net; pcgamingwiki.com/wiki/Borderlands_3"
    )

    /// Palworld. Steam itself ships a "Palworld (DirectX 12)" launch
    /// entry that runs `Palworld.exe -dx12`, so the argument is not a
    /// community guess: the developer provides it.
    static let palworld = GameFix(
        id: "palworld",
        name: "Palworld",
        executables: ["Palworld.exe"],
        steamAppIDs: ["1623730"],
        launchArgs: "-dx12",
        notes: """
        FIRST-HAND VERIFIED (data, not behaviour) 2026-10-29: Steam's \
        appinfo for app 1623730 (via api.steamcmd.net) contains a launch \
        entry described as "Palworld (DirectX 12)" whose command is \
        Palworld.exe -dx12, next to the default "Play Palworld" entry. \
        SOURCE-CLAIMED: Whisky's game-support page (rated Silver) says \
        to add -dx12 as a launch option, to answer "No" if prompted \
        about incompatible drivers, and that some small graphical \
        issues remain (black eye shaders). NOT verified: that the game \
        runs on this machine. Palworld is 64-bit Unreal, so DX12 is the \
        D3DMetal path; the argument selects the D3D12 renderer.
        """,
        source: "Steam appinfo via api.steamcmd.net (app 1623730, read 2026-10-29); github.com/Whisky-App/whisky-book src/game-support/palworld.md"
    )

    /// Fixes compiled into the app: the curated, source-cited set that
    /// ships with Overpass. `Paths.fixes` extends and overrides this
    /// rather than replacing it, so a user fix and a shipped one live
    /// side by side.
    ///
    /// ## Deliberately not shipped (researched 2026-10-29, rejected)
    ///
    /// Kept here rather than discarded so nobody re-derives them, in the
    /// same spirit as `PerformanceSettings`' "Dropped knobs" section.
    ///
    /// (**EA app** and **Ubisoft Connect** were in this list until
    /// advisories existed. Both now ship as `.wontRun` entries: the
    /// finding was never that there is nothing to say, only that there
    /// was no mechanism to express it as.)
    ///
    /// - **Star Trek Online** — `--disable-gpu` fixes the black Cryptic
    ///   launcher on Linux (two Steam threads, 2023), but MacGamingDB has
    ///   a CrossOver 25.0 D3DMetal report at ~55fps needing no fixes at
    ///   all, so shipping it would add an argument nobody on macOS has
    ///   shown a need for.
    /// - **PEAK** — Whisky's docs say Vulkan-only, while 23 MacGamingDB
    ///   CrossOver reports run it on D3DMetal at ~60fps with defaults.
    ///   Different engines disagree, so neither `-force-vulkan` nor
    ///   `-force-d3d12` ships.
    /// - **Rise of the Tomb Raider, Moonlighter** — no documented Wine
    ///   requirement found at all.
    ///
    /// ## Deliberately not shipped (second pass, 2026-10-29, rejected)
    ///
    /// Sources were umu-protonfixes (all 314 Steam recipes, plus the
    /// Battle.net, EGS, Ubisoft and umu directories), Whisky's game-support
    /// docs (254 pages), AppleGamingWiki's GPTK page, PCGamingWiki and
    /// areweanticheatyet.com. Most of protonfixes is Linux-only and was
    /// dropped by rule, not by judgement:
    ///
    /// - **Linux-only mechanisms, not copied anywhere**: esync/fsync
    ///   disables (about fifteen recipes), `set_cpu_topology_limit` core
    ///   caps, the `PROTON_*` variables (`PROTON_OLD_GL_STRING`,
    ///   `PROTON_USE_D7VK`, `PROTON_NO_D3D10`, `PROTON_DLL_COPY`),
    ///   `PULSE_LATENCY_MSEC`, the radeonsi/`AMD_DEBUG`/`__GL_*` driver
    ///   variables, `taskset` pinning, `SteamDeck=0/1` (only meaningful when
    ///   Steam on a Deck sets it) and every `-vulkan` argument. The last
    ///   deserves a flag: Red Dead Redemption 2's recipe is `-fullscreen
    ///   -vulkan`, and there is no Vulkan driver on macOS, so shipping it
    ///   would send a D3DMetal title down a path that cannot exist.
    /// - **Launcher bypasses** (`replace_command`: Borderlands 2, The
    ///   Pre-Sequel and GOTY, Darktide, Strange Brigade, Necromunda and
    ///   some thirty more) — Overpass runs the executable the user
    ///   picks, so the user picks the real one; nothing to fix.
    /// - **Save/config file edits** (Trails in the Sky, Gothic, Sifu,
    ///   Ghostbusters, the Fallout/Elder Scrolls script-extender
    ///   redirects) — file operations, which a `GameFix` cannot express.
    /// - **Witcher 3 and Warframe `hidewineexports`** — not an upstream
    ///   winetricks verb; it is a custom verb in umu-protonfixes'
    ///   `verbs/`, and what it solves (DLSS/Streamline detection of Wine)
    ///   has no meaning under D3DMetal.
    /// - **Warframe `dwrite` disabled** (AppleGamingWiki's GPTK page,
    ///   "to get the installer working") — Warframe's Steam launch entry
    ///   is `Tools/Launcher.exe`, far too generic a name to match, and a
    ///   bottle-wide dwrite disable would break other programs.
    ///   AppleGamingWiki's Warframe page rates CrossOver "Perfect" with
    ///   no fixes and recommends the in-game DX12 option for shader
    ///   caching, which is a setting, not a fix.
    /// - **`libglesv2` disabled** (LOTRO, DDO, protonfixes 311240;
    ///   Whisky's Fear & Hunger and r2modman pages) — it turns off
    ///   Chromium's ANGLE backend. The Whisky pages set it through
    ///   `WINEDLLOVERRIDES`, which a fix's `env` would clobber (see
    ///   `unigineBenchmarks`), and the Epic entry above already records
    ///   it as inconsistent. No 64-bit D3D11 macOS title was found that
    ///   needs it.
    /// - **`dcomp` disabled** (protonfixes 506510, 3950020) — the one
    ///   other "stub dll" recipe found. 3950020 (Duet Night Abyss) is
    ///   Windows-only with Linux evidence only; 506510 (Shadows of Adam)
    ///   has a native macOS build. Whether this Wine's `dcomp.dll` stubs
    ///   abort or merely return an error was not tested.
    /// - **`nvcuda` disabled for Just Cause 2** (WineHQ bug 43440, the
    ///   same abort class as `atiadlxx`) — no installed engine contains
    ///   `nvcuda.dll` (checked in gptk-3.0-3 and both wine-staging
    ///   builds), so the abort cannot occur here. Whisky's own Just
    ///   Cause 2 page (Bronze) only asks for `d3dcompiler_47`, on a
    ///   32-bit DX10 title that cannot reach D3DMetal and reports poor
    ///   performance.
    /// - **`dotnet48` recipes** (Whisky's Cities: Skylines II and Skyrim
    ///   SE pages) — Whisky says they "require user interaction" and take
    ///   a very long time, on Wine 7-era engines; the Epic entry already
    ///   records `dotnet48` as reported to break other games. Not
    ///   applied silently to a bottle.
    /// - **`faudio` for Fallout 4** (Whisky) — the winetricks verb installs
    ///   a native FAudio 19.07 over the engine's builtin, which on a
    ///   current wine-staging is newer. Evidence is Wine-7-era; the risk
    ///   is a regression. The same page's `bBackgroundMouse` edit is a
    ///   file operation.
    /// - **Diablo IV** — AppleGamingWiki's GPTK page lists a Windows
    ///   build-number spoof (`CurrentBuild` 19042) for it; Whisky's two
    ///   pages rate it Garbage ("unplayable") with the same 19042 step in
    ///   a commented-out recipe. The sources contradict each other, so
    ///   nothing ships.
    /// - **Homeworld 3 `-nojoy`** — Whisky measures 5-10 fps from it, but
    ///   it disables controller input, a trade-off rather than a fix. The
    ///   page's "crashes on start if DXVK enabled" is a bottle setting.
    /// - **Elden Ring and other EAC titles rated "Supported" on Linux**
    ///   — that status needs a Linux anti-cheat runtime with no macOS
    ///   equivalent. Launching `eldenring.exe` directly gets past EAC by
    ///   not running it (offline only); it is not recorded as a fix
    ///   because it works by switching the anti-cheat off, and likewise
    ///   GTA V's `-nobattleye`.
    /// - **Genshin Impact** — believed during research to have a native
    ///   Mac client; a web search found no evidence of one, so no
    ///   native-build advisory. Whisky's page (Silver) needs
    ///   `--in-process-gpu` on `launcher.exe`, too generic a name to match,
    ///   and reports account bans after playing through Whisky.
    /// - **Red Dead Redemption 2** — frankea/Whisky issue 276 (September
    ///   2026) runs it end to end on GPTK 3.0, but only with DXVK-macOS
    ///   scoped per executable to Steam's and Rockstar's CEF processes,
    ///   `d3d12` blanked for the launcher and a hand-written
    ///   `atiadlxx.dll`. That is a custom DXVK layout, not a bottle fix.
    ///   AppleGamingWiki also lists it as AVX-affected, but the working
    ///   report does not mention `ROSETTA_ADVERTISE_AVX`, so it is not
    ///   in the AVX group.
    /// - **Counter-Strike 2** — the existing advisory says it launches
    ///   and plays; Whisky's page (a Nov 2025 snapshot) says it opens and
    ///   closes at once. They disagree and neither was reproduced here.
    ///
    /// ## Games where the right answer is not to use Wine
    ///
    /// Not fixes, but the most useful thing known about them: **No Man's
    /// Sky**, **Mechabellum**, **Dead Cells** and **Rise of the Tomb
    /// Raider** all ship native macOS builds. No Man's Sky is the sharpest
    /// case — its Windows build is Vulkan, so D3DMetal cannot help it, and
    /// AppleGamingWiki rates CrossOver "Unplayable" against a native
    /// rating of "Perfect".
    static let builtIn: [GameFix] = [
        // Fixes: they change the bottle or the launch.
        amdADLStubGames,
        battleNet,
        borderlands3,
        dcsWorld,
        deathStranding,
        dyingLight2,
        epicGamesLauncher,
        gogGalaxy,
        horizonForbiddenWest,
        palworld,
        ratchetAndClankRiftApart,
        sonicFrontiers,
        starfield,
        steam,
        unigineBenchmarks,
        yakuza6,
        // Advisories: they change what the user knows.
        baldursGate3,
        civilizationVII,
        control,
        counterStrike2,
        cyberpunk2077,
        deadByDaylight,
        deadCells,
        destiny2,
        eaApp,
        eaJavelinGames,
        fortnite,
        grandTheftAutoV,
        helldivers2,
        liesOfP,
        mechabellum,
        noMansSky,
        rainbowSixSiege,
        riseOfTheTombRaider,
        roblox,
        ubisoftConnect,
        valorant,
    ]

    // MARK: - User fixes

    /// Every `.json` file in `Paths.fixes`, each holding one `GameFix` or
    /// an array of them. Returns the fixes plus the names of any files
    /// that failed to parse, so a caller can surface them.
    static func loadUserFixes() -> (fixes: [GameFix], failed: [String]) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: Paths.fixes,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return ([], []) }

        var fixes: [GameFix] = []
        var failed: [String] = []
        let decoder = JSONDecoder()

        for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard url.pathExtension.lowercased() == "json" else { continue }
            guard let data = try? Data(contentsOf: url) else {
                failed.append(url.lastPathComponent)
                continue
            }
            if let batch = try? decoder.decode([GameFix].self, from: data) {
                fixes.append(contentsOf: batch)
            } else if let single = try? decoder.decode(GameFix.self, from: data) {
                fixes.append(single)
            } else {
                failed.append(url.lastPathComponent)
            }
        }
        return (fixes, failed)
    }

    // MARK: - Merged catalog

    /// `builtIn` unioned with `fixes`, deduped by `id`, user entries
    /// winning — see this type's doc comment for why that is the opposite
    /// of `EngineCatalog`.
    static func merged(with fixes: [GameFix]) -> [GameFix] {
        var byID: [String: GameFix] = [:]
        for fix in builtIn { byID[fix.id] = fix }
        for fix in fixes { byID[fix.id] = fix }
        return byID.values.sorted { $0.id < $1.id }
    }

    /// The full catalog: built-ins merged with whatever is in
    /// `Paths.fixes` right now.
    ///
    /// Live reload is deliberate and kept: a fix file dropped into the
    /// folder is picked up on the very next call, with no relaunch. What
    /// changed is how that is achieved. This used to re-read and re-parse
    /// every JSON file in the folder on every call, and `matching(exe:)`
    /// calls it, so every program launch paid for it. It now compares a
    /// cheap fingerprint of the folder (file names, modification times,
    /// sizes - see `UserFixCache`) against the one the last load saw and
    /// only reads the files when they differ.
    ///
    /// MEASURED (debug build, this machine, median of 10-50 runs; the
    /// release build runs about 10-15 % faster in both columns because the
    /// cost is file reads and JSON decoding, not Swift code).
    /// `matching(exe:)` per launch, files older than the racy window so
    /// they are cacheable:
    ///
    ///     user fix files                    before     after    speed-up
    ///       0  (the normal case)            0.07 ms    0.06 ms    -
    ///       10 files                        0.46 ms    0.18 ms    2.6x
    ///       20 files x 20 fixes each        3.7 ms     0.32 ms   12x
    ///       100 files                       3.9 ms     1.2 ms     3.3x
    ///       400 files                      15.7 ms     4.5 ms     3.5x
    ///       1 file holding 1,000 fixes      9.5 ms     0.49 ms   19x
    ///       1 file holding 3,000 fixes     24.6 ms     1.3 ms    19x
    ///
    /// What remains in the "after" column is the folder fingerprint (a
    /// directory listing plus one stat per file: 0.23 ms per 100 files)
    /// and the per-fix filter in `matching(exe:)`.
    ///
    /// Honest framing: with the usual empty or near-empty folder this is a
    /// rounding error next to starting a Wine process, and it was never
    /// going to be the bottleneck for one launch. It is worth having
    /// because the cost was linear in the size of the user's imported fix
    /// collection and paid on every launch, and a user who imports a
    /// community batch is exactly who would notice. Cached data is
    /// guarded as described on `UserFixCache`; `DebugSelfTest` exercises
    /// every way it could go stale.
    ///
    /// Unreadable user files don't stop the rest loading, but they are no
    /// longer silently dropped either: their names are noted for
    /// `takeUserFixFailureNotice()`. That bookkeeping runs on every call,
    /// cache hit or not, exactly as before.
    static var all: [GameFix] {
        let snapshot = userFixCache.current()
        userFixFailures.note(snapshot.failed)
        return snapshot.merged
    }

    /// How many times the user-fix folder has actually been read and
    /// parsed (cache misses). Exists so `DebugSelfTest` can assert that a
    /// second call is served from the cache and that an edit is not.
    static var userFixDiskLoadCount: Int { userFixCache.loadCount }

    /// The cache behind `all`. Shared, because `all` is a static property
    /// reached from `GameFixService.prepare`, which runs off the main
    /// actor and can overlap with a self-test or a second launch.
    private static let userFixCache = UserFixCache()

    /// Text for a one-time alert naming user fix files that couldn't be
    /// read (bad JSON, wrong shape, unreadable), or `nil` when there is
    /// nothing new to say. Each file is named at most once per session:
    /// `all` re-reads the directory on every launch, so without this the
    /// same broken file would raise the same alert every time the user
    /// starts a program. A file that is fixed and later breaks again, or
    /// a different broken file, is new and does get reported. Calling it
    /// returns each pending name once, then forgets it.
    static func takeUserFixFailureNotice() -> String? {
        let names = userFixFailures.takeUnreported()
        guard !names.isEmpty else { return nil }
        let list = names.joined(separator: ", ")
        return "Overpass couldn't read \(names.count == 1 ? "this game-fix file" : "these game-fix files") and skipped \(names.count == 1 ? "it" : "them"): \(list). Open the Fixes folder (\(Paths.fixes.path)) and make sure each file is valid JSON in the documented format, or delete the ones you don't need."
    }

    /// Fingerprint-validated cache of the merged catalog.
    ///
    /// ## What is cached and how it is validated
    ///
    /// The cached value is the output of `loadUserFixes()` run through
    /// `merged(with:)`, plus the list of files that failed to parse. It is
    /// reused only while the folder's *fingerprint* is unchanged: for
    /// every `.json` file (the loader's own filter), its name, content
    /// modification time (nanosecond resolution on APFS) and byte size.
    /// Adding, removing, renaming or editing a file changes the
    /// fingerprint, so the next call reloads. Validating costs one
    /// directory listing plus one stat per file: 0.23 ms for 100 files
    /// (measured), against 3.9 ms to read and decode them.
    ///
    /// ## Never serving stale data after a write
    ///
    /// A fingerprint can miss an edit that lands inside one timestamp
    /// tick and leaves the size unchanged (flipping a `1` to a `0`, say).
    /// APFS ticks in nanoseconds, so that is already remote, but the
    /// failure would be silent and wrong, so it is closed off the way git
    /// closes its "racily clean" index entries: a snapshot taken while
    /// any file's modification time is within `racyWindow` of the moment
    /// the load began is marked untrusted and is never reused. The next
    /// call reloads, and keeps reloading until the files are older than
    /// the window. A just-written file therefore costs the old behaviour
    /// (a reload per call) for two seconds and then settles into the
    /// cache. A modification time in the future (clock skew) is treated
    /// the same way. The fingerprint is taken *before* the files are read,
    /// so a write that lands mid-load can only make the stored
    /// fingerprint older than the stored data, which causes an extra
    /// reload, never a stale hit.
    ///
    /// ## Thread safety
    ///
    /// `NSLock` around all state, in a `final class` marked
    /// `@unchecked Sendable` - the same shape as `FailureTracker` below,
    /// chosen for the same reason. `all` is a synchronous static
    /// property, so an `actor` (which would force `await` onto it and
    /// onto `matching(exe:)`, `GameFixService.prepare` and the
    /// self-tests) is the wrong tool for a handful of fields. The lock is
    /// held across a reload, deliberately: concurrent launches then wait
    /// for one load and share its result instead of each re-reading the
    /// folder, and nothing else ever takes this lock, so it cannot
    /// deadlock.
    ///
    /// Before/after numbers are on `all`, above.
    final class UserFixCache: @unchecked Sendable {
        /// One file's identity in the fingerprint.
        struct FileStamp: Equatable {
            let name: String
            let modified: Date?
            let size: Int?
        }

        struct Snapshot {
            let fingerprint: [FileStamp]
            let merged: [GameFix]
            let failed: [String]
            /// Readability of each failed file when it was loaded.
            /// A `chmod` that makes an unreadable file readable changes
            /// neither its modification time nor its size, yet it turns a
            /// reported failure into a loadable fix, so the fingerprint
            /// alone would miss it. Only the (rare) failed files are
            /// re-checked, on each hit, because asking for readability of
            /// every file measured ~1 ms per 100 files - four times the
            /// whole cost of the rest of the validation.
            let failedReadable: [String: Bool]
            /// False when a file was too fresh to trust (see the racy
            /// window above); an untrusted snapshot is returned to the
            /// caller but never reused.
            let trusted: Bool
        }

        /// Modification times closer than this to the start of a load
        /// cannot be told apart from "edited again within the same tick".
        /// Two seconds also covers coarse (1 s) filesystems.
        static let racyWindow: TimeInterval = 2

        private let lock = NSLock()
        private var cached: Snapshot?
        private var loads = 0

        var loadCount: Int {
            lock.lock(); defer { lock.unlock() }
            return loads
        }

        func current() -> Snapshot {
            lock.lock(); defer { lock.unlock() }
            let began = Date()
            let fingerprint = Self.fingerprint()
            if let cached, cached.trusted, cached.fingerprint == fingerprint,
               cached.failedReadable.allSatisfy({ name, was in
                   FileManager.default.isReadableFile(atPath: Paths.fixes.appendingPathComponent(name).path) == was
               }) {
                return cached
            }
            let loaded = GameFixCatalog.loadUserFixes()
            loads += 1
            let trusted = !fingerprint.contains { stamp in
                guard let modified = stamp.modified else { return true }
                return modified > began.addingTimeInterval(-Self.racyWindow)
            }
            let snapshot = Snapshot(
                fingerprint: fingerprint,
                merged: GameFixCatalog.merged(with: loaded.fixes),
                failed: loaded.failed,
                failedReadable: Dictionary(
                    loaded.failed.map { name in
                        (name, FileManager.default.isReadableFile(atPath: Paths.fixes.appendingPathComponent(name).path))
                    },
                    uniquingKeysWith: { first, _ in first }
                ),
                trusted: trusted
            )
            cached = snapshot
            return snapshot
        }

        /// Names, modification times and sizes of the `.json` files in
        /// `Paths.fixes`, sorted by name. Empty when the folder is missing
        /// or unreadable, which is also what `loadUserFixes()` sees.
        private static func fingerprint() -> [FileStamp] {
            let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: Paths.fixes, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
            ) else { return [] }
            return entries
                .filter { $0.pathExtension.lowercased() == "json" }
                .map { url -> FileStamp in
                    let values = try? url.resourceValues(forKeys: keys)
                    return FileStamp(name: url.lastPathComponent, modified: values?.contentModificationDate, size: values?.fileSize)
                }
                .sorted { $0.name < $1.name }
        }
    }

    /// Names of unreadable user fix files seen so far, and which of them
    /// have already been surfaced. `all` is reached from
    /// `GameFixService.prepare`, which is not main-actor isolated, so the
    /// state is behind a lock.
    private final class FailureTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [String] = []
        private var surfaced: Set<String> = []
        /// Names currently failing, so a file that gets fixed is forgotten
        /// and will be reported again if it breaks again later.
        private var current: Set<String> = []

        func note(_ failed: [String]) {
            lock.lock(); defer { lock.unlock() }
            current = Set(failed)
            surfaced.formIntersection(current)
            for name in failed where !surfaced.contains(name) && !pending.contains(name) {
                pending.append(name)
            }
            pending.removeAll { !current.contains($0) }
        }

        func takeUnreported() -> [String] {
            lock.lock(); defer { lock.unlock() }
            let names = pending
            surfaced.formUnion(names)
            pending = []
            return names
        }
    }

    private static let userFixFailures = FailureTracker()

    /// Every fix that applies to `exe`, in catalog order. Normally empty:
    /// most programs need no fix at all.
    static func matching(exe: URL, steamAppID: String? = nil) -> [GameFix] {
        all.filter { $0.matches(exe: exe, steamAppID: steamAppID) }
    }
}
