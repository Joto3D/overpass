import Foundation

/// A launchable program inside a bottle, either discovered by
/// `ProgramScanner` or added by the user.
struct PinnedProgram: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    /// Absolute macOS path to the .exe inside drive_c (not a Windows path),
    /// so it can be passed straight to `wine start /unix`.
    var exePath: String
    var args: String
    var isUserAdded: Bool

    init(id: UUID = UUID(), name: String, exePath: String, args: String = "", isUserAdded: Bool = false) {
        self.id = id
        self.name = name
        self.exePath = exePath
        self.args = args
        self.isUserAdded = isUserAdded
    }
}
