import CoreSpotlight
import Foundation
import Observation

/// Keeps Core Spotlight in step with the library index and the curation stores.
///
/// Source of truth is `LibraryIndexService` (prompt text, model, sampler, size) plus
/// ratings and tags. Its change feed (`LibraryIndexService.didChangeNotification`)
/// drives incremental updates: indexed or re-indexed files are (re)submitted, trashed,
/// moved or vanished files are deleted. Curation changes re-submit only the files
/// whose rating or tags changed. Settings ▸ Integrations has the switch (on by
/// default), Rebuild and Remove.
@MainActor @Observable
final class SpotlightController {
    static let shared = SpotlightController()

    static let enabledKey = "integration.spotlightEnabled"
    /// Bumped when the item format changes, so existing installs rebuild once.
    static let formatVersion = 1
    static let builtVersionKey = "integration.spotlightBuiltVersion"

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled { rebuild() } else { removeAll() }
        }
    }

    private(set) var isWorking = false
    private(set) var progress: (done: Int, total: Int)?
    private(set) var indexedCount: Int?
    private(set) var lastMessage: String?
    private(set) var lastError: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let index: CSSearchableIndex
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var queue: Task<Void, Never>?
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    @ObservationIgnored private var started = false
    /// Last seen curation, to find the files whose rating / tags changed.
    @ObservationIgnored private var ratings: [String: Int] = [:]
    @ObservationIgnored private var tagNamesByPath: [String: [String]] = [:]

    init(defaults: UserDefaults = .standard, index: CSSearchableIndex = .default()) {
        self.defaults = defaults
        self.index = index
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    // MARK: Lifecycle

    /// Called once at launch (App file). Subscribes to the change feeds and, when on
    /// and never built in this format, builds the whole index in the background.
    func start() {
        guard !started else { return }
        started = true
        snapshotCuration()
        observers.append(NotificationCenter.default.addObserver(
            forName: LibraryIndexService.didChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let upserted = note.userInfo?[LibraryIndexService.upsertedPathsKey] as? [String] ?? []
            let removed = note.userInfo?[LibraryIndexService.removedPathsKey] as? [String] ?? []
            let reset = note.userInfo?[LibraryIndexService.resetKey] as? Bool ?? false
            MainActor.assumeIsolated {
                self?.libraryIndexDidChange(upserted: upserted, removed: removed, reset: reset)
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: CurationStoreEvents.didChange, object: nil, queue: .main
        ) { [weak self] note in
            let kind = note.userInfo?[CurationStoreEvents.kindKey] as? String
            MainActor.assumeIsolated {
                self?.curationDidChange(kind: kind)
            }
        })
        if isEnabled, defaults.integer(forKey: Self.builtVersionKey) < Self.formatVersion {
            rebuild(announce: false)
        }
    }

    // MARK: Commands

    /// Replaces every item with a fresh build from the library index.
    func rebuild(announce: Bool = true) {
        guard isEnabled, CSSearchableIndex.isIndexingAvailable() else {
            if !CSSearchableIndex.isIndexingAvailable() { lastError = "Spotlight indexing isn't available on this Mac." }
            return
        }
        rebuildTask?.cancel()
        isWorking = true
        progress = (0, 0)
        lastError = nil
        lastMessage = nil
        rebuildTask = enqueue { [weak self] in
            guard let self else { return }
            let roots = await LibraryIndexService.shared.indexedRoots()
            let rows = await LibraryIndexService.shared.spotlightRows()
            guard !Task.isCancelled else { return }
            do {
                try await self.index.deleteAllSearchableItems()
                let count = try await self.submit(rows: rows, roots: roots, reportProgress: true)
                guard !Task.isCancelled else { return }
                self.defaults.set(Self.formatVersion, forKey: Self.builtVersionKey)
                self.indexedCount = count
                self.lastMessage = announce || count > 0 ? "Indexed \(count) file\(count == 1 ? "" : "s") in Spotlight" : nil
            } catch {
                self.lastError = error.localizedDescription
            }
            self.isWorking = false
            self.progress = nil
        }
    }

    /// Deletes every item this app gave Spotlight (the files are untouched).
    func removeAll() {
        rebuildTask?.cancel()
        isWorking = true
        enqueue { [weak self] in
            guard let self else { return }
            do {
                try await self.index.deleteAllSearchableItems()
                self.defaults.set(0, forKey: Self.builtVersionKey)
                self.indexedCount = 0
                self.lastMessage = "Removed PromptLibrary files from Spotlight"
            } catch {
                self.lastError = error.localizedDescription
            }
            self.isWorking = false
            self.progress = nil
        }
    }

    // MARK: Incremental updates

    private func libraryIndexDidChange(upserted: [String], removed: [String], reset: Bool) {
        guard isEnabled else { return }
        if reset {
            enqueue { [weak self] in try? await self?.index.deleteAllSearchableItems() }
            return
        }
        let upsertedSet = Set(upserted)
        // A moved file's old identifier goes; a re-indexed file is simply replaced.
        let deletions = removed.filter { !upsertedSet.contains($0) }
        if !deletions.isEmpty {
            enqueue { [weak self] in try? await self?.index.deleteSearchableItems(withIdentifiers: deletions) }
        }
        if !upserted.isEmpty { submit(paths: upserted) }
    }

    private func curationDidChange(kind: String?) {
        guard let kind, let store = CurationStoreKind(rawValue: kind),
              [.ratings, .tags, .tagAssignments].contains(store)
        else { return }
        let before = (ratings, tagNamesByPath)
        snapshotCuration()
        guard isEnabled else { return }
        let changed = Self.changedPaths(
            oldRatings: before.0, newRatings: ratings, oldTags: before.1, newTags: tagNamesByPath
        )
        if !changed.isEmpty { submit(paths: Array(changed)) }
    }

    /// Paths whose rating or tag names differ between two snapshots.
    nonisolated static func changedPaths(
        oldRatings: [String: Int], newRatings: [String: Int],
        oldTags: [String: [String]], newTags: [String: [String]]
    ) -> Set<String> {
        var changed = Set<String>()
        for path in Set(oldRatings.keys).union(newRatings.keys) where (oldRatings[path] ?? 0) != (newRatings[path] ?? 0) {
            changed.insert(path)
        }
        for path in Set(oldTags.keys).union(newTags.keys) where Set(oldTags[path] ?? []) != Set(newTags[path] ?? []) {
            changed.insert(path)
        }
        return changed
    }

    private func submit(paths: [String]) {
        enqueue { [weak self] in
            guard let self else { return }
            let rows = await LibraryIndexService.shared.spotlightRows(forPaths: paths)
            guard !rows.isEmpty else { return }
            let roots = await LibraryIndexService.shared.indexedRoots()
            _ = try? await self.submit(rows: rows, roots: roots, reportProgress: false)
        }
    }

    // MARK: Building

    private func snapshotCuration() {
        ratings = SettingsStore.shared.loadRatings()
        let tags = TagService.shared.loadTags()
        let namesByID = Dictionary(tags.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        tagNamesByPath = TagService.shared.loadAssignments().mapValues { ids in ids.compactMap { namesByID[$0] } }
    }

    /// Builds (thumbnails off the main actor) and submits items in batches. Returns the
    /// number submitted.
    private func submit(rows: [LibraryIndexSpotlightRow], roots: [String], reportProgress: Bool) async throws -> Int {
        let ratings = self.ratings
        let tags = self.tagNamesByPath
        let batchSize = 100
        var done = 0
        var start = 0
        while start < rows.count {
            try Task.checkCancellation()
            let batch = Array(rows[start..<min(start + batchSize, rows.count)])
            start += batchSize
            let items = await Task.detached(priority: .utility) {
                batch.map { row in
                    SpotlightItemBuilder.item(for: SpotlightEntry(
                        row: row,
                        tags: tags[row.path] ?? [],
                        rating: ratings[row.path] ?? 0,
                        domain: SpotlightItemBuilder.domain(forPath: row.path, roots: roots),
                        thumbnailData: SpotlightItemBuilder.thumbnailData(forPath: row.path)
                    ))
                }
            }.value
            try await index.indexSearchableItems(items)
            done += items.count
            if reportProgress { progress = (done, rows.count) }
        }
        return done
    }

    /// Serializes index work so deletes and submissions land in order.
    @discardableResult
    private func enqueue(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = queue
        let task = Task { @MainActor in
            await previous?.value
            await operation()
        }
        queue = task
        return task
    }
}
