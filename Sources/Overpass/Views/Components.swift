import SwiftUI

/// Small view/formatting helpers shared by the calmer redesign of the
/// sidebar, bottle header, and Programs list. Kept separate from
/// `Theme.swift` (read-only for this pass) so the design-system file stays
/// untouched while these thin, feature-specific helpers live alongside the
/// views that use them.

// MARK: - Engine short name

/// A compact label for an installed engine, used wherever space is tight
/// (sidebar secondary line, bottle header subtitle): "GPTK" for Game
/// Porting Toolkit, "Wine 11.16" for Wine Staging — the version number
/// without the "Staging" qualifier.
func engineShortName(_ engine: InstalledEngine?) -> String {
    guard let engine else { return "Engine missing" }
    switch engine.kind {
    case .gptk: return "GPTK"
    case .wineStaging: return "Wine \(engine.version)"
    }
}

// MARK: - Engine trade-off captions

/// The single most consequential choice in the app, stated the same way
/// everywhere it's made: the Engines screen, the New Bottle and Import
/// Bottle sheets, and the setup wizard. Two variants —
/// `engineTradeoffCaption` is a self-contained one-liner for a picker that
/// has no other description nearby; `engineCaveat` is just the "what can go
/// wrong" half, for the Engines screen where `EngineRelease.notes` already
/// covers what the engine *is*.
func engineTradeoffCaption(for kind: EngineKind) -> String {
    switch kind {
    case .gptk:
        return "Apple's DirectX-to-Metal translation, best for games — but based on an older Wine, so some modern apps, including the Steam client, can fail to run."
    case .wineStaging:
        return "Current Wine, better app compatibility — DirectX goes through DXVK, which is usually slower for games."
    }
}

func engineCaveat(for kind: EngineKind) -> String {
    switch kind {
    case .gptk:
        return "Based on an older Wine, so some modern apps — including the Steam client — can fail to run."
    case .wineStaging:
        return "DirectX goes through DXVK instead of D3DMetal, which is usually slower for games."
    }
}

// MARK: - Path formatting

/// `pin.exePath` relative to the bottle's `drive_c`, for a quieter
/// secondary line in the Programs list than the full macOS path. Falls
/// back to the original path if it isn't actually under `drive_c` (e.g. a
/// URL-target shortcut, where `exePath` may be empty or unrelated).
func pathRelativeToDriveC(_ path: String, bottle: Bottle) -> String {
    let driveCPath = bottle.driveC.path
    guard path.hasPrefix(driveCPath) else { return path }
    var relative = String(path.dropFirst(driveCPath.count))
    if relative.hasPrefix("/") { relative.removeFirst() }
    return relative.isEmpty ? path : relative
}

// MARK: - Sidebar bottle row

/// One "Bottles" sidebar row: a small cylinder glyph, the bottle's name,
/// and — when an engine is installed — a muted secondary line with its
/// short name. Replaces the plain `Label(bottle.name, ...)` row so the
/// sidebar can show the engine at a glance without a chip or full display
/// name competing with the bottle name.
struct BottleSidebarRow: View {
    let bottle: Bottle
    let engine: InstalledEngine?

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: "cylinder")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(bottle.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                if engine != nil {
                    Text(engineShortName(engine))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(height: Theme.Metrics.row)
    }
}

// MARK: - Plain sidebar section header

/// A `List` section header for the sidebar: the shared 11pt uppercase,
/// tracked, secondary style (see `SectionHeader`) but without its accent
/// underline — a sidebar section title should stay quiet, not compete with
/// the one accent already reserved for a bottle's "Run .exe…" button.
///
/// An optional `info` string adds a small info glyph with a `.help(_:)`
/// hover tooltip after the title — used exactly once, on "Bottles", to
/// teach the one piece of jargon this app can't avoid without repeating
/// the explanation on every screen that happens to say the word.
///
/// Deliberately a static `Image` with `.help(_:)` rather than
/// `InfoPopoverButton`'s `Button` + `@State` + `.popover(_:)`: a stateful,
/// interactive subview inside a `List` `Section` header confuses the
/// sidebar's row virtualization on this SwiftUI/AppKit combination — the
/// "Bottles" section's rows stop rendering the moment selection moves to
/// another section and don't come back. A plain hover tooltip carries the
/// same information without touching List internals.
struct SidebarSectionHeader: View {
    let title: String
    var info: String? = nil

    var body: some View {
        HStack(spacing: 3) {
            Text(title)
                .font(Theme.headingFont(11))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.6)
            if let info {
                Image(systemName: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help(info)
            }
        }
    }
}

// MARK: - Icon-only toolbar button

/// A quiet, icon-only button for compact toolbar rows (Programs' Rescan/
/// Add, the filter menu trigger) — a tooltip via `.help` carries the label
/// that would otherwise need visible text.
struct IconToolbarButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: Theme.Metrics.toolbarControl, height: Theme.Metrics.toolbarControl)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

// MARK: - Info popover

/// A small "(i)" affordance that reveals a longer explanation in a
/// popover on click — used next to a toggle whose short caption isn't
/// the whole story, as an alternative to a hover-only `.help` tooltip.
struct InfoPopoverButton: View {
    let text: String
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented) {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 260, alignment: .leading)
                .padding(Theme.Spacing.m)
        }
    }
}
