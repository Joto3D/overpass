# Overpass — agent notes

Read PLAN.md first. It is the full implementation brief.

- Build: `swift build` (Command Line Tools only — there is NO Xcode on this machine, never use xcodebuild or .xcodeproj).
- Package the app: `scripts/bundle.sh` → `build/Overpass.app` (ad-hoc signed).
- Runtime data: `~/Library/Application Support/Overpass/{Engines,Bottles,Logs,Tools}`.
- No third-party Swift packages. Swift 5.9 language mode, SwiftUI, `@Observable`.
- Wine engines are downloaded at runtime (see `Services/EngineCatalog.swift`); never vendor them.
