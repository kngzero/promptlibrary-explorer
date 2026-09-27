import Foundation

struct FileCollection: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var paths: [String]
    var createdAt: Date
    /// The collection set this collection lives in (nil = top level).
    var parentID: UUID?

    init(id: UUID = UUID(), name: String, paths: [String] = [], createdAt: Date = Date(), parentID: UUID? = nil) {
        self.id = id
        self.name = name
        self.paths = paths
        self.createdAt = createdAt
        self.parentID = parentID
    }
}

/// A folder in the collections sidebar. Holds collections and other sets; never files.
struct CollectionSet: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var createdAt: Date
    /// The enclosing set (nil = top level).
    var parentID: UUID?

    init(id: UUID = UUID(), name: String, createdAt: Date = Date(), parentID: UUID? = nil) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.parentID = parentID
    }
}

/// Shared helpers for small JSON stores in Application Support/PromptLibraryExplorer/.
enum CollectionServiceStorage {
    static var directoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("PromptLibraryExplorer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func load<T: Decodable>(_ type: T.Type, from fileName: String) -> T? {
        let url = directoryURL.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, to fileName: String) {
        let url = directoryURL.appendingPathComponent(fileName)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    /// Returns `path` rewritten when it equals `oldPath` or lives beneath it.
    static func migrated(_ path: String, from oldPath: String, to newPath: String) -> String? {
        if path == oldPath { return newPath }
        let prefix = oldPath.hasSuffix("/") ? oldPath : oldPath + "/"
        if path.hasPrefix(prefix) {
            let target = newPath.hasSuffix("/") ? newPath : newPath + "/"
            return target + path.dropFirst(prefix.count)
        }
        return nil
    }
}

@MainActor
final class CollectionService {
    static let shared = CollectionService()

    private static let fileName = "collections.json"
    private static let setsFileName = "collection-sets.json"
    private var collections: [FileCollection]
    private var sets: [CollectionSet]

    private init() {
        collections = CollectionServiceStorage.load([FileCollection].self, from: Self.fileName) ?? []
        sets = CollectionServiceStorage.load([CollectionSet].self, from: Self.setsFileName) ?? []

        // A set deleted by an older build (or a hand-edited file) must not strand its children.
        let setIDs = Set(sets.map(\.id))
        var repaired = false
        for index in collections.indices {
            if let parent = collections[index].parentID, !setIDs.contains(parent) {
                collections[index].parentID = nil
                repaired = true
            }
        }
        for index in sets.indices {
            if let parent = sets[index].parentID, !setIDs.contains(parent) || parent == sets[index].id {
                sets[index].parentID = nil
                repaired = true
            }
        }
        if repaired {
            persist()
            persistSets()
        }
    }

    func all() -> [FileCollection] { collections }

    func allSets() -> [CollectionSet] { sets }

    func collection(id: UUID) -> FileCollection? {
        collections.first { $0.id == id }
    }

    @discardableResult
    func create(name: String, paths: [String], parentID: UUID? = nil) -> FileCollection {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let collection = FileCollection(
            name: trimmed.isEmpty ? "Untitled Collection" : trimmed,
            paths: Self.uniqued(paths),
            parentID: parentID.flatMap { id in sets.contains { $0.id == id } ? id : nil }
        )
        collections.append(collection)
        persist()
        return collection
    }

    func rename(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutate(id) { $0.name = trimmed }
    }

    func delete(id: UUID) {
        let before = collections.count
        collections.removeAll { $0.id == id }
        if collections.count != before { persist() }
    }

    /// Moves a collection into `setID` (nil = top level).
    func move(collection id: UUID, toSet setID: UUID?) {
        if let setID, !sets.contains(where: { $0.id == setID }) { return }
        mutate(id) { $0.parentID = setID }
    }

    // MARK: Sets

    @discardableResult
    func createSet(name: String, parentID: UUID? = nil) -> CollectionSet {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let set = CollectionSet(
            name: trimmed.isEmpty ? "Untitled Set" : trimmed,
            parentID: parentID.flatMap { id in sets.contains { $0.id == id } ? id : nil }
        )
        sets.append(set)
        persistSets()
        return set
    }

