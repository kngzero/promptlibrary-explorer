import Foundation
import UniformTypeIdentifiers

/// Uniform Type Identifier strings for every Art Official document type.
public enum ArtOfficialTypeIdentifiers {
    public static let moodboard = "com.artofficial.mood.mlmboard"
    public static let story = "com.artofficial.story.project"
    public static let storyLegacy = "com.artofficial.story.mlseq"
    public static let plib = "com.artofficial.plib"
    public static let aoe = "com.artofficial.aoe"
    public static let all: [String] = [moodboard, story, storyLegacy, plib, aoe]
}

/// Document kinds understood by this library, detected by file extension.
public enum ArtOfficialFileKind: String, Sendable, CaseIterable, Hashable {
    case moodboard
    case story
    case storyLegacy
    case promptLibrary
    case elements

    public static func detect(url: URL) -> ArtOfficialFileKind? {
        detect(pathExtension: url.pathExtension)
    }

    public static func detect(pathExtension: String) -> ArtOfficialFileKind? {
        let ext = pathExtension.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return allCases.first { $0.fileExtension == ext }
    }

    public var fileExtension: String {
        switch self {
        case .moodboard: return "mlmboard"
        case .story: return "stry"
        case .storyLegacy: return "mlseq"
        case .promptLibrary: return "plib"
        case .elements: return "aoe"
        }
    }

    public var typeIdentifier: String {
        switch self {
        case .moodboard: return ArtOfficialTypeIdentifiers.moodboard
        case .story: return ArtOfficialTypeIdentifiers.story
        case .storyLegacy: return ArtOfficialTypeIdentifiers.storyLegacy
        case .promptLibrary: return ArtOfficialTypeIdentifiers.plib
        case .elements: return ArtOfficialTypeIdentifiers.aoe
        }
    }

    public var utType: UTType {
        UTType(typeIdentifier) ?? UTType(filenameExtension: fileExtension) ?? .data
    }

    public var displayName: String {
        switch self {
        case .moodboard: return "Mood Board"
        case .story: return "Story Project"
        case .storyLegacy: return "Story Project (Legacy)"
        case .promptLibrary: return "Prompt Library"
        case .elements: return "Art Official Elements"
        }
    }

    public var isStory: Bool { self == .story || self == .storyLegacy }
}
