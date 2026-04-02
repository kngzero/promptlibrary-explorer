import AppKit
import SwiftUI

enum AppAppearanceMode: String, CaseIterable, Identifiable {
    case dark
    case light

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dark: return "Dark"
        case .light: return "Light"
        }
    }

    var colorScheme: ColorScheme {
        switch self {
        case .dark: return .dark
        case .light: return .light
        }
    }
}

private enum ThemePalette {
    static func color(
        dark: (red: Int, green: Int, blue: Int),
        light: (red: Int, green: Int, blue: Int)? = nil
    ) -> Color {
        color(
            dark: (dark.red, dark.green, dark.blue, 1),
            light: light.map { ($0.red, $0.green, $0.blue, 1) }
        )
    }

    static func color(
        dark: (red: Int, green: Int, blue: Int, alpha: CGFloat),
        light: (red: Int, green: Int, blue: Int, alpha: CGFloat)? = nil
    ) -> Color {
        let darkColor = nsColor(red: dark.red, green: dark.green, blue: dark.blue, alpha: dark.alpha)
        let lightColor = light.map {
            nsColor(red: $0.red, green: $0.green, blue: $0.blue, alpha: $0.alpha)
        } ?? nsColor(
            red: 255 - dark.red,
            green: 255 - dark.green,
            blue: 255 - dark.blue,
            alpha: dark.alpha
        )

        return Color(nsColor: NSColor(name: nil) { appearance in
            let bestMatch = appearance.bestMatch(from: [.darkAqua, .aqua])
            return bestMatch == .darkAqua ? darkColor : lightColor
        })
    }

    private static func nsColor(red: Int, green: Int, blue: Int, alpha: CGFloat) -> NSColor {
        NSColor(
            calibratedRed: CGFloat(red) / 255.0,
            green: CGFloat(green) / 255.0,
            blue: CGFloat(blue) / 255.0,
            alpha: alpha
        )
    }
}

// MARK: - Brand Colors

extension Color {
    /// Main background: neutral-900 (#171717)
    static let appBackground = ThemePalette.color(dark: (0x17, 0x17, 0x17), light: (0xE8, 0xE8, 0xE8))

    /// Inset panel/tile surface (neutral and darker than the main background)
    static let appSurface = ThemePalette.color(dark: (0x10, 0x10, 0x10), light: (0xEF, 0xEF, 0xEF))

    /// Elevated button/background surface for controls on dark panels
    static let appElevatedSurface = ThemePalette.color(dark: (0x26, 0x26, 0x30), light: (0xD9, 0xD9, 0xCF))

    /// Primary accent: fuchsia (#d946ef)
    static let appAccent = ThemePalette.color(dark: (0xD9, 0x46, 0xEF), light: (0xD9, 0x46, 0xEF))

    /// Accent hover: light fuchsia (#f0abfc)
    static let appAccentHover = ThemePalette.color(dark: (0xF0, 0xAB, 0xFC), light: (0xF0, 0xAB, 0xFC))

    /// Scrollbar thumb (#3f3f46)
    static let appThumb = ThemePalette.color(dark: (0x3F, 0x3F, 0x46), light: (0xC0, 0xC0, 0xB9))

    /// Muted text / secondary (#a1a1aa ~ zinc-400)
    static let appMuted = ThemePalette.color(dark: (0xA1, 0xA1, 0xAA), light: (0x5E, 0x5E, 0x55))

    /// Primary text on neutral app surfaces
    static let appPrimaryText = ThemePalette.color(dark: (0xFF, 0xFF, 0xFF), light: (0x12, 0x12, 0x12))

    /// Hover highlight for rows/items
    static let appHover = ThemePalette.color(
        dark: (0xFF, 0xFF, 0xFF, 0.06),
        light: (0x00, 0x00, 0x00, 0.05)
    )

    /// Selected item highlight
    static let appSelected = Color.appAccent.opacity(0.18)

    /// Border / separator
    static let appBorder = ThemePalette.color(
        dark: (0xFF, 0xFF, 0xFF, 0.08),
        light: (0x00, 0x00, 0x00, 0.08)
    )

    /// Stronger border for controls that need separation from dark sidebars
    static let appControlBorder = ThemePalette.color(
        dark: (0xFF, 0xFF, 0xFF, 0.16),
        light: (0x00, 0x00, 0x00, 0.14)
    )

    /// Success green (#22c55e ~ green-500)
    static let appSuccess = ThemePalette.color(dark: (0x22, 0xC5, 0x5E), light: (0x16, 0xA3, 0x4A))

    /// Error red (#ef4444 ~ red-500)
    static let appError = ThemePalette.color(dark: (0xEF, 0x44, 0x44), light: (0xDC, 0x26, 0x26))

    /// Sidebar backgrounds used by detail-heavy panels
    static let appSidebarBackground = ThemePalette.color(dark: (0x1E, 0x1E, 0x21), light: (0xE1, 0xE1, 0xDE))

    /// Canvas background behind fullscreen/lightbox imagery
    static let appCanvasBackground = ThemePalette.color(dark: (0x00, 0x00, 0x00), light: (0xF7, 0xF7, 0xF7))

    /// Overlay chrome for floating controls on the lightbox canvas
    static let appOverlaySurface = ThemePalette.color(
        dark: (0x00, 0x00, 0x00, 0.62),
        light: (0xFF, 0xFF, 0xFF, 0.90)
    )
    static let appOverlayStroke = ThemePalette.color(
        dark: (0xFF, 0xFF, 0xFF, 0.12),
        light: (0x00, 0x00, 0x00, 0.08)
    )
    static let appOverlayDivider = ThemePalette.color(
        dark: (0xFF, 0xFF, 0xFF, 0.14),
        light: (0x00, 0x00, 0x00, 0.12)
    )
    static let appOverlayActiveFill = ThemePalette.color(
        dark: (0xFF, 0xFF, 0xFF, 0.14),
        light: (0x00, 0x00, 0x00, 0.08)
    )
    static let appShadowColor = ThemePalette.color(
        dark: (0x00, 0x00, 0x00, 0.25),
        light: (0x00, 0x00, 0x00, 0.12)
    )
}

// MARK: - Analysis Segment Colors

extension Color {
    static let segmentFullPrompt = Color(red: 0.56, green: 0.64, blue: 0.80)
    static let segmentBrief = Color(red: 0.60, green: 0.80, blue: 0.60)
    static let segmentSubject = Color(red: 0.85, green: 0.65, blue: 0.45)
    static let segmentAction = Color(red: 0.85, green: 0.50, blue: 0.50)
    static let segmentPlace = Color(red: 0.55, green: 0.75, blue: 0.75)
    static let segmentStyle = Color(red: 0.75, green: 0.55, blue: 0.80)
    static let segmentLighting = Color(red: 0.90, green: 0.85, blue: 0.45)
    static let segmentCamera = Color(red: 0.50, green: 0.65, blue: 0.85)
    static let segmentPalette = Color(red: 0.80, green: 0.55, blue: 0.65)
    static let segmentMood = Color(red: 0.65, green: 0.80, blue: 0.55)
}

// MARK: - Font Helpers

extension Font {
    static let appTitle = Font.system(size: 14, weight: .semibold)
    static let appBody = Font.system(size: 13)
    static let appCaption = Font.system(size: 11, weight: .regular)
    static let appMono = Font.system(size: 12, design: .monospaced)
}

enum LayoutMetrics {
    static let panelHeaderHeight: CGFloat = 44
}
