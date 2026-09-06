# Overpass — a Whisky/CrossOver-style Wine launcher for macOS

> **Implementation brief for Codex.** This document is self-contained. Once approved it is copied to `~/Applications/overpass/PLAN.md` (and a short `AGENTS.md` pointer) so an implementing agent can work from it without any other context. Work phase by phase, commit after each phase, and run the verification steps for the phase before moving on.

## 1. Goal

Build **Overpass**, a native macOS app that runs Windows `.exe` files through Wine, in the style of Whisky (discontinued April 2025) and CrossOver. The user wants an open-engine launcher they own: pick an `.exe`, run it in a Wine "bottle", manage bottles and engines from a SwiftUI UI.

## 2. Environment (already verified on this machine)

| Item | Value |
|---|---|
| Chip / OS | Apple Silicon (arm64), macOS 26.5.2 |
| Rosetta 2 | Installed (`/usr/bin/pgrep -q oahd` succeeds) |
| Toolchain | Command Line Tools only, Swift 6.3. **No Xcode**, so no `xcodebuild`, no `.xcodeproj`. Build with `swift build`. |
| Homebrew | 6.0 at `/opt/homebrew` (optional; runtime must not require it) |
| Wine | Not installed anywhere. CrossOver 26.3 exists in `/Applications` but must not be used (proprietary). |
| Template project | `~/Applications/valheim-mod-launcher` ("Bifrost"): SwiftUI + SPM executable + `scripts/bundle.sh`. Copy its build pattern. |
| Test executables | `/Applications/Geeky.exe` exists on disk for a real-world test. Wine ships `notepad.exe`. |

## 3. Engines (checked September 2026)

Both are x86_64 builds that run under Rosetta 2. The app downloads them at first run; nothing is vendored in the repo.

| id | kind | version | asset URL |
|---|---|---|---|
| `gptk-3.0-3` | Apple Game Porting Toolkit (Gcenx build) | 3.0-3 (Mar 2026) | `https://github.com/Gcenx/game-porting-toolkit/releases/download/Game-Porting-Toolkit-3.0-3/game-porting-toolkit-3.0-3.tar.xz` |
| `wine-staging-11.16` | Wine-staging (Gcenx build) | 11.16 (Aug 2026) | `https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.16/wine-staging-11.16-osx64.tar.xz` |

- GPTK = Wine + Apple D3DMetal (DirectX 11/12 → Metal). Best for games. D3DMetal is licensed by Apple for non-commercial use; note that in the README. **Default engine.**
- Wine-staging = newest upstream Wine, fully open source; DirectX through DXVK-macOS (optional toggle).
- At implementation time, download each tarball once, compute SHA-256, and embed the hashes in the catalog.
- If the GPTK tarball does not contain `lib/external/libd3dshared.dylib`, add an "Locate Apple GPTK .dmg" step in the Engines screen that copies `lib/external/*` from Apple's developer download into the engine folder. Do not commit those files.
- **Risk to document:** Apple removes most of Rosetta 2 in macOS 28 (2027). Keep engine selection behind the `Engine` abstraction so an ARM64 build can be added as one catalog entry later.

## 4. Product scope (v1)

- Engines screen: list catalog, install/remove with download progress, show `wine --version` for installed engines.
- Bottles: create (name, engine, Windows version), delete (move to Trash), list in sidebar. Each bottle is a separate `WINEPREFIX`.
- Run: "Run .exe…" file picker, drag-and-drop onto a bottle, and Finder "Open With Overpass" for `.exe`/`.msi` (shows a bottle picker sheet, defaults to last-used bottle).
- Programs: scan the bottle for installed programs (Start Menu / Desktop `.lnk`, `Program Files` `.exe`) and show a grid of launchable pins with user-added pins and per-pin arguments.
- Config per bottle: engine switch, Windows version (7/10/11), ESync, MSync, Metal HUD, verbose logging, DXVK on/off (Wine-staging only), custom env vars. Buttons for `winecfg`, `regedit`, `explorer`, and "Open C: drive in Finder".
- Winetricks: install verbs from a short curated list (`vcrun2022`, `dotnet48`, `corefonts`, `d3dcompiler_47`) plus a free-text verb field.
- Logs: one log file per run, live tail in the app, "Reveal in Finder".
- Stop: kill everything in the bottle (`wineserver -k`).
- First-run wizard: Rosetta check, install default engine, create first bottle.

Out of scope for v1: CrossOver bottle import, installer recipes (Steam/Battle.net one-clicks), icon extraction from `.exe` (use a generic icon), Homebrew integration.

