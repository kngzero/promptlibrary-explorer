import AppKit
import Foundation

// MARK: - Aspect Ratio

enum AspectRatio: String, Codable {
    case oneToOne = "1:1"
    case sixteenToNine = "16:9"
    case nineToSixteen = "9:16"
    case fourToThree = "4:3"
    case threeToFour = "3:4"
    case notAvailable = "N/A"

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode(String.self)) ?? ""
        self = AspectRatio(rawValue: raw.trimmingCharacters(in: .whitespaces)) ?? .notAvailable
    }
}

// MARK: - Generation Info

struct GenerationInfo: Codable {
    let aspectRatio: AspectRatio
    let model: String
    let timestamp: String
    let numberOfImages: Int

    enum CodingKeys: String, CodingKey {
        case aspectRatio, model, timestamp, numberOfImages
    }
}

extension GenerationInfo {
    /// Lenient decoding: a .plib missing (or mistyping) any single field still loads,
    /// falling back to the same placeholders the app uses elsewhere.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let model = (try? c.decodeIfPresent(String.self, forKey: .model))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(
            aspectRatio: (try? c.decodeIfPresent(AspectRatio.self, forKey: .aspectRatio)) ?? .notAvailable,
            model: (model?.isEmpty == false ? model : nil) ?? "N/A",
            timestamp: Self.decodeTimestamp(c) ?? "",
            numberOfImages: Self.decodeCount(c) ?? 0
        )
    }

    private static func decodeTimestamp(_ c: KeyedDecodingContainer<CodingKeys>) -> String? {
        if let s = try? c.decodeIfPresent(String.self, forKey: .timestamp) { return s }
        // Some writers store epoch milliseconds/seconds as a number.
        if let n = try? c.decodeIfPresent(Double.self, forKey: .timestamp) {
            let seconds = n > 10_000_000_000 ? n / 1000 : n
            return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: seconds))
        }
        return nil
    }

    private static func decodeCount(_ c: KeyedDecodingContainer<CodingKeys>) -> Int? {
        if let n = try? c.decodeIfPresent(Int.self, forKey: .numberOfImages) { return n }
        if let d = try? c.decodeIfPresent(Double.self, forKey: .numberOfImages), d.isFinite { return Int(d) }
        if let s = try? c.decodeIfPresent(String.self, forKey: .numberOfImages) {
            return Int(s.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}

// MARK: - Prompt Analysis

struct PromptAnalysis: Codable {
    var fullPrompt: String?
    var shortDescription: String?
    var subject: String?
    var subjectPose: String?
    var composition: String?
    var artStyle: String?
    var cameraSettings: String?
    var lighting: String?
    var colorPalette: String?
    var mood: String?

    enum CodingKeys: String, CodingKey {
        case fullPrompt = "full_prompt"
        case shortDescription = "short_description"
        case subject
        case subjectPose = "subject_pose"
        case composition
        case artStyle = "art_style"
        case cameraSettings = "camera_settings"
        case lighting
        case colorPalette = "color_palette"
        case mood
    }

    init(
        fullPrompt: String? = nil,
        shortDescription: String? = nil,
        subject: String? = nil,
        subjectPose: String? = nil,
        composition: String? = nil,
        artStyle: String? = nil,
        cameraSettings: String? = nil,
        lighting: String? = nil,
        colorPalette: String? = nil,
        mood: String? = nil
    ) {
        self.fullPrompt = fullPrompt
        self.shortDescription = shortDescription
        self.subject = subject
        self.subjectPose = subjectPose
        self.composition = composition
        self.artStyle = artStyle
        self.cameraSettings = cameraSettings
        self.lighting = lighting
        self.colorPalette = colorPalette
        self.mood = mood
    }

    /// Lenient decoding: a mistyped segment (e.g. a number or object) becomes nil instead of
    /// failing the whole file.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func field(_ key: CodingKeys) -> String? {
            (try? c.decodeIfPresent(String.self, forKey: key)) ?? nil
        }
        self.init(
            fullPrompt: field(.fullPrompt),
            shortDescription: field(.shortDescription),
            subject: field(.subject),
            subjectPose: field(.subjectPose),
            composition: field(.composition),
            artStyle: field(.artStyle),
            cameraSettings: field(.cameraSettings),
            lighting: field(.lighting),
            colorPalette: field(.colorPalette),
            mood: field(.mood)
        )
    }

    /// All non-nil segments as (label, value) pairs.
    var segments: [(label: String, key: String, value: String)] {
        var result: [(String, String, String)] = []
        if let v = fullPrompt, !v.isEmpty { result.append(("Full Prompt", "fullPrompt", v)) }
        if let v = shortDescription, !v.isEmpty { result.append(("Brief", "shortDescription", v)) }
        if let v = subject, !v.isEmpty { result.append(("Subject", "subject", v)) }
        if let v = subjectPose, !v.isEmpty { result.append(("Action", "subjectPose", v)) }
        if let v = composition, !v.isEmpty { result.append(("Place", "composition", v)) }
        if let v = artStyle, !v.isEmpty { result.append(("Style", "artStyle", v)) }
        if let v = cameraSettings, !v.isEmpty { result.append(("Camera", "cameraSettings", v)) }
        if let v = lighting, !v.isEmpty { result.append(("Lighting", "lighting", v)) }
        if let v = colorPalette, !v.isEmpty { result.append(("Palette", "colorPalette", v)) }
        if let v = mood, !v.isEmpty { result.append(("Mood", "mood", v)) }
        return result
    }
}

struct PromptMetadataField: Hashable {
    let label: String
    let value: String
}

// MARK: - Prompt Entry

struct PromptEntry: Identifiable {
    let id = UUID()
    let prompt: String
    var blindPrompt: String?
    var hint: String?
    let generationInfo: GenerationInfo
    /// Decoded images ready for display
    var images: [NSImage]
    /// Reference images (decoded)
    var referenceImages: [NSImage]
    /// Raw image data strings (base64 / paths) as stored in file
    var rawImages: [String]
    var rawReferenceImages: [String]
    var sourcePath: String?
    var videoURL: URL?
    var audioURL: URL?
    var analysis: PromptAnalysis?
    var embeddedMetadata: [PromptMetadataField] = []
    var fileMetadata: FileMetadata?
    /// Raw ComfyUI API-graph JSON from the PNG `prompt` chunk, when present.
    var comfyPromptJSON: String? = nil
    /// Raw ComfyUI UI workflow JSON from the PNG `workflow` chunk, when present.
    var comfyWorkflowJSON: String? = nil
    /// Set for Mood boards and Story projects; `images` then holds the rendered overview.
    var artOfficialDocument: ArtOfficialDocument? = nil
}
