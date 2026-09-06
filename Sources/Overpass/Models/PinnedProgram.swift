import Foundation

/// A launchable program inside a bottle, either discovered by
/// `ProgramScanner` or added by the user.
struct PinnedProgram: Identifiable, Codable, Hashable, Sendable {
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

    init(
        id: UUID = UUID(),
        name: String,
        exePath: String,
        args: String = "",
        isUserAdded: Bool = false,
        isSystem: Bool = false,
        isHelper: Bool = false,
        launchURL: String? = nil
    ) {
        self.id = id
        self.name = name
        self.exePath = exePath
        self.args = args
        self.isUserAdded = isUserAdded
        self.isSystem = isSystem
        self.isHelper = isHelper
        self.launchURL = launchURL
    }

    // Custom decoding so that `metadata.json` files written before
    // `isSystem`/`isHelper`/`launchURL` existed still decode: missing keys
    // default to `false`/`false`/`nil` instead of failing the decode.
    // (`encode(to:)` is left to the compiler-synthesized Encodable
    // conformance, which covers all stored properties as normal.)
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
    }
}
