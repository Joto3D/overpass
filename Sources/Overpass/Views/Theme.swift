import SwiftUI
import AppKit
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

    /// The title at the top of every sheet (New Bottle, Import Bottle,
    /// Open with Overpass, a program's arguments, a catalog app's detail).
    /// These had drifted to 16, 18 and 20pt depending on which file was
    /// written first; one token keeps a sheet's title the same size no
    /// matter which sheet it is. The first-run wizard's "Welcome to
    /// Overpass" deliberately stays at `titleFont()`'s 22pt default — it's
    /// a landing screen, not a task sheet.
    static let sheetTitleFont: Font = titleFont(18)

    /// The name line of a list row — sidebar bottles, Programs rows,
    /// Games rows and cards. Plain system font on purpose (see
    /// `titleFont`'s note on dense lists), pinned to 13pt so the three
    /// screens that spell the same row stay identical.
    static let rowTitleFont: Font = .system(size: 13)

    /// The muted second line under a `rowTitleFont` line (engine short
    /// name, relative path, store and size).
    static let rowSubtitleFont: Font = .system(size: 11)

    // The type scale, written down once so the sizes relate to each other
    // instead of being whatever each file picked first:
    //
    //   22  titleFont()          screen titles (bottle name, wizard welcome)
    //   18  sheetTitleFont       sheet titles
    //   15  headingFont(15)      the primary button label
    //   14  headingFont()        card/sub-section headings
    //   13  bodyFont             body text, row titles, quiet-button labels
    //   11  captionFont          captions, row subtitles, chips, section labels
    //
    // Rounded design is reserved for the 14pt-and-up "voice" of the app and
    // for the small uppercase labels and chips; running text stays on the
    // regular system design (see `titleFont`'s note on dense lists). The
    // jump from 13 to 11 is deliberate: nothing in this app sits at 12 or
    // 10, so a caption is always visibly a caption. 10pt is gone from
    // components in this file — it was the size at which tinted chip text
    // failed contrast in light mode.

    /// Body text. Same size as `rowTitleFont`; named separately so a
    /// paragraph and a list-row name can diverge later without a hunt.
    static let bodyFont: Font = .system(size: 13)

    /// Captions, helper text under a control, popover text.
    static let captionFont: Font = .system(size: 11)

    /// The small uppercase label that opens a section (`SectionHeader`,
    /// `SidebarSectionHeader`). Semibold rounded, tracked by
    /// `labelTracking`.
    static let labelFont: Font = headingFont(11)
    static let labelTracking: CGFloat = 0.6

    /// Chip text. 11pt medium: one step up from the 10pt it used to be,
    /// because 10pt tinted text was the weak point of the old chips.
    static let chipFont: Font = .system(size: 11, weight: .medium, design: .rounded)

    // MARK: - Metrics

    enum Spacing {
        /// Hairline gap between a row's name and its muted second line.
        static let hairline: CGFloat = 1
        /// Gap between a control and the one-line caption directly under it.
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        /// Between `xs` and `s`: the gap inside small clusters of related
        /// controls — a search glyph and its field, wrapped chips, rows in
        /// a short stacked list.
        static let compact: CGFloat = 6
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24

        /// Screen/content outer padding per the shared design spec (20pt) —
        /// distinct from `xl` (24pt), which stays available for larger
        /// internal gaps. Also used as the gap below a tab picker before
        /// its content ("16 above and 20 below" the picker).
        static let outer: CGFloat = 20
    }

    enum Metrics {
        /// Height shared by a toolbar's search field and its icon-only
        /// buttons (filter, rescan, add) so a compact toolbar row reads as
        /// one aligned strip instead of controls of mismatched heights.
        static let toolbarControl: CGFloat = 28
        /// Uniform row height for sidebar rows and program/game list rows.
        static let row: CGFloat = 36
        static let listRow: CGFloat = 44
        /// Vertical padding of the full-size accent and quiet buttons
        /// (`AuroraButtonStyle`, `QuietButtonStyle`) — kept as one value so
        /// a quiet button sits at the same height as the accent button
        /// beside it.
        static let buttonPadding: CGFloat = 14
        /// Minimum hit area for an icon-only button (remove, copy, close,
        /// hover-revealed play). A bare SF Symbol is ~12-17pt square, which
        /// is hard to click; this is the macOS floor for a pointer target.
        /// `toolbarControl` (28) stays the size for the compact toolbar
        /// strip, where the buttons must match the search field's height.
        static let iconButton: CGFloat = 24
        /// Maximum width of a scrolling settings-style column (Engines,
        /// Settings, Config, Performance, Extras), so form rows and cards
        /// don't stretch into unreadably long lines on a wide window.
        static let contentMaxWidth: CGFloat = 760
        /// Width of the standard task sheets (New Bottle, Open with
        /// Overpass, a catalog app, the setup wizard).
        static let sheetWidth: CGFloat = 460
        /// Width of the one sheet with a source list beside a form
        /// (Import Bottle).
        static let wideSheetWidth: CGFloat = 620
        /// Width of the small single-field sheet (a program's arguments).
        static let compactSheetWidth: CGFloat = 380
    }

    enum Opacity {
        /// The faint tint behind a selected row, a chip, or a status icon —
        /// one value so "selected" and "tagged" washes match across
        /// Programs, Settings, Import and `Chip`. (Settings' theme swatch
        /// used 0.16 and the rest 0.14; no one chose the difference.)
        static let wash: Double = 0.14
        /// A hairline edge on a neutral surface (card, quiet button, output
        /// box). Lower than a text-contrast value on purpose: it separates
        /// surfaces, it is not the only thing carrying meaning.
        static let hairline: Double = 0.10
        /// The faintest tint behind a note or status card: enough to read
        /// as "this one is about X" without competing with its own text.
        static let softWash: Double = 0.06
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

    /// The stops behind any fill that carries WHITE text (primary button,
    /// prominent chip). `accentColors` is the decorative sweep and its
    /// bright stops (amber, cyan, sand) are only ~1.5-2:1 against white —
    /// the old button faded to amber under a white label. These are the
    /// same hues pulled down until every stop is at least 4.8:1 against
    /// white (WCAG AA for normal text is 4.5), so the label is readable
    /// along the whole width of the button in either colour scheme.
    let buttonColors: [Color]

    /// The accent as TEXT or a thin glyph on a card — a section icon, a
    /// hovered card's edge — adaptive per colour scheme. `badgeTint` and
    /// the gradient stops are fine as washes and strokes but fail as small
    /// type on a light card (amber on white is ~2:1). Light variants are
    /// >= 4.7:1 against both white and the 0.93-grey window; dark variants
    /// are >= 5.7:1 against a 0.14-0.22 grey card.
    let ink: Color

    /// The signature accent as a left-to-right gradient — the default
    /// orientation for fills (buttons, badges, underlines, progress dots).
    var accentGradient: LinearGradient {
        LinearGradient(colors: accentColors, startPoint: .leading, endPoint: .trailing)
    }

    /// A softened version of the accent gradient for large fills (e.g. a
    /// full-width primary button) where the fully saturated stripe would be
    /// too loud — same hues, lower opacity, blended over the button chrome
    /// so it still reads as a solid, legible button.
    ///
    /// Built from `buttonColors`, not `accentColors`, and no longer blended
    /// at 0.9 opacity: translucency let the card behind change the
    /// contrast under the label, which a contrast guarantee cannot allow.
    var accentButtonFill: LinearGradient {
        LinearGradient(colors: buttonColors, startPoint: .leading, endPoint: .trailing)
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
        badgeTint: Color(red: 0.95, green: 0.66, blue: 0.29),
        buttonColors: [
            Color(red: 0.27, green: 0.20, blue: 0.58),
            Color(red: 0.42, green: 0.23, blue: 0.62),
            Color(red: 0.60, green: 0.26, blue: 0.54),
            Color(red: 0.72, green: 0.29, blue: 0.34),
        ],
        ink: .overpassAdaptive(light: RGB(0.36, 0.22, 0.62), dark: RGB(0.76, 0.66, 1.0))
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
        badgeTint: Color(red: 0.95, green: 0.77, blue: 0.42),
        buttonColors: [
            Color(red: 0.42, green: 0.27, blue: 0.08),
            Color(red: 0.55, green: 0.35, blue: 0.07),
            Color(red: 0.62, green: 0.40, blue: 0.08),
        ],
        ink: .overpassAdaptive(light: RGB(0.55, 0.34, 0.04), dark: RGB(0.96, 0.78, 0.42))
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
        badgeTint: Color(red: 0.95, green: 0.21, blue: 0.69),
        buttonColors: [
            Color(red: 0.00, green: 0.40, blue: 0.52),
            Color(red: 0.36, green: 0.24, blue: 0.82),
            Color(red: 0.76, green: 0.10, blue: 0.52),
        ],
        ink: .overpassAdaptive(light: RGB(0.00, 0.42, 0.52), dark: RGB(0.30, 0.92, 0.92))
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
        badgeTint: Color(red: 0.85, green: 0.78, blue: 0.63),
        buttonColors: [
            Color(red: 0.07, green: 0.30, blue: 0.33),
            Color(red: 0.16, green: 0.40, blue: 0.52),
            Color(red: 0.20, green: 0.46, blue: 0.48),
        ],
        ink: .overpassAdaptive(light: RGB(0.06, 0.38, 0.42), dark: RGB(0.52, 0.84, 0.86))
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
        badgeTint: Color(red: 0.88, green: 0.55, blue: 0.20),
        buttonColors: [
            Color(red: 0.70, green: 0.22, blue: 0.19),
            Color(red: 0.68, green: 0.30, blue: 0.06),
            Color(red: 0.64, green: 0.38, blue: 0.04),
        ],
        ink: .overpassAdaptive(light: RGB(0.72, 0.25, 0.20), dark: RGB(1.0, 0.60, 0.50))
    )

    /// Minimal: the system accent color standing in for the gradient (a
    /// one-stop "gradient" renders as a plain solid fill) over neutral,
    /// near-system surfaces — for people who want it quiet.
    /// MEASURED (29 October 2026): this is the one palette whose button
    /// contrast Overpass cannot guarantee, because the fill is whatever
    /// accent the user picked in System Settings. macOS's own default
    /// blue (0, 0.478, 1) against a white label computes to **4.02:1**,
    /// below the 4.5:1 WCAG AA threshold every other palette here clears.
    /// Left as is deliberately: this palette exists to follow the
    /// system, and Apple ships white-on-accent throughout macOS, so
    /// overriding it would be less consistent, not more accessible.
    /// Anyone who needs the guarantee should pick a named palette.
    static let plain = ThemePalette(
        id: "plain",
        displayName: "Plain",
        summary: "System colors only — no signature gradient.",
        accentColors: [Color.accentColor],
        surface: Color(white: 0.08),
        secondaryAccent: Color.secondary,
        badgeTint: Color.accentColor,
        // The user's own macOS accent: its contrast with white text is
        // whatever the user chose in System Settings, which this file
        // cannot guarantee (the default blue is ~4:1). Plain is the "system
        // colours only" opt-out, so deferring to the system is the point.
        buttonColors: [Color.accentColor],
        ink: Color.accentColor
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

// MARK: - Adaptive colour helpers

/// A plain sRGB triple, so a light/dark pair can be captured by a dynamic
/// colour's `@Sendable` provider without dragging a non-Sendable `NSColor`
/// or `Color` across it.
struct RGB: Sendable {
    let r: Double, g: Double, b: Double
    init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
}

extension Color {
    /// A colour that resolves per appearance at draw time, so it follows the
    /// system light/dark setting live. (Overpass never forces a colour
    /// scheme: even the "dark" palettes are tinted surfaces that must also
    /// work under a light system appearance.)
    static func overpassAdaptive(light: RGB, dark: RGB) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let v = isDark ? dark : light
            return NSColor(srgbRed: v.r, green: v.g, blue: v.b, alpha: 1)
        })
    }
}

