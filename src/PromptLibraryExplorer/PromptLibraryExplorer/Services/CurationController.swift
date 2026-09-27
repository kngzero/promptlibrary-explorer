import AppKit
import Foundation
import Observation

/// What Undo Import puts back.
struct CurationImportUndo: Equatable {
    let backupURL: URL
    let importedAt: Date
    let sourceName: String
}

/// Keeps the user's curation safe, portable and synced: rolling backups, export / import,
/// the per-library data file, the Finder tag mirror and XMP sidecars. The stores stay the
/// app's fast working copy; everything here runs around them.
@MainActor @Observable
final class CurationController {
    static let shared = CurationController()

    // MARK: Preferences

    /// `.promptlibrary/curation.json` in each opened library (on by default).
    var librarySyncEnabled: Bool {
        didSet {
            guard librarySyncEnabled != oldValue else { return }
            defaults.set(librarySyncEnabled, forKey: CurationPreferences.librarySyncKey)
            if librarySyncEnabled, let root = currentRoot {
                librarySync.open(root: root)
            } else if !librarySyncEnabled {
                librarySync.close()
            }
        }
    }

    /// Mirror app tags ↔ Finder tags (on by default).
    var finderTagSyncEnabled: Bool {
        didSet {
            guard finderTagSyncEnabled != oldValue else { return }
            defaults.set(finderTagSyncEnabled, forKey: CurationPreferences.finderTagsKey)
        }
    }

    /// Write and read `<file>.xmp` sidecars (off by default).
    var xmpSidecarsEnabled: Bool {
        didSet {
            guard xmpSidecarsEnabled != oldValue else { return }
            defaults.set(xmpSidecarsEnabled, forKey: CurationPreferences.xmpKey)
        }
    }

    /// Optional second backup folder (e.g. in Dropbox).
    var extraBackupFolder: URL? {
        didSet {
            guard extraBackupFolder != oldValue else { return }
            defaults.set(extraBackupFolder?.path, forKey: CurationPreferences.extraBackupFolderKey)
        }
    }

    // MARK: Status

    private(set) var syncStatus = LibrarySyncStatus()
    private(set) var lastBackupAt: Date?
    private(set) var lastBackupError: String?
    private(set) var lastImportUndo: CurationImportUndo?
    private(set) var isWritingSidecars = false
    private(set) var finderTagFilesSynced = 0
    private(set) var sidecarsWritten = 0
    private(set) var sidecarValuesImported = 0

    var backupsDirectory: URL { backupService.directory }

    // MARK: Plumbing

    @ObservationIgnored let stores: CurationStores
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let deviceID: String
    @ObservationIgnored private let librarySync: CurationLibrarySync
    @ObservationIgnored private let finderState: FinderTagSyncState
    @ObservationIgnored private let sidecarState: SidecarSyncState
    @ObservationIgnored private let sidecarFollower = SidecarFollower()
    @ObservationIgnored private var reloadHandler: (() -> Void)?
    @ObservationIgnored private var refreshListingHandler: (() -> Void)?
    @ObservationIgnored private var bootstrapped = false
    @ObservationIgnored private var trackedFiles: [String: TrackedFile] = [:]
    @ObservationIgnored private var trackerTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var dailyTimer: Timer?
    @ObservationIgnored private(set) var currentRoot: URL?

    private struct TrackedFile: Equatable {
        var rating = 0
        var flag = 0
        var tags: [String] = []
        var favorite = false
    }

    private var backupService: CurationBackupService {
        CurationBackupService(extraDirectory: extraBackupFolder)
    }

