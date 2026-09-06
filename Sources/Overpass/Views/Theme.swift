import SwiftUI
import Observation

/// Overpass's small design system: shared color, gradient, typography, and
/// spacing constants, plus a handful of reusable view helpers, so every
/// screen reads as one consistent identity instead of each view rolling
/// its own ad-hoc styling.
///
/// Color is the one axis that's user-selectable (see `ThemePalette` and
/// `ThemeStore` below) — fonts, spacing, radii, and motion stay global
/// across every palette.
///
/// This file is presentation-only — nothing here reads or mutates any
/// model, service, or `AppState`. Behavior lives entirely in the views that
/// consume these tokens.
enum Theme {
    // MARK: - Typography

    /// Rounded, prominent — used for screen/section titles so headings
    /// feel like part of Overpass's identity rather than default system
    /// chrome. Body text intentionally stays on the regular system font
    /// for maximum readability in dense lists (bottle names, log text).
    static func titleFont(_ size: CGFloat = 22, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    static func headingFont(_ size: CGFloat = 14, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    // MARK: - Metrics

    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    enum Radius {
        static let card: CGFloat = 14
        static let row: CGFloat = 10
        static let icon: CGFloat = 12
        static let pill: CGFloat = 999
    }

    // MARK: - Motion

    /// The one animation curve used for state changes across the app
    /// (launch phases, toggles, badge appearance) — quick and settled,
    /// never bouncy or attention-grabbing.
    static let settle = Animation.easeInOut(duration: 0.22)
}

// MARK: - Theme palette

/// One selectable Overpass color identity: an accent gradient (the "one
/// splash of color" used sparingly for primary actions, badges, progress,
/// and underlines) plus a base surface tone layered under card materials.
/// Fonts, spacing, radii, and motion are deliberately *not* part of this —
/// they're shared across every palette (see `Theme`).
struct ThemePalette: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String

    /// A short, one-line description shown alongside `displayName` in
    /// Settings' Appearance picker (e.g. "Indigo, violet, and dusk-sky
    /// orange — Overpass's default look").
    let summary: String

    /// The accent gradient's stops, left-to-right. A single-color palette
    /// (see `.plain`) is expressed as a one-element array — a `LinearGradient`
    /// with one stop renders as a plain solid fill, so every consumer below
    /// (buttons, badges, underlines, progress dots) can stay a gradient type
    /// without a "does this palette have a gradient?" branch anywhere.
    let accentColors: [Color]

    /// The deep base/surface tone layered at low opacity under card
    /// materials and icon roundels. Always used under a material, never as
    /// an opaque fill, so it reads as intentional in dark mode while
    /// staying subtle in light mode.
    let surface: Color

    /// A single calmer accent that complements the gradient — used where the
    /// full multi-stop sweep would be too busy for a small shape (the theme
    /// swatch's border in Settings' Appearance picker).
    let secondaryAccent: Color

    /// A flat wash used behind palette-flavored surfaces that want a tinted
    /// background rather than the full gradient sweep (the selected-row
    /// highlight in Settings' Appearance picker).
    let badgeTint: Color

    /// The signature accent as a left-to-right gradient — the default
    /// orientation for fills (buttons, badges, underlines, progress dots).
    var accentGradient: LinearGradient {
        LinearGradient(colors: accentColors, startPoint: .leading, endPoint: .trailing)
    }

    /// A softened version of the accent gradient for large fills (e.g. a
    /// full-width primary button) where the fully saturated stripe would be
    /// too loud — same hues, lower opacity, blended over the button chrome
    /// so it still reads as a solid, legible button.
    var accentButtonFill: LinearGradient {
        LinearGradient(colors: accentColors.map { $0.opacity(0.9) }, startPoint: .leading, endPoint: .trailing)
    }
}

extension ThemePalette {
    /// Overpass's default identity, lifted straight from `Resources/icon.png`:
    /// a dusk sky over the highway — deep indigo fading through violet into
    /// sunset orange, over the icon's near-black asphalt navy.
    static let dusk = ThemePalette(
        id: "dusk",
        displayName: "Dusk",
        summary: "Indigo, violet, and sunset orange — Overpass's default look.",
        accentColors: [
            Color(red: 0.18, green: 0.13, blue: 0.40),
            Color(red: 0.36, green: 0.24, blue: 0.60),
            Color(red: 0.61, green: 0.31, blue: 0.62),
            Color(red: 0.86, green: 0.42, blue: 0.36),
            Color(red: 0.95, green: 0.66, blue: 0.29),
        ],
        surface: Color(red: 0.07, green: 0.05, blue: 0.16),
        secondaryAccent: Color(red: 0.36, green: 0.24, blue: 0.60),
        badgeTint: Color(red: 0.95, green: 0.66, blue: 0.29)
    )