extension Theme {
    // MARK: - Status tones

    /// The four state colours, each as an INK (text and glyphs) that stays
    /// readable on its own tint in both colour schemes. System `.green`,
    /// `.red`, `.orange` and `.yellow` are tuned for large fills; as 11pt
    /// type on a light card they are ~2-3.7:1. Every pair below is
    /// >= 4.8:1 in light (against white and the 0.93 window grey) and
    /// >= 4.7:1 in dark (against a 0.14-0.22 grey card). A tone is never
    /// the only carrier of state: every place that uses one also draws a
    /// glyph (check, cross, triangle) or a word.
    enum Tone: Sendable {
        case success, warning, danger, info

        var ink: Color {
            switch self {
            case .success: .overpassAdaptive(light: RGB(0.04, 0.47, 0.20), dark: RGB(0.40, 0.86, 0.52))
            case .warning: .overpassAdaptive(light: RGB(0.60, 0.33, 0.00), dark: RGB(1.00, 0.75, 0.30))
            case .danger:  .overpassAdaptive(light: RGB(0.74, 0.11, 0.10), dark: RGB(1.00, 0.50, 0.46))
            case .info:    .overpassAdaptive(light: RGB(0.05, 0.38, 0.80), dark: RGB(0.45, 0.72, 1.00))
            }
        }
    }

