import Foundation

/// Applies the `GameFixCatalog` entries that match a program about to be
/// launched. Called from `AppState.run` immediately before
/// `WineRunner.launch`, on every launch.
///
/// Two kinds of effect, handled differently on purpose:
///   - **Bottle changes** (registry, winetricks, Windows version) are
///     slow and persistent, so they run once per bottle and the fix's id
///     is recorded in `Bottle.appliedFixes`. Every later launch sees the
///     id and skips them.
///   - **Launch effects** (`env`, `launchArgs`) are cheap and are
///     recomputed on every launch from whatever matches *now*. They are
///     never persisted, so deleting a fix from `Paths.fixes` removes its
///     variables on the next launch with nothing to clean up.
///
/// A failing fix never blocks the launch: the program may well run
/// without it (the built-in Steam fix is documented as not fixing the
/// crash it targets, and Steam launches regardless), so the failure is
/// reported and the launch proceeds. The fix is *not* recorded as
/// applied on failure, so the next launch retries it.
enum GameFixService {
    /// Every failure message `prepare` emits through `progress` starts
    /// with this, so a caller that wants to surface only failures (and
    /// not the per-line winetricks chatter) can tell them apart without
    /// `prepare` needing a second return channel.
    static let failurePrefix = "Game fix failed"

    /// One matching fix's advisory, paired with the name of the fix that
    /// carried it so the caller can say which program it is about.
    struct ResolvedAdvisory: Sendable, Hashable {
        let fixName: String
        let advisory: GameFix.Advisory
    }

    /// Applies any not-yet-applied matching fixes to `bottle` and returns
    /// the bottle (with `appliedFixes` updated), the merged per-launch
    /// environment, and the merged extra launch arguments (`nil` when no
    /// matching fix has any). In the common case — no fix matches — this
    /// does one catalog lookup and returns the bottle untouched with an
    /// empty env, so it is cheap and safe to call on every launch.
    ///
    /// `env` is the union over *all* matching fixes whether or not they
    /// were applied this time, later fixes winning on key collisions
    /// (catalog order is sorted by id, so the winner is deterministic).
    /// The caller must hand it to the launched process without writing
    /// it into the bottle.
    ///
    /// `failures` holds one `failurePrefix` message per fix that failed to
    /// apply, in the order they happened. The same text is also sent
    /// through `progress` (so it lands in the run log), but returning it
    /// lets the caller raise ONE combined alert with the advisories: the
    /// alert is a single slot, and reporting each failure from inside
    /// `progress` as it happened meant every one but the last was
    /// overwritten before the user could read it.
    static func prepare(
        exe: URL,
        bottle: Bottle,
        engine: InstalledEngine,
        progress: @escaping @Sendable (String) -> Void
    ) async -> (bottle: Bottle, env: [String: String], args: String?, advisories: [ResolvedAdvisory], failures: [String]) {
        let fixes = GameFixCatalog.matching(exe: exe)
        guard !fixes.isEmpty else { return (bottle, [:], nil, [], []) }

        var updated = bottle
        var env: [String: String] = [:]
        var args: [String] = []
        var advisories: [ResolvedAdvisory] = []
        var failures: [String] = []

        for fix in fixes {
            for (key, value) in fix.env { env[key] = value }
            if let launchArgs = fix.launchArgs, !launchArgs.isEmpty { args.append(launchArgs) }
            // Advisories are collected from every matching fix regardless
            // of whether anything was applied, and are never recorded as
            // "done" — a program that cannot work should say so on every
            // launch, not once and then silently fail forever after.
            if let advisory = fix.advisory {
                advisories.append(ResolvedAdvisory(fixName: fix.name, advisory: advisory))
            }

            // Launch-only fixes have nothing to apply to the bottle, and
            // an already-recorded fix has been applied before.
            guard !fix.isLaunchOnly else { continue }
            guard !(updated.appliedFixes ?? []).contains(fix.id) else { continue }

            progress("Applying fix \"\(fix.name)\" for \(exe.lastPathComponent)…")
            do {
                try await AppTweak.apply(fix.tweak, to: updated, engine: engine, progress: progress)
                // `AppTweak.apply` switches the *prefix* with `winecfg -v`
                // but has no way to tell the model, so mirror it here.
                // Without this the bottle reports its old Windows version
                // in the UI forever: the fix is recorded as applied on the
                // next line, so nothing ever re-runs to correct the drift.
                // (It never mattered while `AppTweaks.steam` — deliberately
                // `windowsVersion: nil` — was the only tweak in existence;
                // it matters the moment a fix file sets one.)
                if let version = fix.windowsVersion { updated.windowsVersion = version }
                updated.appliedFixes = (updated.appliedFixes ?? []) + [fix.id]
            } catch {
                let failure = "\(failurePrefix): \"\(fix.name)\" (launching anyway): \(error.localizedDescription)"
                progress(failure)
                failures.append(failure)
            }
        }

        return (updated, env, args.isEmpty ? nil : args.joined(separator: " "), advisories, failures)
    }
}
