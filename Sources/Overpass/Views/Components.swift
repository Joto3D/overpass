import SwiftUI

/// Small view/formatting helpers shared by the calmer redesign of the
/// sidebar, bottle header, and Programs list, plus the reusable rows and
/// messages (search field, empty state, inline progress, error text, notes,
/// output box) that several screens had each been spelling out by hand.
/// Kept separate from `Theme.swift` so the design-system file holds only
/// tokens and surfaces, while these thin, feature-specific helpers live
/// alongside the views that use them.

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

            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                Text(bottle.name)
                    .font(Theme.rowTitleFont)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                if engine != nil {
                    Text(engineShortName(engine))
                        .font(Theme.rowSubtitleFont)
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
        HStack(spacing: Theme.Spacing.xs) {
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
///
/// `.help` alone is not an accessibility label: for an `Image` it only
/// becomes the VoiceOver *hint*, and the button itself was announced by its
/// SF Symbol name ("arrow clockwise"). The same string is therefore also
/// set as the label, so the tooltip and what VoiceOver says can't drift.
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
        .accessibilityLabel(help)
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
        .accessibilityLabel("More information")
        .popover(isPresented: $isPresented) {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 260, alignment: .leading)
                .padding(Theme.Spacing.m)
        }
    }
}

// MARK: - Toolbar search field

/// The search field at the left of a compact toolbar row (Programs, Games):
/// a magnifier glyph and a plain text field inside a card, sized to
/// `Theme.Metrics.toolbarControl` so it lines up with the icon buttons
/// beside it. Programs and Games each spelled this out inline, identically
/// down to the magic numbers; the only thing that differed was the prompt.
///
/// The prompt doubles as the field's accessibility label (SwiftUI uses a
/// `TextField`'s title for that), so there is no separate label parameter.
struct ToolbarSearchField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: Theme.Spacing.compact) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, Theme.Spacing.s)
        .frame(maxWidth: .infinity)
        .frame(height: Theme.Metrics.toolbarControl)
        .overpassCard(cornerRadius: Theme.Radius.row)
    }
}

// MARK: - Empty state

/// The centered message shown where a list or grid has nothing to show,
/// saying *why* it's empty rather than leaving a blank region — "No games
/// match ...", "Drop an .exe here ...", "Scanning for games...". Used by the
/// Programs, Games and App Catalog screens, which each had their own copy
/// with different fonts and top padding.
///
/// `showsProgress` puts a spinner above the message for the "still
/// loading" case, so an in-flight first scan is not mistaken for an empty
/// result that is simply final.
///
/// Deliberately not `ContentUnavailableView`: that adds a large symbol and
/// title, which is the right weight for a whole screen being unavailable
/// (and is used for exactly that) but far too loud for a list that is
/// merely filtered down to nothing under a toolbar that is still usable.
struct EmptyStateMessage: View {
    let message: String
    var showsProgress: Bool = false

    init(_ message: String, showsProgress: Bool = false) {
        self.message = message
        self.showsProgress = showsProgress
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.s) {
            if showsProgress {
                ProgressView().controlSize(.small)
            }
            Text(message)
                .font(Theme.rowTitleFont)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Spacing.xl * 2)
    }
}

// MARK: - Inline progress

/// A small spinner followed by a one-line status caption — the "work is in
/// flight" row used under a form or toggle (creating a bottle, applying a
/// Windows version, a DXVK install, a Programs migration). It had been
/// rebuilt by hand six times with the same spacing and font.
struct InlineProgress: View {
    let text: String

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Error text

/// A failure message shown inline: a warning glyph, then the text in red.
/// Selectable, because an error is exactly the string a user wants to paste
/// into a bug report, and never truncated — the glyph means the message no
/// longer relies on red alone to read as an error.
///
/// Takes the message as it is. Callers pass the already-written error string
/// straight through; nothing here rewrites or prefixes it.
struct ErrorText: View {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
            Image(systemName: "exclamationmark.triangle")
                .accessibilityHidden(true)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .font(.caption)
        .foregroundStyle(.red)
    }
}

// MARK: - Inline note

/// A glyph and a paragraph of explanatory text inside a row-radius card —
/// the "heads up" treatment for the Engines update-check failure and the
/// cabextract hint on Extras. `tint` colors the glyph only; the text stays
/// secondary so a note reads as information, not an alarm (use `ErrorText`
/// for a failure that needs to stand out on its own).
struct InlineNote: View {
    let systemImage: String
    var tint: Color = .secondary
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.s) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(Theme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overpassCard(cornerRadius: Theme.Radius.row)
    }
}

// MARK: - Engine trade-off note

/// The `engineTradeoffCaption(for:)` sentence in the small secondary style
/// every engine picker uses. The New Bottle and Import sheets showed it in
/// `.caption2` and the Config tab in `.caption`; one view means the same
/// sentence looks the same wherever the choice is made.
struct EngineTradeoffNote: View {
    let kind: EngineKind