    // MARK: - Readable ink for an arbitrary tint

    /// Relative luminance per WCAG 2.x, from sRGB components in 0...1.
    private static func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
        func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// A version of `tint` that reads as text on a card in `scheme`.
    ///
    /// `Chip` takes any `Color` (`.yellow`, `.orange`, `.green`, the system
    /// accent) from call sites this file does not own, so the ink cannot be
    /// a fixed table. The tint is resolved for the target appearance, then
    /// darkened (light) or lightened (dark) in small steps until it clears
    /// 4.5:1 against a worst-case card backdrop — 0.93 grey in light, 0.20
    /// grey in dark — and left untouched if it already does. That keeps a
    /// green chip green rather than collapsing every light-mode chip to
    /// black text, which was the previous fix. If a tint is so pale it
    /// still fails after the last step, plain `.primary` is the safe floor.
    static func readableInk(_ tint: Color, in scheme: ColorScheme) -> Color {
        let isDark = scheme == .dark
        var resolved: (Double, Double, Double)?
        NSAppearance(named: isDark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            if let c = NSColor(tint).usingColorSpace(.sRGB) {
                resolved = (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
            }
        }
        guard let (r, g, b) = resolved else { return .primary }
        let backdrop = luminance(isDark ? 0.20 : 0.93, isDark ? 0.20 : 0.93, isDark ? 0.20 : 0.93)
        let target = isDark ? 1.0 : 0.0
        for step in 0...8 {
            let t = Double(step) * (isDark ? 0.08 : 0.09)
            let cr = r + (target - r) * t, cg = g + (target - g) * t, cb = b + (target - b) * t
            let l = luminance(cr, cg, cb)
            let ratio = (max(l, backdrop) + 0.05) / (min(l, backdrop) + 0.05)
            if ratio >= 4.5 { return Color(.sRGB, red: cr, green: cg, blue: cb, opacity: 1) }
        }
        return .primary
    }
}

// MARK: - Card surface

/// A "Overpass card": a panel with a faint tint (from the current theme's
/// `surface` color) so it reads as part of the app's identity in both light
/// and dark appearance, plus a hairline border and — in light mode — a soft
/// lift. Used for grouped content in place of the system's default
/// `GroupBox` chrome.
///
/// Light and dark are built differently on purpose. A drop shadow is
/// invisible on a dark window, so dark cards get depth from a translucent
/// material and a lit top edge instead. In light mode the old
/// material-over-window card had almost no edge (8% border on a 93% grey
/// ground), so cards were hard to tell from the page; they now sit on an
/// opaque control-background fill with a faint shadow, which is also what
/// stops the shadow showing through a translucent fill.
///
/// `interactive` is for a card that is itself a click target: on hover the
/// edge picks up the accent ink and the lift deepens. Static cards never
/// react, so hover only ever means "you can click this".
private struct OverpassCardBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(ThemeStore.self) private var themeStore
    @State private var isHovered = false
    var cornerRadius: CGFloat = Theme.Radius.card
    var interactive: Bool = false

