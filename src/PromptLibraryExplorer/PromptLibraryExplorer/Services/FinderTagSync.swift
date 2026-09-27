import AppKit
import Foundation

// MARK: - Finder tag I/O

/// Reads and writes a file's Finder tags (`URLResourceKey.tagNamesKey`). Finder's colour
/// labels are tags too (named Red, Orange, … Gray); the app handles those as labels, so
/// they are filtered out of the tag mirror and always preserved when tags are written.
/// Tag writes change extended attributes (and ctime) only, never the content mtime.
enum FinderTagIO {
    private static let englishLabelNames: Set<String> = ["red", "orange", "yellow", "green", "blue", "purple", "gray", "grey"]

    /// Lowercased names that mean a colour label (Finder's, possibly renamed or
    /// localized, plus the English defaults).
    static let labelNames: Set<String> = {
        var names = englishLabelNames
        for name in NSWorkspace.shared.fileLabels where !name.isEmpty {
            names.insert(name.lowercased())
        }
        names.remove("none")
        return names
    }()

    static func isLabelName(_ name: String) -> Bool {
        labelNames.contains(name.lowercased())
    }

    /// The tags that aren't colour labels, in Finder's order.
    static func userTags(_ names: [String]) -> [String] {
        names.filter { !isLabelName($0) && !$0.isEmpty }
    }

    /// Every Finder tag name on the item, read fresh from disk (nil when unreadable).
    static func readTagNames(at url: URL) -> [String]? {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        guard let values = try? fresh.resourceValues(forKeys: [.tagNamesKey]) else { return nil }
        return values.tagNames ?? []
    }

    /// Replaces the item's user tags with `userTags`, keeping its colour-label tags and
    /// label number exactly as they were.
    static func writeUserTags(_ userTags: [String], at url: URL) throws {
        let current = readTagNames(at: url) ?? []
        let labelTags = current.filter(isLabelName)
        let labelBefore = FileSystemService.labelNumber(at: url)
        var seen = Set<String>()
        let names = (labelTags + userTags).filter { seen.insert($0.lowercased()).inserted }
        try (url as NSURL).setResourceValue(names, forKey: .tagNamesKey)
        if FileSystemService.labelNumber(at: url) != labelBefore {
            try FileSystemService.setLabelNumber(labelBefore, at: url)
        }
    }
}

// MARK: - Merge

enum FinderTagMerge {
    /// Case-insensitive set equality.
    static func sameSet(_ lhs: [String], _ rhs: [String]) -> Bool {
        Set(lhs.map { $0.lowercased() }) == Set(rhs.map { $0.lowercased() })
    }

    /// Three-way merge of tag names. `base` is what both sides held after the last sync
    /// (nil = never synced: union). A tag removed on either side since `base` stays
    /// removed; a tag added on either side is added. Names compare case-insensitively;
    /// the app's spelling wins.
    static func threeWay(base: [String]?, app: [String], finder: [String]) -> [String] {
        let baseKeys = Set((base ?? []).map { $0.lowercased() })
        let appKeys = Set(app.map { $0.lowercased() })
        let finderKeys = Set(finder.map { $0.lowercased() })
        var seen = Set<String>()
        var result: [String] = []
        for name in app + finder {
            let key = name.lowercased()
            guard seen.insert(key).inserted else { continue }
            let removedSomewhere = baseKeys.contains(key) && (!appKeys.contains(key) || !finderKeys.contains(key))
            if !removedSomewhere { result.append(name) }
        }
        return result
    }

    /// A stable preset colour for a tag the app creates from a Finder tag name.
    static func defaultColour(for name: String) -> String {
        let presets = FileTag.presetColors
        let sum = name.lowercased().unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return presets[sum % presets.count]
    }
}

// MARK: - Last-synced state

