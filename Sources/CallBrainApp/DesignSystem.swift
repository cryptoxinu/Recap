import SwiftUI

// MARK: - Buttons

/// Primary action — filled brand accent, white glyph, gentle press feedback. Use for the ONE
/// most-important action on a surface (Send, Record, Save, Generate).
struct CBPrimaryButtonStyle: ButtonStyle {
    var size: ControlSize = .regular
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.cbBody.weight(.semibold))
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, size == .large ? Space.l : Space.m)
            .padding(.vertical, size == .large ? 9 : 6)
            .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(Theme.accent))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(Theme.quick, value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

/// Secondary action — neutral surface + hairline, primary text. Everything that isn't THE action.
struct CBSecondaryButtonStyle: ButtonStyle {
    var size: ControlSize = .regular
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.cbBody.weight(.medium))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, size == .large ? Space.l : Space.m)
            .padding(.vertical, size == .large ? 9 : 6)
            .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).strokeBorder(Theme.hairline))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(Theme.quick, value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == CBPrimaryButtonStyle {
    static var cbPrimary: CBPrimaryButtonStyle { .init() }
    static func cbPrimary(_ size: ControlSize) -> CBPrimaryButtonStyle { .init(size: size) }
}
extension ButtonStyle where Self == CBSecondaryButtonStyle {
    static var cbSecondary: CBSecondaryButtonStyle { .init() }
    static func cbSecondary(_ size: ControlSize) -> CBSecondaryButtonStyle { .init(size: size) }
}

// MARK: - Card hover lift

/// A subtle lift on hover — the card rises 1pt and gains a soft shadow. The premium "this is clickable"
/// feel for content cards (one card lifts at a time, so it never reads as heavy).
struct CardHoverLift: ViewModifier {
    @State private var hovered = false
    func body(content: Content) -> some View {
        content
            .offset(y: hovered ? -1 : 0)
            .shadow(color: .black.opacity(hovered ? 0.12 : 0), radius: 8, y: 3)
            .animation(Theme.quick, value: hovered)
            .onHover { hovered = $0 }
    }
}
extension View {
    /// Subtle hover lift for a clickable content card.
    func cbCardHoverLift() -> some View { modifier(CardHoverLift()) }
}

// MARK: - Avatar

/// Participant initials in a calm accent-wash circle. One avatar treatment across the whole app.
struct Avatar: View {
    let name: String
    var size: CGFloat = 24
    var body: some View {
        Circle()
            .fill(Theme.accentSoft)
            .frame(width: size, height: size)
            .overlay(
                Text(Self.initials(name))
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            )
    }
    static func initials(_ name: String) -> String {
        let parts = name.split(separator: " ")
        let chars = parts.prefix(2).compactMap(\.first)
        return chars.isEmpty ? "?" : String(chars).uppercased()
    }
}

// MARK: - Section header

/// A quiet, consistent section label (optionally with a trailing action). Small, medium-weight,
/// secondary — never shouty.
struct CBSectionHeader: View {
    let title: String
    var systemImage: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        HStack(spacing: Space.s) {
            if let systemImage {
                Image(systemName: systemImage).font(.cbCaption).foregroundStyle(Theme.textTertiary)
            }
            Text(title)
                .font(.cbCaption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
                .textCase(nil)
            Spacer(minLength: 0)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.plain)
                    .font(.cbCaption.weight(.medium))
                    .foregroundStyle(Theme.accent)
            }
        }
    }
}

// MARK: - Empty state

/// A teaching empty state — glyph + title + one line of guidance + optional action. Replaces the
/// bare `Text("nothing here")` placeholders.
struct CBEmptyState: View {
    let systemImage: String
    let title: String
    var message: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: Space.m) {
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            VStack(spacing: Space.xs) {
                Text(title).font(.cbHeadline).foregroundStyle(Theme.textPrimary)
                if let message {
                    Text(message)
                        .font(.cbCallout).foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.cbPrimary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Space.xl)
    }
}

// MARK: - Stat tile (mono — no colored/pastel tiles)

/// A dashboard stat: naked accent glyph, big value, quiet label. Deliberately mono — the founder
/// rejects rainbow/pastel icon tiles as "AI slop". `tint` defaults to the brand accent; pass a
/// status color ONLY when the value is genuinely a status (e.g. engine offline).
struct CBStatTile: View {
    let title: String
    let value: String
    let systemImage: String
    var tint: Color = Theme.accent
    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(tint)
            Text(value)
                .font(.cbTitle)
                .foregroundStyle(Theme.textPrimary)
                .contentTransition(.numericText())
            Text(title)
                .font(.cbCaption)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cbCard(padding: Space.l)
    }
}
