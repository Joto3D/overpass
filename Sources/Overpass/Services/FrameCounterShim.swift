import Foundation

/// Locates the frame-counter shim dylib and computes the
/// `DYLD_INSERT_LIBRARIES` value that injects it.
///
/// The dylib is `Shim/fgshim.m`, compiled by `scripts/bundle.sh` into
/// `Overpass.app/Contents/Resources/libfgshim.dylib` as a universal
/// (x86_64 + arm64) image — universal because Wine runs under Rosetta, so
/// the injected image needs an x86_64 slice. It exists **only inside the
/// .app**: a `swift build` dev run has no such resource, and the bundle
/// script deliberately carries on if clang fails. Everything here therefore
/// degrades to "no injection" (nil / unchanged environment) rather than
/// throwing or reporting an error — the toggle is a diagnostic and a
/// missing diagnostic must never break launching a game.
///
/// What the shim does once injected: counts Metal presents and logs
/// `fgshim:` lines to stderr, which `ProcessRunner` already tees into the
/// per-run log file (`LogStore.newLogURL`, under
/// `~/Library/Application Support/Overpass/Logs/`). Counter only — see
/// `PerformanceSettings.frameCounter`.
enum FrameCounterShim {
    /// File name of the dylib inside the app bundle's Resources.
    static let dylibName = "libfgshim.dylib"

    /// The bundled dylib, or nil when it isn't there (dev run, or the
    /// bundle script's best-effort compile failed). `resourceURL` is a
    /// parameter so tests can point at a temp directory; production passes
    /// nothing and gets `Bundle.main.resourceURL`, which is itself nil for
    /// a bare executable with no bundle.
    static func dylibURL(resourceURL: URL? = Bundle.main.resourceURL) -> URL? {
        guard let resourceURL else { return nil }
        let url = resourceURL.appendingPathComponent(dylibName)
        return FileManager.default.isReadableFile(atPath: url.path) ? url : nil
    }

    /// Adds the shim to `env["DYLD_INSERT_LIBRARIES"]` when `enabled` and
    /// `dylib` is non-nil; otherwise leaves `env` exactly as it was (the
    /// variable is not set, not set empty). If something earlier already
    /// set `DYLD_INSERT_LIBRARIES` (a user's custom variable), the shim is
    /// appended after it, colon-separated, so that injection survives.
    static func apply(to env: inout [String: String], enabled: Bool, dylib: URL?) {
        guard enabled, let dylib else { return }
        if let existing = env["DYLD_INSERT_LIBRARIES"], !existing.isEmpty {
            env["DYLD_INSERT_LIBRARIES"] = "\(existing):\(dylib.path)"
        } else {
            env["DYLD_INSERT_LIBRARIES"] = dylib.path
        }
    }
}

// MARK: - What the counter can observe (verified October 2026)
//
// The hook chain in `Shim/fgshim.m` starts at `CAMetalLayer.nextDrawable`
// and only installs the command-buffer and drawable hooks from inside it,
// so a frame is counted only when a Metal layer is actually driving the
// window. That makes this a test of the **D3DMetal** path specifically,
// and `strings` over the engine's own dlls shows how narrow that path is.
// Counting D3DMetal and wined3d symbol references in `gptk-3.0-3`:
//
//     lib/wine/i386-windows/d3d9.dll       0 D3DMetal, 199 wined3d
//     lib/wine/i386-windows/d3d11.dll      0 D3DMetal, 193 wined3d
//     lib/wine/x86_64-windows/d3d9.dll     0 D3DMetal, 199 wined3d
//     lib/wine/x86_64-windows/d3d11.dll   14 D3DMetal,   0 wined3d
//     lib/wine/x86_64-windows/d3d12.dll   16 D3DMetal,   0 wined3d
//
// Two consequences, both of which cost a test run to learn:
//
//   - **D3D9 never reaches Metal**, on either architecture. It is wined3d
//     all the way down, and wined3d renders through macOS OpenGL, which
//     exposes no `CAMetalLayer` to hook. A D3D9 title therefore reports
//     `presents=0` no matter how well it renders.
//   - **Only 64-bit D3D11/D3D12 is translated.** The `i386-windows` dlls
//     are plain wined3d builds, so a 32-bit game gets no D3DMetal even
//     when it asks for D3D11.
//
// Unigine Heaven 4.0 was tried first and is worthless as a target for
// both reasons at once: it is a 32-bit binary (`Unigine_x86.dll`) that
// offers only DX9 and DX11, so neither mode can reach D3DMetal. Its DX9
// mode loads the world and renders through wined3d while reporting
// `presents=0`; its DX11 mode page-faults inside 32-bit wined3d before
// the engine prints its first line.
//
// A usable target must therefore be a **64-bit** game rendering with
// **D3D11 or D3D12**. `presents=0` from anything else says nothing at all
// about whether the hook works.
