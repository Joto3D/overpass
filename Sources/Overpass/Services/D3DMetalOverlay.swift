import Foundation

/// Errors surfaced by `D3DMetalOverlay`.
enum D3DMetalOverlayError: LocalizedError {
    case noSourceEngine
    case sourceIncomplete(String)
    case copyFailed(String)

    var errorDescription: String? {
        switch self {
        case .noSourceEngine:
            return "D3DMetal overlay needs a Game Porting Toolkit engine installed to copy its D3DMetal files from."
        case .sourceIncomplete(let detail):
            return "The installed GPTK engine is missing D3DMetal files: \(detail)"
        case .copyFailed(let detail):
            return "Failed to install the D3DMetal overlay: \(detail)"
        }
    }
}

/// Layers Apple's D3DMetal (DirectX 11/12 → Metal) — normally exclusive to
/// the Game Porting Toolkit engine — onto a **Wine-staging** bottle, by
/// copying D3DMetal's builtin-DLL/unixlib pair out of an installed GPTK
/// engine into a per-bottle overlay directory and pointing Wine's builtin
/// DLL search path at it. `WineRunner.environment(for:engine:)` does the
/// actual wiring at launch time; this type only manages the overlay's
/// files.
///
/// ## Why this should work (verified September 2026, this machine)
///
/// CrossOver 26.3 runs Steam and other fast DirectX titles by combining a
/// **modern Wine base** (not Apple's old Wine 7.7 tree) with Apple's
/// D3DMetal libraries layered on top as an overlay:
///
/// - `CrossOver.app/.../lib64/apple_gptk/` contains
///   `external/{D3DMetal.framework, libd3dshared.dylib}` and
///   `wine/x86_64-windows/{atidxx64,d3d10,d3d11,d3d12,dxgi,nvapi64,nvngx}.dll`
///   plus matching `wine/x86_64-unix/*.so` files.
/// - Every `x86_64-unix/*.so` there is a 33-byte **symlink** to
///   `../../external/libd3dshared.dylib` — the PE dll is a thin stub, and
///   the actual Metal translation lives in `libd3dshared.dylib`, invoked
///   through Wine's builtin-dll/unixlib pairing mechanism.
/// - Those files are byte-identical (SHA-256 verified) to the ones Overpass
///   already installs at `gptk-3.0-3`'s
///   `.../wine/lib/{external/*, wine/x86_64-windows/{d3d10,d3d11,d3d12,dxgi,...}.dll, wine/x86_64-unix/*.so}`.
///   D3DMetal version 3.0 in both.
/// - CrossOver's `bin/wine` unconditionally points
///   `CX_APPLEGPTK_LIBD3DSHARED_PATH` at that `libd3dshared.dylib`, and
///   enables the overlay per-app with `D3DMetal=1`.
/// - Overpass's Wine-staging 11.16 engine ships **no** `x86_64-unix/*.so`
///   for any `d3d*`/`dxgi` name at all (only `wined3d.so`) — so nothing
///   here shadows anything the engine already provides.
///
/// Since CrossOver loads these exact D3DMetal binaries on a Wine 10.x
/// base, the unixlib ABI is not tied to Apple's Wine 7.7 fork — so a Wine
/// Staging 11.16 base should be able to load them too, via the same
/// `WINEDLLPATH` builtin-dll search mechanism CrossOver's wrapper script
/// uses (`wine(1)`: "a colon-separated list of directories to add to the
/// standard PE and Unix dll search path when loading builtin dlls").
///
/// ## What actually happens (tested September 2026, this machine)
///
/// The bet above does **not** pay off — but not for the ABI reason
/// anticipated. Two mechanisms were tried against the real "Steam"
/// bottle (Wine Staging 11.16), each proven with `WINEDEBUG=+loaddll,
/// +module` and a plain `wine regsvr32 <name>.dll`:
///
/// 1. **`WINEDLLPATH` + `WINEDLLOVERRIDES=...=b`** (what `WineRunner`
///    implements below). Loading `d3d11.dll`/`dxgi.dll` this way
///    resolves to the engine's own stock (417792/208896-byte) copies,
///    not the overlay's (106496/86016-byte) ones — `WINEDLLPATH`'s
///    extra directory is never consulted by this Wine 11.16 build's
///    builtin-dll resolver. Proven conclusively by testing a name the
///    base engine does *not* ship at all, `atidxx64.dll` (present only
///    in the overlay): it fails outright —
///    `warn:module:load_dll Failed to load module L"atidxx64.dll";
///    status=c0000135` (`STATUS_DLL_NOT_FOUND`) — so there is no
///    directory-ordering fix available from environment variables alone;
///    the base engine's own compiled-in `x86_64-windows` directory is
///    the *only* place this Wine build's `find_builtin_dll` looks.
/// 2. **Copy into `system32` + `WINEDLLOVERRIDES=...=n`** (the
///    DXVK-proven fallback `DXVKInstaller` uses for genuinely
///    self-contained native DLLs). This does not work for D3DMetal's
///    DLLs either, and fails a step earlier than expected: Wine refuses
///    to load them as "native" at all —
///    `warn:module:load_dll Failed to load module L"d3d11.dll";
///    status=c0000135` — with no file-mapping attempt logged beforehand,
///    unlike the successful builtin case. These are Wine-style
///    builtin/unixlib-paired DLLs (thin PE stub, real implementation in
///    the companion `.so`), not standalone native PE binaries like
///    DXVK's; Wine's native-DLL path evidently doesn't accept that
///    shape, so this fallback was **not** wired into `WineRunner` —
///    doing so would only replace a working stock `d3d11.dll` with one
///    that fails to load at all, a strict regression for zero benefit.
///
/// ## Re-verified October 2026 against newer everything — still fails
///
/// The September result above was obtained on Wine Staging **11.16** with
/// the **GPTK 3.0** overlay, so it was fair to ask whether either moving
/// on would change it. Both had: Overpass now ships Wine Staging 11.20,
/// and GPTK **4.0b3** exists (it is what Bridgeplay pairs with WineCX,
/// and its `libd3dshared.dylib` is 250,672 bytes against GPTK 3.0's
/// 95,952 — it carries the DLSS-G frame-generation path, `ngx::
/// FrameGenerator` onto `MDEFrameInterpolator`, which is the reason to
/// want it).
///
/// Tested 2026-10-29 on `wine-11.20 (Staging)`, GPTK 4.0b3's seven-dll
/// overlay staged with its `x86_64-unix` symlinks resolving and
/// `CX_APPLEGPTK_LIBD3DSHARED_PATH`/`D3DMetal=1` set exactly as
/// CrossOver's wrapper does. The discriminator this time was
/// `nvngx-on-metalfx.dll`, which 11.20 does not ship at all:
///
///     warn:module:load_dll Failed to load module
///     L"nvngx-on-metalfx.dll"; status=c0000135
///
/// and the resolver printed the path it actually searched —
/// `C:\windows\system32;C:\windows\system;C:\windows;.;…` — with the
/// `WINEDLLPATH` directory **absent from it entirely**. `d3d11.dll`
/// meanwhile loaded the engine's own stock builtin as before.
///
/// So this is not a version-skew problem that a newer Wine or a newer
/// GPTK fixes. Upstream Wine's builtin resolver does not consult
/// `WINEDLLPATH` for these names, full stop; CrossOver's Wine carries its
/// own support for loading this overlay, which is why WineCX works and
/// Wine-staging does not *through `WINEDLLPATH`*.
///
/// **CORRECTED (29 October 2026).** The sentence that used to stand here
/// — that frame generation via GPTK 4 requires a WineCX-class engine and
/// not just the GPTK 4 files — was too strong. It holds for
/// `WINEDLLPATH`, and every observation above it still stands. But
/// copying the redist *into the engine's own `lib/`*, rather than
/// pointing at it from outside, does get the files loaded on
/// wine-staging 11.20: `d3d12`, `d3d12core`, `dxgi` and
/// `nvngx-on-metalfx` map as builtin, and `vmmap` shows
/// `libd3dshared.dylib` and `libdxccontainer.dylib` mapped from that
/// clone's `lib/external`. `GPTKRedist` and `EngineManager` now build
/// such a clone from a user-supplied GPTK 4 download.
///
/// That is *loading*, not *working*: `regsvr32 d3d11.dll` on the result
/// hangs for an undiagnosed reason, and no D3D11 or D3D12 game has been
/// rendered on it. Treat a derived engine as experimental. No public
/// prebuilt WineCX exists either way — Gcenx's homebrew cask is gone,
/// `CodeWeavers/wine` on GitHub 404s, and the build Bridgeplay ships is
/// one it compiled itself (`org.winehq.wine.notproton.winecx`).
///
/// So: `install`/`uninstall` here still do real, useful work (staging
/// the files, `isInstalled` reporting correctly), and `WineRunner`'s
/// env wiring is not harmful — with nothing more than an unconsulted
/// `WINEDLLPATH` added, the base engine's own `d3d11.dll`/`dxgi.dll`
/// keep loading exactly as before, so toggling this on does not regress
/// a Wine-staging bottle's existing (wined3d/DXVK) DirectX support. It
/// just doesn't add D3DMetal to it. See `DebugOverlayCheck` for the
/// load-time evidence this doc comment is based on, and the top-level
/// task report for the full log excerpts.
enum D3DMetalOverlay {
    /// The exact D3DMetal PE dll basenames (without extension) CrossOver
    /// ships in `apple_gptk/wine/x86_64-windows/` — deliberately a subset
    /// of what a GPTK engine itself contains (GPTK also has `d3d10_1`,
    /// `d3d10core`, `d3d9`, `nvngx-on-metalfx`, none of which CrossOver's
    /// overlay includes), so `install` mirrors CrossOver's set rather than
    /// copying everything GPTK has.
    static let dllBaseNames = ["atidxx64", "d3d10", "d3d11", "d3d12", "dxgi", "nvapi64", "nvngx"]

