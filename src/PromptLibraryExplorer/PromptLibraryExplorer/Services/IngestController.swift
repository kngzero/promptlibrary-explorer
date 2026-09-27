import AppKit
import Foundation
import Observation

// MARK: - Pipeline (off the main actor)

/// Metadata a rule can use (rename tokens, tag with model name).
struct IngestFileMetadata: Sendable, Equatable {
    var model: String?
    var prompt: String?
    var seed: String?
    var sampler: String?
    var steps: String?
    var cfg: String?
    var width: Int?
    var height: Int?
}

/// One processed file.
struct IngestResult: Sendable, Equatable {
    var execution: IngestExecution
    var sourceID: UUID
    /// Tag names to add to the file's final location.
    var tags: [String] = []
}

enum IngestPipeline {
    /// Rules that read the file's metadata.
    static func needsMetadata(_ rules: IngestRules) -> Bool {
        rules.tagWithModelName
            || RenameTemplateService.usesAnyToken(RenameTemplateService.parsedDataTokens, in: rules.renameTemplate)
    }

    /// Reads prompt / model / parameters the way the library index does (no image decode).
    static func readMetadata(_ url: URL) async -> IngestFileMetadata {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let candidate = LibraryIndexCandidate(
            path: url.path,
            name: url.lastPathComponent,
            folder: url.deletingLastPathComponent().path,
            mtime: values?.contentModificationDate?.timeIntervalSince1970 ?? 0,
            size: Int64(values?.fileSize ?? 0)
        )
        let record = await LibraryIndexExtractor.record(for: candidate)
        let p = record.parameters
        return IngestFileMetadata(
            model: p.model, prompt: record.prompt.isEmpty ? nil : record.prompt, seed: p.seed, sampler: p.sampler,
            steps: p.steps, cfg: p.cfg, width: p.width, height: p.height
        )
    }

    /// Applies `source`'s rules to `paths` (files that finished writing). Files the
    /// rules reject are left alone and not reported.
    static func process(
        paths: [String],
        source: IngestSource,
        libraryRoot: URL?,
        now: Date,
        timeZone: TimeZone = .current,
        metadata: (URL) async -> IngestFileMetadata = { await readMetadata($0) }
    ) async -> [IngestResult] {
        let rules = source.rules
        let wantsMetadata = needsMetadata(rules)
        var duplicateIndexes: [String: IngestDuplicateIndex] = [:]
        var results: [IngestResult] = []
        var counter = 0
        for path in paths {
            if Task.isCancelled { break }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            guard let attributes, (attributes[.type] as? FileAttributeType) == .typeRegular else { continue }
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let relative = IngestRuleEngine.relativePath(of: url.path, inSource: source.path)
            if IngestRuleEngine.rejectionReason(name: url.lastPathComponent, relativePath: relative, size: size, rules: rules) != nil {
                continue
            }
            let meta = wantsMetadata ? await metadata(url) : IngestFileMetadata()
            let modified = attributes[.modificationDate] as? Date
            let arrival = IngestRuleEngine.arrivalDate(of: url) ?? now

            let destination = IngestRuleEngine.destinationFolder(
                rules: rules, libraryRoot: libraryRoot, date: arrival, timeZone: timeZone
            )
            let context = RenameTemplateContext(
                url: url, index: counter, modifiedDate: modified ?? arrival, prompt: meta.prompt, model: meta.model,
                seed: meta.seed, sampler: meta.sampler, steps: meta.steps, cfg: meta.cfg, width: meta.width, height: meta.height
            )
            let plan = IngestPlan(
                source: url,
                action: rules.action,
                destinationFolder: destination,
                targetName: IngestRuleEngine.renamedFileName(template: rules.renameTemplate, context: context)
            )

            var duplicates: IngestDuplicateIndex?
            if rules.action != .leaveInPlace,
               let base = IngestRuleEngine.destinationFolder(
                   rules: { var r = rules; r.usesDatedSubfolders = false; return r }(),
                   libraryRoot: libraryRoot, date: arrival
               )
            {
                let key = base.path
                if duplicateIndexes[key] == nil { duplicateIndexes[key] = IngestDuplicateIndex(root: base) }
                duplicates = duplicateIndexes[key]
            }
            let execution = IngestExecutor.execute(plan, duplicates: duplicates)
            counter += 1
            let tags = execution.finalURL == nil ? [] : IngestRuleEngine.tagNames(rules: rules, model: meta.model)
            results.append(IngestResult(execution: execution, sourceID: source.id, tags: tags))
        }
        return results
    }