    var body: some View {
        Text(engineTradeoffCaption(for: kind))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Sheet close button

/// The circled-x at the top right of a sheet that has no Cancel button of
/// its own beside the content (Import Bottle, the catalog app detail).
/// Icon-only, so it carries an accessibility label and a tooltip, and is
/// padded out to `Theme.Metrics.iconButton` so it is not a 15pt target.
/// Callers add `.disabled(...)` when closing mid-operation would be unsafe.
struct SheetCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
                .frame(width: Theme.Metrics.iconButton, height: Theme.Metrics.iconButton)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Close")
        .accessibilityLabel("Close")
    }
}

// MARK: - Remove button

/// The small minus button at the end of an environment-variable row
/// (Config's Environment section and Performance's Advanced table), which
/// had drifted to two different glyphs ("minus.circle" and "trash") and
/// neither had a label. `name` is what is being removed ("WINEDEBUG"), so
/// VoiceOver says "Remove WINEDEBUG" rather than an anonymous icon.
struct RemoveRowButton: View {
    let name: String
    let action: () -> Void

    var body: some View {
        Button(role: .destructive, action: action) {
            Image(systemName: "minus.circle")
                .foregroundStyle(.secondary)
                .frame(width: Theme.Metrics.iconButton, height: Theme.Metrics.iconButton)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("Remove \(name)")
        .accessibilityLabel("Remove \(name)")
    }
}

// MARK: - Output box

/// A fixed-height, scrollable, selectable monospaced tail of a running
/// command's output — the install log in the App Catalog sheet and the
/// Winetricks output on Extras. They had two different looks (a
/// near-black fill that looks wrong in a light theme, and a faint
/// primary-tinted one), and the catalog's lines were individually clipped
/// to one line with the start cut off and could not be selected. Lines now
/// wrap and the whole block is selectable.
struct OutputBox: View {
    let lines: [String]
    var height: CGFloat = 160

    var body: some View {
        ScrollView {
            Text(lines.isEmpty ? " " : lines.joined(separator: "\n"))
                .font(.system(.caption2, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(Theme.Spacing.s)
        }
        .frame(height: height)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        }
    }
}

// MARK: - Error alert (root and sheets)

/// How many sheets that have opted in (see `hostsErrorAlert()` and
/// `defersErrorAlert()`) are currently on screen.
///
/// Why this exists: the app reports every failure through one
/// `AppState.errorMessage`, shown as an alert attached to `MainWindow`'s
/// root view. On macOS an alert is itself a window sheet, and a window
/// can't show a second sheet over one that is already up, so an alert
/// raised while a sheet was open (the setup wizard failing to install an
/// engine or create the first bottle, an app install failing in the catalog
/// sheet, an import failing) waited invisibly underneath until the sheet
/// was closed — and the wizard can't usefully be closed without the
/// engine it was trying to install. Counting the open sheets lets the root
/// alert stand down while one is up (`ErrorAlertHost`), so exactly one
/// place ever presents the message.
@MainActor
@Observable
final class SheetPresence {
    static let shared = SheetPresence()
    private(set) var count = 0

    var isShowingSheet: Bool { count > 0 }

    func didAppear() { count += 1 }
    func didDisappear() { count = max(0, count - 1) }
}

/// The single "Overpass" error alert, bound to `AppState.errorMessage`.
/// `isDeferred` keeps it from presenting (the message stays set, and shows
/// as soon as the flag clears).
private struct ErrorAlertHost: ViewModifier {
    @Environment(AppState.self) private var appState
    var isDeferred: Bool

    func body(content: Content) -> some View {
        content.alert("Overpass", isPresented: Binding(
            get: { appState.errorMessage != nil && !isDeferred },
            set: { if !$0 { appState.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { appState.errorMessage = nil }
        } message: {
            Text(appState.errorMessage ?? "")
        }
    }
}

/// Registers the modified view as an open sheet in `SheetPresence`.
private struct SheetPresenceTracker: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onAppear { SheetPresence.shared.didAppear() }
            .onDisappear { SheetPresence.shared.didDisappear() }
    }
}

extension View {
    /// The app-wide error alert, for the root view only. Stands down while
    /// any opted-in sheet is open; those either host their own copy
    /// (`hostsErrorAlert()`) or wait for the sheet to close
    /// (`defersErrorAlert()`).
    func rootErrorAlert() -> some View {
        modifier(ErrorAlertHost(isDeferred: SheetPresence.shared.isShowingSheet))
    }

    /// For a sheet whose actions can fail through `AppState.report` while it
    /// stays open (setup wizard, catalog install, import): shows the error
    /// alert on the sheet itself so it is visible immediately.
    func hostsErrorAlert() -> some View {
        modifier(SheetPresenceTracker()).modifier(ErrorAlertHost(isDeferred: false))
    }

    /// For a sheet that has no error of its own to show (New Bottle closes
    /// itself as soon as creation finishes, Open With, edit arguments): the
    /// root alert simply waits until the sheet is gone instead of queueing
    /// a second window sheet behind it.
    func defersErrorAlert() -> some View {
        modifier(SheetPresenceTracker())
    }
}
