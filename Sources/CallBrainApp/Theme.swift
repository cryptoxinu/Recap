import SwiftUI
import AppKit

// MARK: - Dynamic color plumbing

/// One sRGB color from a 0xRRGGBB literal (+ optional alpha). Private helper so we never collide
/// with the existing `Color(hex: String?)` calendar initializer.
private func cbHex(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

/// A token that resolves to a different value in light vs dark. Backed by an `NSColor` dynamic
/// provider so a single static `Color` follows the SwiftUI appearance environment (including a
/// pinned `.preferredColorScheme`) — the clean, asset-catalog-free way to tune BOTH modes in code.
private func dyn(light: NSColor, dark: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    })
}

/// Design tokens — Recap v2 "Stitch-clean, mono-accent" system. Neutral-first surfaces tuned
/// separately for light & dark; the brand violet is used sparingly (primary action, selection,
/// links, citations). Legibility target: body text ≥ WCAG AA on every surface, both modes.
/// (Supersedes the Fireflies-clone pastel look — see docs/DESIGN-fireflies-reference.md.)
enum Theme {

    // MARK: Brand accent (refined indigo-violet — desaturated in dark so it never glows)
    static let accent      = dyn(light: cbHex(0x5A4BD1), dark: cbHex(0x8B7DF0))
    /// Soft accent wash for selection backgrounds / tinted fills (a touch stronger in dark to stay visible).
    static let accentSoft  = dyn(light: cbHex(0x5A4BD1, 0.10), dark: cbHex(0x8B7DF0, 0.18))
    /// Text/glyph color that sits ON an accent-filled surface (primary buttons). White in light; DARK ink
    /// in dark — white-on-light-violet both fails AA on small labels AND is the source of the dark "glow"
    /// (WCAG critique). Dark ink on #8B7DF0 = 5.5:1 and reads as a calm solid chip.
    static let onAccent    = dyn(light: cbHex(0xFFFFFF), dark: cbHex(0x14121F))

    // MARK: Neutral surfaces (the layered elevation ladder)
    /// Window / app base — never pure white (light) or pure black (dark). Light dropped to #EDEDF1: a
    /// 96.6%-white field under 100%-white cards is what "hurts the eyes"; this lowers field luminance and
    /// ~triples card/bg separation so cards read without leaning on shadow (WCAG critique).
    static let bg              = dyn(light: cbHex(0xEDEDF1), dark: cbHex(0x0E0E12))
    /// Card / primary content surface.
    static let surface         = dyn(light: cbHex(0xFFFFFF), dark: cbHex(0x1A1A20))
    /// Inset surfaces — rails, search fields, sunken wells.
    static let surfaceSunken   = dyn(light: cbHex(0xE7E7EC), dark: cbHex(0x141418))
    /// Raised surfaces — popovers, menus, floating panels (paired with `.cbElevated()`).
    static let surfaceElevated = dyn(light: cbHex(0xFFFFFF), dark: cbHex(0x24242B))
    /// Hairline borders/dividers. Light bumped to 0.13 — at 0.08 the card edge is invisible (1.19:1) and
    /// the UI reads flat (WCAG critique).
    static let hairline        = dyn(light: cbHex(0x000000, 0.13), dark: cbHex(0xFFFFFF, 0.10))

    // MARK: Text ramp (tuned for contrast — not pure black/white, not the too-faint system tertiary)
    static let textPrimary   = dyn(light: cbHex(0x1C1C1F), dark: cbHex(0xECECEF))
    static let textSecondary = dyn(light: cbHex(0x5C5C66), dark: cbHex(0xA4A4AE))
    /// Tertiary retuned to clear AA in BOTH modes on EVERY surface incl. the darker sunken rail (#E7E7EC):
    /// light→#63636D (~4.6:1 on sunken), dark→#909099. (The old #6A6A74 was 4.34 on sunken — scoped-audit MED.)
    static let textTertiary  = dyn(light: cbHex(0x63636D), dark: cbHex(0x909099))

