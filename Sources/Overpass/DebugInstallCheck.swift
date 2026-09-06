import Foundation

/// Headless check hook (see DebugCheck.swift for the pattern). Filled in by
/// the QA pass; a no-op until then.
enum DebugInstallCheck {
    static func runIfRequested() {}
}
