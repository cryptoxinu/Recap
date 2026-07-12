import SwiftUI

/// Minimal flow layout — wraps its subviews (chips) to the available width.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > maxWidth { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}

/// A small accent capsule used for participants, entities, filters.
struct Chip: View {
    let text: String
    var icon: String? = nil
    var tint: Color = Theme.accent
    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.caption2) }
            Text(text).font(.caption)
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(tint.opacity(0.12), in: Capsule())
        .foregroundStyle(tint)
    }
}