    /// Near-black neutrals with a single warm amber accent — night driving
    /// with the dash lights on. The quietest of the dark palettes.
    static let asphalt = ThemePalette(
        id: "asphalt",
        displayName: "Asphalt",
        summary: "Near-black neutrals with a warm amber accent, like night driving.",
        accentColors: [
            Color(red: 0.54, green: 0.35, blue: 0.12),
            Color(red: 0.79, green: 0.54, blue: 0.18),
            Color(red: 0.95, green: 0.77, blue: 0.42),
        ],
        surface: Color(red: 0.05, green: 0.05, blue: 0.06),
        secondaryAccent: Color(red: 0.79, green: 0.54, blue: 0.18),
        badgeTint: Color(red: 0.95, green: 0.77, blue: 0.42)
    )

    /// Electric cyan into magenta over graphite — an arcade-marquee jolt of
    /// color for people who want the loudest option on the list.
    static let neon = ThemePalette(
        id: "neon",
        displayName: "Neon",
        summary: "Electric cyan and magenta on graphite, arcade-marquee energy.",
        accentColors: [
            Color(red: 0.12, green: 0.91, blue: 0.91),
            Color(red: 0.48, green: 0.36, blue: 0.98),
            Color(red: 0.95, green: 0.21, blue: 0.69),
        ],
        surface: Color(red: 0.04, green: 0.05, blue: 0.07),
        secondaryAccent: Color(red: 0.12, green: 0.91, blue: 0.91),
        badgeTint: Color(red: 0.95, green: 0.21, blue: 0.69)
    )

    /// Deep teal and steel blue over a near-black harbor navy, finished with
    /// a pale sand accent — calmer and cooler than Dusk.
    static let harbor = ThemePalette(
        id: "harbor",
        displayName: "Harbor",
        summary: "Deep teal and steel blue with a pale sand accent.",
        accentColors: [
            Color(red: 0.08, green: 0.33, blue: 0.35),
            Color(red: 0.20, green: 0.45, blue: 0.56),
            Color(red: 0.85, green: 0.78, blue: 0.63),
        ],
        surface: Color(red: 0.024, green: 0.10, blue: 0.115),
        secondaryAccent: Color(red: 0.20, green: 0.45, blue: 0.56),
        badgeTint: Color(red: 0.85, green: 0.78, blue: 0.63)
    )

    /// Overpass's one light palette: a warm cream ground under a
    /// coral-to-amber accent, tuned so white button/chip text still reads
    /// clearly against it. Everything else on this list stays dark.
    static let sunrise = ThemePalette(
        id: "sunrise",
        displayName: "Sunrise",
        summary: "Light and warm — coral and amber over a soft cream ground.",
        accentColors: [
            Color(red: 0.83, green: 0.33, blue: 0.29),
            Color(red: 0.88, green: 0.55, blue: 0.20),
            Color(red: 0.90, green: 0.68, blue: 0.30),
        ],
        surface: Color(red: 0.95, green: 0.89, blue: 0.80),
        secondaryAccent: Color(red: 0.83, green: 0.33, blue: 0.29),
        badgeTint: Color(red: 0.88, green: 0.55, blue: 0.20)
    )

    /// Minimal: the system accent color standing in for the gradient (a
    /// one-stop "gradient" renders as a plain solid fill) over neutral,
    /// near-system surfaces — for people who want it quiet.
    static let plain = ThemePalette(
        id: "plain",
        displayName: "Plain",
        summary: "System colors only — no signature gradient.",
        accentColors: [Color.accentColor],
        surface: Color(white: 0.08),
        secondaryAccent: Color.secondary,
        badgeTint: Color.accentColor
    )

    /// Every selectable palette, in the order shown by Settings' theme
    /// picker. `.dusk` stays first as the default.
    static let all: [ThemePalette] = [.dusk, .asphalt, .neon, .harbor, .sunrise, .plain]
}

// MARK: - Theme store

/// Owns the currently-selected `ThemePalette`, persisted across launches,
/// and injected into the view hierarchy via `.environment(_:)` so every
/// screen reads `themeStore.current` instead of a global constant — that's
/// what makes picking a theme in Settings update every screen live without
/// threading a palette through every view's `init`.
@MainActor
@Observable
final class ThemeStore {
    private static let storageKey = "overpass.theme"

    /// Backed by `UserDefaults` under `"overpass.theme"` (the same key an
    /// `@AppStorage("overpass.theme")` would use) so the selection survives
    /// relaunches. Kept as a plain observed property — rather than
    /// `@AppStorage` directly — because `@AppStorage`'s own storage
    /// mechanism doesn't compose with `@Observable`'s; this achieves the
    /// same persistence by hand.
    var current: ThemePalette {
        didSet {
            guard current.id != oldValue.id else { return }
            UserDefaults.standard.set(current.id, forKey: Self.storageKey)
        }
    }

    init() {
        let storedID = UserDefaults.standard.string(forKey: Self.storageKey)
        current = ThemePalette.all.first { $0.id == storedID } ?? .dusk
    }
}

// MARK: - Card surface

/// A "Overpass card": a material panel with a faint tint (from the current
/// theme's `surface` color) so it reads as part of the app's identity in
/// both light and dark appearance, plus a hairline border. Used for grouped
/// content in place of the system's default `GroupBox` chrome.
private struct OverpassCardBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(ThemeStore.self) private var themeStore
    var cornerRadius: CGFloat = Theme.Radius.card

    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(themeStore.current.surface.opacity(colorScheme == .dark ? 0.4 : 0.045))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08), lineWidth: 1)
                }
        }
    }
}

