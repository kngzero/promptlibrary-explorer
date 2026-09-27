import Foundation
import Observation

/// Background text recognition and classification, run on the visual index's schedule:
/// it starts when a visual index run completes, waits while one runs, pauses when the
/// visual index is paused and stops when it's stopped (turned off). Low priority,
/// cancellable, incremental (path + mtime + size).
///
/// Also holds the recognised text of the current listing (for Text in Image search and
/// the smart-folder rule) and a small cache of per-file records for the details panel.
@MainActor @Observable
final class ImageTextController {
    static let shared = ImageTextController()

    enum State: Equatable {
        case idle        // nothing run yet
        case waiting     // the visual index is indexing; analysis follows it
        case analyzing
        case paused      // the visual index is paused
        case stopped     // the visual index is stopped, or both analyses are off
        case completed
    }

    private(set) var state: State = .idle
    private(set) var progress: (done: Int, total: Int)?
    private(set) var currentItemName: String?
    private(set) var lastCompleted: Date?

    /// Persisted, default on.
    var recognizeTextEnabled: Bool {
        didSet {
            guard recognizeTextEnabled != oldValue else { return }
            defaults.set(recognizeTextEnabled, forKey: Self.recognizeTextKey)
            optionsDidChange()
        }
    }

    /// Persisted, default on.
    var suggestTagsEnabled: Bool {
        didSet {
            guard suggestTagsEnabled != oldValue else { return }
            defaults.set(suggestTagsEnabled, forKey: Self.suggestTagsKey)
            optionsDidChange()
        }
    }

    /// Recognised text of the current listing's files (only files with text).
    private(set) var listingText: [String: String] = [:]
    /// Bumped when stored records change (the details panel reloads).
    private(set) var recordsRevision = 0

    @ObservationIgnored var onListingTextChange: (() -> Void)?

    static let recognizeTextKey = "imageText.recognizeText"
    static let suggestTagsKey = "imageText.suggestTags"
    static let lastCompletedKey = "imageText.lastCompleted"

    @ObservationIgnored private let service: ImageTextService
    @ObservationIgnored private let visual: VisualIndexController
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var lastRun: Task<Void, Never>?
    @ObservationIgnored private var runID = 0
    @ObservationIgnored private var runningRoot: URL?
    @ObservationIgnored private var completedRootPath: String?
    @ObservationIgnored private var completedAt: Date?
    @ObservationIgnored private var carriedDone = 0
    @ObservationIgnored private var didAttach = false
    @ObservationIgnored private var listingScope: String?
    @ObservationIgnored private var listingFolder: String?
    @ObservationIgnored private var listingPaths: [String] = []
    @ObservationIgnored private var listingTask: Task<Void, Never>?
    @ObservationIgnored private var recordCache: [String: ImageTextRecord] = [:]
    @ObservationIgnored private var observer: NSObjectProtocol?

    init(service: ImageTextService = .shared, visual: VisualIndexController? = nil, defaults: UserDefaults = .standard) {
        self.service = service
        self.visual = visual ?? .shared
        self.defaults = defaults
        recognizeTextEnabled = defaults.object(forKey: Self.recognizeTextKey) as? Bool ?? true
        suggestTagsEnabled = defaults.object(forKey: Self.suggestTagsKey) as? Bool ?? true
        if defaults.object(forKey: Self.lastCompletedKey) != nil {
            lastCompleted = Date(timeIntervalSince1970: defaults.double(forKey: Self.lastCompletedKey))
        }
    }

    var options: ImageTextOptions {
        ImageTextOptions(recognizeText: recognizeTextEnabled, classify: suggestTagsEnabled)
    }

    // MARK: Lifecycle