    /// Name of the per-bottle overlay directory, created directly inside
    /// the bottle's `WINEPREFIX` (a sibling of `drive_c`, `system.reg`,
    /// ...) rather than under `drive_c` — it holds macOS-side Wine
    /// builtin dlls/unixlibs, not anything Windows-side should see.
    private static let overlayDirName = "overpass-d3dmetal"

    // MARK: - Paths

    static func overlayDir(for bottle: Bottle) -> URL {
        bottle.prefixDir.appendingPathComponent(overlayDirName, isDirectory: true)
    }

    static func overlayWineDir(for bottle: Bottle) -> URL {
        overlayDir(for: bottle).appendingPathComponent("lib/wine", isDirectory: true)
    }

    static func overlayWindowsDir(for bottle: Bottle) -> URL {
        overlayWineDir(for: bottle).appendingPathComponent("x86_64-windows", isDirectory: true)
    }

    static func overlayUnixDir(for bottle: Bottle) -> URL {
        overlayWineDir(for: bottle).appendingPathComponent("x86_64-unix", isDirectory: true)
    }

    static func overlayExternalDir(for bottle: Bottle) -> URL {
        overlayDir(for: bottle).appendingPathComponent("lib/external", isDirectory: true)
    }

    static func overlayLibD3DShared(for bottle: Bottle) -> URL {
        overlayExternalDir(for: bottle).appendingPathComponent("libd3dshared.dylib")
    }

