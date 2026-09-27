import AppKit
import Foundation
import Observation

/// Neutral facts shown under each card in a similar group. Nothing here is
/// used to rank, highlight or pick a "best" copy (see the HARD RULE in
/// Models/SimilarImagesPage.swift).
struct SimilarImageInfo: Equatable, Sendable {
    var pixelWidth: Int?
    var pixelHeight: Int?
    var fileSize: Int64?
    var folderPath: String
    var isVideo: Bool
    var modifiedDate: Date? = nil
    /// Finder label number (0 = none).
    var labelNumber: Int = 0

    var resolutionText: String? {
        guard let pixelWidth, let pixelHeight, pixelWidth > 0, pixelHeight > 0 else { return nil }
        return "\(pixelWidth) × \(pixelHeight)"
    }

    var sizeText: String? {
        fileSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    }

    var aspectRatio: CGFloat? {
        guard let pixelWidth, let pixelHeight, pixelWidth > 0, pixelHeight > 0 else { return nil }
        return CGFloat(pixelWidth) / CGFloat(pixelHeight)
    }
}

/// A culling change on a card, for its brief flash.
struct SimilarCardFeedback: Equatable {
    let id: Int
    let paths: Set<String>
    let action: CullAction
}

/// State of the Similar Images page: the engine's groups (in its display
/// order) with neutral per-file info, the controls, the page's focus, cached
/// results per search, and card prompts. Exposes no removal action of any kind.
@Observable
@MainActor
final class SimilarImagesModel {
    private(set) var sets: [SimilarSet] = []
    private(set) var info: [String: SimilarImageInfo] = [:]
    private(set) var isComputing = false
    private(set) var hasSearched = false
    /// Files the visual index holds under the root (nil until checked).
    private(set) var indexedCount: Int?
    /// Search the shown results belong to.
    private(set) var resultsKey: SimilarResultsKey?
    /// The visual index changed for files these results cover since they were computed.
    private(set) var isStale = false

    /// Selected group and focused card.
    private(set) var focus = SimilarPageFocus()

    /// Card prompts (first positive prompt; "" = none), loaded on demand.
    private(set) var prompts: [String: String] = [:]
    private(set) var cardFeedback: SimilarCardFeedback?

    /// Strictness slider (0.5…1), persisted.
    var strictness: Double {
        didSet {
            guard strictness != oldValue else { return }
            defaults.set(strictness, forKey: Self.strictnessKey)
        }
    }

    /// Include Videos switch (default on), persisted.
    var includeVideos: Bool {
        didSet {
            guard includeVideos != oldValue else { return }
            defaults.set(includeVideos, forKey: Self.includeVideosKey)
        }
    }

    static let strictnessKey = "similarImages.strictness"
    static let includeVideosKey = "similarImages.includeVideos"
    static let strictnessRange: ClosedRange<Double> = 0.5...1

