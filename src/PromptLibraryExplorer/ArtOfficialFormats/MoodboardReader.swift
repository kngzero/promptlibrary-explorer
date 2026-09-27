import CoreGraphics
import Foundation

/// Reads `.mlmboard` files: current web JSON (base64 data-URL assets), the Mac Mood
/// variant of it (extra keys: `boardMode`, text tiles, `caption`, `hideTitle`,
/// `hideSubtitle`, `canvasWidth/Height`, freeform grid flags), Mac Mood's native
/// `ProjectState` Codable JSON, and the legacy ZIP archive (`meta.json` + `assets/`).
public enum MoodboardReader {
    public static func read(from url: URL) throws -> Moodboard {
        try read(data: FileLoader.load(url))
    }

    public static func read(data: Data) throws -> Moodboard {
        if ZipArchive.isZip(data) {
            var board = try readLegacyArchive(data)
            board.sourceByteCount = data.count
            return board
        }
        guard let root = JSON.parseObject(data) else { throw ArtOfficialFormatError.notJSON }
        var board: Moodboard
        if isNativeMacState(root) {
            board = readNativeMac(root)
        } else if root["board"] is JSONObject || (root["canvasItems"] == nil && root["meta"] != nil) {
            // A bare legacy meta.json (no archive): assets can't be resolved.
            board = readLegacyMeta(JSON.object(root, "meta") ?? root, archive: nil)
        } else {
            guard root["assets"] != nil || root["canvasItems"] != nil || root["branding"] != nil
                || root["layoutOptions"] != nil else {
                throw ArtOfficialFormatError.unsupportedFormat("No mood board keys found")
            }
            board = readCurrent(root)
        }
        board.sourceByteCount = data.count
        return board
    }

    // MARK: - Current (web / Mac web-compatible) JSON

    static func readCurrent(_ root: JSONObject) -> Moodboard {
        var board = Moodboard()
        var assetIDs = Set<String>()
        for a in JSON.objects(root, "assets") {
            guard let id = JSON.nonEmptyString(a, "id"),
                  let url = JSON.string(a, "url", "dataUrl", "src"),
                  let image = EmbeddedImage.parse(url) else { continue }
            let kind: MoodboardAsset.Kind = JSON.string(a, "type") == "logo" ? .logo : .image
            board.assets.append(MoodboardAsset(id: id, name: JSON.nonEmptyString(a, "name") ?? id, kind: kind, image: image))
            assetIDs.insert(id)
        }

        board.tiles = JSON.objects(root, "canvasItems").enumerated().compactMap { index, item in
            tile(from: item, index: index, validAssets: assetIDs, legacy: false)
        }

        if let mode = JSON.string(root, "layoutMode").flatMap(Moodboard.LayoutMode.init(rawValue:)) {
            board.layoutMode = mode
        }
        board.boardMode = JSON.string(root, "boardMode").flatMap(Moodboard.BoardMode.init(rawValue:))
        applyLayoutOptions(JSON.object(root, "layoutOptions"), to: &board)
        applyBranding(JSON.object(root, "branding"), to: &board, validAssets: assetIDs)
        return board
    }

