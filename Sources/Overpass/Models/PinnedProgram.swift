import Foundation

/// A launchable program inside a bottle, either discovered by
/// `ProgramScanner` or added by the user.
struct PinnedProgram: Identifiable, Codable, Hashable, Sendable {
    /// How this pin came to exist — drives default visibility in
    /// `ProgramsGridView` (CrossOver/Heroic-style: a bottle's Programs list
    /// defaults to showing only what a Windows Start Menu would list, plus
    /// anything the app itself knows about or the user asked for). `nil`
    /// on a pin decoded from a `metadata.json` written before this field
    /// existed; treated the same as `.discovered` for visibility until the
    /// next rescan re-derives it (see `ProgramScanner.merge`).
    enum Origin: String, Codable, Sendable {
        /// A Start Menu or Desktop `.lnk`/`.url` shortcut points at this
        /// program (or, for a URL-target pin, is where the URL came from).
        case shortcut
        /// No shortcut backs it, but its path matches one of
        /// `AppCatalog`'s `launchExeHints` (Steam, 7-Zip, …) — either
        /// because `AppInstaller` just installed it, or because a scan
        /// simply found it already on disk.
        case catalogApp
        /// The user added it explicitly ("Add program…"), or ran it once
        /// and it got pinned on the fly. Mirrors `isUserAdded`.
        case user
        /// Found by walking Program Files with nothing else vouching for
        /// it: no shortcut, no catalog match, not user-added. Hidden by
        /// default so a Programs list doesn't drown in installer
        /// scaffolding and helper binaries a Start Menu would never show.
        case discovered
    }

    var id: UUID
    var name: String
    /// Absolute macOS path to the .exe inside drive_c (not a Windows path),
    /// so it can be passed straight to `wine start /unix`. For a
    /// URL-target shortcut (see `launchURL`) this holds the raw URL string
    /// instead (e.g. a `steam://rungameid/…` shortcut has no exe on disk).
    var exePath: String
    var args: String
    var isUserAdded: Bool
    /// True for programs the scanner classified as part of Wine's/Windows'
    /// own bundled software (Internet Explorer, Windows Media Player,
    /// WordPad/Notepad under "Windows NT", anything under `drive_c/windows`,
    /// …) rather than something the user installed. Still returned by
    /// `ProgramScanner.scan(bottle:)` — callers decide whether to show
    /// these (e.g. under a collapsed "System" section).
    var isSystem: Bool
    /// True for programs the scanner judged to be scaffolding for another
    /// pin rather than something a user would launch directly: an
    /// installer/updater/uninstaller by name (`GUP`, `vcredist`, …), or an
    /// `.exe` that sits alongside a `.lnk`-targeted program in the same
    /// folder without itself being targeted by any shortcut (`7z.exe` /
    /// `7zG.exe` next to 7-Zip's `7zFM.exe`). Still returned by the
    /// scanner — a "Show all" toggle can reveal these.
    var isHelper: Bool
    /// For a shortcut whose target isn't a Windows path but a URL — a
    /// Steam/GOG/Epic desktop shortcut like `steam://rungameid/12345` —
    /// the raw URL to hand to `wine start <url>`. `nil` for ordinary
    /// exe-backed pins, where `exePath` is the thing to launch.
    var launchURL: String?
    /// See `Origin`. Optional/defaulted so a pre-existing `metadata.json`
    /// keeps decoding; `ProgramScanner` derives it for every pin on the
    /// next rescan (see `ProgramsGridView.migrateIfNeeded`).
    var origin: Origin?

    init(
        id: UUID = UUID(),
        name: String,
        exePath: String,
        args: String = "",
        isUserAdded: Bool = false,
        isSystem: Bool = false,
        isHelper: Bool = false,
        launchURL: String? = nil,
        origin: Origin? = nil
    ) {
        self.id = id
        self.name = name
        self.exePath = exePath
        self.args = args
        self.isUserAdded = isUserAdded
        self.isSystem = isSystem
        self.isHelper = isHelper
        self.launchURL = launchURL
        self.origin = origin
    }

    // Custom decoding so that `metadata.json` files written before
    // `isSystem`/`isHelper`/`launchURL`/`origin` existed still decode:
    // missing keys default to `false`/`false`/`nil`/`nil` instead of
    // failing the decode. (`encode(to:)` is left to the
    // compiler-synthesized Encodable conformance, which covers all stored
    // properties as normal.)
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        exePath = try container.decode(String.self, forKey: .exePath)
        args = try container.decodeIfPresent(String.self, forKey: .args) ?? ""
        isUserAdded = try container.decodeIfPresent(Bool.self, forKey: .isUserAdded) ?? false
        isSystem = try container.decodeIfPresent(Bool.self, forKey: .isSystem) ?? false
        isHelper = try container.decodeIfPresent(Bool.self, forKey: .isHelper) ?? false
        launchURL = try container.decodeIfPresent(String.self, forKey: .launchURL)
        origin = try container.decodeIfPresent(Origin.self, forKey: .origin)
    }
}
