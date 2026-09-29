import AppKit
import SwiftUI

enum AppAppearanceMode: String, CaseIterable, Identifiable {
    /// Follow the macOS system appearance.
    case system
    case dark
    case light

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .dark: return "Dark"
        case .light: return "Light"
        }
    }

    /// The scheme to hand `.preferredColorScheme(_:)`. Always explicit: for
    /// `.system` it is the Mac's current setting. SwiftUI's
    /// `.preferredColorScheme(nil)` releases the window's AppKit appearance but
    /// leaves SwiftUI's own `colorScheme` on the last forced scheme, so Dark →
    /// System turned only the AppKit-drawn parts light.
    @MainActor
    var preferredColorScheme: ColorScheme {
        switch self {
        case .system: return SystemAppearance.shared.colorScheme
        case .dark: return .dark
        case .light: return .light
        }
    }

    /// AppKit appearance for this mode (`nil` = inherit from the system).
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .dark: return NSAppearance(named: .darkAqua)
        case .light: return NSAppearance(named: .aqua)
        }
    }

    /// Applies the mode at the AppKit level too (menus, panels, alerts). For
    /// System it clears the explicit appearances, then re-reads the Mac's
    /// setting so `preferredColorScheme` resolves against it.
    @MainActor
    func applyToApp() {
        NSApp?.appearance = nsAppearance
        for window in NSApp?.windows ?? [] {
            window.appearance = nsAppearance
        }
        SystemAppearance.shared.refresh()
    }
}

/// The Mac's light/dark setting, which `.system` resolves to.
@MainActor
@Observable
final class SystemAppearance {
    static let shared = SystemAppearance()

    private(set) var colorScheme: ColorScheme = .dark
    @ObservationIgnored private var observation: NSKeyValueObservation?

    private init() { refresh() }