    init(stores: CurationStores? = nil, defaults: UserDefaults = .standard) {
        let stores = stores ?? .live
        self.stores = stores
        self.defaults = defaults
        let deviceID = CurationDevice.id(defaults: defaults)
        self.deviceID = deviceID
        librarySyncEnabled = defaults.object(forKey: CurationPreferences.librarySyncKey) as? Bool ?? true
        finderTagSyncEnabled = defaults.object(forKey: CurationPreferences.finderTagsKey) as? Bool ?? true
        xmpSidecarsEnabled = defaults.object(forKey: CurationPreferences.xmpKey) as? Bool ?? false
        extraBackupFolder = defaults.string(forKey: CurationPreferences.extraBackupFolderKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
        if defaults.object(forKey: CurationPreferences.lastBackupKey) != nil {
            lastBackupAt = Date(timeIntervalSince1970: defaults.double(forKey: CurationPreferences.lastBackupKey))
        }
        librarySync = CurationLibrarySync(stores: stores, deviceID: deviceID)
        finderState = FinderTagSyncState(url: FinderTagSyncState.defaultURL)
        sidecarState = SidecarSyncState(url: SidecarSyncState.defaultURL)
        librarySync.onStatusChange = { [weak self] status in self?.syncStatus = status }
        librarySync.onStoresChanged = { [weak self] in self?.reloadHandler?() }
    }

    // MARK: - Lifecycle

    /// First thing the app does: on the first launch with curation safety, back up every
    /// store before anything can write to them; then start watching for changes.
    func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true

        if defaults.integer(forKey: CurationPreferences.migratedSchemaKey) < CurationBundle.currentSchemaVersion {
            if takeBackupNow(reason: .migration) != nil {
                defaults.set(CurationBundle.currentSchemaVersion, forKey: CurationPreferences.migratedSchemaKey)
            }
        }

        trackedFiles = currentTrackedFiles()

        // queue: nil runs the block synchronously in `post`, so `isApplying` flags are
        // still set while the stores post; hop to the main actor when posted elsewhere.
        observers.append(NotificationCenter.default.addObserver(
            forName: CurationStoreEvents.didChange, object: nil, queue: nil
        ) { [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.storesDidChange() }
            } else {
                DispatchQueue.main.async { self?.storesDidChange() }
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushAtQuit() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.librarySync.checkForRemoteChanges()
                self?.takeDailyBackupIfNeeded()
            }
        })

