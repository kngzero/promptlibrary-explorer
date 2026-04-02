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
        let raw = try container.decode(String.self)
        self = AspectRatio(rawValue: raw) ?? .notAvailable
    }
}

// MARK: - Generation Info

struct GenerationInfo: Codable {
    let aspectRatio: AspectRatio
    let model: String
    let timestamp: String
    let numberOfImages: Int
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
    var analysis: PromptAnalysis?
    var embeddedMetadata: [PromptMetadataField] = []
    var fileMetadata: FileMetadata?
}
