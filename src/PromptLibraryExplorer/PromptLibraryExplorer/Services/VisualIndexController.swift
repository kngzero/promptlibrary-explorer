import Foundation
import Observation

/// Drives background visual indexing and publishes its state. The only thing views
/// and the view model use to run or observe the visual pipeline.
///
/// States: `idle` (nothing run yet) → `indexing` → `completed`; `pause()` → `paused`
/// (finished files are kept; `resume()` continues with the rest); `stop()` → `stopped`
/// and `isEnabled = false` (persisted), so nothing starts automatically until it is
/// re-enabled.
@MainActor @Observable
final class VisualIndexController {
    static let shared = VisualIndexController()

    enum State: Equatable { case idle, indexing, paused, stopped, completed }

    private(set) var state: State = .idle
    /// Files done / to do in the current run (across a pause), nil when not running.
    private(set) var progress: (done: Int, total: Int)?
    private(set) var currentItemName: String?
    private(set) var lastCompleted: Date?
    /// The library root being (or last) indexed.
    private(set) var root: URL?

    /// Persisted (`visualIndex.enabled`, default true). false = "Stop": no automatic
    /// indexing until re-enabled; setting it back to true resumes the current root.
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled {
                if state == .stopped { state = .idle }
                if let root { run(root: root, markStale: false, carryProgress: false) }
            } else {
                cancelRun()
                state = .stopped
                progress = nil
                currentItemName = nil
            }
        }
    }

    static let enabledKey = "visualIndex.enabled"
    static let lastCompletedKey = "visualIndex.lastCompleted"

    @ObservationIgnored private let service: VisualIndexService
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The latest run, even once cancelled: a new run waits for it to drain so two
    /// runs never compute the same files.
    @ObservationIgnored private var lastRun: Task<Void, Never>?
    @ObservationIgnored private var runID = 0
    @ObservationIgnored private var runningRootPath: String?
    @ObservationIgnored private var completedRootPath: String?
    @ObservationIgnored private var completedAt: Date?
    @ObservationIgnored private var carriedDone = 0
    @ObservationIgnored private var mutationTask: Task<Void, Never>?

    /// A completed root isn't re-walked if `start` is called again this soon.
    static let restartThrottle: TimeInterval = 10

    init(service: VisualIndexService = .shared, defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        if defaults.object(forKey: Self.lastCompletedKey) != nil {
            lastCompleted = Date(timeIntervalSince1970: defaults.double(forKey: Self.lastCompletedKey))
        }
        state = isEnabled ? .idle : .stopped
    }

    // MARK: Commands

    /// Automatic, low-priority, incremental (mtime + size). Idempotent: a no-op while
    /// the same root is indexing or paused, or just completed. A different root
    /// replaces the current run.
    func start(root: URL) {
        let path = VisualIndexService.normalizedPath(root.path)
        self.root = root
        guard isEnabled else {
            state = .stopped
            return
        }
        switch state {
        case .paused:
            return   // stays paused; resume() indexes the new root
        case .indexing where runningRootPath == path:
            return
        case .completed where completedRootPath == path
            && (completedAt.map { Date().timeIntervalSince($0) < Self.restartThrottle } ?? false):
            return
        default:
            run(root: root, markStale: false, carryProgress: false)
        }
    }

    func pause() {
        guard state == .indexing else { return }
        carriedDone = progress?.done ?? 0
        cancelRun()
        state = .paused
        currentItemName = nil
    }

    func resume() {
        guard state == .paused, let root else { return }
        run(root: root, markStale: false, carryProgress: true)
    }

    /// Cancels and disables automatic indexing (persisted) until re-enabled.
    func stop() {
        cancelRun()
        state = .stopped
        progress = nil
        currentItemName = nil
        if isEnabled { isEnabled = false }
    }

    /// Recomputes every file under `root`. Existing rows stay queryable meanwhile (they
    /// are only marked stale), and a pause/resume doesn't redo files already rebuilt.
    /// Explicit, so it runs even when automatic indexing is stopped.
    func reindex(root: URL) {
        self.root = root
        run(root: root, markStale: true, carryProgress: false)
    }

    /// The app calls this for files renamed, moved, trashed, restored or edited. Paths
    /// that no longer exist lose their rows (and descendants); existing paths are
    /// re-queued if new or changed (mtime + size). A batch of exactly one missing and
    /// one existing path is a rename / move: rows move instead of being recomputed.
    func invalidate(paths: [String]) {
        let service = service
        let reindex = isEnabled && state != .paused
        enqueueMutation {
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
            if reindex, !existing.isEmpty {
                await service.index(paths: existing)
            }
        }
    }

    /// A rename / move the app performed itself: rows move without recomputing.
    func moved(from oldPath: String, to newPath: String) {
        let service = service
        enqueueMutation { await service.movePath(from: oldPath, to: newPath) }
    }

    /// Clears the whole visual index (all libraries).
    func resetIndex() async {
        cancelRun()
        if state == .indexing || state == .paused || state == .completed { state = isEnabled ? .idle : .stopped }
        progress = nil
        currentItemName = nil
        completedRootPath = nil
        await service.reset()
    }

    /// Waits for queued `invalidate` / `moved` work (tests).
    func waitForMutations() async {
        await mutationTask?.value
    }

    /// Waits for the current run (tests).
    func waitForRun() async {
        await lastRun?.value
    }

    // MARK: Running

    private func run(root: URL, markStale: Bool, carryProgress: Bool) {
        cancelRun()
        runID += 1
        let id = runID
        let path = VisualIndexService.normalizedPath(root.path)
        runningRootPath = path
        if !carryProgress {
            carriedDone = 0
            progress = (0, 0)
        }
        state = .indexing
        currentItemName = nil
        let service = service
        let previousMutations = mutationTask
        let previousRun = lastRun
        // Holds the controller for the length of the run (it's a long-lived singleton).
        let run = Task.detached(priority: .utility) { [self] in
            await previousRun?.value
            await previousMutations?.value
            if markStale { await service.markStale(under: root) }
            let finished = await service.indexLibrary(root: root) { update in
                Task { @MainActor in self.apply(update, runID: id) }
            }
            await self.finish(runID: id, finished: finished)
        }
        task = run
        lastRun = run
    }

    private func apply(_ update: VisualIndexProgress, runID id: Int) {
        guard id == runID, state == .indexing else { return }
        let done = carriedDone + update.done
        let total = carriedDone + update.total
        if let current = progress, current.total == total, current.done > done { return }  // late, out of order
        progress = (done, total)
        if let name = update.currentName { currentItemName = name }
    }

    private func finish(runID id: Int, finished: Bool) {
        guard id == runID else { return }
        task = nil
        runningRootPath = nil
        guard finished else {
            if state == .indexing { state = isEnabled ? .idle : .stopped; progress = nil; currentItemName = nil }
            return
        }
        state = .completed
        progress = nil
        currentItemName = nil
        carriedDone = 0
        let now = Date()
        lastCompleted = now
        completedAt = now
        completedRootPath = root.map { VisualIndexService.normalizedPath($0.path) }
        defaults.set(now.timeIntervalSince1970, forKey: Self.lastCompletedKey)
    }

    private func cancelRun() {
        task?.cancel()
        task = nil
        runID += 1
        runningRootPath = nil
    }

    private func enqueueMutation(_ work: @escaping @Sendable () async -> Void) {
        let previous = mutationTask
        mutationTask = Task.detached(priority: .utility) {
            await previous?.value
            await work()
        }
    }
}
