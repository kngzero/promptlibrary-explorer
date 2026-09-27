import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Format

/// Output format of an export. `keepOriginal` writes each image in its own format
/// (falling back to PNG when ImageIO can't write that format, e.g. WebP or GIF).
enum ExportFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case keepOriginal
    case png
    case jpeg
    case webp
    case heic
    case tiff

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keepOriginal: return "Keep Original"
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        case .webp: return "WebP"
        case .heic: return "HEIC"
        case .tiff: return "TIFF"
        }
    }

    var utType: UTType? {
        switch self {
        case .keepOriginal: return nil
        case .png: return .png
        case .jpeg: return .jpeg
        case .webp: return .webP
        case .heic: return .heic
        case .tiff: return .tiff
        }
    }

    var fileExtension: String? {
        switch self {
        case .keepOriginal: return nil
        case .png: return "png"
        case .jpeg: return "jpg"
        case .webp: return "webp"
        case .heic: return "heic"
        case .tiff: return "tiff"
        }
    }

    /// Lossy formats honour the quality setting.
    var usesQuality: Bool {
        self == .jpeg || self == .heic || self == .webp || self == .keepOriginal
    }

    var supportsAlpha: Bool {
        self != .jpeg
    }

    /// Whether ImageIO can write this format on this Mac (WebP depends on the OS).
    var isAvailable: Bool {
        guard let utType else { return true }
        return ExportFormat.writableTypeIdentifiers.contains(utType.identifier)
    }

    /// Formats offered in pickers: only those this Mac can write.
    static var availableCases: [ExportFormat] {
        allCases.filter(\.isAvailable)
    }

    static let writableTypeIdentifiers: Set<String> = {
        Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
    }()

    /// The concrete format an image with `sourceExtension` is written as.
    func resolved(forSourceExtension sourceExtension: String) -> ExportFormat {
        guard self == .keepOriginal else { return isAvailable ? self : .png }
        switch sourceExtension.lowercased() {
        case "png": return .png
        case "jpg", "jpeg": return .jpeg
        case "heic", "heif": return ExportFormat.heic.isAvailable ? .heic : .png
        case "tif", "tiff": return .tiff
        case "webp": return ExportFormat.webp.isAvailable ? .webp : .png
        default: return .png
        }
    }
}

// MARK: - Size

struct ExportSizing: Codable, Equatable, Sendable {
    enum Mode: String, Codable, CaseIterable, Identifiable, Sendable {
        case original
        case longEdge
        case exact
        case scale

        var id: String { rawValue }

        var title: String {
            switch self {
            case .original: return "Original Size"
            case .longEdge: return "Long Edge"
            case .exact: return "Exact Size (crop to fill)"
            case .scale: return "Scale"
            }
        }
    }

    var mode: Mode = .original
    /// Long edge in pixels (`longEdge`).
    var longEdge: Int = 2048
    /// Output width × height (`exact`): scaled to fill, then centre-cropped.
    var width: Int = 1080
    var height: Int = 1080
    /// Percent of the original (`scale`).
    var scalePercent: Double = 50
    /// `longEdge` never enlarges unless this is on.
    var allowUpscale: Bool = false

    static let original = ExportSizing()

    init(
        mode: Mode = .original,
        longEdge: Int = 2048,
        width: Int = 1080,
        height: Int = 1080,
        scalePercent: Double = 50,
        allowUpscale: Bool = false
    ) {
        self.mode = mode
        self.longEdge = longEdge
        self.width = width
        self.height = height
        self.scalePercent = scalePercent
        self.allowUpscale = allowUpscale
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ExportSizing()
        mode = (try? c.decode(Mode.self, forKey: .mode)) ?? fallback.mode
        longEdge = (try? c.decode(Int.self, forKey: .longEdge)) ?? fallback.longEdge
        width = (try? c.decode(Int.self, forKey: .width)) ?? fallback.width
        height = (try? c.decode(Int.self, forKey: .height)) ?? fallback.height
        scalePercent = (try? c.decode(Double.self, forKey: .scalePercent)) ?? fallback.scalePercent
        allowUpscale = (try? c.decode(Bool.self, forKey: .allowUpscale)) ?? fallback.allowUpscale
    }
}

// MARK: - Colour