    // MARK: Status (used ONLY for real status — never as decoration). Light hues darkened so they clear AA as
    // TEXT even off a white card (on Theme.bg / surfaceSunken, where status text is often rendered — scoped-audit MED).
    static let success = dyn(light: cbHex(0x166E46), dark: cbHex(0x40C088))
    static let warning = dyn(light: cbHex(0x7F5309), dark: cbHex(0xE0A93A))
    static let danger  = dyn(light: cbHex(0xA9302D), dark: cbHex(0xF0736E))
    static let successSoft = dyn(light: cbHex(0x166E46, 0.12), dark: cbHex(0x40C088, 0.16))
    static let warningSoft = dyn(light: cbHex(0x7F5309, 0.13), dark: cbHex(0xE0A93A, 0.16))
    static let dangerSoft  = dyn(light: cbHex(0xA9302D, 0.12), dark: cbHex(0xF0736E, 0.18))

    // MARK: Curated categorical hues (replace the raw 8-color system rainbow). Muted + dark-tuned so they
    // stay harmonious with the brand and legible AS TEXT on `surface` in BOTH modes.
    static let ventureBlue = dyn(light: cbHex(0x2F6BC0), dark: cbHex(0x5C96E6))
    static let ventureTeal = dyn(light: cbHex(0x1C8474), dark: cbHex(0x39B0A3))
    /// Stable tints assigned to user-defined ventures by position (blue, teal, amber, rose, plum, …).
    static let venturePalette: [Color] = [
        ventureBlue, ventureTeal,
        dyn(light: cbHex(0x9A6516), dark: cbHex(0xCB9440)),  // amber
        dyn(light: cbHex(0xB24568), dark: cbHex(0xE07C9C)),  // rose
        dyn(light: cbHex(0x7A4A9C), dark: cbHex(0xA97FD0)),  // plum
        accent,                                              // indigo (brand)
    ]
    private static let speakerHues: [Color] = [
        accent,                                              // indigo (brand)
        ventureTeal,                                         // teal
        ventureBlue,                                         // blue
        dyn(light: cbHex(0x9A6516), dark: cbHex(0xCB9440)),  // amber
        dyn(light: cbHex(0xB24568), dark: cbHex(0xE07C9C)),  // rose
        dyn(light: cbHex(0x7A4A9C), dark: cbHex(0xA97FD0)),  // plum
    ]
    /// A stable, tasteful hue per speaker/label — legible as text on `surface` in both modes. Use the hue
    /// for the name + a 15% wash for the avatar (never a full-saturation fill with white ink → that glows).
    static func speakerColor(_ name: String) -> Color {
        var h = 5381
        for b in name.utf8 { h = (h &* 33) &+ Int(b) }
        return speakerHues[(h & 0x7fffffff) % speakerHues.count]
    }

    // MARK: Card surface (kept API-compatible: cardFill/cardRadius/hairline used across the app)
    static let cardFill   = surface
    static let cardRadius: CGFloat = Radius.md

    // MARK: Motion — shared curves so every surface settles the same way (buttery, never choppy)
    static let quick   = Animation.easeOut(duration: 0.18)
    static let smooth  = Animation.easeInOut(duration: 0.22)
    static let springy = Animation.spring(response: 0.34, dampingFraction: 0.86)
    static let gentle  = Animation.spring(response: 0.5, dampingFraction: 0.9)
}

