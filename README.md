# Overpass

Overpass is a native macOS app that runs Windows `.exe` files through Wine —
a Whisky/CrossOver-style launcher for Apple Silicon, built for people who
want an open, self-hosted alternative now that Whisky is discontinued.
Overpass owns its Wine engines, its bottles, and its data; nothing is
proprietary and nothing phones home.

## Features

- **Engines** — install Apple's Game Porting Toolkit (D3DMetal) or
  open-source Wine-staging with one click; both are downloaded on demand,
  never bundled with the app.
- **Bottles** — create isolated Wine prefixes per Windows version
  (7/10/11), each with its own engine, ESync/MSync, Metal HUD, and
  environment variables.
- **Install App** — a built-in catalog of common Windows apps (Steam,
  7-Zip, Notepad++, redistributables, ...) that downloads the installer
  and runs it in a bottle for you, CrossOver-style.
- **Run** — pick an `.exe`/`.msi` with a file picker, drag one onto a
  bottle, or set Overpass as the default handler in Finder.
- **Programs** — Overpass scans a bottle's Start Menu, Desktop, and
  `Program Files` for installed programs and turns them into a launchable
  grid; pin your own too.
- **Performance** — per-bottle tuning presets and advanced Wine/Metal
  settings (threading, FSR/MetalFX upscaling, frame pacing) for squeezing
  more out of games.
- **Extras** — one-click Winetricks verbs (Visual C++, .NET, fonts,
  codecs, ...) and a DXVK toggle for better DirectX 9/10/11 support on
  Wine-staging bottles.
- **Logs** — one file per run, tailed live in the app, with a "Reveal in
  Finder" shortcut.
- **Config** — per-bottle `winecfg`, `regedit`, `explorer`, and an "Open
  C: drive in Finder" shortcut.

## Install and first run

1. Download `Overpass.app` (see [Building from source](#building-from-source)
   if you'd rather build it yourself) and drag it into `/Applications`.
2. **Right-click → Open** the first time you launch it. Overpass is
   ad-hoc signed (no Apple Developer ID), so Gatekeeper blocks a plain
   double-click on first run — right-click → Open shows an "Open anyway"
   option that a double-click doesn't.
3. Overpass checks for Rosetta 2 on first launch and offers to install it
   if it's missing. To install it yourself ahead of time:
   ```
   softwareupdate --install-rosetta --agree-to-license
   ```
4. The setup wizard walks you through installing an engine and creating
   your first bottle. Both Wine engines are x86_64 builds and run under
   Rosetta 2 — Apple Silicon Macs handle this transparently.

## Engines

Overpass ships two engine choices, both downloaded from Gcenx's community
builds at first use — nothing is vendored in this repo or the app bundle:

| Engine | What it is | Licence |
|---|---|---|
| **Game Porting Toolkit** (default) | Wine plus Apple's D3DMetal, which translates DirectX 11/12 directly to Metal. Best performance and compatibility for most games. | D3DMetal is distributed under Apple's **non-commercial** licence. |
| **Wine-staging** | The newest upstream Wine-staging build, fully open source. DirectX 9/10/11 titles can use DXVK (Extras tab) instead of Wine's built-in translation. | Wine's own licence (LGPL). |

Pick Wine-staging if you need a fully open-source stack or a title
specifically wants DXVK; otherwise Game Porting Toolkit is the better
default for games.

### A note on macOS 28 and Rosetta

Both engines are x86_64 binaries and depend on Rosetta 2. Apple has said
it plans to remove most of Rosetta 2 starting with macOS 28 (expected
2027) — at that point these engines may stop working on whatever OS
version ships then. Overpass keeps engine selection behind an `Engine`
abstraction specifically so a native arm64 build (once one exists) can be
added as a single new catalog entry rather than a rewrite.

## Building from source

No Xcode is required or used — this is a plain Swift package built with
the Command Line Tools:

```
git clone <this repo> overpass
cd overpass
swift build                 # debug build, for development
scripts/bundle.sh           # release build + .app assembly, ad-hoc signed
open build/Overpass.app
```

`scripts/bundle.sh` compiles in release mode, assembles
`build/Overpass.app` (executable, `Info.plist`, icon), and codesigns it
ad-hoc so it launches like any other downloaded app (right-click → Open
on first run, per Gatekeeper).

### Headless smoke test

`build/Overpass.app/Contents/MacOS/Overpass --check [engine-id]` runs a
full round trip with no UI: installs the given engine (`gptk-3.0-3` by
default, from the download cache when possible), creates a throwaway
bottle, launches Notepad, confirms it's alive, stops it, and deletes the
bottle — printing `CHECK OK` and exiting `0`, or `CHECK FAILED: ...` and
exiting non-zero on the first failure. Pass `--keep` to leave the test
bottle in place for inspection instead of deleting it. Useful in CI or
after changing `EngineManager`/`WineRunner` without wanting to click
through the UI by hand.

## Data locations

Everything Overpass manages lives under
`~/Library/Application Support/Overpass/`:

| Folder | Contents |
|---|---|
| `Engines/` | Installed Wine engines, one folder per engine id. |
| `Bottles/` | Wine prefixes (`WINEPREFIX`), one folder per bottle, each with its own `drive_c` and `metadata.json`. |
| `Logs/` | One log file per run, grouped by bottle. |
| `Tools/` | Helper downloads: the `winetricks` script, DXVK archives, engine tarballs (removed after install). |

Deleting a bottle moves its folder to the Trash, not a permanent delete —
recoverable until you empty it.

## Credits

Overpass is a thin, native front end over other people's excellent work:

- [Wine](https://www.winehq.org) — the compatibility layer everything
  here runs on.
- [Gcenx](https://github.com/Gcenx) — maintains the macOS builds of both
  Wine-staging and the Game Porting Toolkit that Overpass installs.
- [Apple Game Porting Toolkit](https://developer.apple.com/games/game-porting-toolkit/) —
  D3DMetal, distributed under Apple's non-commercial licence.
- [Winetricks](https://github.com/Winetricks/winetricks) — the verb
  installer behind the Extras tab.
- [DXVK-macOS](https://github.com/Gcenx/DXVK-macOS) — the DXVK build
  Overpass installs for the DirectX-over-DXVK option.

Overpass is not affiliated with Wine, Apple, CodeWeavers, or the original
Whisky project.
