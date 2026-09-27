import Foundation

// MARK: - Manual stacks (curation data)
//
// Version stacks group variants of one image behind a cover tile. Automatic stacks are
// recomputed from the listing (see StackDetection.swift) and never stored; what IS
// stored is what the user decided:
//   - manual stacks (Stack Selected, or an automatic stack pinned by Set as Cover /
//     Remove from Stack), with an optional cover;
//   - files kept out of automatic stacks (Unstack / Remove from Stack).
// Covers are display-only: they imply nothing about which file to keep, and nothing in
// the stacks feature ever suggests, marks or selects a file for deletion.

/// A stack the user made or pinned. `coverPath == nil` = the most recently modified member.
struct ManualStack: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    /// Members in the order they were stacked (display order comes from the listing).
    var paths: [String]
    var coverPath: String?
    var createdAt: Date

    init(id: UUID = UUID(), paths: [String], coverPath: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.paths = paths
        self.coverPath = coverPath
        self.createdAt = createdAt
    }
}

/// Everything the stacks feature persists.
struct StackBook: Codable, Equatable, Sendable {
    var stacks: [ManualStack] = []
    /// Files that never join an automatic stack.
    var excludedPaths: Set<String> = []

    init(stacks: [ManualStack] = [], excludedPaths: Set<String> = []) {
        self.stacks = stacks
        self.excludedPaths = excludedPaths
    }

    enum CodingKeys: String, CodingKey { case stacks, excludedPaths }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stacks = (try? c.decodeIfPresent([ManualStack].self, forKey: .stacks)) ?? []
        excludedPaths = (try? c.decodeIfPresent(Set<String>.self, forKey: .excludedPaths)) ?? []
    }

    var isEmpty: Bool { stacks.isEmpty && excludedPaths.isEmpty }

    func stack(containing path: String) -> ManualStack? {
        stacks.first { $0.paths.contains(path) }
    }

    /// Makes `paths` one manual stack (a file belongs to at most one: it leaves any other
    /// manual stack, and stops being excluded from automatic stacks). Returns nil for
    /// fewer than two distinct paths.
    @discardableResult
    mutating func createStack(paths rawPaths: [String], coverPath: String? = nil, id: UUID = UUID(), now: Date = Date()) -> ManualStack? {
        var seen = Set<String>()
        let paths = rawPaths.filter { seen.insert($0).inserted }
        guard paths.count >= 2 else { return nil }
        let members = Set(paths)
        for index in stacks.indices {
            stacks[index].paths.removeAll { members.contains($0) }
        }
        excludedPaths.subtract(members)
        let stack = ManualStack(
            id: id,
            paths: paths,
            coverPath: coverPath.flatMap { members.contains($0) ? $0 : nil },
            // Whole seconds, so the value survives ISO 8601 round trips (bundles, sync).
            createdAt: Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        )
        stacks.append(stack)
        normalize()
        return stack
    }

    /// Unstack: the stack goes, and its members stay out of automatic stacks (otherwise
    /// they would regroup straight away).
    mutating func dissolve(id: UUID) {
        guard let index = stacks.firstIndex(where: { $0.id == id }) else { return }
        excludedPaths.formUnion(stacks[index].paths)
        stacks.remove(at: index)
    }

    /// Unstack for an automatic stack.
    mutating func exclude(_ paths: [String]) {
        excludedPaths.formUnion(paths)
    }

    /// Takes `path` out of its manual stack (dissolving a stack left with one member)
    /// and keeps it out of automatic stacks.
    mutating func remove(_ path: String) {
        for index in stacks.indices {
            stacks[index].paths.removeAll { $0 == path }
            if stacks[index].coverPath == path { stacks[index].coverPath = nil }
        }
        excludedPaths.insert(path)
        normalize()
    }

    mutating func setCover(_ path: String, stackID: UUID) {
        guard let index = stacks.firstIndex(where: { $0.id == stackID }), stacks[index].paths.contains(path) else { return }
        stacks[index].coverPath = path
    }

    /// Rewrites every path at or under `oldPath` (rename / move). Returns false when
    /// nothing matched.
    @discardableResult
    mutating func migrate(from oldPath: String, to newPath: String) -> Bool {
        guard oldPath != newPath else { return false }
        var changed = false
        func rewrite(_ path: String) -> String {
            guard let rewritten = MetadataPathKeys.rewrite(path, from: oldPath, to: newPath), rewritten != path else { return path }
            changed = true
            return rewritten
        }
        for index in stacks.indices {
            stacks[index].paths = stacks[index].paths.map(rewrite)
            stacks[index].coverPath = stacks[index].coverPath.map(rewrite)
        }
        excludedPaths = Set(excludedPaths.map(rewrite))
        return changed
    }

    /// Drops stacks with fewer than two members, duplicate members and covers that
    /// aren't members.
    mutating func normalize() {
        var claimed = Set<String>()
        var result: [ManualStack] = []
        for var stack in stacks {
            var seen = Set<String>()
            stack.paths = stack.paths.filter { seen.insert($0).inserted && !claimed.contains($0) }
            guard stack.paths.count >= 2 else { continue }
            claimed.formUnion(stack.paths)
            if let cover = stack.coverPath, !stack.paths.contains(cover) { stack.coverPath = nil }
            result.append(stack)
        }
        stacks = result
    }
}

/// Persists the stack book as JSON in `defaults` (injectable for tests) and posts
/// `CurationStoreEvents` so backups, the library data file and sync pick it up.
struct StackStore {
    static let storageKey = "promptlibrary.stacks"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> StackBook {
        guard let data = defaults.data(forKey: Self.storageKey),
              let book = try? JSONDecoder().decode(StackBook.self, from: data)
        else { return StackBook() }
        return book
    }

    func save(_ book: StackBook) {
        var normalized = book
        normalized.normalize()
        if let data = try? JSONEncoder().encode(normalized) {
            defaults.set(data, forKey: Self.storageKey)
            CurationStoreEvents.post(.stacks)
        }
    }
}
