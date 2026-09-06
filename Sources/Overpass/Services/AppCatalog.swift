import Foundation

/// One category shown as a filter chip in `AppCatalogView`.
enum AppCategory: String, Codable, CaseIterable, Sendable, Identifiable {
    case gameStores = "Game stores"
    case games = "Games"
    case utilities = "Utilities"
    case runtimes = "Runtimes"
    case productivity = "Productivity"

    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .gameStores: return "gamecontroller"
        case .games: return "die.face.5"
        case .utilities: return "wrench.and.screwdriver"
        case .runtimes: return "shippingbox"
        case .productivity: return "doc.richtext"
        }
    }
}

/// One entry in the "Install App" catalog: a known Windows program, where
/// to download its installer (if any — a winetricks-only entry like
/// ".NET Framework 4.8" has none), and how `AppInstaller` should run it
/// silently inside a bottle.
struct CatalogApp: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let publisher: String
    let category: AppCategory
    let blurb: String
    /// Direct download URL for the installer. `nil` for entries that only
    /// install via `winetricksVerbs` (e.g. .NET Framework, DirectX).
    let installerURL: URL?
    /// File name the installer is saved as under `Paths.downloads`.
    let installerFileName: String
    /// Arguments that make the installer run non-interactively. Empty
    /// means "no known silent mode" — `AppInstaller` still runs it, just
    /// without those flags, and `postInstallNotes` should say so.
    let silentArgs: [String]
    /// True to run it through `msiexec /i` instead of executing it
    /// directly.
    let isMSI: Bool
    let recommendedWindows: WindowsVersion
    /// `nil` means "no preference" — fall back to whatever engine is
    /// installed.
    let preferredEngine: EngineKind?
    /// Winetricks verbs applied before the installer runs (or, for a
    /// winetricks-only entry, instead of running one at all).
    let winetricksVerbs: [String]
    let postInstallNotes: String?
    /// Relative Windows-side paths under `drive_c` to look for after
    /// install, in preference order, e.g.
    /// `"Program Files (x86)/Steam/steam.exe"`. The first one that exists
    /// gets pinned.
    let launchExeHints: [String]
    let launchArgs: String
    let keywords: [String]
    let iconSymbol: String

    init(
        id: String,
        name: String,
        publisher: String,
        category: AppCategory,
        blurb: String,
        installerURL: URL? = nil,
        installerFileName: String = "",
        silentArgs: [String] = [],
        isMSI: Bool = false,
        recommendedWindows: WindowsVersion = .win10,
        preferredEngine: EngineKind? = nil,
        winetricksVerbs: [String] = [],
        postInstallNotes: String? = nil,
        launchExeHints: [String] = [],
        launchArgs: String = "",
        keywords: [String] = [],
        iconSymbol: String = "app.badge"
    ) {
        self.id = id
        self.name = name
        self.publisher = publisher
        self.category = category
        self.blurb = blurb
        self.installerURL = installerURL
        self.installerFileName = installerFileName
        self.silentArgs = silentArgs
        self.isMSI = isMSI
        self.recommendedWindows = recommendedWindows
        self.preferredEngine = preferredEngine
        self.winetricksVerbs = winetricksVerbs
        self.postInstallNotes = postInstallNotes
        self.launchExeHints = launchExeHints
        self.launchArgs = launchArgs
        self.keywords = keywords
        self.iconSymbol = iconSymbol
    }

    /// True when the installer has a known non-interactive mode. Shown as
    /// a "Silent install" badge; when false the UI should say the
    /// installer needs the user to click through it.
    var hasSilentInstall: Bool { !silentArgs.isEmpty }
}