    static func tile(from item: JSONObject, index: Int, validAssets: Set<String>, legacy: Bool) -> MoodboardTile? {
        let type = JSON.string(item, "type", "kind") ?? "image"
        let id = JSON.nonEmptyString(item, "id") ?? "item-\(index)"
        let colSpan = max(1, JSON.int(item, "colSpan") ?? 1)
        let rowSpan = max(1, JSON.int(item, "rowSpan") ?? 1)
        let caption = JSON.nonEmptyString(item, "caption")
        switch type {
        case "color":
            let hex = Hex.normalize(JSON.string(item, "hex")) ?? "#CCCCCC"
            return MoodboardTile(id: id, colSpan: colSpan, rowSpan: rowSpan, caption: caption, content: .color(hex: hex))
        case "text":
            let text = JSON.string(item, "text") ?? ""
            return MoodboardTile(id: id, colSpan: colSpan, rowSpan: rowSpan, caption: caption, content: .text(
                text,
                textHex: Hex.normalize(JSON.string(item, "textColor")),
                backgroundHex: Hex.normalize(JSON.string(item, "backgroundColor", "itemBackgroundColor")),
                fontSize: JSON.int(item, "fontSize"),
                alignment: JSON.string(item, "textAlign"),
                bold: JSON.string(item, "fontWeight") == "bold"
            ))
        default:
            guard let assetId = JSON.nonEmptyString(item, "assetId", "assetID"), validAssets.contains(assetId) else {
                return nil
            }
            var x = 0.0, y = 0.0
            var zoom = JSON.double(item, "zoom")
            if let pos = JSON.object(item, "position") {
                x = JSON.double(pos, "x") ?? 0
                y = JSON.double(pos, "y") ?? 0
            } else {
                x = JSON.double(item, "positionX") ?? 0
                y = JSON.double(item, "positionY") ?? 0
            }
            if legacy, let crop = JSON.object(item, "crop"), let cx = JSON.double(crop, "x") {
                x = (cx - 50) / 100
                y = ((JSON.double(crop, "y") ?? 50) - 50) / 100
                zoom = JSON.double(crop, "zoom") ?? zoom
            }
            // Spec: |x| or |y| > 2 are old pixel offsets -> reset.
            if abs(x) > 2 { x = 0 }
            if abs(y) > 2 { y = 0 }
            let z = min(max(zoom ?? 1, 1), 3)
            return MoodboardTile(id: id, colSpan: colSpan, rowSpan: rowSpan, caption: caption,
                                 content: .image(assetId: assetId, pan: CGPoint(x: x, y: y), zoom: z))
        }
    }

    static func applyLayoutOptions(_ lo: JSONObject?, to board: inout Moodboard) {
        guard let lo else { return }
        board.zoom = JSON.double(lo, "zoom") ?? board.zoom
        board.columns = max(1, min(JSON.int(lo, "columns") ?? board.columns, 24))
        board.gap = max(0, JSON.double(lo, "gap") ?? board.gap)
        board.padding = max(0, JSON.double(lo, "boardPadding") ?? board.padding)
        board.rounded = JSON.bool(lo, "roundedCorners") ?? board.rounded
        board.shadow = JSON.bool(lo, "softShadow") ?? board.shadow
        board.safeMargin = max(0, JSON.double(lo, "safeMargin") ?? board.safeMargin)
        board.aspectRatio = JSON.nonEmptyString(lo, "aspectRatio") ?? board.aspectRatio
        board.imageBorder = JSON.bool(lo, "imageBorder") ?? board.imageBorder
        board.imageBorderWidth = JSON.double(lo, "imageBorderWidth") ?? board.imageBorderWidth
        board.imageBorderHex = Hex.normalize(JSON.string(lo, "imageBorderColor")) ?? board.imageBorderHex
        board.canvasWidth = JSON.int(lo, "canvasWidth").flatMap { $0 > 0 ? $0 : nil }
        board.canvasHeight = JSON.int(lo, "canvasHeight").flatMap { $0 > 0 ? $0 : nil }
    }

    static func applyBranding(_ b: JSONObject?, to board: inout Moodboard, validAssets: Set<String>) {
        guard let b else { return }
        board.font = JSON.nonEmptyString(b, "font") ?? board.font
        let palette = JSON.strings(b, "palette").compactMap(Hex.normalize)
        if !palette.isEmpty { board.palette = palette }
        board.customPalette = JSON.strings(b, "customPalette").compactMap(Hex.normalize)
        board.backgroundHex = Hex.normalize(JSON.string(b, "backgroundColor")) ?? board.backgroundHex
        board.textHex = Hex.normalize(JSON.string(b, "textColor")) ?? board.textHex
        board.title = JSON.string(b, "title") ?? board.title
        board.subtitle = JSON.string(b, "subtitle") ?? board.subtitle
        board.hideTitle = JSON.bool(b, "hideTitle") ?? board.hideTitle
        board.hideSubtitle = JSON.bool(b, "hideSubtitle") ?? board.hideSubtitle
        if let logo = logo(from: JSON.object(b, "logo"), validAssets: validAssets) { board.logo = logo }
        if let bg = JSON.object(b, "background"), let id = JSON.nonEmptyString(bg, "assetId"), validAssets.contains(id) {
            board.background = MoodboardBackground(assetId: id, opacity: JSON.double(bg, "opacity") ?? 0.3,
                                                   blur: JSON.double(bg, "blur") ?? 4)
        }
    }

