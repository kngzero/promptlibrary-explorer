import Foundation

/// Plain-text extraction for Spotlight-style indexing and in-app search.
public enum ArtOfficialSearchText {
    /// Title + body (subtitle, asset names, captions, text tiles, palette hex values).
    public static func moodboard(_ board: Moodboard) -> (title: String, body: String) {
        var parts: [String] = []
        append(board.subtitle, to: &parts)
        for asset in board.assets { append(asset.name, to: &parts) }
        for tile in board.tiles {
            append(tile.caption, to: &parts)
            if case .text(let text, _, _, _, _, _) = tile.content { append(text, to: &parts) }
        }
        parts.append(contentsOf: board.palette)
        return (board.title.trimmingCharacters(in: .whitespacesAndNewlines), joined(parts))
    }

    public static func story(_ document: StoryDocument) -> (title: String, body: String) {
        let real = document.projects.filter { !$0.isUnassigned }
        let title = real.map(\.title).first ?? document.projects.first?.title ?? ""
        let body = document.projects.map { p -> String in
            let s = story(p)
            return joined([s.title, s.body])
        }
        return (title, joined(body))
    }

    /// Title/code/logline/credits/notes, scene names + locations + notes, shot names,
    /// descriptions, notes, types, tags, asset library entries and script text.
    public static func story(_ project: StoryProject) -> (title: String, body: String) {
        var parts: [String] = []
        for v in [project.code, project.logline, project.director, project.producer, project.productionNotes] {
            append(v, to: &parts)
        }
        for scene in project.scenes {
            append(scene.name, to: &parts)
            append(scene.location, to: &parts)
            append(scene.notes, to: &parts)
            for shot in scene.shots {
                append(shot.name, to: &parts)
                append(shot.description, to: &parts)
                append(shot.detailedNotes, to: &parts)
                parts.append(contentsOf: shot.types.filter { !$0.isEmpty })
                parts.append(contentsOf: shot.tags.filter { !$0.isEmpty })
                for take in shot.takes { append(take.label, to: &parts) }
            }
        }
        for list in project.assetLists {
            append(list.name, to: &parts)
            for asset in list.assets {
                append(asset.name, to: &parts)
                append(asset.description, to: &parts)
            }
        }
        for script in project.scripts {
            append(script.name, to: &parts)
            append(script.content, to: &parts)
        }
        return (project.title, joined(parts))
    }

    private static func append(_ value: String?, to parts: inout [String]) {
        guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return }
        parts.append(v)
    }

    private static func joined(_ parts: [String]) -> String {
        parts.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