    @ObservationIgnored private var cache = SimilarResultsCache()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var runningKey: SimilarResultsKey?
    @ObservationIgnored private var promptTasks: [String: Task<String, Never>] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var indexObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.object(forKey: Self.strictnessKey) as? Double ?? 0.85
        strictness = min(max(stored, Self.strictnessRange.lowerBound), Self.strictnessRange.upperBound)
        includeVideos = defaults.object(forKey: Self.includeVideosKey) as? Bool ?? true
        indexObserver = NotificationCenter.default.addObserver(
            forName: VisualIndexController.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let paths = note.userInfo?[VisualIndexController.changedPathsKey] as? [String]
            MainActor.assumeIsolated { self?.indexDidChange(paths: paths) }
        }
    }

    var fileCount: Int { sets.reduce(0) { $0 + $1.paths.count } }
    var exactGroupCount: Int { sets.filter { $0.kind == .exact }.count }

    var selectedSet: SimilarSet? {
        focus.groupIndex(in: sets).map { sets[$0] }
    }

    var focusedPath: String? { focus.path }

    /// Cards of a group: exactly the engine's order (folder, then name), never
    /// re-sorted by size or resolution.
    nonisolated static func rows(for set: SimilarSet, info: [String: SimilarImageInfo]) -> [(path: String, info: SimilarImageInfo?)] {
        set.paths.map { ($0, info[$0]) }
    }

    func rows(for set: SimilarSet) -> [(path: String, info: SimilarImageInfo?)] {
        Self.rows(for: set, info: info)
    }

    /// A minimal entry for culling / More Like This on a card (no disk read).
    func entry(for path: String) -> FileEntry {
        let details = info[path]
        return FileEntry(
            url: URL(fileURLWithPath: path),
            isDirectory: false,
            modifiedDate: details?.modifiedDate,
            fileSize: details?.fileSize,
            labelNumber: details?.labelNumber
        )
    }

    // MARK: Searching

    func refreshIndexStats(root: URL?) async {
        indexedCount = await VisualIndexService.shared.stats(under: root).indexed
    }

    func key(for scope: VisualScope) -> SimilarResultsKey {
        SimilarResultsKey(scope: scope, strictness: strictness, includeVideos: includeVideos)
    }

    /// Shows the results for `scope` with the current controls: cached ones
    /// at once, otherwise a new search. `force` always searches again (Find).
    func show(scope: VisualScope?, root: URL?, force: Bool = false) {
        guard let scope else {
            cancel()
            sets = []
            info = [:]
            resultsKey = nil
            focus = SimilarPageFocus()
            return
        }
        let key = key(for: scope)
        if !force {
            if let entry = cache.entry(for: key) {
                cancel()
                cache.touch(key)
                apply(entry, key: key)
                return
            }
            if isComputing, runningKey == key { return }
        }
        run(key: key, root: root)
    }

    private func run(key: SimilarResultsKey, root: URL?) {
        task?.cancel()
        isComputing = true
        hasSearched = true
        runningKey = key
        task = Task { [weak self] in
            let found = await VisualIndexService.shared.similarSets(
                in: key.scope,
                strictness: key.strictness,
                includeVideos: key.includeVideos
            )
            guard !Task.isCancelled else { return }
            let paths = found.flatMap(\.paths)
            let signatures = await VisualIndexService.shared.signatures(forPaths: paths)
            let details = await Task.detached(priority: .userInitiated) {
                Self.fileDetails(for: paths, signatures: signatures)
            }.value
            let stats = await VisualIndexService.shared.stats(under: root)
            guard !Task.isCancelled, let self else { return }
            let entry = SimilarResultsEntry(sets: found, info: details, indexedCount: stats.indexed)
            self.cache.store(entry, for: key)
            self.apply(entry, key: key)
            self.isComputing = false
            self.runningKey = nil
        }
    }

    private func apply(_ entry: SimilarResultsEntry, key: SimilarResultsKey) {
        sets = entry.sets
        info = entry.info
        if let indexed = entry.indexedCount { indexedCount = indexed }
        resultsKey = key
        hasSearched = true
        isStale = false
        focus = focus.resolved(in: sets)
    }

    func cancel() {
        task?.cancel()
        task = nil
        runningKey = nil
        isComputing = false
    }

    /// The visual index changed (nil: everything): drop affected cached
    /// searches; the shown results say they may be out of date.
    func indexDidChange(paths: [String]?) {
        if let paths {
            cache.invalidate(paths: paths)
        } else {
            cache.removeAll()
        }
        if let resultsKey, cache.entry(for: resultsKey) == nil, !isComputing {
            isStale = true
        }
    }

    /// Drops paths that no longer exist from the groups (after a rename, move
    /// or trash elsewhere); a group left with fewer than two files disappears.
    func pruneMissingFiles() {
        let fm = FileManager.default
        let pruned = sets.compactMap { set -> SimilarSet? in
            let existing = set.paths.filter { fm.fileExists(atPath: $0) }
            guard existing.count >= 2 else { return nil }
            return existing.count == set.paths.count
                ? set
                : SimilarSet(id: set.id, paths: existing, kind: set.kind)
        }
        guard pruned != sets else { return }
        sets = pruned
        focus = focus.resolved(in: sets)
    }

    // MARK: Focus

    func moveGroup(by step: Int) {
        focus = focus.movingGroup(by: step, in: sets)
    }

    func moveCard(by step: Int) {
        focus = focus.movingCard(by: step, in: sets)
    }

    func selectGroup(_ id: String) {
        focus = focus.selectingGroup(id, in: sets)
    }

    func focus(path: String) {
        focus = focus.focusing(path, in: sets)
    }

    // MARK: Prompts (same parsing path as the details panel, off the main actor)

    func loadPrompt(for path: String) {
        guard prompts[path] == nil else { return }
        _ = promptTask(for: path)
    }

    /// The card's prompt ("" when it has none), loading it when needed.
    func prompt(for path: String) async -> String {
        if let cached = prompts[path] { return cached }
        return await promptTask(for: path).value
    }

    private func promptTask(for path: String) -> Task<String, Never> {
        if let running = promptTasks[path] { return running }
        let task = Task { [weak self] () -> String in
            let text = await Self.readPrompt(atPath: path)
            self?.prompts[path] = text
            self?.promptTasks[path] = nil
            return text
        }
        promptTasks[path] = task
        return task
    }

    /// The parser the details panel, Copy Prompt and the prompt index use
    /// (`ImageMetadataParser` for images; videos carry none it reads).
    nonisolated static func readPrompt(atPath path: String) async -> String {
        let entry = FileEntry(url: URL(fileURLWithPath: path), isDirectory: false)
        let parsed = await ExplorerViewModel.parsePromptData(for: entry)
        return parsed.prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: Culling feedback

    /// After a flag / rating / label change: refresh the labels shown on cards
    /// (they're on disk) and flash the change on the cards it touched.
    func noteCullApplied(_ action: CullAction, paths: [String]) {
        let shown = paths.filter { info[$0] != nil }
        guard !shown.isEmpty else { return }
        if case .label = action {
            for path in shown {
                info[path]?.labelNumber = FileSystemService.labelNumber(at: URL(fileURLWithPath: path))
            }
        }
        cardFeedback = SimilarCardFeedback(id: (cardFeedback?.id ?? 0) &+ 1, paths: Set(shown), action: action)
    }

    // MARK: File details

    nonisolated private static func fileDetails(
        for paths: [String],
        signatures: [String: VisualSignature]
    ) -> [String: SimilarImageInfo] {
        var result: [String: SimilarImageInfo] = [:]
        for path in paths {
            let signature = signatures[path]
            let entry = FileEntry.load(from: URL(fileURLWithPath: path))
            result[path] = SimilarImageInfo(
                pixelWidth: signature?.pixelWidth,
                pixelHeight: signature?.pixelHeight,
                fileSize: entry?.fileSize,
                folderPath: (path as NSString).deletingLastPathComponent,
                isVideo: signature?.isVideo ?? FileHelpers.isVideoFile(path),
                modifiedDate: entry?.modifiedDate,
                labelNumber: entry?.labelNumber ?? 0
            )
        }
        return result
    }
}