    /// Files in `source` that arrived after `since` and weren't handled yet, oldest
    /// first. Hidden folders and packages are skipped.
    static func scan(source: IngestSource, since: Date?, processed: Set<String>) -> [String] {
        let root = URL(fileURLWithPath: source.path, isDirectory: true)
        var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        if !source.includeSubfolders { options.insert(.skipsSubdirectoryDescendants) }
        let keys: [URLResourceKey] = [.isRegularFileKey, .addedToDirectoryDateKey, .creationDateKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: options) else {
            return []
        }
        // Rebuilt from the source path, so every result keeps its prefix even where
        // FileManager resolves it (/var → /private/var).
        let sourcePath = FolderEventCoalescer.trimmed(source.path)
        let resolvedRoot = root.resolvingSymlinksInPath().path
        var found: [(path: String, date: Date)] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let resolved = url.deletingLastPathComponent().resolvingSymlinksInPath().path + "/" + url.lastPathComponent
            let relative = resolved.hasPrefix(resolvedRoot + "/") ? String(resolved.dropFirst(resolvedRoot.count + 1)) : url.lastPathComponent
            let path = sourcePath + "/" + relative
            guard !processed.contains(path) else { continue }
            let arrival = values.addedToDirectoryDate ?? values.creationDate ?? values.contentModificationDate
            guard IngestRuleEngine.isNewArrival(arrival: arrival, since: since) else { continue }
            guard IngestRuleEngine.rejectionReason(name: url.lastPathComponent, relativePath: relative, size: nil, rules: source.rules) == nil
            else { continue }
            found.append((path, arrival ?? .distantPast))
        }
        return found.sorted { $0.date < $1.date }.map(\.path)
    }
}

// MARK: - Host (the view model)

/// What the ingest controller needs from the app: undoable moves, curation
/// reloads, the Inbox listing and toasts.
@MainActor protocol IngestHost: AnyObject {
    var ingestLibraryRoot: URL? { get }
    /// Moves / renames ingest performed (to migrate metadata and record undo) and
    /// copies it made; refresh the listing without touching the selection.
    func ingestDidPerform(moves: [(from: URL, to: URL)], copies: [URL]) async
    func ingestDidChangeCuration()
    func ingestInboxDidChange()
    func ingestShowToast(_ message: String, type: ToastType)
}

// MARK: - Controller

/// The ingest inbox: watched source folders, their rules, the Inbox of recently
/// ingested files and the activity log. Nothing it does ever deletes a file.
@MainActor @Observable
final class IngestController {
    static let shared = IngestController()

    private(set) var sources: [IngestSource] = []
    private(set) var inbox: [InboxItem] = []
    private(set) var log: [IngestLogEvent] = []
    private(set) var lastSeen: Date?
    private(set) var clearedAt: Date?
    /// Files being processed right now.
    private(set) var processingCount = 0
    /// Files waiting to finish being written.
    private(set) var waitingCount = 0
    private(set) var unavailableSourceIDs: Set<UUID> = []
    /// Presents the log sheet on the main window.
    var logSheetOpen = false

    static let retention: TimeInterval = 7 * 24 * 3600

    @ObservationIgnored weak var host: IngestHost?
    /// Tag / collection writes (tests replace it).
    @ObservationIgnored var curationWriter: (_ tagsByPath: [String: [String]], _ collectionPaths: [UUID: [String]]) -> Bool = IngestController.writeCuration
    /// FSEvents on the sources (off in tests, which feed `receive`).
    @ObservationIgnored var watchesLive = true
    /// Feed the library / visual indexes with new files (off in tests).
    @ObservationIgnored var feedsIndexes = true
    @ObservationIgnored var metadataReader: (URL) async -> IngestFileMetadata = { await IngestPipeline.readMetadata($0) }
    @ObservationIgnored var debounce: TimeInterval = 0.3
    @ObservationIgnored var pollInterval: TimeInterval = 0.5
    @ObservationIgnored var periodicInterval: TimeInterval = 60

