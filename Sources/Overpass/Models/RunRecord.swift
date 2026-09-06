import Foundation

/// One launch of an executable inside a bottle. Kept in memory by
/// `AppState` while the app runs; the log file on disk is the durable part.
struct RunRecord: Identifiable, Hashable, Sendable {
    let id: UUID
    let bottleID: UUID
    let exePath: String
    let startedAt: Date
    let logURL: URL
    /// pid of the launcher process (`wine64 start ...`), if still known.
    var pid: Int32?
    var isRunning: Bool

    init(bottleID: UUID, exePath: String, logURL: URL, pid: Int32?) {
        self.id = UUID()
        self.bottleID = bottleID
        self.exePath = exePath
        self.startedAt = Date()
        self.logURL = logURL
        self.pid = pid
        self.isRunning = true
    }
}
