import Foundation

/// Plain view models for the Quick Look HTML preview. Images are already encoded
/// (`data:` URIs), so `PreviewHTML` is a pure string transform and easy to test.

public struct MoodPreviewModel: Sendable, Equatable {
    public var title: String
    public var subtitle: String
    public var boardImageURI: String?
    public var palette: [String]
    public var imageCount: Int
    public var tileCount: Int
    public var layout: String
    public var canvas: String?
    public var isLegacyArchive: Bool

    public init(title: String, subtitle: String, boardImageURI: String? = nil, palette: [String] = [],
                imageCount: Int = 0, tileCount: Int = 0, layout: String = "auto", canvas: String? = nil,
                isLegacyArchive: Bool = false) {
        self.title = title; self.subtitle = subtitle; self.boardImageURI = boardImageURI
        self.palette = palette; self.imageCount = imageCount; self.tileCount = tileCount
        self.layout = layout; self.canvas = canvas; self.isLegacyArchive = isLegacyArchive
    }
}

public struct StoryPreviewModel: Sendable, Equatable {
    public struct Shot: Sendable, Equatable {
        public var label: String          // "1.3"
        public var name: String
        public var types: [String]
        public var description: String
        public var durationSec: Int
        public var status: String
        public var tags: [String]
        public var thumbURI: String?
        public init(label: String, name: String, types: [String] = [], description: String = "",
                    durationSec: Int = 0, status: String = "", tags: [String] = [], thumbURI: String? = nil) {
            self.label = label; self.name = name; self.types = types; self.description = description
            self.durationSec = durationSec; self.status = status; self.tags = tags; self.thumbURI = thumbURI
        }
    }

    public struct Scene: Sendable, Equatable {
        public var heading: String        // "Scene 1 · Opening"
        public var slugline: String?
        public var notes: String
        public var durationSec: Int
        public var shots: [Shot]
        public init(heading: String, slugline: String? = nil, notes: String = "", durationSec: Int = 0, shots: [Shot] = []) {
            self.heading = heading; self.slugline = slugline; self.notes = notes
            self.durationSec = durationSec; self.shots = shots
        }
    }

    public struct Project: Sendable, Equatable {
        public var title: String
        public var code: String
        public var status: String
        public var logline: String?
        public var info: [PreviewField]
        public var notes: String?
        public var contactSheetURI: String?
        public var scenes: [Scene]
        public init(title: String, code: String = "", status: String = "", logline: String? = nil,
                    info: [PreviewField] = [], notes: String? = nil, contactSheetURI: String? = nil, scenes: [Scene] = []) {
            self.title = title; self.code = code; self.status = status; self.logline = logline
            self.info = info; self.notes = notes; self.contactSheetURI = contactSheetURI; self.scenes = scenes
        }
    }

    public var fileTitle: String
    public var projects: [Project]
    /// Shots whose thumbnails were omitted because of the per-preview budget.
    public var omittedThumbCount: Int

    public init(fileTitle: String, projects: [Project], omittedThumbCount: Int = 0) {
        self.fileTitle = fileTitle; self.projects = projects; self.omittedThumbCount = omittedThumbCount
    }
}

public struct PromptPreviewModel: Sendable, Equatable {
    public var kindName: String           // "Prompt Library" / "Art Official Elements"
    public var title: String
    public var prompt: String
    public var shortDescription: String?
    public var imageURIs: [String]
    public var totalImageCount: Int
    public var referenceImageURIs: [String]
    public var generation: [PreviewField]
    public var analysis: [PreviewField]

    public init(kindName: String, title: String, prompt: String, shortDescription: String? = nil,
                imageURIs: [String] = [], totalImageCount: Int = 0, referenceImageURIs: [String] = [],
                generation: [PreviewField] = [], analysis: [PreviewField] = []) {
        self.kindName = kindName; self.title = title; self.prompt = prompt; self.shortDescription = shortDescription
        self.imageURIs = imageURIs; self.totalImageCount = totalImageCount
        self.referenceImageURIs = referenceImageURIs; self.generation = generation; self.analysis = analysis
    }
}