/// Per-file tag names both sides held after the last sync, so a removal on either side
/// propagates instead of being re-added from the other. Persisted as JSON.
final class FinderTagSyncState: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var bases: [String: [String]]
    private var dirty = false

    init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: [String]].self, from: data)
        {
            bases = decoded
        } else {
            bases = [:]
        }
    }

    static var defaultURL: URL {
        CollectionServiceStorage.directoryURL.appendingPathComponent("finder-tag-sync.json")
    }

    func base(for path: String) -> [String]? {
        lock.lock()
        defer { lock.unlock() }
        return bases[path]
    }

    func setBase(_ names: [String], for path: String) {
        lock.lock()
        defer { lock.unlock() }
        let value: [String]? = names.isEmpty ? [] : names
        guard bases[path] != value else { return }
        bases[path] = value
        dirty = true
    }

    func migrate(from oldPath: String, to newPath: String) {
        lock.lock()
        defer { lock.unlock() }
        if let migrated = MetadataPathKeys.migratingKeys(of: bases, from: oldPath, to: newPath) {
            bases = migrated
            dirty = true
        }
    }

    func flush() {
        lock.lock()
        guard dirty else {
            lock.unlock()
            return
        }
        let snapshot = bases
        dirty = false
        lock.unlock()
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: url, options: [.atomic])
        }
    }
}

// MARK: - Sync pass

/// One file's outcome of a Finder ↔ app tag sync.
struct FinderTagSyncOutcome: Equatable {
    let path: String
    /// The merged names both sides now hold.
    let names: [String]
    /// The app's names need updating to `names`.
    let appNeedsUpdate: Bool
    let wroteFinder: Bool
}

enum FinderTagSyncer {
    /// Syncs one file. `appNames` are the app's tag names for it; `finderNames` the
    /// Finder tags if already known (else read fresh). Writes Finder when the merged
    /// names differ from Finder's and records the new base. App tags that happen to be
    /// named like a colour label ("Red") are never mirrored, so they can't turn into a
    /// Finder label.
    static func sync(
        path: String,
        appNames allAppNames: [String],
        finderNames knownFinderNames: [String]?,
        state: FinderTagSyncState
    ) -> FinderTagSyncOutcome? {
        let url = URL(fileURLWithPath: path)
        let appNames = FinderTagIO.userTags(allAppNames)
        guard let allFinderNames = knownFinderNames ?? FinderTagIO.readTagNames(at: url) else { return nil }
        let finder = FinderTagIO.userTags(allFinderNames)
        let base = state.base(for: path)
        if FinderTagMerge.sameSet(finder, appNames) {
            state.setBase(appNames, for: path)
            return nil
        }
        let merged = FinderTagMerge.threeWay(base: base, app: appNames, finder: finder)
        var wrote = false
        if !FinderTagMerge.sameSet(merged, finder) {
            do {
                try FinderTagIO.writeUserTags(merged, at: url)
                wrote = true
            } catch {
                NSLog("PromptLibraryExplorer: couldn't write Finder tags for %@: %@", path, error.localizedDescription)
                return nil
            }
        }
        state.setBase(merged, for: path)
        return FinderTagSyncOutcome(
            path: path,
            names: merged,
            appNeedsUpdate: !FinderTagMerge.sameSet(merged, appNames),
            wroteFinder: wrote
        )
    }

    /// Applies merged names to the app's tag store in one write, creating tags for names
    /// the app doesn't know (colour labels are never created as tags). Returns the
    /// number of files updated.
    @MainActor
    @discardableResult
    static func applyToApp(_ outcomes: [FinderTagSyncOutcome], tags service: TagService) -> Int {
        let updates = outcomes.filter(\.appNeedsUpdate)
        guard !updates.isEmpty else { return 0 }
        var tags = service.loadTags()
        var assignments = service.loadAssignments()
        var idByName: [String: UUID] = [:]
        for tag in tags where idByName[tag.name.lowercased()] == nil { idByName[tag.name.lowercased()] = tag.id }
        var tagsChanged = false
        let labelNamedTagIDs = Set(tags.filter { FinderTagIO.isLabelName($0.name) }.map(\.id))
        for outcome in updates {
            // App tags named like a colour label aren't mirrored; keep them.
            var ids: [UUID] = (assignments[outcome.path] ?? []).filter(labelNamedTagIDs.contains)
            for name in outcome.names where !FinderTagIO.isLabelName(name) {
                let key = name.lowercased()
                let id: UUID
                if let existing = idByName[key] {
                    id = existing
                } else {
                    let tag = FileTag(name: name, colorHex: FinderTagMerge.defaultColour(for: name))
                    tags.append(tag)
                    idByName[key] = tag.id
                    tagsChanged = true
                    id = tag.id
                }
                if !ids.contains(id) { ids.append(id) }
            }
            if ids.isEmpty { assignments.removeValue(forKey: outcome.path) } else { assignments[outcome.path] = ids }
        }
        if tagsChanged { service.saveTags(tags) }
        service.saveAssignments(assignments)
        return updates.count
    }
}