extension View {
    /// Wraps this view's existing padding/content in a Overpass card
    /// surface. Callers should apply their own `.padding(...)` first.
    func overpassCard(cornerRadius: CGFloat = Theme.Radius.card) -> some View {
        modifier(OverpassCardBackground(cornerRadius: cornerRadius))
    }
}

// MARK: - Section header

/// A small rounded-title header with a thin accent underline — the
/// section-header treatment used throughout the app in place of plain
/// `GroupBox`/`Section` titles.
struct SectionHeader: View {
    @Environment(ThemeStore.self) private var themeStore
    let title: String
    var systemImage: String?

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(Theme.headingFont(12))
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(Theme.headingFont(13))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.4)
        }
        .padding(.bottom, 2)
        .overlay(alignment: .bottomLeading) {
            themeStore.current.accentGradient
                .frame(width: 28, height: 2)
                .clipShape(Capsule())
                .offset(y: 4)
        }
    }
}

// MARK: - Capsule chip

/// A small pill-shaped label used for stats ("↓ 12K"), category tags,
/// keybinds ("⌨ H"), and dependency names — the compact, calm secondary
/// vocabulary that lets the accent stay rare.
struct Chip: View {
    @Environment(ThemeStore.self) private var themeStore
    let text: String
    var systemImage: String?
    var tint: Color = .secondary
    var prominent: Bool = false

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(text)
                .lineLimit(1)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(prominent ? .white : tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            if prominent {
                Capsule().fill(themeStore.current.accentGradient)
            } else {
                Capsule().fill(tint.opacity(0.14))
            }
        }
    }
}

/// A gradient-filled chip specifically for "something needs your
/// attention" states (update available, active profile) — the current
/// theme's accent applied to a badge rather than a full button.
// MARK: - Status pill card (Home's 2x2 grid)

/// One compact status check for the Home hero panel's 2x2 grid: an icon,
/// a title, and a one-line subtitle, tinted green or red by `ok`.
struct StatusPillCard: View {
    let title: String
    let ok: Bool
    let subtitle: String
    let systemImage: String

    private var tint: Color { ok ? .green : .red }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.s) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.16))
                Image(systemName: ok ? "checkmark" : "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(tint)
            }
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: systemImage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overpassCard(cornerRadius: Theme.Radius.row)
    }
}

// MARK: - Button styles

/// Overpass's primary action style: a full-width accent-gradient fill with
/// bold rounded text — reserved for the single most important action on a
/// screen (Play, Install, primary wizard actions).
///
/// Named `AuroraButtonStyle` for source compatibility with call sites that
/// spell it `.buttonStyle(.aurora)`; `AccentButtonStyle` below is the
/// Overpass-flavored alias for any new code.
struct AuroraButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(ThemeStore.self) private var themeStore
    var verticalPadding: CGFloat = 14

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.headingFont(15))
            .foregroundStyle(.white)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .fill(themeStore.current.accentButtonFill)
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(Theme.settle, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == AuroraButtonStyle {
    static var aurora: AuroraButtonStyle { AuroraButtonStyle() }
}

/// Overpass-flavored alias for `AuroraButtonStyle` — prefer this name (and
/// `.buttonStyle(.accent)`) in new code; `AuroraButtonStyle`/`.aurora` stick
/// around only because existing call sites already spell it that way.
typealias AccentButtonStyle = AuroraButtonStyle

extension ButtonStyle where Self == AccentButtonStyle {
    static var accent: AccentButtonStyle { AccentButtonStyle() }
}

/// A quiet secondary action style: plain text, no chrome beyond a faint
/// hover-independent background, for actions that should sit beside a
/// primary accent button without competing with it (Play Vanilla).
struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(isEnabled ? .primary : .secondary)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.10 : 0.05))
            }
            .opacity(isEnabled ? 1 : 0.5)
            .animation(Theme.settle, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == QuietButtonStyle {
    static var quiet: QuietButtonStyle { QuietButtonStyle() }
}

// MARK: - Flow layout

/// A simple left-to-right, top-to-bottom wrapping layout for chip/capsule
/// collections (category tags, dependency lists) whose count varies and
/// shouldn't be clipped or force a fixed column count the way
/// `LazyVGrid` would.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var origin = CGPoint.zero
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x + size.width > maxWidth, origin.x > 0 {
                origin.x = 0
                origin.y += rowHeight + spacing
                totalHeight = origin.y
                rowHeight = 0
            }
            origin.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            totalHeight = origin.y + rowHeight
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : origin.x, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var origin = CGPoint(x: bounds.minX, y: bounds.minY)
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x + size.width > bounds.maxX, origin.x > bounds.minX {
                origin.x = bounds.minX
                origin.y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: origin, proposal: ProposedViewSize(size))
            origin.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