    @ObservationIgnored private let store: IngestStore
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var processed: [String: [String]] = [:]
    @ObservationIgnored private var processedSets: [UUID: Set<String>] = [:]
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var coalescer = FolderEventCoalescer()
    @ObservationIgnored private var gate: FileStabilityGate
    @ObservationIgnored private var pendingSource: [String: UUID] = [:]
    @ObservationIgnored private var suppressor = RecentWriteSuppressor()
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var flushGeneration = 0
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var periodicTask: Task<Void, Never>?
    @ObservationIgnored private var processingChain: Task<Void, Never>?
    @ObservationIgnored private var inFlightBatches = 0
    @ObservationIgnored private var sessionStart: Date
    @ObservationIgnored private var started = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(store: IngestStore = IngestStore(), clock: @escaping () -> Date = { Date() }, gate: FileStabilityGate = FileStabilityGate()) {
        self.store = store
        self.clock = clock
        self.gate = gate
        self.sessionStart = clock()
        load()
    }

    // MARK: Derived state

    var hasSources: Bool { !sources.isEmpty }

    /// Items still in the Inbox (last 7 days, since the last Clear).
    var visibleItems: [InboxItem] {
        let cutoff = max(clock().addingTimeInterval(-Self.retention), clearedAt ?? .distantPast)
        return inbox.filter { $0.date > cutoff }.sorted { $0.date > $1.date }
    }

    func visibleItems(sourceID: UUID?) -> [InboxItem] {
        guard let sourceID else { return visibleItems }
        return visibleItems.filter { $0.sourceID == sourceID }
    }

    /// New since Mark All Seen (the sidebar badge).
    var unseenCount: Int { unseenCount(sourceID: nil) }

    func unseenCount(sourceID: UUID?) -> Int {
        let seen = lastSeen ?? .distantPast
        return visibleItems(sourceID: sourceID).filter { $0.date > seen }.count
    }

    /// Inbox paths newest first, each once.
    func inboxPaths(sourceID: UUID?) -> [String] {
        var seen = Set<String>()
        return visibleItems(sourceID: sourceID).map(\.path).filter { seen.insert($0).inserted }
    }

    var isBusy: Bool { processingCount > 0 || waitingCount > 0 }

    func source(id: UUID) -> IngestSource? { sources.first { $0.id == id } }

    func isAvailable(_ source: IngestSource) -> Bool { !unavailableSourceIDs.contains(source.id) }

    // MARK: Lifecycle