/// The curated, fixed catalog of installable Windows apps. Every
/// `installerURL` below was verified reachable (final response 200 with a
/// binary content-type after following redirects) with
/// `curl -sIL <url> | grep -iE '^(HTTP|location)'` in September 2026 — see
/// the implementation report for the full table. Entries the author could
/// not verify a working direct-download URL for (itch.io's app, which only
/// ships as a signed, short-lived, expiring R2 URL that 403s on a plain
/// `curl -I`; a standalone Doom/Freedoom engine, which upstream only ships
/// as `.zip` with no installer) were left out rather than shipped broken.
enum AppCatalog {
    static let apps: [CatalogApp] = [
        // MARK: Game stores

        CatalogApp(
            id: "steam",
            name: "Steam",
            publisher: "Valve",
            category: .gameStores,
            blurb: "Valve's PC game store and launcher. Most Windows-only Steam games run well under GPTK once Steam itself is installed.",
            installerURL: URL(string: "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe")!,
            installerFileName: "SteamSetup.exe",
            silentArgs: ["/S"],
            recommendedWindows: .win10,
            preferredEngine: .wineStaging,  // GPTK 3.0-3 is Wine 7.7-based; current steamwebhelper (Chromium 126) hangs there but works on Wine 11
            postInstallNotes: "Launch flags \"-allosarches -cef-disable-gpu -cef-disable-gpu-compositing\" are applied automatically (the GPU flags reduce steamwebhelper crashes). Important: on the Game Porting Toolkit engine (Wine 7.7 base) the current Steam client shows \"steamwebhelper is not responding\" no matter what flags are used; run the Steam bottle on the Wine Staging 11.16 engine instead (Config → Engine) and enable DXVK in Extras for DirectX games — they work around steamwebhelper (Steam's embedded Chromium browser) crashing on launch under Apple Silicon GPTK/Wine, a fix documented by CrossOver support and mirrored on mybyways.com's \"Running Steam in Game Porting Toolkit\" (Sept 2026). If the login screen itself renders blank, add \"-noreactlogin\" (Valve's older non-React login UI) as a fallback — note that Valve has periodically threatened to remove that flag from Steam, so it may stop working in a future Steam update.",
            launchExeHints: ["Program Files (x86)/Steam/steam.exe"],
            launchArgs: "-allosarches -cef-disable-gpu -cef-disable-gpu-compositing",
            keywords: ["valve", "games", "store"],
            iconSymbol: "gamecontroller.fill"
        ),
        CatalogApp(
            id: "battlenet",
            name: "Battle.net",
            publisher: "Blizzard Entertainment",
            category: .gameStores,
            blurb: "Blizzard's launcher for World of Warcraft, Diablo, Overwatch, and StarCraft.",
            installerURL: URL(string: "https://downloader.battle.net/download/getInstaller?os=win&installer=Battle.net-Setup.exe")!,
            installerFileName: "Battle.net-Setup.exe",
            silentArgs: [],
            recommendedWindows: .win10,
            postInstallNotes: "Battle.net's installer has no documented silent/unattended mode — it launches its own bootstrapper UI which downloads the real client. Run it and click through the first-run setup once; subsequent updates happen inside the app.",
            launchExeHints: ["Program Files (x86)/Battle.net/Battle.net Launcher.exe"],
            keywords: ["blizzard", "wow", "diablo", "overwatch"],
            iconSymbol: "gamecontroller"
        ),
        CatalogApp(
            id: "epic-games-launcher",
            name: "Epic Games Launcher",
            publisher: "Epic Games",
            category: .gameStores,
            blurb: "Epic's storefront, home to Fortnite, Unreal Engine, and the weekly free-game giveaways.",
            installerURL: URL(string: "https://launcher-public-service-prod06.ol.epicgames.com/launcher/api/installer/download/EpicGamesLauncherInstaller.msi")!,
            installerFileName: "EpicGamesLauncherInstaller.msi",
            silentArgs: ["/passive", "/norestart"],
            isMSI: true,
            recommendedWindows: .win10,
            postInstallNotes: "Uses \"/passive\" rather than msiexec's fully silent \"/qn\" — Epic's MSI shows an unattended progress UI under \"/passive\" but has been reported to fail silently (installs nothing, exits 0) under \"/qn\" in Wine.",
            launchExeHints: ["Program Files (x86)/Epic Games/Launcher/Portal/Binaries/Win32/EpicGamesLauncher.exe", "Program Files (x86)/Epic Games/Launcher/Portal/Binaries/Win64/EpicGamesLauncher.exe"],
            keywords: ["epic", "fortnite", "unreal"],
            iconSymbol: "e.square"
        ),
        CatalogApp(
            id: "gog-galaxy",
            name: "GOG Galaxy",
            publisher: "CD Projekt",
            category: .gameStores,
            blurb: "GOG's DRM-free game store and optional launcher, including cross-platform save sync.",
            installerURL: URL(string: "https://webinstallers.gog-statics.com/download/GOG_Galaxy_2.0.exe")!,
            installerFileName: "GOG_Galaxy_2.0.exe",
            silentArgs: ["/VERYSILENT", "/NORESTART"],
            recommendedWindows: .win10,
            postInstallNotes: "Inno Setup installer; \"/VERYSILENT\" suppresses all UI including the finish-page \"Run GOG Galaxy\" checkbox.",
            launchExeHints: ["Program Files (x86)/GOG Galaxy/GalaxyClient.exe"],
            keywords: ["gog", "cd projekt", "drm-free"],
            iconSymbol: "g.square"
        ),
        CatalogApp(
            id: "ea-app",
            name: "EA app",
            publisher: "Electronic Arts",
            category: .gameStores,
            blurb: "EA's current launcher (successor to Origin) for Battlefield, The Sims, and other EA titles.",
            installerURL: URL(string: "https://origin-a.akamaihd.net/EA-Desktop-Client-Download/installer-releases/EAappInstaller.exe")!,
            installerFileName: "EAappInstaller.exe",
            silentArgs: [],
            recommendedWindows: .win10,
            postInstallNotes: "This is EA's small bootstrap stub — it downloads the full client on first run over the network, so it has no meaningful silent flag; run it and let the first-run download finish.",
            launchExeHints: ["Program Files/Electronic Arts/EA Desktop/EA Desktop/EADesktop.exe"],
            keywords: ["ea", "origin", "battlefield", "sims"],
            iconSymbol: "e.circle"
        ),
        CatalogApp(
            id: "ubisoft-connect",
            name: "Ubisoft Connect",
            publisher: "Ubisoft",
            category: .gameStores,
            blurb: "Ubisoft's launcher for Assassin's Creed, Far Cry, and other Ubisoft titles, plus cross-save and rewards.",
            installerURL: URL(string: "https://static3.cdn.ubi.com/orbit/launcher_installer/UbisoftConnectInstaller.exe")!,
            installerFileName: "UbisoftConnectInstaller.exe",
            silentArgs: ["/S"],
            recommendedWindows: .win10,
            launchExeHints: ["Program Files (x86)/Ubisoft/Ubisoft Game Launcher/UbisoftConnect.exe"],
            keywords: ["ubisoft", "uplay", "assassin's creed", "far cry"],
            iconSymbol: "u.square"
        ),

        // MARK: Utilities

        CatalogApp(
            id: "7zip",
            name: "7-Zip",
            publisher: "Igor Pavlov",
            category: .utilities,
            blurb: "Open-source archive manager with very high compression, needed by a lot of Windows installers and mod tools.",
            installerURL: URL(string: "https://www.7-zip.org/a/7z2409-x64.exe")!,
            installerFileName: "7z2409-x64.exe",
            silentArgs: ["/S"],
            recommendedWindows: .win10,
            launchExeHints: ["Program Files/7-Zip/7zFM.exe"],
            keywords: ["archive", "zip", "compression", "7z"],
            iconSymbol: "archivebox"
        ),
        CatalogApp(
            id: "notepad-plus-plus",
            name: "Notepad++",
            publisher: "Don Ho",
            category: .utilities,
            blurb: "A fast, free source-code and text editor with syntax highlighting for dozens of languages.",
            installerURL: URL(string: "https://github.com/notepad-plus-plus/notepad-plus-plus/releases/download/v8.9.8/npp.8.9.8.Installer.x64.exe")!,
            installerFileName: "npp.8.9.8.Installer.x64.exe",
            silentArgs: ["/S"],
            recommendedWindows: .win10,
            launchExeHints: ["Program Files/Notepad++/notepad++.exe"],
            keywords: ["editor", "text", "code"],
            iconSymbol: "doc.text"
        ),
        CatalogApp(
            id: "vlc",
            name: "VLC media player",
            publisher: "VideoLAN",
            category: .utilities,
            blurb: "Plays essentially any video or audio format, including codecs some Windows programs expect to find installed.",
            installerURL: URL(string: "https://get.videolan.org/vlc/last/win64/vlc-3.0.23-win64.exe")!,
            installerFileName: "vlc-3.0.23-win64.exe",
            silentArgs: ["/S"],
            recommendedWindows: .win10,
            launchExeHints: ["Program Files/VideoLAN/VLC/vlc.exe"],
            keywords: ["video", "media player", "codec"],
            iconSymbol: "play.rectangle"
        ),
        CatalogApp(
            id: "winrar",
            name: "WinRAR",
            publisher: "win.rar GmbH",
            category: .utilities,
            blurb: "The classic Windows archive manager for RAR and ZIP files; free to evaluate indefinitely.",
            installerURL: URL(string: "https://www.win-rar.com/fileadmin/winrar-versions/winrar/winrar-x64-723.exe")!,
            installerFileName: "winrar-x64-723.exe",
            silentArgs: ["/S"],
            recommendedWindows: .win10,
            launchExeHints: ["Program Files/WinRAR/WinRAR.exe"],
            keywords: ["archive", "rar", "zip", "compression"],
            iconSymbol: "doc.zipper"
        ),

        // MARK: Runtimes

        CatalogApp(
            id: "dotnet48",
            name: ".NET Framework 4.8",
            publisher: "Microsoft",
            category: .runtimes,
            blurb: "The Windows .NET runtime that many older Windows applications and games require to launch at all.",
            winetricksVerbs: ["dotnet48"],
            postInstallNotes: "Installed entirely through winetricks (no separate installer download) — this can take several minutes the first time as winetricks fetches and runs Microsoft's real offline installer inside the bottle.",
            keywords: ["dotnet", "framework", "runtime", "microsoft"],
            iconSymbol: "shippingbox"
        ),
        CatalogApp(
            id: "vcredist-2022",
            name: "Visual C++ 2015-2022 Redistributable",
            publisher: "Microsoft",
            category: .runtimes,
            blurb: "The C++ runtime DLLs most modern Windows games and applications link against. Install this first if a program complains about a missing MSVCP*.dll or VCRUNTIME*.dll.",
            installerURL: URL(string: "https://aka.ms/vs/17/release/vc_redist.x64.exe")!,
            installerFileName: "vc_redist.x64.exe",
            silentArgs: ["/install", "/quiet", "/norestart"],
            recommendedWindows: .win10,
            keywords: ["vcredist", "c++", "runtime", "microsoft", "msvcp", "vcruntime"],
            iconSymbol: "shippingbox.fill"
        ),
        CatalogApp(
            id: "directx9",
            name: "DirectX End-User Runtime",
            publisher: "Microsoft",
            category: .runtimes,
            blurb: "Legacy DirectX 9 DLLs (D3DX9, XAudio 2.7, XInput 1.3, ...) that many older games install-check for even when they actually render through D3D11/12.",
            winetricksVerbs: ["directx9"],
            postInstallNotes: "Installed through winetricks rather than Microsoft's web installer, which requires clicking through a EULA and no longer reliably serves the offline redistributable package.",
            keywords: ["directx", "d3d9", "dx9", "microsoft"],
            iconSymbol: "shippingbox"
        ),
    ]

    /// Case-insensitive match on name, publisher, category, and keywords.
    /// Empty query returns every app, sorted by name.
    static func search(_ query: String) -> [CatalogApp] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let sorted = apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !trimmed.isEmpty else { return sorted }

        let needle = trimmed.lowercased()
        return sorted.filter { app in
            if app.name.lowercased().contains(needle) { return true }
            if app.publisher.lowercased().contains(needle) { return true }
            if app.category.rawValue.lowercased().contains(needle) { return true }
            return app.keywords.contains { $0.lowercased().contains(needle) }
        }
    }
}