        takeDailyBackupIfNeeded()
        dailyTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.takeDailyBackupIfNeeded() }
        }
    }

    /// The view model's glue: how to reload its copies of the stores and re-read the listing.
    func attach(reload: @escaping () -> Void, refreshListing: @escaping () -> Void) {
        reloadHandler = reload
        refreshListingHandler = refreshListing
    }

    func rootDidOpen(_ root: URL) {
        currentRoot = root
        if librarySyncEnabled {
            librarySync.open(root: root)
        }
    }

    private func flushAtQuit() {
        trackerTask?.cancel()
        if librarySyncEnabled { librarySync.flushSynchronously() }
        finderState.flush()
        sidecarState.flush()
    }

    // MARK: - Local changes

    private func storesDidChange() {
        if librarySyncEnabled, !librarySync.isApplying {
            librarySync.noteLocalChange()
        }
        trackerTask?.cancel()
        trackerTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.processTrackedChanges()
        }
    }

    private func currentTrackedFiles() -> [String: TrackedFile] {
        var result: [String: TrackedFile] = [:]
        let tagsByID = Dictionary(stores.tags.loadTags().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (path, rating) in stores.settings.loadRatings() where rating > 0 { result[path, default: TrackedFile()].rating = rating }
        for (path, flag) in stores.flags.load().flags { result[path, default: TrackedFile()].flag = flag.rawValue }
        for (path, ids) in stores.tags.loadAssignments() {
            let names = CurationLibraryAdapter.tagNames(for: ids, tagsByID: tagsByID)
            if !names.isEmpty { result[path, default: TrackedFile()].tags = names }
        }
        for path in stores.favorites.loadFavorites() { result[path, default: TrackedFile()].favorite = true }
        return result
    }

    private func processTrackedChanges() {
        let next = currentTrackedFiles()
        var tagChanged: [String] = []
        var curationChanged: [String] = []
        for path in Set(trackedFiles.keys).union(next.keys) {
            let before = trackedFiles[path], after = next[path]
            guard before != after else { continue }
            if (before?.tags ?? []) != (after?.tags ?? []) { tagChanged.append(path) }
            if before?.rating != after?.rating || before?.flag != after?.flag || before?.tags != after?.tags {
                curationChanged.append(path)
            }
        }
        trackedFiles = next
        if finderTagSyncEnabled, !tagChanged.isEmpty {
            pushFinderTags(paths: tagChanged, names: next.mapValues(\.tags))
        }
        if xmpSidecarsEnabled, !curationChanged.isEmpty {
            Task { await writeSidecars(paths: curationChanged, force: false) }
        }
    }

    /// Finder labels changed in the app (they live on the files, not in a store).
    func labelsDidChange(paths: [String]) {
        guard xmpSidecarsEnabled, !paths.isEmpty else { return }
        Task { await writeSidecars(paths: paths, force: false) }
    }

    // MARK: - Metadata migration hooks (called by the view model)

    /// A file or folder moved from `oldPath` to `newPath` (rename, move, undo).
    func itemDidMove(from oldPath: String, to newPath: String) {
        finderState.migrate(from: oldPath, to: newPath)
        if let migrated = MetadataPathKeys.migratingKeys(of: trackedFiles, from: oldPath, to: newPath) {
            trackedFiles = migrated
        }
        if let moved = sidecarFollower.fileDidMove(
            from: URL(fileURLWithPath: oldPath), to: URL(fileURLWithPath: newPath)
        ) {
            sidecarState.record(moved)
        }
    }

    /// The item at `path` is leaving (trash, replace, delete): its sidecar goes to the
    /// Trash with it. The records belong in the item's undo snapshot.
    func itemWillBeRemoved(at path: String) -> [SidecarTrashRecord] {
        sidecarFollower.fileWasTrashed(URL(fileURLWithPath: path)).map { [$0] } ?? []
    }

    /// Undo put the item back at `newPath` (maybe under another name than `oldPath`):
    /// so do its sidecars.
    func itemWasRestored(_ records: [SidecarTrashRecord], from oldPath: String, to newPath: String) {
        for record in records {
            if let restored = sidecarFollower.restore(record, besideFileAt: URL(fileURLWithPath: newPath)) {
                sidecarState.record(restored)
            }
        }
    }

    // MARK: - Listing hooks

    /// A folder listing was read: mirror Finder tags into the app and import sidecars.
    func listingDidLoad(_ entries: [FileEntry]) {
        let files = entries.filter { !$0.isDirectory }
        guard !files.isEmpty else { return }
        if finderTagSyncEnabled { reconcileFinderTags(files) }
        if xmpSidecarsEnabled { importSidecars(files) }
    }

    // MARK: - Finder tags

    private func appTagNames() -> [String: [String]] {
        let tagsByID = Dictionary(stores.tags.loadTags().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return stores.tags.loadAssignments().mapValues { CurationLibraryAdapter.tagNames(for: $0, tagsByID: tagsByID) }
    }

    private func reconcileFinderTags(_ files: [FileEntry]) {
        let appNames = appTagNames()
        let state = finderState
        let candidates: [(path: String, app: [String], finder: [String])] = files.compactMap { entry in
            guard let finder = entry.tagNames else { return nil }
            let app = appNames[entry.path] ?? []
            let finderUser = FinderTagIO.userTags(finder)
            let appUser = FinderTagIO.userTags(app)
            if FinderTagMerge.sameSet(finderUser, appUser) {
                if !appUser.isEmpty || state.base(for: entry.path) != nil {
                    state.setBase(appUser, for: entry.path)
                }
                return nil
            }
            return (entry.path, app, finder)
        }
        guard !candidates.isEmpty else { return }
        Task {
            let outcomes = await Task.detached(priority: .utility) {
                let outcomes = candidates.compactMap {
                    FinderTagSyncer.sync(path: $0.path, appNames: $0.app, finderNames: $0.finder, state: state)
                }
                state.flush()
                return outcomes
            }.value
            applyFinderOutcomes(outcomes)
        }
    }

    private func pushFinderTags(paths: [String], names: [String: [String]]) {
        let state = finderState
        let items = paths.map { (path: $0, app: names[$0] ?? []) }
        Task {
            let outcomes = await Task.detached(priority: .utility) {
                let outcomes = items.compactMap { item -> FinderTagSyncOutcome? in
                    guard FileManager.default.fileExists(atPath: item.path) else { return nil }
                    return FinderTagSyncer.sync(path: item.path, appNames: item.app, finderNames: nil, state: state)
                }
                state.flush()
                return outcomes
            }.value
            applyFinderOutcomes(outcomes)
        }
    }

    private func applyFinderOutcomes(_ outcomes: [FinderTagSyncOutcome]) {
        guard !outcomes.isEmpty else { return }
        finderTagFilesSynced += outcomes.count
        let updated = FinderTagSyncer.applyToApp(outcomes, tags: stores.tags)
        if updated > 0 {
            // Already in step with Finder: the tracker mustn't push these back.
            trackedFiles = currentTrackedFiles()
            reloadHandler?()
        }
    }

    // MARK: - XMP sidecars

    private func sidecarCuration(for paths: [String]) -> [SidecarFileCuration] {
        let ratings = stores.settings.loadRatings()
        let flags = stores.flags.load()
        let names = appTagNames()
        return paths.map {
            SidecarFileCuration(
                path: $0,
                rating: ratings[$0] ?? 0,
                flag: flags.flag(for: $0),
                tagNames: names[$0] ?? [],
                label: .none
            )
        }
    }

    /// Writes sidecars for `paths` (files without a sidecar and without curation are
    /// skipped unless `force`). Returns how many sidecars changed.
    @discardableResult
    func writeSidecars(paths: [String], force: Bool) async -> Int {
        let items = sidecarCuration(for: paths.filter { SidecarLocator.supportsSidecar(($0 as NSString).lastPathComponent) })
        guard !items.isEmpty else { return 0 }
        isWritingSidecars = true
        defer { isWritingSidecars = false }
        let state = sidecarState
        let written = await Task.detached(priority: .utility) { () -> Int in
            var count = 0
            for var item in items {
                if Task.isCancelled { break }
                let url = URL(fileURLWithPath: item.path)
                guard FileManager.default.fileExists(atPath: item.path) else { continue }
                item.label = FinderLabel(labelNumber: FileSystemService.labelNumber(at: url))
                let parsed = await ExplorerViewModel.parsePromptData(for: FileEntry(url: url, isDirectory: false))
                item.prompt = parsed.prompt
                item.negativePrompt = parsed.negative
                do {
                    if try SidecarWriter.write(item, force: force, state: state) != nil { count += 1 }
                } catch {
                    NSLog("PromptLibraryExplorer: couldn't write the sidecar for %@: %@", item.path, error.localizedDescription)
                }
            }
            state.flush()
            return count
        }.value
        sidecarsWritten += written
        return written
    }

    private func importSidecars(_ files: [FileEntry]) {
        let media = files.filter { SidecarLocator.supportsSidecar($0.name) }
        guard !media.isEmpty else { return }
        // The listing already names every sibling, so no extra directory reads.
        var siblings: [String: [String]] = [:]
        for entry in files { siblings[entry.url.deletingLastPathComponent().path, default: []].append(entry.name) }
        guard siblings.values.contains(where: { $0.contains(where: SidecarLocator.isSidecarName) }) else { return }

        let ratings = stores.settings.loadRatings()
        let flags = stores.flags.load()
        let names = appTagNames()
        let inputs = media.map { entry in
            (path: entry.path, app: SidecarAppValues(
                rating: ratings[entry.path] ?? 0,
                flag: flags.flag(for: entry.path),
                tagNames: names[entry.path] ?? [],
                label: FinderLabel(labelNumber: entry.labelNumber)
            ))
        }
        let state = sidecarState
        Task {
            let imports = await Task.detached(priority: .utility) {
                let imports = SidecarImporter.scan(files: inputs, siblingsByFolder: siblings, state: state)
                state.flush()
                return imports
            }.value
            await applySidecarImports(imports)
        }
    }

    private func applySidecarImports(_ imports: [SidecarImport]) async {
        guard !imports.isEmpty else { return }
        var ratings = stores.settings.loadRatings()
        var flags = stores.flags.load()
        var ratingsChanged = false, flagsChanged = false
        var tagOutcomes: [FinderTagSyncOutcome] = []
        var labels: [(URL, FinderLabel)] = []
        for item in imports {
            if let rating = item.rating, (ratings[item.path] ?? 0) == 0 {
                ratings[item.path] = rating
                ratingsChanged = true
            }
            if let flag = item.flag, flags.flag(for: item.path) == .unflagged {
                flags.set(flag, for: item.path)
                flagsChanged = true
            }
            if let names = item.tagNames {
                tagOutcomes.append(FinderTagSyncOutcome(path: item.path, names: names, appNeedsUpdate: true, wroteFinder: false))
            }
            if let label = item.label { labels.append((URL(fileURLWithPath: item.path), label)) }
        }
        if ratingsChanged { stores.settings.saveRatings(ratings) }
        if flagsChanged { stores.flags.save(flags) }
        FinderTagSyncer.applyToApp(tagOutcomes, tags: stores.tags)
        sidecarValuesImported += imports.count

        if !labels.isEmpty {
            await Task.detached(priority: .utility) {
                for (url, label) in labels where FileSystemService.labelNumber(at: url) == 0 {
                    try? FileSystemService.setLabelNumber(label.rawValue, at: url)
                }
            }.value
        }
        trackedFiles = currentTrackedFiles()
        reloadHandler?()
        // Tags imported from sidecars go to Finder too.
        if finderTagSyncEnabled, !tagOutcomes.isEmpty {
            pushFinderTags(paths: tagOutcomes.map(\.path), names: trackedFiles.mapValues(\.tags))
        }
        if !labels.isEmpty { refreshListingHandler?() }
    }

    // MARK: - Backups

    private var knownRoots: [URL] {
        var roots: [URL] = []
        if let currentRoot { roots.append(currentRoot) }
        if let libraryRoot = syncStatus.libraryRoot { roots.append(libraryRoot) }
        let last = stores.settingsDefaults.string(forKey: "lastOpenedFolder") ?? ""
        if !last.isEmpty { roots.append(URL(fileURLWithPath: last)) }
        roots.append(contentsOf: stores.recents.loadAllRecentFolders().map(\.url))
        return roots
    }

    func makeBundle(reason: CurationBackupReason) -> CurationBundle {
        CurationBundleBuilder.make(from: stores, roots: knownRoots, reason: reason.rawValue, deviceID: deviceID)
    }

    /// Writes a backup synchronously (used before imports, restores and upgrades, which
    /// must not proceed without one). Returns its URL.
    @discardableResult
    func takeBackupNow(reason: CurationBackupReason) -> URL? {
        let bundle = makeBundle(reason: reason)
        do {
            let url = try backupService.write(try bundle.encoded(), date: bundle.createdAt, reason: reason)
            noteBackup(at: bundle.createdAt)
            return url
        } catch {
            lastBackupError = error.localizedDescription
            NSLog("PromptLibraryExplorer: curation backup failed: %@", error.localizedDescription)
            return nil
        }
    }

    /// Background backup (daily).
    func takeBackupInBackground(reason: CurationBackupReason) {
        let bundle = makeBundle(reason: reason)
        let service = backupService
        Task {
            let result: Result<URL, Error> = await Task.detached(priority: .background) {
                Result { try service.write(try bundle.encoded(), date: bundle.createdAt, reason: reason) }
            }.value
            switch result {
            case .success: noteBackup(at: bundle.createdAt)
            case let .failure(error): lastBackupError = error.localizedDescription
            }
        }
    }

    private func noteBackup(at date: Date) {
        lastBackupAt = date
        lastBackupError = nil
        defaults.set(date.timeIntervalSince1970, forKey: CurationPreferences.lastBackupKey)
    }

    /// Launch and app-activation both call this; the write is async, so without
    /// this guard both saw "no backup today" and wrote two daily backups.
    @ObservationIgnored private var dailyBackupStartedAt: Date?

    func takeDailyBackupIfNeeded() {
        if let started = dailyBackupStartedAt, Calendar.current.isDateInToday(started) { return }
        let latest = backupService.latestDate(reason: .daily)
        if let latest, Calendar.current.isDateInToday(latest) { return }
        dailyBackupStartedAt = Date()
        takeBackupInBackground(reason: .daily)
    }

    func listBackups() async -> [CurationBackupInfo] {
        let service = backupService
        return await Task.detached(priority: .userInitiated) { service.list() }.value
    }

    func revealBackupsFolder() {
        let directory = backupService.directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    // MARK: - Export / import

    func export(to url: URL) throws -> CurationCounts {
        let bundle = makeBundle(reason: .manual)
        try bundle.encoded().write(to: url, options: [.atomic])
        return bundle.counts
    }

    func loadBundle(from url: URL) async throws -> CurationBundle {
        try await Task.detached(priority: .userInitiated) {
            try CurationBundle.decode(try Data(contentsOf: url))
        }.value
    }

    private var resolver: CurationPathResolver {
        CurationPathResolver(localRoots: knownRoots)
    }

    func previewImport(_ bundle: CurationBundle, mode: CurationImportMode, includeSettings: Bool) -> [CurationImportKindChange] {
        CurationImporter.plan(bundle, into: stores, mode: mode, includeSettings: includeSettings, resolver: resolver)
    }

    /// Imports after taking a backup (refuses without one), so Undo Import can put
    /// everything back. `sourceName` is shown next to the undo button.
    func importBundle(
        _ bundle: CurationBundle,
        mode: CurationImportMode,
        includeSettings: Bool,
        sourceName: String,
        reason: CurationBackupReason = .preImport
    ) throws {
        guard let backup = takeBackupNow(reason: reason) else {
            throw CurationImportError.backupFailed(lastBackupError ?? "unknown error")
        }
        CurationImporter.apply(bundle, to: stores, mode: mode, includeSettings: includeSettings, resolver: resolver)
        lastImportUndo = CurationImportUndo(backupURL: backup, importedAt: Date(), sourceName: sourceName)
        if includeSettings { reloadPreferences() }
        afterBulkChange()
    }

    /// Picks up this page's switches after settings were restored into the defaults.
    private func reloadPreferences() {
        librarySyncEnabled = defaults.object(forKey: CurationPreferences.librarySyncKey) as? Bool ?? true
        finderTagSyncEnabled = defaults.object(forKey: CurationPreferences.finderTagsKey) as? Bool ?? true
        xmpSidecarsEnabled = defaults.object(forKey: CurationPreferences.xmpKey) as? Bool ?? false
    }

    /// Puts back exactly what was there before the last import.
    func undoLastImport() async throws {
        guard let undo = lastImportUndo else { return }
        let bundle = try await loadBundle(from: undo.backupURL)
        guard takeBackupNow(reason: .preRestore) != nil else {
            throw CurationImportError.backupFailed(lastBackupError ?? "unknown error")
        }
        CurationImporter.apply(bundle, to: stores, mode: .replace, includeSettings: true, resolver: resolver)
        lastImportUndo = nil
        reloadPreferences()
        afterBulkChange()
    }

    private func afterBulkChange() {
        reloadHandler?()
        trackedFiles = currentTrackedFiles()
        if librarySyncEnabled { librarySync.noteLocalChange() }
    }

    func syncLibraryNow() async {
        await librarySync.syncNow()
    }

    var recentSyncConflicts: [CurationConflict] { librarySync.recentConflicts }
}

enum CurationImportError: LocalizedError {
    case backupFailed(String)

    var errorDescription: String? {
        switch self {
        case let .backupFailed(detail):
            return "Nothing was imported because a safety backup couldn't be written first (\(detail))."
        }
    }
}