    // MARK: - Availability

    /// The installed GPTK engine `install` would copy D3DMetal from —
    /// the first `.gptk` engine in `engines` that actually has the files
    /// (`external/libd3dshared.dylib` plus at least `d3d11.dll`/`.so`),
    /// so a half-broken or unusually old GPTK install doesn't get offered
    /// as a source.
    static func sourceEngine(from engines: [InstalledEngine]) -> InstalledEngine? {
        engines.first { engine in
            guard engine.kind == .gptk else { return false }
            let fm = FileManager.default
            let external = engine.libDir.appendingPathComponent("external", isDirectory: true)
            let dylib = external.appendingPathComponent("libd3dshared.dylib")
            let windowsDir = engine.libDir.appendingPathComponent("wine/x86_64-windows", isDirectory: true)
            let unixDir = engine.libDir.appendingPathComponent("wine/x86_64-unix", isDirectory: true)
            guard fm.fileExists(atPath: dylib.path) else { return false }
            guard fm.fileExists(atPath: windowsDir.appendingPathComponent("d3d11.dll").path) else { return false }
            guard fm.fileExists(atPath: unixDir.appendingPathComponent("d3d11.so").path) else { return false }
            return true
        }
    }

    static func isAvailable(engines: [InstalledEngine]) -> Bool {
        sourceEngine(from: engines) != nil
    }

    /// True once `install` has successfully populated the bottle's
    /// overlay directory (checked by looking for the one file every
    /// install run must produce, `lib/external/libd3dshared.dylib`).
    static func isInstalled(in bottle: Bottle) -> Bool {
        FileManager.default.fileExists(atPath: overlayLibD3DShared(for: bottle).path)
    }

    // MARK: - Install