    /// NSApp's effective appearance is the system's only while the app sets
    /// none, so it is read only then. `applyToApp()` calls this after clearing
    /// it for `.system`; KVO calls it when the Mac's setting changes.
    func refresh() {
        guard let app = NSApp else { return }
        if observation == nil {
            observation = app.observe(\.effectiveAppearance) { _, _ in
                Task { @MainActor in SystemAppearance.shared.refresh() }
            }
        }
        guard app.appearance == nil else { return }
        let scheme: ColorScheme = app.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
        if scheme != colorScheme { colorScheme = scheme }
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
    static let appElevatedSurface = ThemePalette.color(dark: (0x26, 0x26, 0x26), light: (0xD9, 0xD9, 0xD9))   // neutral (owner, 2026-09-28)

    /// Primary accent: fuchsia on dark (#d946ef), deeper magenta on light (#a726bd)
    static let appAccent = ThemePalette.color(dark: (0xD9, 0x46, 0xEF), light: (0xA7, 0x26, 0xBD))

    /// Accent hover: light fuchsia on dark (#f0abfc), darker magenta on light (#8e1f9f)
    static let appAccentHover = ThemePalette.color(dark: (0xF0, 0xAB, 0xFC), light: (0x8E, 0x1F, 0x9F))

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
    static let appSidebarBackground = ThemePalette.color(dark: (0x1E, 0x1E, 0x1E), light: (0xE1, 0xE1, 0xDE))   // neutral dark (owner, 2026-09-28)

    /// Sidebar top-level section headers (Favorites, Recent, …). ~15:1 on the light sidebar.
    static let appSidebarHeaderText = ThemePalette.color(dark: (0xA1, 0xA1, 0xAA), light: (0x1A, 0x1A, 0x1A))
    /// Sidebar row labels when not selected. ~13:1 on the light sidebar.
    static let appSidebarText = ThemePalette.color(dark: (0xA1, 0xA1, 0xAA), light: (0x26, 0x26, 0x24))
    /// Sidebar counts, paths, hints and chevrons. ~7.5:1 on the light sidebar.
    static let appSidebarSecondaryText = ThemePalette.color(dark: (0xA1, 0xA1, 0xAA), light: (0x4A, 0x4A, 0x44))

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

// MARK: - File Type Badge Colors

extension Color {
    /// .plib badge: vivid magenta
    static let badgePlib = Color(red: 0xD9 / 255.0, green: 0x00 / 255.0, blue: 0xD9 / 255.0)
    /// .aoe badge: electric purple
    static let badgeAoe = Color(red: 0x8B / 255.0, green: 0x5C / 255.0, blue: 0xF6 / 255.0)
    /// .mlmboard (Mood board) badge: deep gold
    static let badgeMood = Color(red: 0xCA / 255.0, green: 0x8A / 255.0, blue: 0x04 / 255.0)
    /// .stry / .mlseq (Story project) badge: indigo
    static let badgeStory = Color(red: 0x63 / 255.0, green: 0x66 / 255.0, blue: 0xF1 / 255.0)
    /// PNG badge: teal
    static let badgePng = Color(red: 0x06 / 255.0, green: 0xB6 / 255.0, blue: 0xD4 / 255.0)
    /// JPEG badge: amber
    static let badgeJpg = Color(red: 0xF9 / 255.0, green: 0x73 / 255.0, blue: 0x16 / 255.0)
    /// WebP badge: green
    static let badgeWebp = Color(red: 0x22 / 255.0, green: 0xC5 / 255.0, blue: 0x5E / 255.0)
    /// GIF badge: pink
    static let badgeGif = Color(red: 0xEC / 255.0, green: 0x48 / 255.0, blue: 0x99 / 255.0)
    /// Video badge: red
    static let badgeVideo = Color(red: 0xEF / 255.0, green: 0x44 / 255.0, blue: 0x44 / 255.0)
    /// Audio badge: violet
    static let badgeAudio = Color(red: 0xA7 / 255.0, green: 0x55 / 255.0, blue: 0xF5 / 255.0)
    /// Other image badge: blue
    static let badgeImage = Color(red: 0x3B / 255.0, green: 0x82 / 255.0, blue: 0xF6 / 255.0)
    /// Generic file badge: gray
    static let badgeFile = Color(red: 0x6B / 255.0, green: 0x72 / 255.0, blue: 0x80 / 255.0)
    /// Favorite pin: gold
    static let favoriteGold = Color(red: 0xFA / 255.0, green: 0xCC / 255.0, blue: 0x15 / 255.0)
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

// MARK: - Text-safe Colour Variants
//
// The decorative badge / segment / favourite colours above are tuned for fills
// and dots. Used as text or thin glyphs they wash out on light surfaces, so
// these variants keep the hue but meet ~4.5:1 on appCanvasBackground,
// appSurface, appBackground and appSidebarBackground in both modes.

extension Color {
    static let favoriteGoldText = ThemePalette.color(dark: (0xFA, 0xCC, 0x15), light: (0x7A, 0x5A, 0x00))

    static let segmentFullPromptText = ThemePalette.color(dark: (0x8F, 0xA3, 0xCC), light: (0x3D, 0x5A, 0x8C))
    static let segmentBriefText = ThemePalette.color(dark: (0x99, 0xCC, 0x99), light: (0x2F, 0x6B, 0x2F))
    static let segmentSubjectText = ThemePalette.color(dark: (0xD9, 0xA6, 0x73), light: (0x85, 0x50, 0x1F))
    static let segmentActionText = ThemePalette.color(dark: (0xD9, 0x80, 0x80), light: (0xA3, 0x3A, 0x3A))
    static let segmentPlaceText = ThemePalette.color(dark: (0x8C, 0xBF, 0xBF), light: (0x2B, 0x63, 0x63))
    static let segmentStyleText = ThemePalette.color(dark: (0xBF, 0x8C, 0xCC), light: (0x7A, 0x3D, 0x8A))
    static let segmentLightingText = ThemePalette.color(dark: (0xE6, 0xD9, 0x73), light: (0x6E, 0x5F, 0x00))
    static let segmentCameraText = ThemePalette.color(dark: (0x80, 0xA6, 0xD9), light: (0x2F, 0x5A, 0x99))
    static let segmentPaletteText = ThemePalette.color(dark: (0xCC, 0x8C, 0xA6), light: (0x8C, 0x3D, 0x5A))
    static let segmentMoodText = ThemePalette.color(dark: (0xA6, 0xCC, 0x8C), light: (0x42, 0x6B, 0x2C))

    static let badgePlibText = ThemePalette.color(dark: (0xE8, 0x60, 0xE8), light: (0xA0, 0x00, 0xA0))
    static let badgeAoeText = ThemePalette.color(dark: (0xA3, 0x88, 0xF9), light: (0x6A, 0x3C, 0xD6))
    static let badgeMoodText = ThemePalette.color(dark: (0xEA, 0xB3, 0x08), light: (0x7A, 0x5C, 0x00))
    static let badgeStoryText = ThemePalette.color(dark: (0x8B, 0x8F, 0xF8), light: (0x3F, 0x42, 0xC9))
    static let badgePngText = ThemePalette.color(dark: (0x06, 0xB6, 0xD4), light: (0x0B, 0x6A, 0x7B))
    static let badgeJpgText = ThemePalette.color(dark: (0xF9, 0x73, 0x16), light: (0xA8, 0x46, 0x00))
    static let badgeWebpText = ThemePalette.color(dark: (0x22, 0xC5, 0x5E), light: (0x18, 0x73, 0x3A))
    static let badgeGifText = ThemePalette.color(dark: (0xF0, 0x6A, 0xAA), light: (0xB0, 0x21, 0x5F))
    static let badgeVideoText = ThemePalette.color(dark: (0xF0, 0x60, 0x60), light: (0xBD, 0x25, 0x25))
    static let badgeAudioText = ThemePalette.color(dark: (0xB7, 0x7A, 0xF7), light: (0x7B, 0x32, 0xC2))
    static let badgeImageText = ThemePalette.color(dark: (0x5B, 0x9A, 0xF8), light: (0x23, 0x56, 0xC2))
    static let badgeFileText = ThemePalette.color(dark: (0x9C, 0xA3, 0xAF), light: (0x52, 0x58, 0x62))

    /// Text drawn on a solid `appAccent` fill (small badges). Near-black on the
    /// bright dark-mode fuchsia, white on the deeper light-mode magenta.
    static let appOnAccent = ThemePalette.color(dark: (0x1A, 0x06, 0x20), light: (0xFF, 0xFF, 0xFF))

    /// Label colour for a filled button in its disabled state (on appElevatedSurface).
    static let appDisabledText = ThemePalette.color(dark: (0xA1, 0xA1, 0xAA), light: (0x5E, 0x5E, 0x55))
}

// MARK: - Analysis Segment Lookup

extension Color {
    /// Decorative segment colour for a prompt-analysis key (fills, strokes).
    static func segment(forAnalysisKey key: String) -> Color? {
        switch key {
        case "fullPrompt": return .segmentFullPrompt
        case "shortDescription": return .segmentBrief
        case "subject": return .segmentSubject
        case "subjectPose": return .segmentAction
        case "composition": return .segmentPlace
        case "artStyle": return .segmentStyle
        case "cameraSettings": return .segmentCamera
        case "lighting": return .segmentLighting
        case "colorPalette": return .segmentPalette
        case "mood": return .segmentMood
        default: return nil
        }
    }

    /// Text-safe segment colour for a prompt-analysis key (labels, glyphs).
    static func segmentText(forAnalysisKey key: String) -> Color? {
        switch key {
        case "fullPrompt": return .segmentFullPromptText
        case "shortDescription": return .segmentBriefText
        case "subject": return .segmentSubjectText
        case "subjectPose": return .segmentActionText
        case "composition": return .segmentPlaceText
        case "artStyle": return .segmentStyleText
        case "cameraSettings": return .segmentCameraText
        case "lighting": return .segmentLightingText
        case "colorPalette": return .segmentPaletteText
        case "mood": return .segmentMoodText
        default: return nil
        }
    }
}

// MARK: - Finder Label Colours
//
// Fills for Finder colour-label dots, stripes and swatches (Finder's hues), plus
// text-safe variants (~4.5:1 on the app surfaces in both modes) for label names
// and thin glyphs.

extension Color {
    static let labelRed = ThemePalette.color(dark: (0xFF, 0x45, 0x3A), light: (0xFF, 0x3B, 0x30))
    static let labelOrange = ThemePalette.color(dark: (0xFF, 0x9F, 0x0A), light: (0xFF, 0x95, 0x00))
    static let labelYellow = ThemePalette.color(dark: (0xFF, 0xD6, 0x0A), light: (0xF5, 0xC4, 0x00))
    static let labelGreen = ThemePalette.color(dark: (0x32, 0xD7, 0x4B), light: (0x28, 0xCD, 0x41))
    static let labelBlue = ThemePalette.color(dark: (0x0A, 0x84, 0xFF), light: (0x00, 0x7A, 0xFF))
    static let labelPurple = ThemePalette.color(dark: (0xBF, 0x5A, 0xF2), light: (0xAF, 0x52, 0xDE))
    static let labelGray = ThemePalette.color(dark: (0x98, 0x98, 0x9D), light: (0x8E, 0x8E, 0x93))

    static let labelRedText = ThemePalette.color(dark: (0xFF, 0x6B, 0x62), light: (0xB3, 0x26, 0x1E))
    static let labelOrangeText = ThemePalette.color(dark: (0xFF, 0xA8, 0x33), light: (0xA3, 0x52, 0x00))
    static let labelYellowText = ThemePalette.color(dark: (0xFF, 0xD6, 0x0A), light: (0x7A, 0x5C, 0x00))
    static let labelGreenText = ThemePalette.color(dark: (0x4A, 0xDB, 0x62), light: (0x1E, 0x7A, 0x30))
    static let labelBlueText = ThemePalette.color(dark: (0x40, 0x9C, 0xFF), light: (0x00, 0x58, 0xC7))
    static let labelPurpleText = ThemePalette.color(dark: (0xC9, 0x7B, 0xF5), light: (0x8A, 0x2B, 0xB8))
    static let labelGrayText = ThemePalette.color(dark: (0xA1, 0xA1, 0xAA), light: (0x5E, 0x5E, 0x63))
}

extension FinderLabel {
    /// Decorative fill (dots, stripes, swatches). `.none` is muted.
    var color: Color {
        switch self {
        case .none: return .appMuted
        case .red: return .labelRed
        case .orange: return .labelOrange
        case .yellow: return .labelYellow
        case .green: return .labelGreen
        case .blue: return .labelBlue
        case .purple: return .labelPurple
        case .gray: return .labelGray
        }
    }

    /// Text-safe variant for label names and thin glyphs.
    var textColor: Color {
        switch self {
        case .none: return .appMuted
        case .red: return .labelRedText
        case .orange: return .labelOrangeText
        case .yellow: return .labelYellowText
        case .green: return .labelGreenText
        case .blue: return .labelBlueText
        case .purple: return .labelPurpleText
        case .gray: return .labelGrayText
        }
    }
}

extension FileFlag {
    /// Text-safe tint for the flag glyph (pick = accent, reject = error red).
    var tint: Color {
        switch self {
        case .pick: return .appAccent
        case .unflagged: return .appMuted
        case .reject: return .appError
        }
    }
}

// MARK: - Font Helpers

extension Font {
    static let appLargeTitle = Font.system(size: 20, weight: .semibold)
    static let appTitle = Font.system(size: 14, weight: .semibold)
    static let appHeadline = Font.system(size: 13, weight: .semibold)
    static let appBody = Font.system(size: 13)
    static let appCallout = Font.system(size: 12)
    static let appCalloutEmphasis = Font.system(size: 12, weight: .semibold)
    static let appCaption = Font.system(size: 11, weight: .regular)
    static let appCaptionEmphasis = Font.system(size: 11, weight: .semibold)
    static let appFootnote = Font.system(size: 10)
    static let appMicro = Font.system(size: 9, weight: .semibold)
    static let appMono = Font.system(size: 12, design: .monospaced)

    // Sidebar
    static let appSidebarHeader = Font.system(size: 14, weight: .bold)
    static let appSidebarItem = Font.system(size: 13)
    static let appSidebarItemEmphasis = Font.system(size: 13, weight: .semibold)
    static let appSidebarDetail = Font.system(size: 11)

    /// Point-size sizing for SF Symbols and other glyphs.
    static func appIcon(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.system(size: size, weight: weight)
    }
}

// MARK: - Radius & Spacing

enum AppRadius {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 6
    static let md: CGFloat = 8
    static let lg: CGFloat = 12
    static let xl: CGFloat = 16
    static let xxl: CGFloat = 20
}

enum AppSpacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 6
    static let md: CGFloat = 8
    static let lg: CGFloat = 12
    static let xl: CGFloat = 16
    static let xxl: CGFloat = 24
    static let xxxl: CGFloat = 32
}

enum LayoutMetrics {
    static let panelHeaderHeight: CGFloat = 44
}
