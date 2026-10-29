import Foundation
import AppKit

/// Works out what to tell the user about an advisory's `alternative`:
/// whether that app is installed on this Mac, and the one extra sentence
/// that goes on the end of the advisory's message.
///
/// A separate helper, rather than code in the launch path, so the logic
/// can be unit-tested. The only thing that touches the real machine is the
/// `lookup` closure, which defaults to `NSWorkspace` and which the
/// self-test replaces with a stub — so the installed and not-installed
/// wordings are both testable on a machine that has FX Steam Launcher
/// installed (this one) and on one that does not.
///
/// Decisions recorded here:
///
/// - **Detection by bundle identifier**, via
///   `NSWorkspace.urlForApplication(withBundleIdentifier:)`, which asks
///   Launch Services and so finds the app wherever it lives. Verified on
///   this machine: FX Steam Launcher resolves from `es.fxgam.steamac`.
/// - **One sentence only.** The advisory messages are already long and
///   share a single alert slot with fix failures; this adds exactly one
///   sentence, in one of two forms.
/// - **Text only, no button.** `AppState.report` takes a plain string and
///   the alert has no action slot. Giving it one is a larger change than
///   this feature justifies, so the not-installed case prints the URL and
///   the installed case names the app, and the user acts on it themselves.
/// - **Nothing is opened, downloaded or launched** on the user's behalf.
enum AlternativeApp {
    /// Resolves a bundle identifier to the app's location, or `nil` if no
    /// such app is installed. Injectable; see the type comment.
    typealias Lookup = (_ bundleIdentifier: String) -> URL?

    /// The real lookup: Launch Services, via `NSWorkspace`.
    static let systemLookup: Lookup = { bundleIdentifier in
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    /// Where `alternative` is installed, or `nil` if it is not.
    static func installedURL(of alternative: GameFix.Advisory.Alternative, lookup: Lookup = systemLookup) -> URL? {
        lookup(alternative.bundleIdentifier)
    }

    /// The single sentence appended to an advisory message:
    /// - installed: "FX Steam Launcher can run it and is installed on this Mac — open that instead."
    /// - missing:   "FX Steam Launcher can run it; it is not installed, and is available at <url>."
    static func sentence(for alternative: GameFix.Advisory.Alternative, lookup: Lookup = systemLookup) -> String {
        if installedURL(of: alternative, lookup: lookup) != nil {
            return "\(alternative.name) can run it and is installed on this Mac — open that instead."
        }
        return "\(alternative.name) can run it; it is not installed, and is available at \(alternative.url.absoluteString)."
    }

    /// The advisory's message exactly as written, plus the alternative's
    /// sentence when it has one. An advisory without an alternative comes
    /// back byte-for-byte unchanged, which is what keeps every other
    /// entry's text untouched.
    static func message(for advisory: GameFix.Advisory, lookup: Lookup = systemLookup) -> String {
        guard let alternative = advisory.alternative else { return advisory.message }
        return advisory.message + " " + sentence(for: alternative, lookup: lookup)
    }
}
