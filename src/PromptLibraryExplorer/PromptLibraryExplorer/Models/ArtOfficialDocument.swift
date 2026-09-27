import ArtOfficialFormats
import Foundation

/// A parsed Art Official document owned by another app (Mood, Story). Attached to a
/// `PromptEntry` so the details panel and lightbox can switch on it while prompt-centric
/// screens keep working with the entry as before.
enum ArtOfficialDocument: Sendable {
    case moodboard(Moodboard)
    case story(StoryDocument)

    enum Kind: String, Sendable {
        case moodboard
        case story

        /// Bundle identifier of the app that owns (edits) this kind.
        var ownerBundleID: String {
            switch self {
            case .moodboard: return "com.artofficial.mood"
            case .story: return "com.artofficial.story"
            }
        }

        var ownerAppName: String {
            switch self {
            case .moodboard: return "Mood"
            case .story: return "Story"
            }
        }

        var displayName: String {
            switch self {
            case .moodboard: return "Mood Board"
            case .story: return "Story Project"
            }
        }
    }

    var kind: Kind {
        switch self {
        case .moodboard: return .moodboard
        case .story: return .story
        }
    }

    var moodboard: Moodboard? {
        if case .moodboard(let board) = self { return board }
        return nil
    }

    var story: StoryDocument? {
        if case .story(let document) = self { return document }
        return nil
    }

    /// Title + body for the prompt index and the library index.
    var searchText: (title: String, body: String) {
        switch self {
        case .moodboard(let board): return ArtOfficialSearchText.moodboard(board)
        case .story(let document): return ArtOfficialSearchText.story(document)
        }
    }

    /// Title and body joined, as the in-folder prompt index stores it.
    var indexText: String {
        let text = searchText
        return [text.title, text.body]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// Reads a Mood board or Story project from disk (nil for other files or unusable data).
    /// Synchronous and uncached: call off the main actor.
    static func read(from url: URL) -> ArtOfficialDocument? {
        guard let kind = ArtOfficialFileKind.detect(url: url) else { return nil }
        switch kind {
        case .moodboard:
            return (try? MoodboardReader.read(from: url)).map { .moodboard($0) }
        case .story, .storyLegacy:
            return (try? StoryReader.read(from: url)).map { .story($0) }
        case .promptLibrary, .elements:
            return nil
        }
    }
}

extension StoryDocument {
    /// The project shown by default: the first real project, else the first one
    /// (possibly the synthetic "Unassigned" collector).
    var defaultProject: StoryProject? {
        projects.first(where: { !$0.isUnassigned }) ?? projects.first
    }
}

extension StoryProject {
    /// Every shot with its scene, in outline order, for storyboard stepping.
    var storyboardSteps: [StoryboardStep] {
        var steps: [StoryboardStep] = []
        for (sceneOffset, scene) in scenes.enumerated() {
            for (shotOffset, shot) in scene.shots.enumerated() {
                steps.append(StoryboardStep(
                    scene: scene,
                    sceneNumber: scene.number > 0 ? scene.number : sceneOffset + 1,
                    shotNumber: shotOffset + 1,
                    shot: shot
                ))
            }
        }
        return steps
    }
}

/// One shot in a storyboard walk-through, with its position label.
struct StoryboardStep: Sendable {
    let scene: StoryScene
    let sceneNumber: Int
    let shotNumber: Int
    let shot: StoryShot

    var positionLabel: String {
        scene.isUnassigned ? "Unassigned · Shot \(shotNumber)" : "Scene \(sceneNumber) · Shot \(shotNumber)"
    }
}
