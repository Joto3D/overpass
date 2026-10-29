import Foundation

/// One Proton-style per-game fix: the criteria that decide which programs
/// it applies to, plus the bottle changes to make when one of them runs.
///
/// This is the generalisation of `AppTweak`. `AppTweak` models *what* to
/// change (registry, winetricks, Windows version) and already did it well;
/// what it lacked was any way to say *which* program a change belongs to,
/// or to express one without recompiling. A `GameFix` is an `AppTweak`
/// plus matching criteria plus identity, and it round-trips through JSON —
/// so a fix can ship in `GameFixCatalog.builtIn`, or be dropped into
/// `Paths.fixes` as a file, with no code change either way.
///
/// The model is deliberately close to Proton's `protonfixes`: match a
/// game, then apply DLL overrides, winetricks verbs, a Windows version and
/// environment variables before it starts. The parts of protonfixes that
/// assume a Linux host (esync/fsync tuning, Vulkan driver workarounds)
/// have no analogue here and are not modelled.
struct GameFix: Codable, Hashable, Sendable, Identifiable {
    /// Stable identifier, e.g. `"steam"`. Recorded in
    /// `Bottle.appliedFixes` once applied so the (potentially very slow)
    /// winetricks steps run once per bottle rather than once per launch,
    /// and used as the merge key between built-in and user fixes.
    let id: String

    /// Human-readable name, shown in logs: "Steam", "Fallout 3".
    let name: String

    /// Executable basenames this fix matches, compared case-insensitively
    /// against the launched file's last path component — `"steam.exe"`,
    /// not a full path. This is the primary matcher, because Overpass
    /// launches arbitrary `.exe` files rather than Steam app ids.
    var executables: [String] = []

    /// Steam app ids this fix matches. Modelled because it is how
    /// protonfixes keys its data, which makes importing from there
    /// mechanical — but Overpass does not yet track an app id per
    /// launched program, so nothing matches on this today. Populating it
    /// costs nothing and keeps imported fixes lossless.
    var steamAppIDs: [String] = []

    var registry: [AppTweak.RegistryEntry] = []
    var winetricks: [String] = []
    var windowsVersion: WindowsVersion? = nil

    /// Extra environment variables merged into the launch environment.
    /// Unlike the rest of a fix these are *not* persisted into the bottle
    /// — they apply per launch, so removing a fix removes its variables.
    var env: [String: String] = [:]

    /// Extra arguments appended to the program's own launch arguments.
    var launchArgs: String? = nil

    /// A compatibility fact that no bottle setting can change, surfaced to
    /// the user at launch instead of letting the program fail silently.
    ///
    /// This is the half of the database that isn't a fix. Research turns up
    /// as many "this cannot work, here is why, go there instead" findings
    /// as it does recipes, and those are worth just as much to someone
    /// about to spend twenty minutes installing something — but they have
    /// nowhere to live in a model that only knows how to change a bottle.
    var advisory: Advisory? = nil

    struct Advisory: Codable, Hashable, Sendable {
        enum Severity: String, Codable, Hashable, Sendable, CaseIterable {
            /// Known not to run under Wine on macOS at all. Nothing in a
            /// bottle fixes it; the program needs a different approach.
            case wontRun
            /// Runs, but with a limitation worth knowing before starting.
            case degraded
            /// Runs fine — there is simply a better route, almost always
            /// a native macOS build.
            case info
        }

        var severity: Severity
        /// Shown to the user verbatim, so write it for them: what is
        /// wrong, and where to go instead.
        var message: String

        /// Another application that can run this program even though
        /// Overpass cannot, when one has been verified to exist.
        ///
        /// Several "will not run" findings are really "will not run
        /// *through Wine on macOS*". Helldivers 2 is the clearest: Easy
        /// Anti-Cheat rejects Wine, but real Proton inside a Linux VM
        /// works, and FX Steam Launcher packages exactly that. Saying only
        /// "cannot work" strands the user; naming the app that can is the
        /// useful half of the finding.
        ///
        /// Optional so every existing advisory, and every user fix file
        /// written before this field existed, still decodes (see the
        /// hand-written `init(from:)` below). Only entries whose
        /// alternative has actually been researched carry one — the EA app
        /// and Ubisoft Connect deliberately do not, because the research
        /// there points at paid CrossOver, and a launch alert should not
        /// recommend a purchase.
        var alternative: Alternative? = nil

        /// A named macOS application that can stand in for Overpass for
        /// one program, plus what is needed to tell whether it is already
        /// installed and where to get it if not. Detection logic lives in
        /// `AlternativeApp`, which takes an injectable lookup so it can be
        /// tested without any particular app being on the machine.
        struct Alternative: Codable, Hashable, Sendable {
            /// What the user sees: "FX Steam Launcher".
            var name: String
            /// `CFBundleIdentifier`, what `NSWorkspace` is asked about to
            /// find out whether it is installed ("es.fxgam.steamac").
            /// Used instead of a path because users keep apps in
            /// `/Applications`, `~/Applications`, or elsewhere.
            var bundleIdentifier: String
            /// Where to get it if it is not installed. A project page,
            /// not a direct download link, so nothing is fetched on the
            /// user's behalf.
            var url: URL
        }
    }

