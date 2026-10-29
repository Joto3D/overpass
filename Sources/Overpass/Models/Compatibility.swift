import Foundation

/// How well a program is expected to run under Overpass, derived from the
/// fix database rather than from telemetry.
///
/// This is the at-a-glance rating shown on a game's cover, in the spirit
/// of ProtonDB's medals or FX Steam Launcher's "Runs well / Playable with
/// issues / Unplayable / Does not start". The shape is borrowed; the data
/// is not, and could not be:
///
/// - **ProtonDB** rates Proton on Linux. Overpass is Wine on macOS, and
///   today's clearest example of the gap is Easy Anti-Cheat, which clears
///   Proton on Linux and rejects Wine on macOS. A Platinum rating there
///   can mean "will not start" here.
/// - **FX Steam Launcher's statistics page** rates real Proton inside a
///   Linux VM. Same objection, same direction.
///
/// So every rating here comes from `GameFixCatalog` — entries written by
/// hand, each carrying a `source`. The honest consequence is that the
/// common case is `.untested`: the catalog holds a few dozen entries and
/// there are tens of thousands of Windows games. `.untested` is a real
/// answer meaning "nobody has written this down", and it must never be
/// dressed up as "works".
///
/// Deliberately UI-free. `label`, `detail` and `systemImage` live here so
/// there is one source of truth for the words, but the colour of a badge
/// is a theme decision and stays in the view layer.
enum Compatibility: String, Codable, Hashable, Sendable, CaseIterable {
    /// An advisory says no bottle setting can make this work.
    case wontRun
    /// Runs, with a limitation worth knowing before starting.
    case limited
    /// Runs, but there is a better route — almost always a native build.
    case nativeBetter
    /// A documented fix applies, and Overpass will apply it for you.
    case worksWithFix
    /// Nothing is written down about this program. Not a prediction.
    case untested

    /// Worst first. Used to pick a single rating when several catalog
    /// entries match one program: a "will not run" finding must win over a
    /// cheerful one, never the other way round.
    private var severityRank: Int {
        switch self {
        case .wontRun:      return 0
        case .limited:      return 1
        case .nativeBetter: return 2
        case .worksWithFix: return 3
        case .untested:     return 4
        }
    }

    /// Short enough for a badge on a cover.
    var label: String {
        switch self {
        case .wontRun:      return "Won't run"
        case .limited:      return "Limited"
        case .nativeBetter: return "Native build"
        case .worksWithFix: return "Fix applied"
        case .untested:     return "Untested"
        }
    }

    /// One sentence for a tooltip or a detail row. Written for the user.
    var detail: String {
        switch self {
        case .wontRun:
            return "Known not to work under Wine on macOS. Nothing in a bottle changes this."
        case .limited:
            return "Runs, with a documented limitation worth knowing about first."
        case .nativeBetter:
            return "Runs, but there is a better route — usually a native macOS build."
        case .worksWithFix:
            return "Overpass has a documented fix for this and applies it at launch."
        case .untested:
            return "No entry in the fix database. That means nobody has written this one down, not that it works."
        }
    }

    var systemImage: String {
        switch self {
        case .wontRun:      return "xmark.octagon.fill"
        case .limited:      return "exclamationmark.triangle.fill"
        case .nativeBetter: return "apple.logo"
        case .worksWithFix: return "wrench.adjustable.fill"
        case .untested:     return "questionmark.circle"
        }
    }

    /// True when this rating is worth putting in front of the user before
    /// they spend twenty minutes installing something. `.untested` is not:
    /// it would mark almost every game and so would say nothing.
    var isNoteworthy: Bool { self != .untested }

    // MARK: - Derivation

    /// The rating for one catalog entry.
    static func of(_ fix: GameFix) -> Compatibility {
        switch fix.advisory?.severity {
        case .wontRun:  return .wontRun
        case .degraded: return .limited
        case .info:     return .nativeBetter
        case nil:       return fix.isInert ? .untested : .worksWithFix
        }
    }

    /// The rating for a discovered game.
    ///
    /// **The Steam trap this exists to avoid.** `InstalledGame.launchExe`
    /// for a Steam title is Steam's own `Steam.exe`, which then
    /// `-applaunch`es the game — the game's binary is never named. Matching
    /// a Steam game by its executable would therefore match the catalog's
    /// `steam` entry for *every* Steam game in the library, and paint the
    /// whole grid with one rating that is really about the Steam client.
    /// So a Steam game is matched on its app id alone, and a game whose
    /// app id is unknown is `.untested` rather than guessed at.
    ///
    /// GOG and Epic titles have no such indirection — `launchExe` is the
    /// game — so they match by executable as usual.
    static func forGame(_ game: InstalledGame, in catalog: [GameFix] = GameFixCatalog.all) -> Compatibility {
        let matches: [GameFix]
        switch game.store {
        case .steam:
            guard let appID = game.appID else { return .untested }
            matches = catalog.filter { $0.steamAppIDs.contains(appID) }
        case .gog, .epic:
            guard let exe = game.launchExe else { return .untested }
            matches = catalog.filter { $0.matches(exe: exe) }
        }
        return worst(of: matches)
    }

    /// The rating for an arbitrary executable, for the Programs list where
    /// there is no store and no app id — only a path the user picked.
    static func forExecutable(_ exe: URL, in catalog: [GameFix] = GameFixCatalog.all) -> Compatibility {
        worst(of: catalog.filter { $0.matches(exe: exe) })
    }

    /// The most severe rating among `fixes`, or `.untested` when none
    /// matched. Severity wins over order so the answer does not depend on
    /// how the catalog happens to be sorted.
    private static func worst(of fixes: [GameFix]) -> Compatibility {
        fixes.map(of).min { $0.severityRank < $1.severityRank } ?? .untested
    }
}