    /// Starts watching and catches up on files that arrived while the app was closed.
    func start() {
        guard !started else { return }
        started = true
        sessionStart = clock()
        refreshAvailability(logChanges: true)
        restartWatcher()
        Task { await catchUpOnLaunch() }
        startPeriodicChecks()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.volumesDidChange() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.noteTermination() }
        })
    }

    /// Records how far each source was considered, so the next launch only
    /// processes what arrived after (files still being written count as not seen).
    func noteTermination() {
        let now = clock()
        let earliestPending = gate.pending.values.map(\.firstSeen).min()
        let mark = min(now, earliestPending ?? now)
        for index in sources.indices { sources[index].lastScan = mark }
        persist()
    }

    // MARK: Sources

    @discardableResult
    func addSource(_ url: URL) -> IngestSource? {
        let path = FolderEventCoalescer.trimmed(url.standardizedFileURL.path)
        guard !sources.contains(where: { $0.path == path }) else {
            host?.ingestShowToast("\u{201C}\(url.lastPathComponent)\u{201D} is already a source", type: .info)
            return nil
        }
        let source = IngestSource(path: path, createdAt: clock())
        sources.append(source)
        addLog(.info, source: source, "Watching \((path as NSString).abbreviatingWithTildeInPath) for new files")
        refreshAvailability(logChanges: false)
        persist()
        restartWatcher()
        host?.ingestInboxDidChange()
        return source
    }

    func updateSource(_ source: IngestSource) {
        guard let index = sources.firstIndex(where: { $0.id == source.id }) else { return }
        let watchingChanged = sources[index].path != source.path || sources[index].isEnabled != source.isEnabled
            || sources[index].includeSubfolders != source.includeSubfolders
        sources[index] = source
        persist()
        if watchingChanged {
            refreshAvailability(logChanges: false)
            restartWatcher()
        }
    }

    /// Stops watching the folder. Its files and the Inbox entries stay.
    func removeSource(id: UUID) {
        guard let source = source(id: id) else { return }
        sources.removeAll { $0.id == id }
        processed.removeValue(forKey: id.uuidString)
        processedSets.removeValue(forKey: id)
        unavailableSourceIDs.remove(id)
        addLog(.info, source: source, "Stopped watching; no files were changed")
        persist()
        restartWatcher()
        host?.ingestInboxDidChange()
    }

    /// Settings ▸ Ingest ▸ Process Existing Files: applies the rules to every
    /// file already in the source that wasn't handled yet.
    func processExistingNow(sourceID: UUID) {
        guard let source = source(id: sourceID), isAvailable(source) else { return }
        let processedSet = processedSets[sourceID] ?? []
        Task {
            let paths = await Task.detached(priority: .utility) {
                IngestPipeline.scan(source: source, since: nil, processed: processedSet)
            }.value
            if paths.isEmpty {
                self.host?.ingestShowToast("No unprocessed files in \u{201C}\(source.name)\u{201D}", type: .info)
                return
            }
            self.addLog(.info, source: source, "Processing \(paths.count) existing file\(paths.count == 1 ? "" : "s")")
            self.track(paths, sourceID: sourceID)
        }
    }

    // MARK: Inbox

    func markAllSeen() {
        lastSeen = clock()
        persist()
    }

    /// Empties the Inbox listing (files are untouched).
    func clearInbox() {
        let now = clock()
        clearedAt = now
        lastSeen = now
        persist()
        host?.ingestInboxDidChange()
    }

    /// A file the app renamed or moved: its Inbox entry follows it.
    func itemDidMove(from oldPath: String, to newPath: String) {
        var changed = false
        for index in inbox.indices {
            if let rewritten = MetadataPathKeys.rewrite(inbox[index].path, from: oldPath, to: newPath), rewritten != inbox[index].path {
                inbox[index].path = rewritten
                changed = true
            }
        }
        if changed { persist() }
    }

    func clearLog() {
        log = []
        persist()
    }

    // MARK: Events

    /// Feeds FSEvents for the sources (tests call this directly).
    func receive(_ events: [FolderWatchEvent]) {
        coalescer.add(events)
        flushTask?.cancel()
        flushGeneration &+= 1
        let generation = flushGeneration
        let delay = debounce
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await self.flushEvents()
            if self.flushGeneration == generation { self.flushTask = nil }
        }
    }

    /// Waits until nothing is queued, waiting or processing (tests).
    func waitForIdle(timeout: TimeInterval = 10) async {
        let deadline = Date().addingTimeInterval(timeout)
        while (flushTask != nil || pollTask != nil || inFlightBatches > 0 || !gate.isEmpty), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func flushEvents() async {
        let batch = coalescer.drain()
        if batch.rootChanged || !batch.rescanDirectories.isEmpty {
            refreshAvailability(logChanges: true)
            restartWatcher()
            await catchUp(sourceIDs: nil, reason: nil)
        }
        guard !batch.paths.isEmpty else { return }
        let now = clock()
        var candidates: [(path: String, sourceID: UUID)] = []
        for path in batch.paths {
            guard let source = owningSource(of: path), source.isEnabled else { continue }
            if suppressor.isSuppressed(path, now: now) { continue }
            if processedSets[source.id]?.contains(path) == true { continue }
            if pendingSource[path] != nil { continue }
            let relative = IngestRuleEngine.relativePath(of: path, inSource: source.path)
            if IngestRuleEngine.rejectionReason(name: (path as NSString).lastPathComponent, relativePath: relative, size: nil, rules: source.rules) != nil {
                continue
            }
            candidates.append((path, source.id))
        }
        guard !candidates.isEmpty else { return }
        // Only files that arrived while watching (or after the source was added) are new.
        let since: [UUID: Date] = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, max($0.createdAt, sessionStart)) })
        let fresh = await Task.detached(priority: .utility) {
            candidates.filter { candidate in
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                    return false
                }
                let arrival = IngestRuleEngine.arrivalDate(of: URL(fileURLWithPath: candidate.path))
                return IngestRuleEngine.isNewArrival(arrival: arrival, since: since[candidate.sourceID])
            }
        }.value
        for (sourceID, group) in Dictionary(grouping: fresh, by: \.sourceID) {
            track(group.map(\.path), sourceID: sourceID)
        }
    }

    private func owningSource(of path: String) -> IngestSource? {
        sources
            .filter { IngestRuleEngine.isWithinSource(path, source: $0) }
            .max { $0.path.count < $1.path.count }
    }

    /// Hands files to the stability gate; they're processed once they stop changing.
    private func track(_ paths: [String], sourceID: UUID) {
        let now = clock()
        for path in paths where pendingSource[path] == nil {
            if gate.track(path, now: now, stat: FileStatSnapshot.read) {
                pendingSource[path] = sourceID
            }
        }
        waitingCount = gate.count
        startPolling()
    }

    private func startPolling() {
        guard pollTask == nil, !gate.isEmpty else { return }
        let interval = pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self else { return }
                if await self.pollGate() { break }
            }
            self?.pollTask = nil
        }
    }

    /// Returns true when nothing is waiting any more.
    private func pollGate() async -> Bool {
        let paths = Array(gate.pending.keys)
        let stats = await Task.detached(priority: .utility) {
            Dictionary(uniqueKeysWithValues: paths.map { ($0, FileStatSnapshot.read($0)) })
        }.value
        let outcome = gate.poll(now: clock()) { path in stats[path] ?? FileStatSnapshot.read(path) }
        for path in outcome.vanished { pendingSource.removeValue(forKey: path) }
        var ready: [UUID: [String]] = [:]
        for path in outcome.ready {
            guard let sourceID = pendingSource.removeValue(forKey: path) else { continue }
            ready[sourceID, default: []].append(path)
        }
        waitingCount = gate.count
        for (sourceID, paths) in ready { enqueue(paths, sourceID: sourceID) }
        return gate.isEmpty
    }

    // MARK: Processing

    private func enqueue(_ paths: [String], sourceID: UUID) {
        guard let source = source(id: sourceID) else { return }
        // Mark as handled up front, so events for the same files during processing are ignored.
        for path in paths { markProcessed(path, sourceID: sourceID) }
        let previous = processingChain
        let root = host?.ingestLibraryRoot
        let reader = metadataReader
        inFlightBatches += 1
        processingCount += paths.count
        processingChain = Task { [weak self] in
            await previous?.value
            let now = Date()
            let results = await Task.detached(priority: .utility) {
                await IngestPipeline.process(paths: paths, source: source, libraryRoot: root, now: now, metadata: reader)
            }.value
            guard let self else { return }
            await self.apply(results, source: source)
            self.processingCount = max(0, self.processingCount - paths.count)
            self.inFlightBatches -= 1
        }
    }

    private func apply(_ results: [IngestResult], source: IngestSource) async {
        let now = clock()
        var moves: [(from: URL, to: URL)] = []
        var copies: [URL] = []
        var tagsByPath: [String: [String]] = [:]
        var collectionPaths: [UUID: [String]] = [:]
        var failures: [String] = []
        var added = 0

        for result in results {
            let execution = result.execution
            if case let .failed(url, message) = execution {
                failures.append(url.lastPathComponent)
                addLog(.error, source: source, "Couldn't ingest \(url.lastPathComponent): \(message)", path: url.path)
                continue
            }
            guard let final = execution.finalURL, let outcome = execution.outcomeKind else { continue }
            markProcessed(final.path, sourceID: source.id)
            suppressor.note(final.path, now: now)
            switch execution {
            case let .moved(from, to), let .renamedInPlace(from, to):
                moves.append((from, to))
                addLog(.info, source: source, "\(execution.verb) \(from.lastPathComponent) → \(Self.displayPath(to))", path: to.path)
            case let .copied(from, to):
                copies.append(to)
                addLog(.info, source: source, "Copied \(from.lastPathComponent) → \(Self.displayPath(to))", path: to.path)
            case let .duplicate(src, existing):
                addLog(.warning, source: source,
                       "\(src.lastPathComponent) is identical to \(Self.displayPath(existing)); linked the existing file and left the new one in place",
                       path: existing.path)
            case let .surfaced(url):
                addLog(.info, source: source, "New file \(url.lastPathComponent)", path: url.path)
            case .failed:
                break
            }
            inbox.append(InboxItem(path: final.path, originalPath: execution.sourceURL.path, sourceID: source.id, date: now, outcome: outcome))
            added += 1
            if !result.tags.isEmpty { tagsByPath[final.path, default: []] += result.tags }
            if let collectionID = source.rules.collectionID { collectionPaths[collectionID, default: []].append(final.path) }
        }

        pruneInbox()
        if let index = sources.firstIndex(where: { $0.id == source.id }) {
            sources[index].lastScan = max(sources[index].lastScan ?? .distantPast, now)
        }
        persist()

        if !tagsByPath.isEmpty || !collectionPaths.isEmpty {
            if curationWriter(tagsByPath, collectionPaths) { host?.ingestDidChangeCuration() }
        }
        if !moves.isEmpty || !copies.isEmpty {
            await host?.ingestDidPerform(moves: moves, copies: copies)
        }
        feedIndexes(results.compactMap { $0.execution.finalURL?.path })
        if added > 0 { host?.ingestInboxDidChange() }
        if !failures.isEmpty {
            let what = failures.count == 1 ? "\u{201C}\(failures[0])\u{201D}" : "\(failures.count) files"
            host?.ingestShowToast("Ingest couldn't process \(what) from \(source.name) — see the Ingest Log", type: .error)
        }
    }

    /// Live updates normally feed the indexes; this covers files outside the
    /// open library's watcher (or with live updates off).
    private func feedIndexes(_ paths: [String]) {
        guard feedsIndexes, !paths.isEmpty else { return }
        let root = host?.ingestLibraryRoot.map { FolderEventCoalescer.trimmed($0.standardizedFileURL.path) }
        let inLibrary = paths.filter { path in root.map { path.hasPrefix($0 + "/") } ?? false }
        guard !inLibrary.isEmpty else { return }
        VisualIndexController.shared.invalidate(paths: inLibrary.filter { VisualSearchEligibility.isVisual(($0 as NSString).lastPathComponent) })
        Task.detached(priority: .utility) { await LibraryIndexService.shared.index(paths: inLibrary) }
    }

    private func markProcessed(_ path: String, sourceID: UUID) {
        guard processedSets[sourceID, default: []].insert(path).inserted else { return }
        var list = processed[sourceID.uuidString] ?? []
        list.append(path)
        if list.count > IngestStore.maxProcessedPerSource {
            let dropped = list.prefix(list.count - IngestStore.maxProcessedPerSource)
            list.removeFirst(dropped.count)
            processedSets[sourceID]?.subtract(dropped)
        }
        processed[sourceID.uuidString] = list
    }

    // MARK: Catch-up

    /// On launch: "N new files since last run", per each source's rules (when its
    /// "process files added while the app was closed" is on).
    func catchUpOnLaunch() async {
        await catchUp(sourceIDs: nil, reason: .launch)
    }

    enum CatchUpReason { case launch, reconnected, poll }

    /// Scans sources for files that arrived after their last scan.
    func catchUp(sourceIDs: Set<UUID>?, reason: CatchUpReason?) async {
        let scanStart = clock()
        var found = 0
        for source in sources where source.isEnabled && isAvailable(source) {
            if let sourceIDs, !sourceIDs.contains(source.id) { continue }
            if reason == .launch, !source.processWhileClosed {
                setLastScan(scanStart, for: source.id)
                continue
            }
            let processedSet = processedSets[source.id] ?? []
            let since = source.lastScan ?? source.createdAt
            let paths = await Task.detached(priority: .utility) {
                IngestPipeline.scan(source: source, since: since, processed: processedSet)
            }.value
            let fresh = paths.filter { pendingSource[$0] == nil }
            if !fresh.isEmpty {
                found += fresh.count
                let noun = fresh.count == 1 ? "file" : "files"
                let when = reason == .launch ? " since last run" : ""
                addLog(.info, source: source, "\(fresh.count) new \(noun)\(when)")
                track(fresh, sourceID: source.id)
            }
            setLastScan(scanStart, for: source.id)
        }
        persist()
        if reason == .launch, found > 0 {
            host?.ingestShowToast("Ingest: \(found) new file\(found == 1 ? "" : "s") since last run", type: .info)
        }
    }

    private func setLastScan(_ date: Date, for id: UUID) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[index].lastScan = date
    }

    private func startPeriodicChecks() {
        periodicTask?.cancel()
        let interval = periodicInterval
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                await self.periodicCheck()
            }
        }
    }

    /// Sources that came back get their watcher and a catch-up; network volumes
    /// (where FSEvents misses other machines' writes) are rescanned.
    private func periodicCheck() async {
        let reconnected = refreshAvailability(logChanges: true)
        if !reconnected.isEmpty {
            restartWatcher()
            await catchUp(sourceIDs: reconnected, reason: .reconnected)
        }
        let remote = Set(sources.filter { $0.isEnabled && isAvailable($0) && !Self.isLocalVolume($0.path) }.map(\.id))
        if !remote.isEmpty { await catchUp(sourceIDs: remote, reason: .poll) }
    }

    private func volumesDidChange() {
        Task {
            let reconnected = refreshAvailability(logChanges: true)
            restartWatcher()
            if !reconnected.isEmpty { await catchUp(sourceIDs: reconnected, reason: .reconnected) }
        }
    }

    /// Updates `unavailableSourceIDs`; returns the sources that just came back.
    @discardableResult
    private func refreshAvailability(logChanges: Bool) -> Set<UUID> {
        var unavailable = Set<UUID>()
        for source in sources {
            var isDirectory: ObjCBool = false
            if !(FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory) && isDirectory.boolValue) {
                unavailable.insert(source.id)
            }
        }
        let cameBack = unavailableSourceIDs.subtracting(unavailable)
        let wentAway = unavailable.subtracting(unavailableSourceIDs)
        if logChanges {
            for id in wentAway { if let source = source(id: id) { addLog(.warning, source: source, "Source folder is unavailable (disconnected, moved or deleted)") } }
            for id in cameBack { if let source = source(id: id) { addLog(.info, source: source, "Source folder is available again") } }
        }
        if unavailable != unavailableSourceIDs { unavailableSourceIDs = unavailable }
        return cameBack
    }

    private func restartWatcher() {
        watcher?.stop()
        watcher = nil
        let paths = sources.filter { $0.isEnabled && isAvailable($0) }.map(\.path)
        coalescer = FolderEventCoalescer(roots: paths)
        guard watchesLive, started, !paths.isEmpty else { return }
        let watcher = FolderWatcher(paths: paths, latency: 0.5) { [weak self] events in
            Task { @MainActor in self?.receive(events) }
        }
        if watcher.start() { self.watcher = watcher }
    }

    static func isLocalVolume(_ path: String) -> Bool {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeIsLocalKey])
        return values?.volumeIsLocal ?? true
    }

    // MARK: Log & persistence

    func addLog(_ level: IngestLogEvent.Level, source: IngestSource?, _ message: String, path: String? = nil) {
        log.append(IngestLogEvent(date: clock(), level: level, sourceName: source?.name, message: message, path: path))
        if log.count > IngestStore.maxLogEvents { log.removeFirst(log.count - IngestStore.maxLogEvents) }
    }

    private func pruneInbox() {
        let cutoff = clock().addingTimeInterval(-Self.retention)
        inbox.removeAll { $0.date < cutoff }
    }

    private func load() {
        let state = store.load()
        sources = state.sources
        inbox = state.inbox
        log = Array(state.log.suffix(IngestStore.maxLogEvents))
        lastSeen = state.lastSeen
        clearedAt = state.clearedAt
        processed = state.processed
        processedSets = [:]
        for (key, list) in state.processed {
            if let id = UUID(uuidString: key) { processedSets[id] = Set(list) }
        }
        pruneInbox()
    }

    private func persist() {
        var state = IngestState()
        state.sources = sources
        state.inbox = inbox
        state.log = log
        state.lastSeen = lastSeen
        state.clearedAt = clearedAt
        state.processed = processed
        store.save(state)
    }

    static func displayPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    // MARK: Curation (tags, collections)

    /// Adds tags (created when missing) and collection memberships. Returns true
    /// when anything changed.
    static func writeCuration(tagsByPath: [String: [String]], collectionPaths: [UUID: [String]]) -> Bool {
        var changed = false
        if !tagsByPath.isEmpty {
            var tags = TagService.shared.loadTags()
            for (path, names) in tagsByPath {
                for name in names {
                    let tag: FileTag
                    if let existing = tags.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                        tag = existing
                    } else {
                        let colors = FileTag.presetColors
                        let seed = name.lowercased().unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
                        let color = colors[abs(seed) % colors.count]
                        tag = FileTag(name: name, colorHex: color)
                        TagService.shared.addTag(tag)
                        tags.append(tag)
                    }
                    TagService.shared.assignTag(tag.id, toPath: path)
                    changed = true
                }
            }
        }
        for (id, paths) in collectionPaths where CollectionService.shared.collection(id: id) != nil {
            CollectionService.shared.add(paths: paths, to: id)
            changed = true
        }
        return changed
    }
}

private extension IngestExecution {
    var verb: String {
        switch self {
        case .moved: return "Moved"
        case .renamedInPlace: return "Renamed"
        default: return ""
        }
    }
}