    static func logo(from obj: JSONObject?, validAssets: Set<String>) -> MoodboardLogo? {
        guard let obj, let id = JSON.nonEmptyString(obj, "assetId"), validAssets.contains(id) else { return nil }
        return MoodboardLogo(assetId: id, scale: JSON.double(obj, "scale") ?? 0.1,
                             position: JSON.nonEmptyString(obj, "position") ?? "bottom-right")
    }

    // MARK: - Mac Mood native ProjectState (Codable) JSON

    static func isNativeMacState(_ root: JSONObject) -> Bool {
        let items = JSON.objects(root, "canvasItems")
        let assets = JSON.objects(root, "assets")
        if let first = items.first, first["kind"] != nil, first["type"] == nil { return true }
        if let first = assets.first, first["imageData"] != nil || first["symbolName"] != nil { return true }
        if let b = JSON.object(root, "branding"), b["logoAssetID"] != nil || b["backgroundAssetID"] != nil { return true }
        return false
    }

    static func readNativeMac(_ root: JSONObject) -> Moodboard {
        var board = Moodboard()
        // Mac-native defaults (Models.swift LayoutOptions.default / BrandingOptions.default).
        board.gap = 20; board.padding = 40; board.rounded = false; board.shadow = false
        board.safeMargin = 20; board.aspectRatio = "1:1"
        var ids = Set<String>()
        for a in JSON.objects(root, "assets") {
            guard let id = JSON.nonEmptyString(a, "id"), let b64 = JSON.string(a, "imageData"), !b64.isEmpty else { continue }
            let filename = JSON.string(a, "filename") ?? ""
            let image = EmbeddedImage(kind: .base64, mimeType: MIME.fromExtension((filename as NSString).pathExtension),
                                      storage: .encoded(b64, payloadStart: b64.startIndex, isBase64: true))
            let kind: MoodboardAsset.Kind = JSON.string(a, "kind") == "logo" ? .logo : .image
            board.assets.append(MoodboardAsset(id: id, name: JSON.nonEmptyString(a, "name") ?? filename, kind: kind, image: image))
            ids.insert(id)
        }
        board.tiles = JSON.objects(root, "canvasItems").enumerated().compactMap { index, item in
            tile(from: item, index: index, validAssets: ids, legacy: false)
        }
        board.layoutMode = JSON.string(root, "layoutMode").flatMap(Moodboard.LayoutMode.init(rawValue:)) ?? .auto
        board.boardMode = JSON.string(root, "boardMode").flatMap(Moodboard.BoardMode.init(rawValue:))
        applyLayoutOptions(JSON.object(root, "layoutOptions"), to: &board)
        if let b = JSON.object(root, "branding") {
            applyBranding(b, to: &board, validAssets: ids)
            if let f = JSON.string(b, "font") {
                board.font = f.hasPrefix("font-") ? f : (f == "mono" ? "font-roboto-mono" : "font-\(f)")
            }
            if let id = JSON.nonEmptyString(b, "logoAssetID"), ids.contains(id) {
                board.logo = MoodboardLogo(assetId: id, scale: JSON.double(b, "logoScale") ?? 0.1,
                                           position: JSON.nonEmptyString(b, "logoPosition") ?? "bottom-right")
            }
            if let id = JSON.nonEmptyString(b, "backgroundAssetID"), ids.contains(id) {
                board.background = MoodboardBackground(assetId: id, opacity: JSON.double(b, "backgroundOpacity") ?? 0.3,
                                                       blur: JSON.double(b, "backgroundBlur") ?? 4)
            }
        }
        return board
    }

    // MARK: - Legacy ZIP