enum ExportColorProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    case keep
    case sRGB
    case displayP3

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keep: return "Keep Original"
        case .sRGB: return "sRGB"
        case .displayP3: return "Display P3"
        }
    }

    var colorSpaceName: CFString? {
        switch self {
        case .keep: return nil
        case .sRGB: return CGColorSpace.sRGB
        case .displayP3: return CGColorSpace.displayP3
        }
    }
}

// MARK: - Metadata

/// A piece of embedded metadata the "keep only" policy can retain.
enum ExportMetadataField: String, Codable, CaseIterable, Identifiable, Sendable {
    case prompt
    case negativePrompt
    case model
    case seed
    case parameters
    case workflow
    case ratingKeywords
    case camera
    case gps

    var id: String { rawValue }

    var title: String {
        switch self {
        case .prompt: return "Prompt"
        case .negativePrompt: return "Negative prompt"
        case .model: return "Model"
        case .seed: return "Seed"
        case .parameters: return "Other parameters (steps, sampler, CFG, size…)"
        case .workflow: return "ComfyUI workflow / graph JSON"
        case .ratingKeywords: return "Rating and keywords"
        case .camera: return "EXIF camera and lens"
        case .gps: return "GPS location"
        }
    }

    /// Fields that describe how the image was generated.
    var isAIField: Bool {
        switch self {
        case .prompt, .negativePrompt, .model, .seed, .parameters, .workflow: return true
        case .ratingKeywords, .camera, .gps: return false
        }
    }
}

struct ExportMetadataPolicy: Codable, Equatable, Sendable {
    enum Mode: String, Codable, CaseIterable, Identifiable, Sendable {
        case keepAll
        case stripAI
        case stripAll
        case keepOnly

        var id: String { rawValue }

        var title: String {
            switch self {
            case .keepAll: return "Keep All"
            case .stripAI: return "Strip AI Metadata"
            case .stripAll: return "Strip All"
            case .keepOnly: return "Keep Only…"
            }
        }

        var explanation: String {
            switch self {
            case .keepAll:
                return "Everything is carried over, including prompts and ComfyUI workflows (as far as the output format can hold them)."
            case .stripAI:
                return "Removes prompts, negative prompts, seeds, parameters, ComfyUI graphs, descriptions and GPS. Keeps camera data, rating, keywords and copyright."
            case .stripAll:
                return "Removes all metadata except orientation and the colour profile."
            case .keepOnly:
                return "Removes everything, then keeps only the fields you tick."
            }
        }
    }

    var mode: Mode = .keepAll
    /// Used by `keepOnly`.
    var keptFields: Set<ExportMetadataField> = [.prompt, .model]

    static let keepAll = ExportMetadataPolicy(mode: .keepAll)
    static let stripAI = ExportMetadataPolicy(mode: .stripAI)
    static let stripAll = ExportMetadataPolicy(mode: .stripAll)

    init(mode: Mode = .keepAll, keptFields: Set<ExportMetadataField> = [.prompt, .model]) {
        self.mode = mode
        self.keptFields = keptFields
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = (try? c.decode(Mode.self, forKey: .mode)) ?? .keepAll
        // Unknown field names (from a newer build) are dropped, not fatal.
        let raw = (try? c.decode([String].self, forKey: .keptFields)) ?? ["prompt", "model"]
        keptFields = Set(raw.compactMap(ExportMetadataField.init(rawValue:)))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mode, forKey: .mode)
        try c.encode(keptFields.map(\.rawValue).sorted(), forKey: .keptFields)
    }

    private enum CodingKeys: String, CodingKey { case mode, keptFields }

    /// True when `field` survives this policy.
    func keeps(_ field: ExportMetadataField) -> Bool {
        switch mode {
        case .keepAll: return true
        case .stripAI: return !field.isAIField && field != .gps
        case .stripAll: return false
        case .keepOnly: return keptFields.contains(field)
        }
    }

    /// True when the output keeps every AI field verbatim.
    var keepsRawAIMetadata: Bool { mode == .keepAll }
}

// MARK: - Destination / collisions

enum ExportDestinationMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case ask
    case fixedFolder
    case subfolder

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: return "Ask Each Time"
        case .fixedFolder: return "Fixed Folder"
        case .subfolder: return "Subfolder Next to Each Original"
        }
    }
}

enum ExportCollisionPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case unique
    case overwrite
    case skip

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unique: return "Keep Both (add a number)"
        case .overwrite: return "Replace (asks first; old files go to the Trash)"
        case .skip: return "Skip"
        }
    }
}

// MARK: - Watermark