    private var isDark: Bool { colorScheme == .dark }
    private var lifted: Bool { interactive && isHovered }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                ZStack {
                    if isDark {
                        shape.fill(.regularMaterial)
                    } else {
                        shape
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .shadow(color: .black.opacity(lifted ? 0.13 : 0.06),
                                    radius: lifted ? 8 : 3, x: 0, y: lifted ? 3 : 1)
                    }
                    shape.fill(themeStore.current.surface.opacity(isDark ? 0.4 : 0.045))
                    if lifted {
                        shape.strokeBorder(themeStore.current.ink.opacity(0.6), lineWidth: 1)
                    } else if isDark {
                        // A lit top-left edge fading to a dim one: the dark
                        // stand-in for the light-mode shadow.
                        shape.strokeBorder(
                            LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.06)],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 1)
                    } else {
                        shape.strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                    }
                }
                .animation(Theme.settle, value: lifted)
            }
            .onHover { hovering in
                if interactive { isHovered = hovering }
            }
    }
}

extension View {
    /// Wraps this view's existing padding/content in a Overpass card
    /// surface. Callers should apply their own `.padding(...)` first.
    /// Pass `interactive: true` only for a card that is a click target.
    func overpassCard(cornerRadius: CGFloat = Theme.Radius.card, interactive: Bool = false) -> some View {
        modifier(OverpassCardBackground(cornerRadius: cornerRadius, interactive: interactive))
    }
}