    /// Why this fix exists and what was actually observed — the same
    /// honesty the rest of the codebase applies to its own findings. A
    /// fix that is known *not* to work should say so here rather than be
    /// deleted, so nobody re-derives it.
    var notes: String? = nil

    /// Where the recipe came from: a CrossOver profile, protonfixes, an
    /// AppleGamingWiki page, or first-hand testing on this machine.
    var source: String? = nil

    /// The bottle-mutating half of this fix, in the form `AppTweak.apply`
    /// already understands. `env` is deliberately absent — it is a launch
    /// concern, applied by `GameFixService`, not a bottle mutation.
    var tweak: AppTweak {
        AppTweak(
            registry: registry,
            winetricks: winetricks,
            windowsVersion: windowsVersion,
            launchArgs: launchArgs
        )
    }

    /// True when this fix applies to `exe`. Matching is on the basename
    /// only and case-insensitive, since Windows paths vary in case and
    /// the same program lands under different install roots.
    func matches(exe: URL, steamAppID: String? = nil) -> Bool {
        let name = exe.lastPathComponent.lowercased()
        if executables.contains(where: { $0.lowercased() == name }) { return true }
        if let steamAppID, steamAppIDs.contains(steamAppID) { return true }
        return false
    }

    /// True when the fix changes nothing about the bottle — only env
    /// vars, launch args and/or an advisory. Such a fix never needs
    /// recording in `Bottle.appliedFixes`, because there is nothing to
    /// avoid redoing (and an advisory should reappear every launch).
    var isLaunchOnly: Bool {
        registry.isEmpty && winetricks.isEmpty && windowsVersion == nil
    }

    /// True when the entry carries nothing at all — no mechanism and no
    /// advisory. Such an entry is dead weight; `DebugSelfTest` fails the
    /// build if a built-in one ever becomes inert.
    var isInert: Bool {
        isLaunchOnly && env.isEmpty && launchArgs == nil && advisory == nil
    }
}

/// Hand-written decoding so a fix file only has to spell out the fields
/// it actually uses.
///
/// Swift's *synthesized* `init(from:)` ignores a property's default value
/// and requires its key to be present, so with synthesized decoding a
/// perfectly reasonable three-field fix — `id`, `name`, `executables` —
/// fails with `keyNotFound` on `steamAppIDs`, and `GameFixCatalog`
/// reports the file as malformed. Every fix file would have to carry
/// every key, including empty arrays it has no use for. That is exactly
/// the friction this database exists to remove, so each optional field is
/// decoded with `decodeIfPresent` and falls back to the same default
/// declared above.
///
/// This lives in an extension rather than the struct body on purpose:
/// declaring any initializer inside the body would suppress the
/// memberwise initializer, which `GameFixCatalog.builtIn` uses.
extension GameFix {
    private enum CodingKeys: String, CodingKey {
        case id, name, executables, steamAppIDs, registry, winetricks
        case windowsVersion, env, launchArgs, advisory, notes, source
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        executables = try c.decodeIfPresent([String].self, forKey: .executables) ?? []
        steamAppIDs = try c.decodeIfPresent([String].self, forKey: .steamAppIDs) ?? []
        registry = try c.decodeIfPresent([AppTweak.RegistryEntry].self, forKey: .registry) ?? []
        winetricks = try c.decodeIfPresent([String].self, forKey: .winetricks) ?? []
        windowsVersion = try c.decodeIfPresent(WindowsVersion.self, forKey: .windowsVersion)
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        launchArgs = try c.decodeIfPresent(String.self, forKey: .launchArgs)
        advisory = try c.decodeIfPresent(Advisory.self, forKey: .advisory)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        source = try c.decodeIfPresent(String.self, forKey: .source)
    }
}

/// Hand-written decoding for `Advisory`, for the same reason as `GameFix`
/// above: synthesized decoding requires every key, so a fix file written
/// before `alternative` existed — or one that simply has no alternative —
/// would be rejected with `keyNotFound`. `alternative` is therefore read
/// with `decodeIfPresent`; `severity` and `message` stay required, as they
/// always were.
///
/// In an extension so the memberwise initializer (used by the catalog's
/// `.init(severity:message:)` calls) survives. Encoding stays synthesized,
/// which omits a nil `alternative` and so leaves existing files' shape
/// unchanged.
extension GameFix.Advisory {
    private enum CodingKeys: String, CodingKey {
        case severity, message, alternative
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        severity = try c.decode(Severity.self, forKey: .severity)
        message = try c.decode(String.self, forKey: .message)
        alternative = try c.decodeIfPresent(Alternative.self, forKey: .alternative)
    }
}
