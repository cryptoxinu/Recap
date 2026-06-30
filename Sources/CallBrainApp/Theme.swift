import SwiftUI
import AppKit

/// Lightweight design tokens for the Fireflies-style calm look (docs/DESIGN-fireflies-reference.md).
enum Theme {
    /// Violet accent, à la Fireflies, for primary actions + selection.
    static let accent = Color(red: 0.45, green: 0.36, blue: 0.93)
    static let cardRadius: CGFloat = 14
    static let cardFill = Color(nsColor: .controlBackgroundColor)
    static let hairline = Color(nsColor: .separatorColor)
}

extension View {
    /// A soft, rounded card surface with a hairline border.
    func cbCard(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Theme.cardFill))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}