    static func readLegacyArchive(_ data: Data) throws -> Moodboard {
        let archive = try ZipArchive(data: data)
        guard let metaEntry = archive.entry(named: "meta.json") ?? archive.entry(lastPathComponent: "meta.json") else {
            throw ArtOfficialFormatError.archive("meta.json not found")
        }
        guard let metaData = archive.extract(metaEntry), let meta = JSON.parseObject(metaData) else {
            throw ArtOfficialFormatError.archive("meta.json is damaged")
        }
        var board = readLegacyMeta(meta, archive: archive)
        board.isLegacyArchive = true
        return board
    }

    /// Applies the documented legacy -> current mapping (web App.tsx load path, with the
    /// Mac codec's extra filename fallbacks).
    static func readLegacyMeta(_ meta: JSONObject, archive: ZipArchive?) -> Moodboard {
        var board = Moodboard()          // web defaultProjectState defaults
        board.layoutMode = .mosaic       // legacy default
        let b = JSON.object(meta, "board") ?? [:]
        let legacyLogoID = JSON.nonEmptyString(JSON.object(b, "logo"), "assetId")

        var ids = Set<String>()
        for a in JSON.objects(meta, "assets") {
            guard let id = JSON.nonEmptyString(a, "id") else { continue }
            let fileName = JSON.nonEmptyString(a, "fileName", "file") ?? JSON.nonEmptyString(a, "name") ?? id
            let image: EmbeddedImage
            if let archive {
                guard let entry = resolveLegacyEntry(fileName, in: archive) else { continue }
                image = .archiveEntry(archive, entry)
            } else {
                image = EmbeddedImage(kind: .unresolvedReference, mimeType: MIME.fromExtension((fileName as NSString).pathExtension),
                                      storage: .unresolved(fileName))
            }
            let type = JSON.string(a, "type")
            let kind: MoodboardAsset.Kind = (type == "logo" || (type == nil && id == legacyLogoID)) ? .logo : .image
            let name = JSON.nonEmptyString(a, "name") ?? ((fileName as NSString).lastPathComponent as NSString).deletingPathExtension
            board.assets.append(MoodboardAsset(id: id, name: name, kind: kind, image: image))
            ids.insert(id)
        }

        let items = JSON.objects(b, "items").isEmpty ? JSON.objects(b, "images") : JSON.objects(b, "items")
        board.tiles = items.enumerated().compactMap { index, item in
            tile(from: item, index: index, validAssets: ids, legacy: true)
        }

        if let mode = JSON.string(b, "layoutMode") {
            board.layoutMode = mode == "square" ? .grid : (Moodboard.LayoutMode(rawValue: mode) ?? .mosaic)
        }
        applyLayoutOptions(JSON.object(b, "layoutOptions"), to: &board)
        board.columns = max(1, min(JSON.int(b, "columns") ?? board.columns, 24))
        board.gap = JSON.double(b, "gap") ?? board.gap
        board.padding = JSON.double(b, "boardPadding") ?? board.padding
        board.rounded = JSON.bool(b, "rounded") ?? board.rounded
        board.shadow = JSON.bool(b, "shadow") ?? board.shadow
        board.zoom = JSON.double(b, "zoom") ?? board.zoom
        if let show = JSON.bool(b, "showSafeMargin") {
            let m = JSON.double(b, "safeMargin") ?? 0
            board.safeMargin = show ? (m > 0 ? m : 40) : 0
        } else if let m = JSON.double(b, "safeMargin") {
            board.safeMargin = m
        }

        applyBranding(JSON.object(b, "branding"), to: &board, validAssets: ids)
        board.title = JSON.string(b, "title") ?? board.title
        board.subtitle = JSON.string(b, "description") ?? board.subtitle
        board.backgroundHex = Hex.normalize(JSON.string(b, "bg")) ?? Hex.normalize(JSON.string(b, "backgroundColor")) ?? board.backgroundHex
        if let logo = logo(from: JSON.object(b, "logo"), validAssets: ids) { board.logo = logo }
        return board
    }

    static func resolveLegacyEntry(_ fileName: String, in archive: ZipArchive) -> ZipArchive.Entry? {
        guard let safe = ZipArchive.sanitizedPath(fileName) else { return nil }
        return archive.entry(named: "assets/\(safe)")
            ?? archive.entry(named: safe)
            ?? archive.entry(lastPathComponent: (safe as NSString).lastPathComponent)
    }
}