    func renameSet(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = sets.firstIndex(where: { $0.id == id }),
              sets[index].name != trimmed else { return }
        sets[index].name = trimmed
        persistSets()
    }

    /// Deletes a set. Its collections and sub-sets move up to the set's parent,
    /// so no collection is ever lost by deleting a set.
    func deleteSet(id: UUID) {
        guard let index = sets.firstIndex(where: { $0.id == id }) else { return }
        let parent = sets[index].parentID
        sets.remove(at: index)
        for i in sets.indices where sets[i].parentID == id {
            sets[i].parentID = parent
        }
        var collectionsChanged = false
        for i in collections.indices where collections[i].parentID == id {
            collections[i].parentID = parent
            collectionsChanged = true
        }
        persistSets()
        if collectionsChanged { persist() }
    }

    /// Moves a set under `parentID` (nil = top level). Refuses moves that would
    /// put a set inside itself or one of its descendants.
    func moveSet(id: UUID, toParent parentID: UUID?) {
        guard let index = sets.firstIndex(where: { $0.id == id }) else { return }
        if let parentID {
            guard sets.contains(where: { $0.id == parentID }),
                  !descendantSetIDs(of: id, including: true).contains(parentID) else { return }
        }
        guard sets[index].parentID != parentID else { return }
        sets[index].parentID = parentID
        persistSets()
    }

    /// `id`'s sub-sets at every depth (plus `id` itself when `including`).
    func descendantSetIDs(of id: UUID, including: Bool = false) -> Set<UUID> {
        var result: Set<UUID> = including ? [id] : []
        var frontier = [id]
        while let current = frontier.popLast() {
            for child in sets where child.parentID == current && result.insert(child.id).inserted {
                frontier.append(child.id)
            }
        }
        return result
    }

    // MARK: Membership

    func add(paths: [String], to id: UUID) {
        mutate(id) { collection in
            var seen = Set(collection.paths)
            for path in paths where seen.insert(path).inserted {
                collection.paths.append(path)
            }
        }
    }

    func remove(paths: [String], from id: UUID) {
        let removing = Set(paths)
        mutate(id) { $0.paths.removeAll { removing.contains($0) } }
    }

    /// Replaces the order of a collection's paths. Paths not already in the collection are ignored;
    /// existing paths omitted from `paths` are kept at the end in their previous order.
    func reorder(id: UUID, paths: [String]) {
        mutate(id) { collection in
            let existing = Set(collection.paths)
            var ordered = Self.uniqued(paths.filter { existing.contains($0) })
            let placed = Set(ordered)
            ordered.append(contentsOf: collection.paths.filter { !placed.contains($0) })
            collection.paths = ordered
        }
    }

    func migratePaths(from oldPath: String, to newPath: String) {
        guard oldPath != newPath else { return }
        var changed = false
        for index in collections.indices {
            var updated: [String] = []
            var seen = Set<String>()
            for path in collections[index].paths {
                let mapped = CollectionServiceStorage.migrated(path, from: oldPath, to: newPath) ?? path
                if mapped != path { changed = true }
                if seen.insert(mapped).inserted { updated.append(mapped) }
            }
            collections[index].paths = updated
        }
        if changed { persist() }
    }

    func removePaths(_ paths: [String]) {
        let removing = Set(paths)
        guard !removing.isEmpty else { return }
        var changed = false
        for index in collections.indices {
            let before = collections[index].paths.count
            collections[index].paths.removeAll { removing.contains($0) }
            if collections[index].paths.count != before { changed = true }
        }
        if changed { persist() }
    }

    // MARK: - Private

    private func mutate(_ id: UUID, _ body: (inout FileCollection) -> Void) {
        guard let index = collections.firstIndex(where: { $0.id == id }) else { return }
        let before = collections[index]
        body(&collections[index])
        if collections[index] != before { persist() }
    }

    private func persist() {
        CollectionServiceStorage.save(collections, to: Self.fileName)
    }

    private func persistSets() {
        CollectionServiceStorage.save(sets, to: Self.setsFileName)
    }

    private static func uniqued(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }
}