## 5. Architecture and file layout

```
~/Applications/overpass/
  Package.swift                    swift-tools-version 5.9, platforms [.macOS(.v14)], executableTarget "Overpass" at Sources/Overpass
  Resources/Info.plist             bundle id com.joshua.overpass, CFBundleDocumentTypes for .exe/.msi, LSMinimumSystemVersion 14.0
  Resources/icon.png               1024x1024
  scripts/bundle.sh                copy of valheim-mod-launcher/scripts/bundle.sh with APP_NAME="Overpass"; produces build/Overpass.app, ad-hoc signed
  README.md                        install (right-click → Open), engines + licences, Rosetta/macOS 28 note
  PLAN.md                          this file
  AGENTS.md                        "Read PLAN.md. Build with scripts/bundle.sh. No Xcode."
  Sources/Overpass/
    OverpassApp.swift                  @main; copy the activation-policy trick from valheim-mod-launcher/Sources/Bifrost/BifrostApp.swift; handle open-file events
    AppState.swift                 @Observable root: engines, bottles, running runs, selected bottle, error banner
    Models/Engine.swift            enum EngineKind { gptk, wineStaging }; struct EngineRelease (id, kind, version, url, sha256); struct InstalledEngine (id, rootDir, binDir, libDir)
    Models/Bottle.swift            Codable: id (UUID), name, engineID, windowsVersion, esync, msync, metalHUD, verboseLog, dxvk, env [String:String], pins [PinnedProgram], createdAt, lastUsed
    Models/PinnedProgram.swift     id, name, exePath (Windows path "C:\\..."), args, isUserAdded
    Models/RunRecord.swift         bottleID, exe, startedAt, logURL, pid
    Services/ShellRunner.swift     copy verbatim from valheim-mod-launcher/Sources/Bifrost/Services/ShellRunner.swift (async Process wrapper that drains both pipes)
    Services/Paths.swift           ~/Library/Application Support/Overpass/{Engines,Bottles,Logs,Tools}
    Services/EngineCatalog.swift   the two releases above, hashes embedded
    Services/EngineManager.swift   download (URLSession with progress), sha256 verify, `tar -xJf` into Engines/<id>, `xattr -dr com.apple.quarantine`, locate bin/wine64 (fallback bin/wine) and lib by walking the extracted tree, health check via `wine --version`
    Services/BottleStore.swift     load/save metadata.json per bottle, create (mkdir + wineboot -i + winecfg -v), delete to Trash, list
    Services/WineRunner.swift      env builder + streaming Process launcher; tracks child pids; stop() runs `wineserver -k`
    Services/Winetricks.swift      download https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks to Tools/, run `bash winetricks -q <verb>` with the bottle env, stream to log
    Services/DXVKInstaller.swift   download latest Gcenx DXVK-macOS release zip, copy x64 dlls (d3d9, d3d10core, d3d11, dxgi) into drive_c/windows/system32, backup originals, set WINEDLLOVERRIDES; uninstall restores backups
    Services/ProgramScanner.swift  walk drive_c/users/*/Desktop, drive_c/ProgramData/Microsoft/Windows/Start Menu, drive_c/Program Files*; parse .lnk target path (ShellLink format: LinkTargetIDList/LinkInfo LocalBasePath) and list .exe files; ignore uninstallers/redistributables by name
    Services/LogStore.swift        Logs/<bottleID>/<yyyyMMdd-HHmmss>-<exe>.log; append; tail for viewer
    Views/MainWindow.swift         NavigationSplitView: sidebar (bottles + "Engines" + "Settings"), detail
    Views/BottleDetailView.swift   header (name, engine, Run .exe…, Stop), tabs: Programs / Config / Logs; drop target for .exe
    Views/BottleConfigView.swift   form bound to Bottle; applying Windows version/ESync etc. re-writes metadata and, where needed, runs winecfg/regedit commands
    Views/ProgramsGridView.swift
    Views/EnginesView.swift
    Views/SetupWizardView.swift
    Views/LogViewerView.swift
    Views/BottlePickerSheet.swift  used by open-file and drop when the target bottle is ambiguous
    Views/Theme.swift              copy valheim-mod-launcher/Sources/Bifrost/Views/Theme.swift and retint
```

## 6. Key behaviours