/// Spacing scale — an 8pt-ish rhythm. Use these instead of magic numbers so every surface breathes
/// the same way.
enum Space {
    static let xs: CGFloat = 4
    static let s:  CGFloat = 8
    static let m:  CGFloat = 12
    static let l:  CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

/// Corner-radius scale.
enum Radius {
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
}

// MARK: - Typographic scale

extension Font {
    /// Screen title (greeting / hero).
    static let cbLargeTitle = Font.system(size: 26, weight: .semibold)
    /// Section / navigation title.
    static let cbTitle      = Font.system(size: 20, weight: .semibold)
    /// Card + row headline.
    static let cbHeadline   = Font.system(size: 15, weight: .semibold)
    /// Default body.
    static let cbBody       = Font.system(size: 13)
    /// Supporting text.
    static let cbCallout    = Font.system(size: 12.5)
    /// Metadata / captions.
    static let cbCaption    = Font.system(size: 11.5)
    /// Finest print.
    static let cbFootnote   = Font.system(size: 10.5)
}

// MARK: - Named glyphs (NO sparkles/emoji — one intentional icon per concept, used everywhere)

/// The app's icon vocabulary. Centralized so the "AI slop" sparkle never creeps back and every
/// surface names the same concept the same way.
enum CBIcon {
    static let ask        = "bubble.left.and.bubble.right"  // Ask AI / chat entry (valid SF Symbol; the
                                                            // old "bubble.left.and.text.bubble" doesn't
                                                            // exist → rendered BLANK in the sidebar)
    static let assistant  = "bubble.left"                    // an assistant answer / message
    static let aiNotes    = "text.alignleft"                 // AI-generated notes / summary
    static let regenerate = "arrow.clockwise"                // regenerate / refresh
    static let premium     = "bolt"                          // premium provider (Claude/Codex)
    static let agenda     = "rectangle.stack"                // agenda / prep stack
    static let prep       = "doc.text.magnifyingglass"       // call prep
    static let record     = "record.circle"                  // record
    static let recording  = "waveform"                       // active recording
    static let call       = "waveform.circle.fill"           // a recorded call
}

// MARK: - Surface modifiers

/// A small circular initials avatar tinted to a speaker's hue (15% wash + hue ink, never a
/// full-saturation fill → matches the `Theme.speakerColor` guidance and stays legible in both modes).
/// The shared "who is talking" glyph for the live-transcript / caption surfaces.
struct SpeakerAvatar: View {
    let name: String
    var tint: Color
    var diameter: CGFloat = 26

    private var initials: String {
        let words = name.split(whereSeparator: { $0.isWhitespace })
        let letters = words.prefix(2).compactMap { $0.first.map(String.init) }.joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    var body: some View {
        Circle()
            .fill(tint.opacity(0.15))
            .frame(width: diameter, height: diameter)
            .overlay(Text(initials).font(.system(size: diameter * 0.38, weight: .semibold)).foregroundStyle(tint))
            .overlay(Circle().strokeBorder(tint.opacity(0.25), lineWidth: 1))
    }
}

/// A subtle hover fill for list/recent rows — the macOS "this is clickable" affordance, animated.
struct HoverRow: ViewModifier {
    var radius: CGFloat = Radius.sm
    @State private var hovered = false
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(hovered ? Theme.accentSoft : .clear))
            .animation(Theme.smooth, value: hovered)
            .onHover { hovered = $0 }
    }
}

extension View {
    /// A soft, rounded card surface with a hairline border (calm — no shadow; use `.cbElevated()`
    /// for floating surfaces). `.continuous` corners read more premium than the default circular arc.
    func cbCard(padding: CGFloat = Space.l) -> some View {
        self
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1))
    }

    /// A raised surface (popover/menu/floating panel): elevated fill + hairline + a soft shadow that
    /// is near-invisible in dark (dark depth comes from the lighter fill, not a muddy shadow).
    func cbElevated(padding: CGFloat = Space.l, radius: CGFloat = Radius.md) -> some View {
        self
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.surfaceElevated))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1))
            .shadow(color: dyn(light: cbHex(0x000000, 0.10), dark: cbHex(0x000000, 0.28)),
                    radius: 14, y: 6)
    }

    /// Subtle animated hover highlight for clickable rows.
    func cbHoverRow(radius: CGFloat = Radius.sm) -> some View { modifier(HoverRow(radius: radius)) }
}
