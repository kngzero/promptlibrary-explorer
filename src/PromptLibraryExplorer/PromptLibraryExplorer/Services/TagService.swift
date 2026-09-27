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
///
/// Both collections are decoded from UserDefaults once and then served from
/// memory; every save writes through to UserDefaults.
final class TagService {
    static let shared = TagService()

    static let tagsKey = "promptlibrary.tags"
    static let assignmentsKey = "promptlibrary.tagAssignments"

    private let lock = NSLock()
    private let defaults: UserDefaults
    private var tagsCache: [FileTag]?
    private var assignmentsCache: [String: [UUID]]?

    /// `defaults` is injectable for tests; the app uses `shared`.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Tag Definitions

    func loadTags() -> [FileTag] {
        lock.lock()
        defer { lock.unlock() }
        return cachedTags()
    }

    func saveTags(_ tags: [FileTag]) {
        lock.lock()
        defer { lock.unlock() }
        storeTags(tags)
    }

    func addTag(_ tag: FileTag) {
        lock.lock()
        defer { lock.unlock() }
        var tags = cachedTags()
        tags.append(tag)
        storeTags(tags)
    }

    func removeTag(id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        var tags = cachedTags()
        tags.removeAll { $0.id == id }
        storeTags(tags)

        // Remove all assignments for this tag
        var assignments = cachedAssignments()
        for (path, tagIDs) in assignments {
            assignments[path] = tagIDs.filter { $0 != id }
            if assignments[path]?.isEmpty == true {
                assignments.removeValue(forKey: path)
            }
        }
        storeAssignments(assignments)
    }

    func updateTag(_ tag: FileTag) {
        lock.lock()
        defer { lock.unlock() }
        var tags = cachedTags()
        if let index = tags.firstIndex(where: { $0.id == tag.id }) {
            tags[index] = tag
        }
        storeTags(tags)
    }

    // MARK: - Assignments (path -> [tagID])

    func loadAssignments() -> [String: [UUID]] {
        lock.lock()
        defer { lock.unlock() }
        return cachedAssignments()
    }

    func saveAssignments(_ assignments: [String: [UUID]]) {
        lock.lock()
        defer { lock.unlock() }
        storeAssignments(assignments)
    }

    func tagsForFile(at path: String, allTags: [FileTag]) -> [FileTag] {
        let assignments = loadAssignments()
        guard let tagIDs = assignments[path] else { return [] }
        let idSet = Set(tagIDs)
        return allTags.filter { idSet.contains($0.id) }
    }

    func assignTag(_ tagID: UUID, toPath path: String) {
        lock.lock()
        defer { lock.unlock() }
        var assignments = cachedAssignments()
        var tagIDs = assignments[path] ?? []
        guard !tagIDs.contains(tagID) else { return }
        tagIDs.append(tagID)
        assignments[path] = tagIDs
        storeAssignments(assignments)
    }

    func removeTag(_ tagID: UUID, fromPath path: String) {
        lock.lock()
        defer { lock.unlock() }
        var assignments = cachedAssignments()
        guard var tagIDs = assignments[path] else { return }
        tagIDs.removeAll { $0 == tagID }
        if tagIDs.isEmpty {
            assignments.removeValue(forKey: path)
        } else {
            assignments[path] = tagIDs
        }
        storeAssignments(assignments)
    }

    func toggleTag(_ tagID: UUID, forPath path: String) {
        lock.lock()
        defer { lock.unlock() }
        var assignments = cachedAssignments()
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
        storeAssignments(assignments)
    }

    func pathsWithTag(_ tagID: UUID) -> Set<String> {
        let assignments = loadAssignments()
        var paths: Set<String> = []
        for (path, tagIDs) in assignments where tagIDs.contains(tagID) {
            paths.insert(path)
        }
        return paths
    }

    // MARK: - Private (call with the lock held)

    private func cachedTags() -> [FileTag] {
        if let tagsCache { return tagsCache }
        let decoded: [FileTag]
        if let data = defaults.data(forKey: Self.tagsKey),
           let value = try? JSONDecoder().decode([FileTag].self, from: data)
        {
            decoded = value
        } else {
            decoded = []
        }
        tagsCache = decoded
        return decoded
    }

    private func cachedAssignments() -> [String: [UUID]] {
        if let assignmentsCache { return assignmentsCache }
        let decoded: [String: [UUID]]
        if let data = defaults.data(forKey: Self.assignmentsKey),
           let value = try? JSONDecoder().decode([String: [UUID]].self, from: data)
        {
            decoded = value
        } else {
            decoded = [:]
        }
        assignmentsCache = decoded
        return decoded
    }

    private func storeTags(_ tags: [FileTag]) {
        tagsCache = tags
        if let data = try? JSONEncoder().encode(tags) {
            defaults.set(data, forKey: Self.tagsKey)
        }
        CurationStoreEvents.post(.tags)
    }

    private func storeAssignments(_ assignments: [String: [UUID]]) {
        assignmentsCache = assignments
        if let data = try? JSONEncoder().encode(assignments) {
            defaults.set(data, forKey: Self.assignmentsKey)
        }
        CurationStoreEvents.post(.tagAssignments)
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