    /// Copies D3DMetal's PE dlls, their unixlib companions, and the
    /// `external` support files out of `gptk`'s tree into
    /// `<bottle.prefixDir>/overpass-d3dmetal/lib/{wine/x86_64-windows,
    /// wine/x86_64-unix, external}`, then strips quarantine from the
    /// copy. Synchronous (no network, no long-running subprocess beyond a
    /// couple of `ditto`/`xattr` calls) so it can be called from either a
    /// UI `Task` or the headless `--check-overlay` entry point.
    ///
    /// Re-running `install` (e.g. after a GPTK engine update) simply
    /// replaces the overlay directory outright — there's no per-file
    /// backup/restore to manage the way `DXVKInstaller` needs, because
    /// nothing outside `overpass-d3dmetal/` is ever touched.
    static func install(
        into bottle: Bottle,
        from gptk: InstalledEngine,
        progress: @escaping @Sendable (String) -> Void
    ) throws {
        let fm = FileManager.default
        let sourceExternal = gptk.libDir.appendingPathComponent("external", isDirectory: true)
        let sourceWindows = gptk.libDir.appendingPathComponent("wine/x86_64-windows", isDirectory: true)
        let sourceUnix = gptk.libDir.appendingPathComponent("wine/x86_64-unix", isDirectory: true)
        let sourceDylib = sourceExternal.appendingPathComponent("libd3dshared.dylib")

        guard fm.fileExists(atPath: sourceDylib.path) else {
            throw D3DMetalOverlayError.sourceIncomplete("libd3dshared.dylib not found at \(sourceDylib.path)")
        }

        let overlay = overlayDir(for: bottle)
        let destWindows = overlayWindowsDir(for: bottle)
        let destUnix = overlayUnixDir(for: bottle)
        let destExternal = overlayExternalDir(for: bottle)

        progress("Preparing overlay directory…")
        if fm.fileExists(atPath: overlay.path) {
            try fm.removeItem(at: overlay)
        }
        try fm.createDirectory(at: destWindows, withIntermediateDirectories: true)
        try fm.createDirectory(at: destUnix, withIntermediateDirectories: true)
        try fm.createDirectory(at: destExternal.deletingLastPathComponent(), withIntermediateDirectories: true)

        progress("Copying D3DMetal support libraries…")
        try ditto(from: sourceExternal, to: destExternal)

        progress("Copying D3DMetal DLLs…")
        var copiedAny = false
        for base in dllBaseNames {
            let sourceDLL = sourceWindows.appendingPathComponent("\(base).dll")
            guard fm.fileExists(atPath: sourceDLL.path) else { continue }
            let destDLL = destWindows.appendingPathComponent("\(base).dll")
            try ditto(from: sourceDLL, to: destDLL)
            copiedAny = true

            // Recreate the unixlib symlink ourselves rather than copying
            // whatever's at `sourceUnix/<base>.so` — that file is already
            // just a 33-byte relative symlink to
            // `../../external/libd3dshared.dylib`, and our overlay has the
            // exact same `lib/wine/x86_64-unix` → `lib/external` shape as
            // the GPTK tree it came from, so a freshly created symlink
            // with that same relative target resolves correctly here too.
            let destSO = destUnix.appendingPathComponent("\(base).so")
            if fm.fileExists(atPath: sourceUnix.appendingPathComponent("\(base).so").path) {
                try? fm.removeItem(at: destSO)
                try fm.createSymbolicLink(atPath: destSO.path, withDestinationPath: "../../external/libd3dshared.dylib")
            }
        }
        guard copiedAny else {
            try? fm.removeItem(at: overlay)
            throw D3DMetalOverlayError.sourceIncomplete("none of \(dllBaseNames.joined(separator: ", ")) were found under \(sourceWindows.path)")
        }

        progress("Removing quarantine flag…")
        _ = try? runSync("/usr/bin/xattr", ["-dr", "com.apple.quarantine", overlay.path])

        progress("D3DMetal overlay installed.")
    }

    // MARK: - Uninstall

    /// Removes the whole overlay directory. Safe to call even when it
    /// doesn't exist.
    static func uninstall(from bottle: Bottle) throws {
        let overlay = overlayDir(for: bottle)
        guard FileManager.default.fileExists(atPath: overlay.path) else { return }
        try FileManager.default.removeItem(at: overlay)
    }

    // MARK: - Helpers

    /// `ditto src dst` — used instead of `FileManager.copyItem` so a
    /// `.framework` bundle (with its own internal symlinks, e.g.
    /// `Versions/Current -> A`) is reproduced correctly; `copyItem`
    /// follows symlinks it encounters inside a directory tree, `ditto`
    /// (like `cp -R`) preserves them.
    private static func ditto(from source: URL, to destination: URL) throws {
        let result = try runSync("/usr/bin/ditto", [source.path, destination.path])
        guard result.status == 0 else {
            throw D3DMetalOverlayError.copyFailed(result.stderr.isEmpty ? "ditto exited with status \(result.status)" : result.stderr)
        }
    }

    /// Minimal synchronous process runner — `install`/`uninstall` are
    /// deliberately synchronous (no `async`) so they're trivial to call
    /// from `--check-overlay` without a run-loop pump, and every command
    /// here (`ditto` on a few small files, `xattr -dr`) finishes in well
    /// under a second.
    @discardableResult
    private static func runSync(_ executable: String, _ arguments: [String]) throws -> (status: Int32, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()
        try process.run()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: errData, encoding: .utf8) ?? "")
    }
}
