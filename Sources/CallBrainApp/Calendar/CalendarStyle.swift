import SwiftUI

/// Calendar v3 shared visual language (Notion-style): quiet chrome, loud events. Event
/// surfaces use SOLID calendar-color fills with auto-contrast text — not tinted pastels.
extension Color {
    init?(hex: String?) {
        guard let rgb = CalendarStyle.rgb(hex) else { return nil }
        self = Color(red: rgb.r, green: rgb.g, blue: rgb.b)
    }
}

enum CalendarStyle {
    static func rgb(_ hex: String?) -> (r: Double, g: Double, b: Double)? {
        guard let hex, hex.hasPrefix("#"), hex.count == 7,
              let v = Int(hex.dropFirst(), radix: 16) else { return nil }
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }
}

/// One derivation for every event surface (week block, all-day pill, month chip): solid fill,
/// text picked by luminance so light calendar colors (yellows) stay legible in both modes.
enum EventPalette {
    struct Style {
        let base: Color            // the raw calendar color (selection rings, bars, dots)
        let fill: Color
        let text: Color
        var secondaryText: Color { text.opacity(0.75) }
    }

    static func style(hex: String?, scheme: ColorScheme) -> Style {
        // Fallback = Theme.accent's components (violet).
        let (r, g, b) = CalendarStyle.rgb(hex) ?? (0.45, 0.36, 0.93)
        let base = Color(red: r, green: g, blue: b)
        // WCAG relative luminance (P3 audit MED): the YIQ heuristic picked white text on
        // bright greens where black is the readable choice. Linearize, then threshold.
        func lin(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let lum = 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
        if scheme == .dark {
            return Style(base: base, fill: base.opacity(0.82),
                         text: (lum * 0.82) > 0.35 ? Color.black.opacity(0.82) : .white)
        }
        return Style(base: base, fill: base,
                     text: lum > 0.4 ? Color.black.opacity(0.78) : .white)
    }
}