enum WatermarkPosition: String, Codable, CaseIterable, Identifiable, Sendable {
    case topLeft, top, topRight
    case left, center, right
    case bottomLeft, bottom, bottomRight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topLeft: return "Top Left"
        case .top: return "Top"
        case .topRight: return "Top Right"
        case .left: return "Left"
        case .center: return "Centre"
        case .right: return "Right"
        case .bottomLeft: return "Bottom Left"
        case .bottom: return "Bottom"
        case .bottomRight: return "Bottom Right"
        }
    }

    /// 0 = left/top, 0.5 = centre, 1 = right/bottom (top-left origin).
    var anchor: (x: Double, y: Double) {
        switch self {
        case .topLeft: return (0, 0)
        case .top: return (0.5, 0)
        case .topRight: return (1, 0)
        case .left: return (0, 0.5)
        case .center: return (0.5, 0.5)
        case .right: return (1, 0.5)
        case .bottomLeft: return (0, 1)
        case .bottom: return (0.5, 1)
        case .bottomRight: return (1, 1)
        }
    }
}

struct ExportWatermark: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case text
        case image

        var id: String { rawValue }
        var title: String { self == .text ? "Text" : "Image" }
    }

    var isEnabled = false
    var kind: Kind = .text
    var text = "© Your Name"
    /// Hex RGB, e.g. "#FFFFFF".
    var textColorHex = "#FFFFFF"
    var bold = true
    /// PNG (with alpha) or any image ImageIO reads.
    var imagePath: String?
    var position: WatermarkPosition = .bottomRight
    /// Margin as a fraction of the output's short edge.
    var margin: Double = 0.03
    var opacity: Double = 0.6
    /// Watermark width as a fraction of the output width.
    var scale: Double = 0.2
    var shadow = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ExportWatermark()
        isEnabled = (try? c.decode(Bool.self, forKey: .isEnabled)) ?? d.isEnabled
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? d.kind
        text = (try? c.decode(String.self, forKey: .text)) ?? d.text
        textColorHex = (try? c.decode(String.self, forKey: .textColorHex)) ?? d.textColorHex
        bold = (try? c.decode(Bool.self, forKey: .bold)) ?? d.bold
        imagePath = try? c.decodeIfPresent(String.self, forKey: .imagePath)
        position = (try? c.decode(WatermarkPosition.self, forKey: .position)) ?? d.position
        margin = (try? c.decode(Double.self, forKey: .margin)) ?? d.margin
        opacity = (try? c.decode(Double.self, forKey: .opacity)) ?? d.opacity
        scale = (try? c.decode(Double.self, forKey: .scale)) ?? d.scale
        shadow = (try? c.decode(Bool.self, forKey: .shadow)) ?? d.shadow
    }

    /// True when there is something to draw.
    var isActive: Bool {
        guard isEnabled else { return false }
        switch kind {
        case .text: return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .image: return imagePath?.isEmpty == false
        }
    }
}

// MARK: - Preset

