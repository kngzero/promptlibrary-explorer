import Foundation
import SwiftUI

/// A user-defined tag that can be applied to files.
struct FileTag: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var colorHex: String

    init(name: String, colorHex: String) {
        self.id = UUID()
        self.name = name
        self.colorHex = colorHex
    }

    var color: Color {
        Color(hex: colorHex)
    }

    static let presetColors: [String] = [
        "#EF4444", "#F97316", "#EAB308", "#22C55E",
        "#06B6D4", "#3B82F6", "#8B5CF6", "#EC4899",
    ]
}

/// Manages tag definitions and per-file tag assignments.
final class TagService {
    static let shared = TagService()

    private static let tagsKey = "promptlibrary.tags"
    private static let assignmentsKey = "promptlibrary.tagAssignments"

    private init() {}

    // MARK: - Tag Definitions

    func loadTags() -> [FileTag] {
        guard let data = UserDefaults.standard.data(forKey: Self.tagsKey),
              let tags = try? JSONDecoder().decode([FileTag].self, from: data)
        else { return [] }
        return tags
    }

    func saveTags(_ tags: [FileTag]) {
        if let data = try? JSONEncoder().encode(tags) {
            UserDefaults.standard.set(data, forKey: Self.tagsKey)
        }
    }

    func addTag(_ tag: FileTag) {
        var tags = loadTags()
        tags.append(tag)
        saveTags(tags)
    }

    func removeTag(id: UUID) {
        var tags = loadTags()
        tags.removeAll { $0.id == id }
        saveTags(tags)

        // Remove all assignments for this tag
        var assignments = loadAssignments()
        for (path, tagIDs) in assignments {
            assignments[path] = tagIDs.filter { $0 != id }
            if assignments[path]?.isEmpty == true {
                assignments.removeValue(forKey: path)
            }
        }
        saveAssignments(assignments)
    }

    func updateTag(_ tag: FileTag) {
        var tags = loadTags()
        if let index = tags.firstIndex(where: { $0.id == tag.id }) {
            tags[index] = tag
        }
        saveTags(tags)
    }

    // MARK: - Assignments (path -> [tagID])

    func loadAssignments() -> [String: [UUID]] {
        guard let data = UserDefaults.standard.data(forKey: Self.assignmentsKey),
              let decoded = try? JSONDecoder().decode([String: [UUID]].self, from: data)
        else { return [:] }
        return decoded
    }

    func saveAssignments(_ assignments: [String: [UUID]]) {
        if let data = try? JSONEncoder().encode(assignments) {
            UserDefaults.standard.set(data, forKey: Self.assignmentsKey)
        }
    }

    func tagsForFile(at path: String, allTags: [FileTag]) -> [FileTag] {
        let assignments = loadAssignments()
        guard let tagIDs = assignments[path] else { return [] }
        let idSet = Set(tagIDs)
        return allTags.filter { idSet.contains($0.id) }
    }

    func assignTag(_ tagID: UUID, toPath path: String) {
        var assignments = loadAssignments()
        var tagIDs = assignments[path] ?? []
        guard !tagIDs.contains(tagID) else { return }
        tagIDs.append(tagID)
        assignments[path] = tagIDs
        saveAssignments(assignments)
    }

    func removeTag(_ tagID: UUID, fromPath path: String) {
        var assignments = loadAssignments()
        guard var tagIDs = assignments[path] else { return }
        tagIDs.removeAll { $0 == tagID }
        if tagIDs.isEmpty {
            assignments.removeValue(forKey: path)
        } else {
            assignments[path] = tagIDs
        }
        saveAssignments(assignments)
    }

    func toggleTag(_ tagID: UUID, forPath path: String) {
        var assignments = loadAssignments()
        var tagIDs = assignments[path] ?? []
        if tagIDs.contains(tagID) {
            tagIDs.removeAll { $0 == tagID }
        } else {
            tagIDs.append(tagID)
        }
        if tagIDs.isEmpty {
            assignments.removeValue(forKey: path)
        } else {
            assignments[path] = tagIDs
        }
        saveAssignments(assignments)
    }

    func pathsWithTag(_ tagID: UUID) -> Set<String> {
        let assignments = loadAssignments()
        var paths: Set<String> = []
        for (path, tagIDs) in assignments where tagIDs.contains(tagID) {
            paths.insert(path)
        }
        return paths
    }
}

// MARK: - Color Hex Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let scanner = Scanner(string: hex)
        var rgb: UInt64 = 0
        scanner.scanHexInt64(&rgb)

        let r = Double((rgb >> 16) & 0xFF) / 255.0
        let g = Double((rgb >> 8) & 0xFF) / 255.0
        let b = Double(rgb & 0xFF) / 255.0

        self.init(red: r, green: g, blue: b)
    }
}