// MARK: - Section header

/// A small rounded-title header with a thin accent underline — the
/// section-header treatment used throughout the app in place of plain
/// `GroupBox`/`Section` titles.
///
/// The title stays quiet secondary type; the accent appears twice and only
/// in small amounts — the leading glyph (in the palette's text-safe `ink`,
/// not `.secondary`, so the section has a colour anchor) and the underline.
struct SectionHeader: View {
    @Environment(ThemeStore.self) private var themeStore
    let title: String
    var systemImage: String?

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(Theme.headingFont(12))
                    .foregroundStyle(themeStore.current.ink)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(Theme.labelFont)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(Theme.labelTracking)
        }
        .padding(.bottom, Theme.Spacing.xxs)
        .overlay(alignment: .bottomLeading) {
            themeStore.current.accentGradient
                .frame(width: 28, height: 2)
                .clipShape(Capsule())
                .offset(y: Theme.Spacing.xs)
        }
    }
}

// MARK: - Capsule chip

/// A small pill-shaped label used for stats ("↓ 12K"), category tags,
/// keybinds ("⌨ H"), and dependency names — the compact, calm secondary
/// vocabulary that lets the accent stay rare.
///
/// Chip, `InlineNote` and `StatusPillCard` share one recipe: a faint wash
/// of the tint, a matching hairline edge, and a glyph — so a state reads
/// from shape and wording first and colour second.
struct Chip: View {
    @Environment(ThemeStore.self) private var themeStore
    @Environment(\.colorScheme) private var colorScheme
    let text: String
    var systemImage: String?
    var tint: Color = .secondary
    var prominent: Bool = false

    private var isNeutral: Bool { tint == .secondary }

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(prominent ? .white : labelColor)
                    .accessibilityHidden(true)
            }
            Text(text)
                .lineLimit(1)
                .foregroundStyle(prominent ? .white : labelColor)
        }
        .font(Theme.chipFont)
        .padding(.horizontal, Theme.Spacing.s)
        .padding(.vertical, Theme.Spacing.xs)
        .background {
            if prominent {
                // Same safe-for-white-text fill as the primary button; a
                // lit rim separates a selected chip from the wash chips
                // beside it by shape of edge as well as by colour.
                Capsule().fill(themeStore.current.accentButtonFill)
                    .overlay { Capsule().strokeBorder(.white.opacity(0.28), lineWidth: 1) }
            } else {
                Capsule().fill(washColor)
                    .overlay { Capsule().strokeBorder(edgeColor, lineWidth: 1) }
            }
        }
    }

    private var washColor: Color {
        isNeutral ? Color.primary.opacity(0.07) : tint.opacity(Theme.Opacity.wash)
    }

    private var edgeColor: Color {
        isNeutral ? Color.primary.opacity(Theme.Opacity.hairline) : tint.opacity(0.30)
    }

    /// 11pt coloured type on a 14% wash of its own colour is where the
    /// previous pass found yellow and orange chips unreadable in light
    /// mode. The label (and glyph) now use `Theme.readableInk`, which only
    /// darkens or lightens the tint as far as 4.5:1 requires, so a green
    /// chip stays green. Neutral chips use primary text at 72% rather than
    /// `.secondary`, because secondary type on a secondary-coloured wash
    /// lands near 4:1. Every chip still carries a glyph or a word for its
    /// state, so colour is never the only signal.
    private var labelColor: Color {
        isNeutral ? Color.primary.opacity(0.72) : Theme.readableInk(tint, in: colorScheme)
    }
}