**Engine install.** Download to `Tools/downloads/<id>.tar.xz` with progress; verify SHA-256; extract with `/usr/bin/tar -xJf` into `Engines/<id>/`; strip quarantine; walk the tree to find `bin/wine64` (else `bin/wine`) and `lib`; run `wine64 --version` and store the string in `InstalledEngine`. Failure at any step deletes the partial folder and surfaces the error.

**Bottle environment** (built by `WineRunner.environment(for:)`):
```
WINEPREFIX=<Bottles>/<id>
PATH=<engine>/bin:/usr/bin:/bin
WINEDEBUG=-all                      (verboseLog → "fixme-all")
WINEESYNC=1 / WINEMSYNC=1           (from toggles; omit when off)
MTL_HUD_ENABLED=1                   (metalHUD)
DYLD_FALLBACK_LIBRARY_PATH=<engine>/lib:<engine>/lib/external   (needed by GPTK for D3DMetal)
WINEDLLOVERRIDES=d3d9,d3d10core,d3d11,dxgi=n,b   (only when dxvk is on)
+ bottle.env
```
GPTK enables D3DMetal itself when its dylibs are on the library path; do not set overrides for it.

**Running an exe.** `wine64 start /unix "<absolute exe path>" <args>` with working directory = exe's folder so the app doesn't block. Also track the `wineserver` process for the prefix. stdout/stderr are piped continuously to the log file (never read pipes only at exit; see the deadlock comment in ShellRunner). "Stop" runs `wineserver -k` with the same env, then after 3 s `-k9` if `pgrep -f <prefix>` still finds processes.

**Bottle creation.** `wineboot -i` → `winecfg -v win10|win11|win7` → write `metadata.json`. Show progress; wineboot takes 10–60 s on first run.

**Open-with / drop.** `Info.plist` `CFBundleDocumentTypes` with `LSItemContentTypes` `com.microsoft.windows-executable` and `com.microsoft.msi`, role Viewer. Handle `NSApplicationDelegate application(_:open:)` via `NSApplicationDelegateAdaptor`; if more than one bottle exists show `BottlePickerSheet`, else run in the only bottle. `.msi` runs through `wine64 msiexec /i`.

**Gatekeeper.** App is ad-hoc signed by `bundle.sh`; README documents right-click → Open on first launch (same as Bifrost).

## 7. Phases (commit after each)

1. **Scaffold** — `git init`, Package.swift, Info.plist, bundle.sh, OverpassApp, AppState, Theme, empty MainWindow, README stub, AGENTS.md. `swift build` passes and `scripts/bundle.sh` produces a launching app.
2. **Engines** — models, EngineCatalog with real hashes, EngineManager, EnginesView with progress and version string.
3. **Bottles + Run** — Bottle model, BottleStore, WineRunner, LogStore, SetupWizard, BottleDetail with Run .exe…, Stop, live log.
4. **Programs + Config** — ProgramScanner, ProgramsGridView with pins, BottleConfigView, winecfg/regedit/explorer/Finder buttons.
5. **Extras** — Winetricks, DXVKInstaller, open-with + drag-drop, app icon, README finished (licences, Rosetta/macOS 28 note).

Coding conventions: Swift 5.9 language mode is fine; `@Observable` + `@MainActor` for state; all process work `async` off the main thread; no third-party packages; errors are user-facing strings surfaced through `AppState.errorMessage`, never silent.

## 8. Verification (run after each relevant phase)

1. `cd ~/Applications/overpass && swift build` is clean; `scripts/bundle.sh` produces `build/Overpass.app`; `open build/Overpass.app` shows the window.
2. Engines: install `gptk-3.0-3` and `wine-staging-11.16`; each shows a version string from `wine64 --version`; the folder contains `bin/wine64` and `lib/wine`.
3. Create bottle "Test" on GPTK: `~/Library/Application Support/Overpass/Bottles/<id>/drive_c/windows` exists, `metadata.json` written, bottle reappears after relaunch.
4. Programs → System → `notepad.exe` launches a window; the run's log has no `err:` lines about missing dylibs.
5. Run `/Applications/Geeky.exe` in the bottle; it opens (or the log shows a clear Wine-side reason it does not).
6. Switch the bottle to Wine-staging, rerun notepad. Toggle DXVK on: `drive_c/windows/system32/d3d11.dll` is the DXVK build and `.bak` originals exist; toggle off restores them.
7. Winetricks `corefonts` completes and `drive_c/windows/Fonts/arial.ttf` exists.
8. Finder: double-click a `.exe` → Overpass opens the bottle picker and runs it.
9. Stop: after clicking Stop, `pgrep -fl 'Overpass/Bottles'` returns nothing.