struct ExportPreset: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var format: ExportFormat = .keepOriginal
    var sizing: ExportSizing = .original
    /// 0…1, for JPEG / HEIC / WebP.
    var quality: Double = 0.9
    var colorProfile: ExportColorProfile = .keep
    var metadata: ExportMetadataPolicy = .keepAll
    /// RenameTemplateService tokens; the output format's extension is appended.
    var filenameTemplate = "{name}"
    var destination: ExportDestinationMode = .ask
    var fixedFolderPath: String?
    var subfolderName = "Exports"
    var collision: ExportCollisionPolicy = .unique
    var watermark = ExportWatermark()
    /// Mood / Story / .plib / .aoe: export their rendered image instead of skipping them.
    var exportRenderedDocuments = false
    /// Videos and audio: remove metadata with a passthrough re-mux where AVFoundation can.
    var stripMediaMetadata = false

    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ExportPreset(name: "")
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? "Preset"
        format = (try? c.decode(ExportFormat.self, forKey: .format)) ?? d.format
        sizing = (try? c.decode(ExportSizing.self, forKey: .sizing)) ?? d.sizing
        quality = min(1, max(0, (try? c.decode(Double.self, forKey: .quality)) ?? d.quality))
        colorProfile = (try? c.decode(ExportColorProfile.self, forKey: .colorProfile)) ?? d.colorProfile
        metadata = (try? c.decode(ExportMetadataPolicy.self, forKey: .metadata)) ?? d.metadata
        filenameTemplate = (try? c.decode(String.self, forKey: .filenameTemplate)) ?? d.filenameTemplate
        destination = (try? c.decode(ExportDestinationMode.self, forKey: .destination)) ?? d.destination
        fixedFolderPath = try? c.decodeIfPresent(String.self, forKey: .fixedFolderPath)
        subfolderName = (try? c.decode(String.self, forKey: .subfolderName)) ?? d.subfolderName
        collision = (try? c.decode(ExportCollisionPolicy.self, forKey: .collision)) ?? d.collision
        watermark = (try? c.decode(ExportWatermark.self, forKey: .watermark)) ?? d.watermark
        exportRenderedDocuments = (try? c.decode(Bool.self, forKey: .exportRenderedDocuments)) ?? d.exportRenderedDocuments
        stripMediaMetadata = (try? c.decode(Bool.self, forKey: .stripMediaMetadata)) ?? d.stripMediaMetadata
    }

    /// Short description for menus and the sheet ("JPEG · 2048 px · strip AI").
    var summary: String {
        var parts: [String] = [format.title]
        switch sizing.mode {
        case .original: break
        case .longEdge: parts.append("\(sizing.longEdge) px")
        case .exact: parts.append("\(sizing.width)×\(sizing.height)")
        case .scale: parts.append("\(Int(sizing.scalePercent.rounded()))%")
        }
        if format.usesQuality, format != .keepOriginal { parts.append("Q\(Int((quality * 100).rounded()))") }
        switch metadata.mode {
        case .keepAll: break
        case .stripAI: parts.append("no AI metadata")
        case .stripAll: parts.append("no metadata")
        case .keepOnly: parts.append("selected metadata")
        }
        if watermark.isActive { parts.append("watermark") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Defaults

extension ExportPreset {
    /// Stable ids so the shipped presets can be recognised (and the privacy one found).
    static let webJPEGID = UUID(uuidString: "6E0C1F0A-0001-4000-8000-000000000001")!
    static let fullResPNGID = UUID(uuidString: "6E0C1F0A-0002-4000-8000-000000000002")!
    static let instagramID = UUID(uuidString: "6E0C1F0A-0003-4000-8000-000000000003")!
    static let heicArchiveID = UUID(uuidString: "6E0C1F0A-0004-4000-8000-000000000004")!
    static let sharingID = UUID(uuidString: "6E0C1F0A-0005-4000-8000-000000000005")!

    static var webJPEG2048: ExportPreset {
        var preset = ExportPreset(id: webJPEGID, name: "Web JPEG 2048")
        preset.format = .jpeg
        preset.sizing = ExportSizing(mode: .longEdge, longEdge: 2048)
        preset.quality = 0.85
        preset.colorProfile = .sRGB
        preset.metadata = .stripAI
        preset.stripMediaMetadata = true
        return preset
    }

    static var fullResPNG: ExportPreset {
        var preset = ExportPreset(id: fullResPNGID, name: "Full-res PNG")
        preset.format = .png
        preset.metadata = .keepAll
        return preset
    }

    static var instagram1080: ExportPreset {
        var preset = ExportPreset(id: instagramID, name: "Instagram 1080")
        preset.format = .jpeg
        preset.sizing = ExportSizing(mode: .longEdge, longEdge: 1080)
        preset.quality = 0.9
        preset.colorProfile = .sRGB
        preset.metadata = .stripAI
        preset.stripMediaMetadata = true
        return preset
    }

    static var heicArchive: ExportPreset {
        var preset = ExportPreset(id: heicArchiveID, name: "HEIC Archive")
        preset.format = ExportFormat.heic.isAvailable ? .heic : .png
        preset.quality = 0.8
        preset.metadata = .keepAll
        return preset
    }

    /// File ▸ Export for Sharing (Strip AI Metadata)…: same format and size, pixels
    /// untouched where the format allows, AI metadata and GPS removed.
    static var sharing: ExportPreset {
        var preset = ExportPreset(id: sharingID, name: "For Sharing (Strip AI Metadata)")
        preset.format = .keepOriginal
        preset.metadata = .stripAI
        preset.stripMediaMetadata = true
        return preset
    }

    static var defaults: [ExportPreset] {
        [webJPEG2048, fullResPNG, instagram1080, heicArchive, sharing]
    }

    var isSharingPreset: Bool { id == Self.sharingID }
}