// MARK: - Status pill card

/// One compact status check (used by the first-run setup wizard's
/// checklist): an icon, a title, and a one-line subtitle, tinted green or
/// red by `ok`.
struct StatusPillCard: View {
    let title: String
    let ok: Bool
    let subtitle: String
    let systemImage: String

    /// Success/danger inks from `Theme.Tone`, not system green/red: the
    /// glyph is a graphic that needs 3:1 and sits on its own wash.
    private var tone: Theme.Tone { ok ? .success : .danger }
    private var tint: Color { tone.ink }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.s) {
            ZStack {
                Circle()
                    .fill(tint.opacity(Theme.Opacity.wash))
                Circle()
                    .strokeBorder(tint.opacity(0.35), lineWidth: 1)
                Image(systemName: ok ? "checkmark" : "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(tint)
            }
            .frame(width: 22, height: 22)
            // The green/red tint is the visual signal; the check/cross glyph
            // is the shape-based one; this is the spoken one. The subtitle
            // beside it already says why ("Installed", "Not installed…"),
            // so this only needs to name the state.
            .accessibilityElement(children: .ignore)
            // "Not ready", the plain opposite of "Ready": the one place
            // this card is used is a first-run checklist, where an unticked
            // step is simply not done yet, not a fault ("Needs attention"
            // implied something had gone wrong).
            .accessibilityLabel(ok ? "Ready" : "Not ready")

            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: systemImage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                }
                // No line limit: the subtitle can be a command the user has
                // to copy out ("softwareupdate --install-rosetta ..."), and
                // the old two-line middle-truncation cut the part that
                // matters out of the middle of it. Selectable for the same
                // reason.
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The same soft tinted wash `InlineNote` uses, laid between the
        // card surface and the content, so a ready step and a pending one
        // differ by more than a 22pt circle.
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(tint.opacity(Theme.Opacity.softWash))
        }
        .overpassCard(cornerRadius: Theme.Radius.row)
    }
}

// MARK: - Button styles

/// Overpass's primary action style: a full-width accent-gradient fill with
/// bold rounded text — reserved for the single most important action on a
/// screen (Play, Install, primary wizard actions).
///
/// The button hierarchy is: this (filled, coloured, white label) >
/// `QuietButtonStyle` (neutral fill with a hairline edge, primary-colour
/// label) > the system `.borderless` / `.plain` styles (no chrome). Fill
/// weight alone separates the tiers, so it holds up in greyscale too.
///
/// Named `AuroraButtonStyle` for source compatibility with call sites that
/// spell it `.buttonStyle(.aurora)`; `AccentButtonStyle` below is the
/// Overpass-flavored alias for any new code.
struct AuroraButtonStyle: ButtonStyle {
    var verticalPadding: CGFloat = Theme.Metrics.buttonPadding
    /// Full-width by default (sheets, wizards). Toolbar-sized buttons pass
    /// `false` so the label keeps its own width plus breathing room instead
    /// of being clipped against the gradient's edges.
    var fillsWidth: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        AccentButtonBody(configuration: configuration, verticalPadding: verticalPadding, fillsWidth: fillsWidth)
    }
}

/// The body lives in its own `View` because hover needs `@State`, which a
/// `ButtonStyle` struct cannot hold.
private struct AccentButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let verticalPadding: CGFloat
    let fillsWidth: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(ThemeStore.self) private var themeStore
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
        configuration.label
            .font(Theme.headingFont(15))
            // A disabled primary used to be the same gradient at 40%
            // opacity with a white label — still shaped like a live button
            // and unreadable. It is now a neutral, flat surface with a
            // secondary label, which also cannot be mistaken for enabled.
            .foregroundStyle(isEnabled ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.vertical, verticalPadding)
            .padding(.horizontal, Theme.Spacing.l)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .background {
                if isEnabled {
                    shape.fill(themeStore.current.accentButtonFill)
                        // Hover lifts, press sinks. Applied to the fill
                        // only, so the white label's contrast is unchanged
                        // by more than the ~0.08 brightness the stops were
                        // given headroom for (all >= 4.8:1).
                        .brightness(configuration.isPressed ? -0.08 : (isHovered ? 0.05 : 0))
                        .overlay {
                            shape.strokeBorder(
                                LinearGradient(colors: [.white.opacity(0.26), .white.opacity(0.04)],
                                               startPoint: .top, endPoint: .bottom),
                                lineWidth: 1)
                        }
                        .shadow(color: themeStore.current.ink.opacity(colorScheme == .dark ? 0.30 : 0.22),
                                radius: configuration.isPressed ? 2 : 5, x: 0, y: configuration.isPressed ? 1 : 2)
                } else {
                    shape.fill(Color.primary.opacity(0.08))
                }
            }
            .contentShape(shape)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(Theme.settle, value: configuration.isPressed)
            .animation(Theme.settle, value: isHovered)
            .onHover { isHovered = $0 }
    }
}

