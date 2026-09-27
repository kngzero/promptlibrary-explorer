import Foundation

/// Input for `MoodboardWriter`. Produces a board with one 1x1 image tile per image.
public struct MoodboardDraft: Sendable {
    public struct Image: Sendable {
        public var name: String
        public var data: Data
        public var mimeType: String

        public init(name: String, data: Data, mimeType: String) {
            self.name = name
            self.data = data
            self.mimeType = mimeType
        }
    }

    public var title: String
    public var subtitle: String
    public var images: [Image]
    /// nil -> web "Default" palette.
    public var palette: [String]?
    public var layoutMode: Moodboard.LayoutMode
    public var columns: Int
    /// nil -> first palette colour (web default behaviour).
    public var backgroundHex: String?
    /// nil -> last palette colour.
    public var textHex: String?

    public init(
        title: String = "My Mood Board",
        subtitle: String = "Project Name",
        images: [Image] = [],
        palette: [String]? = nil,
        layoutMode: Moodboard.LayoutMode = .auto,
        columns: Int = 4,
        backgroundHex: String? = nil,
        textHex: String? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.images = images
        self.palette = palette
        self.layoutMode = layoutMode
        self.columns = columns
        self.backgroundHex = backgroundHex
        self.textHex = textHex
    }
}

/// Writes the CURRENT `.mlmboard` JSON format (web `ProjectState`, base64 data-URL
/// assets), which both the web app and Mac Mood (`WebProjectFile`) load.
public enum MoodboardWriter {
    public static func write(_ draft: MoodboardDraft, to url: URL) throws {
        try FileLoader.write(encode(draft), to: url)
    }

    /// Streams the JSON into a single buffer: each image is base64-encoded once and
    /// appended, so no intermediate full-document object graph is built.
    public static func encode(_ draft: MoodboardDraft) throws -> Data {
        let palette = (draft.palette ?? []).compactMap(Hex.normalize)
        let resolvedPalette = palette.isEmpty ? MoodboardPalette.defaultPalette : palette
        let background = Hex.normalize(draft.backgroundHex) ?? resolvedPalette.first ?? "#FFFFFF"
        let text = Hex.normalize(draft.textHex)
            ?? (resolvedPalette.count >= 2 ? resolvedPalette.last! : "#1F2937")

        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        var out = Data()
        out.reserveCapacity(draft.images.reduce(4096) { $0 + $1.data.count * 4 / 3 + 256 })
        func put(_ s: String) { out.append(contentsOf: Array(s.utf8)) }

        var assetIDs: [String] = []
        put("{\n  \"assets\": [")
        for (i, image) in draft.images.enumerated() {
            let id = "asset-\(stamp)-\(i)-\(UUID().uuidString.prefix(8).lowercased())"
            assetIDs.append(id)
            let mime = image.mimeType.isEmpty ? (MIME.sniff(image.data) ?? "application/octet-stream") : image.mimeType
            put(i == 0 ? "\n    {" : ",\n    {")
            put("\n      \"id\": \(JSON.quote(id)),")
            put("\n      \"name\": \(JSON.quote(image.name)),")
            put("\n      \"type\": \"image\",")
            put("\n      \"url\": \"data:\(mime);base64,")
            out.append(image.data.base64EncodedData())
            put("\"\n    }")
        }
        put(draft.images.isEmpty ? "],\n" : "\n  ],\n")

        put("  \"canvasItems\": [")
        for (i, assetID) in assetIDs.enumerated() {
            let item: [String: Any] = [
                "id": "item-\(stamp)-\(i)",
                "type": "image",
                "assetId": assetID,
                "colSpan": 1,
                "rowSpan": 1,
                "position": ["x": 0, "y": 0],
                "zoom": 1,
            ]
            put(i == 0 ? "\n    " : ",\n    ")
            put(JSON.fragment(item))
        }
        put(assetIDs.isEmpty ? "],\n" : "\n  ],\n")

        put("  \"layoutMode\": \(JSON.quote(draft.layoutMode.rawValue)),\n")
        let layoutOptions: [String: Any] = [
            "zoom": 100,
            "columns": max(1, min(draft.columns, 12)),
            "gap": 12,
            "boardPadding": 32,
            "roundedCorners": true,
            "softShadow": true,
            "safeMargin": 0,
            "aspectRatio": "auto",
            "imageBorder": false,
            "imageBorderWidth": 2,
            "imageBorderColor": "#FFFFFF",
        ]
        put("  \"layoutOptions\": \(JSON.fragment(layoutOptions)),\n")
        let branding: [String: Any] = [
            "font": "font-inter",
            "palette": resolvedPalette,
            "customPalette": [String](),
            "backgroundColor": background,
            "textColor": text,
            "title": draft.title,
            "subtitle": draft.subtitle,
        ]
        put("  \"branding\": \(JSON.fragment(branding))\n}\n")
        return out
    }
}
