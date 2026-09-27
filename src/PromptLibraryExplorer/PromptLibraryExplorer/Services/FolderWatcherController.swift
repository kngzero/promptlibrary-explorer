import Foundation
import Observation

/// What changed on disk under the watched library, after coalescing and after new
/// or rewritten files finished being written.
struct FolderLiveChangeSet: Sendable, Equatable {
    /// Paths that no longer exist.
    var removed: [String] = []
    /// Files that appeared or were rewritten, with their size / mtime once stable.
    var changedFiles: [String: FileStatSnapshot] = [:]
    /// Folders that appeared (existing ones changing isn't interesting).
    var changedDirectories: [String] = []
    /// FSEvents dropped events, a volume changed, or the root moved: reload fully.
    var needsFullRefresh = false

    var isEmpty: Bool {
        removed.isEmpty && changedFiles.isEmpty && changedDirectories.isEmpty && !needsFullRefresh
    }
}

/// Live folder updates: one FSEvents stream on the open library root (recursive, so
/// the open folder is covered too). Bursts are coalesced, the ignore rules drop the
/// app's own data and temp files, and new or changed files wait until they stop
/// growing. Each finished batch goes to the library index and the visual index, and
/// to `onChanges` (the view model's incremental refresh).
@MainActor @Observable
final class FolderWatcherController {
    static let shared = FolderWatcherController()

    static let enabledKey = "liveUpdates.enabled"