extension ButtonStyle where Self == AuroraButtonStyle {
    static var aurora: AuroraButtonStyle { AuroraButtonStyle() }
    /// Accent button sized to its label — for toolbars and headers.
    static var accentCompact: AuroraButtonStyle { AuroraButtonStyle(verticalPadding: Theme.Spacing.s, fillsWidth: false) }
}

/// Overpass-flavored alias for `AuroraButtonStyle` — prefer this name (and
/// `.buttonStyle(.accent)`) in new code; `AuroraButtonStyle`/`.aurora` stick
/// around only because existing call sites already spell it that way.
typealias AccentButtonStyle = AuroraButtonStyle

extension ButtonStyle where Self == AccentButtonStyle {
    static var accent: AccentButtonStyle { AccentButtonStyle() }
}

/// The secondary action style: a neutral fill with a hairline edge and a
/// primary-colour label, for actions that sit beside a primary accent
/// button without competing with it (Play Vanilla). The edge is what makes
/// it read as a button rather than a caption once the old 5% fill is
/// placed on a card; the accent button remains the only coloured one.
struct QuietButtonStyle: ButtonStyle {
    var verticalPadding: CGFloat = Theme.Metrics.buttonPadding
    /// Full-width by default (a block under a list or form). Header and
    /// action rows pass `false` (see `.quietCompact`) so the button keeps
    /// its label's width and sits at the height of the bordered buttons
    /// beside it instead of stretching across the row at 46pt tall.
    var fillsWidth: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        QuietButtonBody(configuration: configuration, verticalPadding: verticalPadding, fillsWidth: fillsWidth)
    }
}

private struct QuietButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let verticalPadding: CGFloat
    let fillsWidth: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
        let fill = !isEnabled ? 0.03 : (configuration.isPressed ? 0.14 : (isHovered ? 0.09 : 0.06))
        configuration.label
            // 13pt rounded medium, up from the 11pt `.subheadline`: beside
            // the 15pt primary label the old size read as a different
            // species of control rather than a lower tier of the same one.
            .font(Theme.headingFont(13, weight: .medium))
            .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.vertical, verticalPadding)
            .padding(.horizontal, fillsWidth ? 0 : Theme.Spacing.m)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .background {
                shape.fill(Color.primary.opacity(fill))
                    .overlay { shape.strokeBorder(Color.primary.opacity(isEnabled ? 0.14 : 0.07), lineWidth: 1) }
            }
            .contentShape(shape)
            .animation(Theme.settle, value: configuration.isPressed)
            .animation(Theme.settle, value: isHovered)
            .onHover { isHovered = $0 }
    }
}

extension ButtonStyle where Self == QuietButtonStyle {
    static var quiet: QuietButtonStyle { QuietButtonStyle() }
    /// Quiet button sized to its label — the counterpart of
    /// `.accentCompact`, for rows of buttons (log tools, engine actions).
    static var quietCompact: QuietButtonStyle { QuietButtonStyle(verticalPadding: Theme.Spacing.compact, fillsWidth: false) }
}

// MARK: - Flow layout

/// A simple left-to-right, top-to-bottom wrapping layout for chip/capsule
/// collections (category tags, dependency lists) whose count varies and
/// shouldn't be clipped or force a fixed column count the way
/// `LazyVGrid` would.
struct FlowLayout: Layout {
    var spacing: CGFloat = Theme.Spacing.compact

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
