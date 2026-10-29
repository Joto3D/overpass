# Overpass

Overpass is a native macOS app that runs Windows `.exe` files through Wine —
a Whisky/CrossOver-style launcher for Apple Silicon, built for people who
want an open, self-hosted alternative now that Whisky is discontinued.
Overpass owns its Wine engines, its bottles, and its data; nothing is
proprietary and nothing phones home.

## Features

- **Engines** — install Apple's Game Porting Toolkit (D3DMetal) or
  open-source Wine-staging with one click; both are downloaded on demand,
  never bundled with the app. See [Engines](#engines) below for the
  trade-off between the two — it's the one choice in Overpass worth
  reading about before you make it.
- **Bottles** — a bottle is a private Windows environment: its own C:
  drive, installed programs, and engine, isolated from every other
  bottle. Create one per Windows version (7/10/11), each with its own
  engine, ESync/MSync, Metal HUD, and environment variables.
- **Install App** — a built-in catalog of common Windows apps (Steam,
  7-Zip, Notepad++, redistributables, ...) that downloads the installer
  and runs it in a bottle for you, CrossOver-style.
- **Run** — pick an `.exe`/`.msi` with a file picker, drag one onto a
  bottle, or set Overpass as the default handler in Finder.
- **Programs** — Overpass scans a bottle's Start Menu, Desktop, and
  `Program Files` for installed programs and turns them into a launchable
  grid; pin your own too.
- **Fixes** — a per-game fix database in the spirit of Proton's
  `protonfixes`. Launch a program Overpass knows about and it applies
  that program's documented recipe — Winetricks verbs, registry keys,
  Windows version, environment variables, launch arguments — once per
  bottle, with nothing to configure. Where a program is known *not* to
  work, it says so up front instead of leaving you watching a window that
  never opens. Add your own by dropping a JSON file in. See
  [Fixes](#fixes).
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

| Engine | What it is | Trade-off | Licence |
|---|---|---|---|
| **Game Porting Toolkit** (default) | Wine plus Apple's D3DMetal, which translates DirectX 11/12 directly to Metal. Best performance for most games. | Based on an older Wine, so some modern apps — **including the Steam client itself** — can fail to run under it. | D3DMetal is distributed under Apple's **non-commercial** licence. |
| **Wine-staging** | The newest upstream Wine-staging build, fully open source, with the widest app compatibility. DirectX 9/10/11 titles can use DXVK (Extras tab) instead of Wine's built-in translation. | DirectX goes through DXVK rather than D3DMetal, which is usually slower for games. | Wine's own licence (LGPL). |

Pick Wine-staging if the Steam client (or another app) won't run under
Game Porting Toolkit, if you need a fully open-source stack, or if a
title specifically wants DXVK; otherwise Game Porting Toolkit is the
better default for games. Overpass shows this same trade-off wherever
you pick an engine — the Engines screen, New Bottle, Import Bottle, and
the first-run setup wizard — since it's the single most consequential
choice in the app.

### A note on macOS 28 and Rosetta

Both engines are x86_64 binaries and depend on Rosetta 2. Apple has said
it plans to remove most of Rosetta 2 starting with macOS 28 (expected
2027) — at that point these engines may stop working on whatever OS
version ships then. Overpass keeps engine selection behind an `Engine`
abstraction specifically so a native arm64 build (once one exists) can be
added as a single new catalog entry rather than a rewrite.

## Fixes

Some Windows programs need a particular nudge before they run under Wine —
a font package, a registry value, a launch flag. Overpass keeps those
recipes in a database and applies them for you, so you don't have to know
they exist.

A fix matches on a program's executable name. The slow parts (Winetricks
verbs above all) run once per bottle and are then recorded, so they never
repeat. Environment variables and launch arguments are re-applied on every
launch, which means removing a fix removes its effects with nothing left
behind.

### Advisories

Not every finding is a fix. Some programs cannot work under Wine on macOS
at all, and the most useful thing a database can do is say so *before* you
spend twenty minutes installing one. Those entries carry an advisory
instead of a recipe:

| Severity | Meaning | Example |
|---|---|---|
| `wontRun` | No bottle setting can make this work. | Ubisoft Connect needs engine-level support that only CrossOver has. |
| `degraded` | Runs, with a limitation worth knowing first. | Counter-Strike 2 plays, but VAC keeps compatibility layers off its secure servers. |
| `info` | Runs fine — there's simply a better route. | No Man's Sky ships a native Mac build, and its Windows build renders with Vulkan, which D3DMetal can't translate. |

`wontRun` and `degraded` are surfaced in the app. `info` goes to the run
log — worth recording, not worth interrupting for.

### Adding your own

Drop a `.json` file into `~/Library/Application Support/Overpass/Fixes/`.
Each file holds one fix or an array of them, and only the fields you
actually need:

```json
{
  "id": "example-game",
  "name": "Example Game",
  "executables": ["example.exe"],
  "winetricks": ["vcrun2019"],
  "notes": "Black screen on startup without vcrun2019.",
  "source": "https://www.pcgamingwiki.com/wiki/Example_Game"
}
```

A user fix with the same `id` as a built-in one replaces it, so anything
that ships can be overridden. A malformed file is skipped rather than
breaking the rest of the database.

### The sourcing rule

Every built-in fix cites a public source, and the test suite fails the
build if one doesn't. A fix without a source is folklore, and a wrong
Winetricks verb costs minutes of install time in every bottle it touches,
for everyone.

The fix data is public domain (CC0 — see [LICENSE-FIXES](LICENSE-FIXES)),
separately from the GPL code, so recipes can move freely between projects.
The flip side is that entries must **not** be copied out of a GPL fix
database such as umu-protonfixes or proton-ge: that expression can't be
relicensed as public domain. Read the underlying fact from a public source
and write the entry yourself, citing it.

## Troubleshooting

The app surfaces this same guidance next to the Logs tab ("Program won't
start?") in every bottle, but it's worth having in writing too:

- **Black or invisible window** — try turning on a virtual desktop
  (Config tab), turning DXVK off (Extras tab), or switching engines
  (Engines screen). All three change how the bottle asks macOS to put
  pixels on screen, and one of them usually fixes it.
- **Program won't start at all** — open the Logs tab and check the last
  line of the run's log; it usually names the missing DLL or the crash.
  If it mentions a missing Visual C++/.NET runtime or font, install it
  from the Extras tab.
- **Steam (or another app) crashes or won't run under Game Porting
  Toolkit** — this is the known Steam-client caveat above, not
  necessarily a bug in Overpass. Create or switch that bottle to the
  Wine-staging engine.
- **Fonts, installers, or Winetricks verbs failing** — several verbs
  (the Visual C++ and .NET runtimes, corefonts) need `cabextract` to
  unpack their downloads. If it's missing:
  ```
  brew install cabextract
  ```

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
| `Fixes/` | Your own per-game fixes, as `.json` files. Merged over the built-in ones by `id`. Overpass only ever reads this folder. |

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
- [DXVK](https://github.com/doitsujin/dxvk) — the DirectX-over-Vulkan
  translation layer Overpass installs for the DXVK option.

Overpass is not affiliated with Wine, Apple, CodeWeavers, or the original
Whisky project.

## Licence

Overpass is free software, licensed under the **GNU General Public
Licence, version 3 or later**. The full text is in [LICENSE](LICENSE).

    Copyright (C) 2026 Joshua

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.

The GPL covers Overpass's own source. It does **not** cover the engines
Overpass downloads at runtime and never redistributes: Wine is LGPL-2.1+,
and Apple's D3DMetal comes under Apple's non-commercial licence, which you
accept when you install the Game Porting Toolkit engine. Keeping engines
out of this repository (see `AGENTS.md`) is what keeps that boundary
clean.

### The fix database is public domain

The per-game fix **data** — every `GameFix`'s executables, winetricks
verbs, registry entries, notes and sources — is dedicated to the public
domain under **CC0 1.0**, separately from the code. See
[LICENSE-FIXES](LICENSE-FIXES).

A fix recipe is a statement of fact, and facts belong to everybody. The
dedication exists so these recipes can move freely in both directions
between Overpass and projects whose licences are otherwise incompatible
with each other.

The flip side, stated plainly: because the data is CC0 rather than GPL,
entries may **not** be copied out of a GPL fix database (umu-protonfixes,
Bridgeplay, proton-ge) or a proprietary one. Read the underlying fact from
a public source and write the entry yourself, citing it. Every built-in
fix was produced that way, and `source` is mandatory — the self-test fails
the build on a fix that cites nothing.