    /// Starts following the visual index (idempotent). The app calls this at launch.
    func attach() {
        guard !didAttach else { return }
        didAttach = true
        // Recognised text goes into the library search index too.
        let library = LibraryIndexService.shared
        LibraryIndexExtractor.imageTextLookup = { path in await ImageTextService.shared.text(forPath: path) }
        Task { await service.setOnTextStored { paths in await library.refreshIndexedText(paths: paths) } }
        observer = NotificationCenter.default.addObserver(
            forName: VisualIndexController.didChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let paths = note.userInfo?[VisualIndexController.changedPathsKey] as? [String]
            MainActor.assumeIsolated { self?.visualIndexDidChange(paths: paths) }
        }
        observeVisualState()
        visualStateDidChange()
    }

    private func observeVisualState() {
        withObservationTracking {
            _ = visual.state
            _ = visual.isEnabled
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.visualStateDidChange()
                self?.observeVisualState()
            }
        }
    }

    private func visualStateDidChange() {
        guard !options.isEmpty else {
            cancelRun()
            state = .stopped
            return
        }
        switch visual.state {
        case .indexing:
            if state == .analyzing { suspendRun() }
            state = .waiting
        case .paused:
            if state == .analyzing { suspendRun() }
            state = .paused
        case .stopped:
            cancelRun()
            carriedDone = 0
            progress = nil
            currentItemName = nil
            state = .stopped
        case .completed:
            guard let root = visual.root else { return }
            if state == .analyzing, runningRoot?.path == root.path { return }
            // Just finished this root: don't re-walk it on every visual-state blip.
            if state == .completed, completedRootPath == root.path,
               let completedAt, Date().timeIntervalSince(completedAt) < 10 { return }
            run(root: root, markStale: false)
        case .idle:
            if state == .stopped || state == .paused { state = .idle }
        }
    }

    /// A rename / move / removal the visual index processed: follow it.
    private func visualIndexDidChange(paths: [String]?) {
        guard let paths, !paths.isEmpty else { return }
        // A completed run posts its root: that's handled by the state change.
        if paths.count == 1, let root = visual.root, VisualIndexService.normalizedPath(root.path) == paths[0] { return }
        let service = service
        let options = options
        let analyze = !options.isEmpty && visual.state != .paused && visual.state != .stopped
        Task { [weak self] in
            var existing: [String] = []
            var missing: [String] = []
            for path in paths {
                if FileManager.default.fileExists(atPath: path) { existing.append(path) } else { missing.append(path) }
            }
            if missing.count == 1, existing.count == 1 {
                await service.movePath(from: missing[0], to: existing[0])
            } else {
                for path in missing { await service.removeEntries(under: path) }
            }
            let files = existing.filter { FileHelpers.isImageFile(($0 as NSString).lastPathComponent) }
            if analyze, !files.isEmpty { await service.analyze(paths: files, options: options) }
            self?.recordsDidChange(paths: paths)
        }
    }

    // MARK: Commands

    /// Redoes every image under `root` (explicit; runs even when the visual index is idle).
    func reanalyze(root: URL) {
        run(root: root, markStale: true)
    }

    func resetStore() async {
        cancelRun()
        progress = nil
        currentItemName = nil
        state = options.isEmpty ? .stopped : .idle
        await service.reset()
        recordsDidChange(paths: nil)
    }

    private func optionsDidChange() {
        if options.isEmpty {
            cancelRun()
            state = .stopped
        } else if state == .stopped, visual.state != .stopped {
            state = .idle
            visualStateDidChange()
        } else if state == .completed || state == .idle, let root = visual.root, visual.state == .completed {
            run(root: root, markStale: false)
        }
        recordsDidChange(paths: nil)
    }

    // MARK: Running

    private func run(root: URL, markStale: Bool) {
        guard !options.isEmpty else { return }
        cancelRun()
        runID += 1
        let id = runID
        runningRoot = root
        state = .analyzing
        progress = (carriedDone, carriedDone)
        currentItemName = nil
        let service = service
        let options = options
        let previous = lastRun
        // Holds the controller for the length of the pass (it's a long-lived singleton).
        let run = Task.detached(priority: .utility) { [self] in
            await previous?.value
            if markStale { await service.markStale(under: root) }
            let finished = await service.analyzeLibrary(root: root, options: options) { update in
                Task { @MainActor in self.apply(update, runID: id) }
            }
            await self.finish(runID: id, finished: finished)
        }
        task = run
        lastRun = run
    }

    private func apply(_ update: ImageTextProgress, runID id: Int) {
        guard id == runID, state == .analyzing else { return }
        let done = carriedDone + update.done, total = carriedDone + update.total
        if let current = progress, current.total == total, current.done > done { return }
        progress = (done, total)
        if let name = update.currentName { currentItemName = name }
        if !update.flushed.isEmpty { recordsDidChange(paths: update.flushed) }
    }

    private func finish(runID id: Int, finished: Bool) {
        guard id == runID else { return }
        let root = runningRoot
        task = nil
        runningRoot = nil
        guard finished else {
            if state == .analyzing { state = .idle; progress = nil; currentItemName = nil }
            return
        }
        completedRootPath = root?.path
        completedAt = Date()
        carriedDone = 0
        progress = nil
        currentItemName = nil
        state = .completed
        let now = Date()
        lastCompleted = now
        defaults.set(now.timeIntervalSince1970, forKey: Self.lastCompletedKey)
        recordsDidChange(paths: nil)
    }

    /// Stops the current pass but remembers its progress (pause / waiting).
    private func suspendRun() {
        carriedDone = progress?.done ?? 0
        cancelRun()
        currentItemName = nil
    }

    private func cancelRun() {
        task?.cancel()
        task = nil
        runID += 1
        runningRoot = nil
    }

    /// Waits for the current pass (tests).
    func waitForRun() async {
        await lastRun?.value
    }

    // MARK: Records

    private func recordsDidChange(paths: [String]?) {
        if let paths {
            for path in paths { recordCache.removeValue(forKey: path) }
        } else {
            recordCache.removeAll()
        }
        recordsRevision &+= 1
        let touchesListing = paths.map { changed in
            changed.contains { path in
                listingFolder.map { VisualIndexService.parentPath(path) == $0 } ?? listingPaths.contains(path)
            }
        } ?? true
        if touchesListing { reloadListingText() }
    }

    /// The stored record (cached). Nil when the file hasn't been analysed.
    func record(for path: String) async -> ImageTextRecord? {
        if let cached = recordCache[path] { return cached }
        let record = await service.record(forPath: path)
        if let record {
            if recordCache.count > 300 { recordCache.removeAll() }
            recordCache[path] = record
        }
        return record
    }

    /// Analyses one file now (user-initiated, e.g. the details panel's Analyse button).
    func analyzeNow(paths: [String]) async -> [String: ImageTextRecord] {
        let options = options.isEmpty ? ImageTextOptions() : options
        let records = await service.analyze(paths: paths, options: options)
        recordsDidChange(paths: paths)
        return records
    }

    // MARK: Listing text

    /// The browser's listing changed: load its recognised text (a folder query, or per
    /// path for collections).
    func listingDidChange(scope: String?, folder: String?, paths: [String]) {
        listingScope = scope
        listingFolder = folder
        listingPaths = folder == nil ? paths : []
        reloadListingText()
    }

    private func reloadListingText() {
        listingTask?.cancel()
        let scope = listingScope
        let folder = listingFolder
        let paths = listingPaths
        let service = service
        guard scope != nil else {
            if !listingText.isEmpty {
                listingText = [:]
                onListingTextChange?()
            }
            return
        }
        listingTask = Task { [weak self] in
            let texts: [String: String]
            if let folder {
                texts = await service.texts(inFolder: folder)
            } else {
                texts = await service.texts(forPaths: paths)
            }
            guard let self, !Task.isCancelled, self.listingScope == scope else { return }
            if texts != self.listingText {
                self.listingText = texts
                self.onListingTextChange?()
            }
        }
    }
}
