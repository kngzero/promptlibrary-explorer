import CoreGraphics
import Foundation

/// A Mood board document (`.mlmboard`), normalised from any supported encoding.
public struct Moodboard: Sendable {
    public enum LayoutMode: String, Sendable, Hashable, CaseIterable {
        case auto, grid, mosaic
    }

    /// Mac Mood only: `infinite` boards place items freely. nil = grid (web default).
    public enum BoardMode: String, Sendable, Hashable {
        case grid, infinite
    }

    public var title: String = MoodboardDefaults.title
    public var subtitle: String = MoodboardDefaults.subtitle
    public var hideTitle: Bool = false
    public var hideSubtitle: Bool = false
    public var layoutMode: LayoutMode = .auto
    public var boardMode: BoardMode?
    public var columns: Int = 4
    public var gap: Double = 12
    public var padding: Double = 32
    public var rounded: Bool = true
    public var shadow: Bool = true
    public var safeMargin: Double = 0
    public var zoom: Double = 100
    public var aspectRatio: String = "auto"
    public var imageBorder: Bool = false
    public var imageBorderWidth: Double = 2
    public var imageBorderHex: String = "#FFFFFF"
    public var canvasWidth: Int?
    public var canvasHeight: Int?
    public var backgroundHex: String = MoodboardPalette.defaultPalette[0]
    public var textHex: String = MoodboardPalette.defaultPalette[6]
    public var palette: [String] = MoodboardPalette.defaultPalette
    public var customPalette: [String] = []
    public var font: String = "font-inter"
    public var logo: MoodboardLogo?
    public var background: MoodboardBackground?
    public var assets: [MoodboardAsset] = []
    public var tiles: [MoodboardTile] = []
    public var isLegacyArchive: Bool = false
    public var sourceByteCount: Int = 0

    public init() {}

    public func asset(id: String) -> MoodboardAsset? {
        assets.first { $0.id == id }
    }

    public var logoAsset: MoodboardAsset? { logo.flatMap { asset(id: $0.assetId) } }
    public var backgroundAsset: MoodboardAsset? { background.flatMap { asset(id: $0.assetId) } }
    public var imageTileCount: Int { tiles.filter { $0.assetId != nil }.count }

    /// Parsed aspect ratio (w/h) or nil for "auto"/unparseable.
    public var aspectRatioValue: Double? {
        if let w = canvasWidth, let h = canvasHeight, w > 0, h > 0 { return Double(w) / Double(h) }
        let parts = aspectRatio.split(separator: ":")
        guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]), w > 0, h > 0 else { return nil }
        return w / h
    }
}

public struct MoodboardAsset: Sendable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        case image, logo
    }

    public var id: String
    public var name: String
    public var kind: Kind
    public var image: EmbeddedImage

    public init(id: String, name: String, kind: Kind, image: EmbeddedImage) {
        self.id = id
        self.name = name
        self.kind = kind
        self.image = image
    }
}

public struct MoodboardTile: Sendable, Identifiable {
    public enum Content: Sendable {
        /// `pan` is a ratio of the tile size; (0,0) = centred. `zoom` >= 1.
        case image(assetId: String, pan: CGPoint, zoom: Double)
        case color(hex: String)
        /// Text tiles (web + Mac Mood).
        case text(String, textHex: String?, backgroundHex: String?, fontSize: Int?, alignment: String?, bold: Bool)
    }

    public var id: String
    public var colSpan: Int
    public var rowSpan: Int
    public var caption: String?
    public var content: Content

    public init(id: String, colSpan: Int = 1, rowSpan: Int = 1, caption: String? = nil, content: Content) {
        self.id = id
        self.colSpan = max(1, colSpan)
        self.rowSpan = max(1, rowSpan)
        self.caption = caption
        self.content = content
    }

    public var assetId: String? {
        if case .image(let id, _, _) = content { return id }
        return nil
    }
}

public struct MoodboardLogo: Sendable, Hashable {
    public var assetId: String
    public var scale: Double
    /// "top-left" | "top-right" | "bottom-left" | "bottom-right"
    public var position: String

    public init(assetId: String, scale: Double, position: String) {
        self.assetId = assetId
        self.scale = scale
        self.position = position
    }
}

public struct MoodboardBackground: Sendable, Hashable {
    public var assetId: String
    public var opacity: Double
    public var blur: Double

    public init(assetId: String, opacity: Double, blur: Double) {
        self.assetId = assetId
        self.opacity = opacity
        self.blur = blur
    }
}

enum MoodboardDefaults {
    static let title = "My Mood Board"
    static let subtitle = "Project Name"
}