    /// Settings ▸ Ingest ▸ Live folder updates (persisted, default on).
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Self.enabledKey)
            restart()
        }
    }

    /// The watched library root.
    private(set) var root: URL?
    /// True while the stream is running.
    private(set) var isWatching = false
    /// Files waiting to finish being written.
    private(set) var pendingFileCount = 0

    /// Receives each finished batch (installed by the view model).
    @ObservationIgnored var onChanges: (@MainActor (FolderLiveChangeSet) async -> Void)?
    /// Also feed the library and visual indexes (off in tests).
    @ObservationIgnored var feedsIndexes = true

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var coalescer = FolderEventCoalescer()
    @ObservationIgnored private var gate: FileStabilityGate
    @ObservationIgnored private let gateTemplate: FileStabilityGate
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var deliveryTask: Task<Void, Never>?
    @ObservationIgnored private var inFlightDeliveries = 0
    @ObservationIgnored private var flushGeneration = 0
    @ObservationIgnored private var pendingRemoved: [String] = []
    @ObservationIgnored private var pendingDirectories: [String] = []
    @ObservationIgnored private var pendingFullRefresh = false
    @ObservationIgnored private let clock: @Sendable () -> Date
    /// Quiet time after the last FSEvents callback before a batch is processed.
    @ObservationIgnored var debounce: TimeInterval = 0.3
    @ObservationIgnored var pollInterval: TimeInterval = 0.5

    init(
        defaults: UserDefaults = .standard,
        clock: @escaping @Sendable () -> Date = { Date() },
        gate: FileStabilityGate = FileStabilityGate()
    ) {
        self.defaults = defaults
        self.clock = clock
        self.gate = gate
        self.gateTemplate = gate
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    // MARK: Commands

    /// Watches `root` (nil stops). Idempotent for the same root.
    func watch(root: URL?) {
        let normalized = root.map { URL(fileURLWithPath: FolderEventCoalescer.trimmed($0.standardizedFileURL.path)) }
        guard normalized?.path != self.root?.path || (isEnabled && !isWatching && normalized != nil) else { return }
        self.root = normalized
        restart()
    }

    func stopWatching() {
        watcher?.stop()
        watcher = nil
        isWatching = false
        flushTask?.cancel()
        pollTask?.cancel()
        flushTask = nil
        pollTask = nil
        _ = coalescer.drain()
        gate = gateTemplate
        pendingFileCount = 0
        pendingRemoved = []
        pendingDirectories = []
        pendingFullRefresh = false
    }

    /// Feeds events directly (tests, and the ingest controller's shared plumbing).
    func receive(_ events: [FolderWatchEvent]) {
        coalescer.add(events)
        scheduleFlush()
    }

    /// Waits for queued work (tests).
    func waitForIdle() async {
        while flushTask != nil || pollTask != nil || inFlightDeliveries > 0 {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: Stream

    private func restart() {
        stopWatching()
        guard isEnabled, let root else { return }
        coalescer = FolderEventCoalescer(roots: [root.path])
        let watcher = FolderWatcher(paths: [root.path], latency: 0.5) { [weak self] events in
            Task { @MainActor in self?.receive(events) }
        }
        isWatching = watcher.start()
        self.watcher = isWatching ? watcher : nil
    }

    private func scheduleFlush() {
        flushTask?.cancel()
        flushGeneration &+= 1
        let generation = flushGeneration
        let delay = debounce
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await self.flush()
            if self.flushGeneration == generation { self.flushTask = nil }
        }
    }

    private func flush() async {
        let batch = coalescer.drain()
        guard !batch.isEmpty else { return }
        if batch.rootChanged || !batch.rescanDirectories.isEmpty { pendingFullRefresh = true }
        if batch.rootChanged, let root, !FileManager.default.fileExists(atPath: root.path) {
            // The library went away (volume ejected, folder moved): nothing to watch.
            watcher?.stop()
            watcher = nil
            isWatching = false
        }

        let paths = batch.paths
        let stats = await Task.detached(priority: .utility) {
            paths.map { ($0, FileStatSnapshot.read($0)) }
        }.value
        let now = clock()
        for (path, snapshot) in stats {
            guard let snapshot else {
                gate.forget(path)
                pendingRemoved.append(path)
                continue
            }
            if snapshot.isDirectory {
                pendingDirectories.append(path)
            } else {
                gate.track(path, now: now) { _ in snapshot }
            }
        }
        pendingFileCount = gate.count
        // Removals and new folders don't need to wait.
        deliver(changedFiles: [:])
        startPollingIfNeeded()
    }

    private func startPollingIfNeeded() {
        guard pollTask == nil, !gate.isEmpty else { return }
        let interval = pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                let done = await self.pollGate()
                if done { break }
            }
            self?.pollTask = nil
        }
    }

    /// Returns true when nothing is pending any more.
    private func pollGate() async -> Bool {
        let paths = Array(gate.pending.keys)
        let stats = await Task.detached(priority: .utility) {
            Dictionary(uniqueKeysWithValues: paths.map { ($0, FileStatSnapshot.read($0)) })
        }.value
        let outcome = gate.poll(now: clock()) { stats[$0] ?? nil }
        pendingRemoved += outcome.vanished
        var ready: [String: FileStatSnapshot] = [:]
        for path in outcome.ready {
            if let snapshot = stats[path] ?? nil { ready[path] = snapshot }
        }
        pendingFileCount = gate.count
        deliver(changedFiles: ready)
        return gate.isEmpty
    }

    private func deliver(changedFiles: [String: FileStatSnapshot]) {
        var set = FolderLiveChangeSet()
        set.removed = Array(NSOrderedSet(array: pendingRemoved).compactMap { $0 as? String })
        set.changedFiles = changedFiles
        set.changedDirectories = Array(NSOrderedSet(array: pendingDirectories).compactMap { $0 as? String })
        set.needsFullRefresh = pendingFullRefresh
        pendingRemoved = []
        pendingDirectories = []
        pendingFullRefresh = false
        guard !set.isEmpty else { return }

        if feedsIndexes { feedIndexes(set) }
        let previous = deliveryTask
        let handler = onChanges
        inFlightDeliveries += 1
        deliveryTask = Task { [weak self] in
            await previous?.value
            await handler?(set)
            self?.inFlightDeliveries -= 1
        }
    }

    /// New and changed files go to the prompt search index and the visual index;
    /// removed ones lose their rows. Separate calls for removals and changes, so the
    /// visual index never mistakes an unrelated removal + addition for a move.
    private func feedIndexes(_ set: FolderLiveChangeSet) {
        let changed = Array(set.changedFiles.keys)
        let removed = set.removed
        if !removed.isEmpty {
            VisualIndexController.shared.invalidate(paths: removed)
        }
        if !changed.isEmpty {
            VisualIndexController.shared.invalidate(paths: changed.filter { VisualSearchEligibility.isVisual(($0 as NSString).lastPathComponent) })
        }
        let libraryPaths = removed + changed
        if !libraryPaths.isEmpty {
            Task.detached(priority: .utility) {
                await LibraryIndexService.shared.index(paths: libraryPaths)
            }
        }
    }
}
