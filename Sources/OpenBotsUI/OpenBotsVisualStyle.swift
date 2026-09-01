import SwiftUI

/// Neutral surfaces for the approved chat-first workspace. Distinctive color
/// remains in each bot's existing character, rather than the application chrome.
///
/// These values deliberately stop at color, spacing, and corner geometry.
/// Typography, controls, focus, and materials continue to come from SwiftUI's
/// macOS semantic system so accessibility settings retain their native effect.
public enum OpenBotsVisualStyle {
    public static let spacing4: CGFloat = 4
    public static let spacing8: CGFloat = 8
    public static let spacing12: CGFloat = 12
    public static let spacing16: CGFloat = 16
    public static let spacing24: CGFloat = 24
    public static let spacing32: CGFloat = 32

    public static let radiusSmall: CGFloat = 8
    public static let radiusMedium: CGFloat = 12
    public static let radiusLarge: CGFloat = 16

    public static func canvas(for colorScheme: ColorScheme) -> Color {
        switch colorScheme {
        case .dark:
            rgb(0x0D, 0x0D, 0x0E)
        default:
            rgb(0xFA, 0xFA, 0xFA)
        }
    }

    public static func surface(for colorScheme: ColorScheme) -> Color {
        switch colorScheme {
        case .dark:
            rgb(0x19, 0x19, 0x1B)
        default:
            rgb(0xF1, 0xF1, 0xF2)
        }
    }

    public static func brandAccent(for colorScheme: ColorScheme) -> Color {
        switch colorScheme {
        case .dark:
            rgb(0xE7, 0xE7, 0xE9)
        default:
            rgb(0x30, 0x30, 0x33)
        }
    }

    public static func brandWash(for colorScheme: ColorScheme) -> Color {
        switch colorScheme {
        case .dark:
            rgb(0x30, 0x30, 0x32)
        default:
            rgb(0xE5, 0xE5, 0xE8)
        }
    }

    public static func elevatedSurface(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? rgb(0x25, 0x25, 0x27) : rgb(0xFF, 0xFF, 0xFF)
    }

    public static func secondaryText(for colorScheme: ColorScheme) -> Color {
        // Normal-size text remains readable on the darkest and raised surfaces.
        colorScheme == .dark ? rgb(0xB8, 0xB8, 0xBE) : rgb(0x57, 0x57, 0x60)
    }

    public static func border(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? rgb(0x38, 0x38, 0x3B) : rgb(0xD7, 0xD7, 0xDB)
    }

    private static func rgb(_ red: Int, _ green: Int, _ blue: Int) -> Color {
        Color(
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255
        )
    }
}
