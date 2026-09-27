import Foundation

/// A Story workspace (`.stry` / legacy `.mlseq`): web `AppState` JSON, optionally
/// with the Mac app's extension keys.
public struct StoryDocument: Sendable {
    public var projects: [StoryProject]
    public var sourceByteCount: Int

    public init(projects: [StoryProject] = [], sourceByteCount: Int = 0) {
        self.projects = projects
        self.sourceByteCount = sourceByteCount
    }
}

public struct StoryProject: Sendable, Identifiable {
    public var id: String
    public var index: Int
    public var title: String
    public var code: String
    public var status: String
    public var logline: String?
    public var director: String?
    public var producer: String?
    public var productionNotes: String?
    public var aspectRatio: String
    /// "yyyy-MM-dd" exactly as stored.
    public var dateStart: String?
    public var dateEnd: String?
    public var coverImage: EmbeddedImage?
    public var scenes: [StoryScene]
    public var scripts: [StoryScript]
    public var assetLists: [StoryAssetList]
    /// True for the synthetic project that collects orphans in multi-project files.
    public var isUnassigned: Bool

    public init(id: String, index: Int = 0, title: String, code: String = "", status: String = "Planning",
                logline: String? = nil, director: String? = nil, producer: String? = nil,
                productionNotes: String? = nil, aspectRatio: String = "16:9", dateStart: String? = nil,
                dateEnd: String? = nil, coverImage: EmbeddedImage? = nil, scenes: [StoryScene] = [],
                scripts: [StoryScript] = [], assetLists: [StoryAssetList] = [], isUnassigned: Bool = false) {
        self.id = id; self.index = index; self.title = title; self.code = code; self.status = status
        self.logline = logline; self.director = director; self.producer = producer
        self.productionNotes = productionNotes; self.aspectRatio = aspectRatio
        self.dateStart = dateStart; self.dateEnd = dateEnd; self.coverImage = coverImage
        self.scenes = scenes; self.scripts = scripts; self.assetLists = assetLists; self.isUnassigned = isUnassigned
    }

    /// Width / height; 16:9 when unparseable (same fallback as Story for Mac).
    public var aspectRatioValue: Double {
        let parts = aspectRatio.split(separator: ":")
        if parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]), w > 0, h > 0 { return w / h }
        return 16.0 / 9.0
    }

    public var allShots: [StoryShot] { scenes.flatMap(\.shots) }
    public var shotCount: Int { scenes.reduce(0) { $0 + $1.shots.count } }

    /// Sum of shot durations; a scene with no shots contributes its own estimate.
    public var estimatedDurationSec: Int {
        scenes.reduce(0) { total, scene in
            total + (scene.shots.isEmpty ? scene.estDurationSec : scene.shots.reduce(0) { $0 + max(0, $1.estDurationSec) })
        }
    }
}

public struct StoryScene: Sendable, Identifiable {
    public var id: String
    public var index: Int
    public var name: String
    public var number: Int
    public var location: String
    public var intExt: String
    public var dayNight: String
    public var estDurationSec: Int
    public var notes: String
    public var isUnassigned: Bool
    public var shots: [StoryShot]

    public init(id: String, index: Int = 0, name: String, number: Int = 1, location: String = "",
                intExt: String = "INT", dayNight: String = "DAY", estDurationSec: Int = 0, notes: String = "",
                isUnassigned: Bool = false, shots: [StoryShot] = []) {
        self.id = id; self.index = index; self.name = name; self.number = number; self.location = location
        self.intExt = intExt; self.dayNight = dayNight; self.estDurationSec = estDurationSec; self.notes = notes
        self.isUnassigned = isUnassigned; self.shots = shots
    }

    /// Screenplay-style heading, e.g. "INT. KITCHEN - NIGHT".
    public var slugline: String {
        let loc = location.trimmingCharacters(in: .whitespaces)
        return loc.isEmpty ? "\(intExt). \(dayNight)" : "\(intExt). \(loc.uppercased()) - \(dayNight)"
    }
}

public struct StoryShot: Sendable, Identifiable {
    public var id: String
    public var index: Int
    public var name: String
    public var types: [String]
    public var description: String
    public var detailedNotes: String
    public var tags: [String]
    public var estDurationSec: Int
    public var status: String
    public var thumb: EmbeddedImage?
    public var videoRef: String?
    public var takes: [StoryTake]

    public init(id: String, index: Int = 0, name: String, types: [String] = [], description: String = "",
                detailedNotes: String = "", tags: [String] = [], estDurationSec: Int = 5, status: String = "Planned",
                thumb: EmbeddedImage? = nil, videoRef: String? = nil, takes: [StoryTake] = []) {
        self.id = id; self.index = index; self.name = name; self.types = types; self.description = description
        self.detailedNotes = detailedNotes; self.tags = tags; self.estDurationSec = estDurationSec
        self.status = status; self.thumb = thumb; self.videoRef = videoRef; self.takes = takes
    }
}

public struct StoryTake: Sendable, Identifiable {
    public var id: String
    public var label: String?
    public var image: EmbeddedImage?
}

public struct StoryScript: Sendable, Identifiable {
    public var id: String
    public var name: String
    public var filename: String
    /// Raw Fountain text.
    public var content: String
}

public struct StoryAssetList: Sendable, Identifiable {
    public var id: String
    public var name: String
    public var assets: [StoryAsset]
}

public struct StoryAsset: Sendable, Identifiable {
    public var id: String
    public var name: String
    public var description: String
    public var sceneIds: [String]
    public var thumb: EmbeddedImage?
}
