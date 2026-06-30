import SwiftUI
import AppKit

/// Lightweight design tokens for the Fireflies-style calm look (docs/DESIGN-fireflies-reference.md).
enum Theme {
    /// Violet accent, à la Fireflies, for primary actions + selection.
    static let accent = Color(red: 0.45, green: 0.36, blue: 0.93)
    static let accentSoft = accent.opacity(0.10)
    static let cardRadius: CGFloat = 14
    static let cardFill = Color(nsColor: .controlBackgroundColor)
    static let hairline = Color(nsColor: .separatorColor)

    // Shared motion curves so every surface settles the same way (buttery, never choppy).
    static let springy = Animation.spring(response: 0.34, dampingFraction: 0.86)
    static let smooth = Animation.easeInOut(duration: 0.22)
}

/// A subtle hover fill for list/recent rows — the macOS "this is clickable" affordance, animated.
struct HoverRow: ViewModifier {
    var radius: CGFloat = 8
    @State private var hovered = false
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius).fill(hovered ? Theme.accentSoft : .clear))
            .animation(Theme.smooth, value: hovered)
            .onHover { hovered = $0 }
    }
}

extension View {
    /// A soft, rounded card surface with a hairline border.
    func cbCard(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Theme.cardFill))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.hairline, lineWidth: 1))
    }
    /// Subtle animated hover highlight for clickable rows.
    func cbHoverRow(radius: CGFloat = 8) -> some View { modifier(HoverRow(radius: radius)) }
}
