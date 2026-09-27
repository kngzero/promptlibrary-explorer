import CryptoKit
import Foundation

// MARK: - File I/O (no actor)

/// Reading and writing `.promptlibrary/curation.json`, conflicted copies and this Mac's
/// per-root ledger. Everything here is synchronous and runs off the main actor.
enum LibrarySyncIO {
    static let directoryName = ".promptlibrary"
    static let fileName = "curation.json"

    static func dataDirectory(for root: URL) -> URL {
        root.appendingPathComponent(directoryName, isDirectory: true)
    }

    static func fileURL(for root: URL) -> URL {
        dataDirectory(for: root).appendingPathComponent(fileName)
    }

    /// The library a folder belongs to: the nearest ancestor-or-self that already has a
    /// library data file (so opening a subfolder keeps using the library's file), else
    /// the folder itself.
    static func libraryRoot(for folder: URL, fileManager: FileManager = .default) -> URL {
        let start = folder.standardizedFileURL
        let home = fileManager.homeDirectoryForCurrentUser.standardizedFileURL.path
        var candidate = start
        for _ in 0..<8 {
            if fileManager.fileExists(atPath: fileURL(for: candidate).path) { return candidate }
            let parent = candidate.deletingLastPathComponent()
            let path = parent.path
            if path == candidate.path || path == "/" || path == home || path == "/Volumes" || path == "/Users" { break }
            candidate = parent
        }
        return start
    }

    static func ledgerURL(for rootPath: String, in directory: URL) -> URL {
        let digest = SHA256.hash(data: Data(rootPath.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("ledger-\(digest).json")
    }

    static var defaultLedgerDirectory: URL {
        CollectionServiceStorage.directoryURL.appendingPathComponent("LibrarySync", isDirectory: true)
    }

    struct Remotes {
        var main: LibraryCurationDocument?
        var mainModified: Date?
        var conflicted: [(url: URL, document: LibraryCurationDocument)] = []
        /// Set when the main file exists but can't be used (unreadable or newer format):
        /// nothing is written until that's resolved.
        var blockingError: String?
    }

    static func readRemotes(root: URL, fileManager: FileManager = .default) -> Remotes {
        var remotes = Remotes()
        let directory = dataDirectory(for: root)
        let main = fileURL(for: root)
        if fileManager.fileExists(atPath: main.path) {
            do {
                let data = try Data(contentsOf: main)
                remotes.main = try LibraryCurationDocument.decode(data)
                remotes.mainModified = (try? main.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            } catch {
                remotes.blockingError = error.localizedDescription
            }
        }
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where CurationMergeEngine.isConflictedCopy(fileName: name) {
            let url = directory.appendingPathComponent(name)
            // An unreadable conflicted copy is left alone (never deleted).
            guard let data = try? Data(contentsOf: url), let document = try? LibraryCurationDocument.decode(data) else {
                NSLog("PromptLibraryExplorer: skipped unreadable conflicted copy %@", name)
                continue
            }
            remotes.conflicted.append((url, document))
        }
        return remotes
    }

    static func loadLedger(at url: URL) -> LibraryCurationDocument? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? LibraryCurationDocument.decode(data)
    }

    static func saveLedger(_ document: LibraryCurationDocument, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try document.encoded().write(to: url, options: [.atomic])
    }

    /// Writes the library file atomically (temp file + rename in the same folder, which
    /// Dropbox handles as one change). Returns the bytes written.
    static func writeLibraryFile(_ document: LibraryCurationDocument, root: URL) throws -> Data {
        let directory = dataDirectory(for: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try document.encoded()
        try data.write(to: fileURL(for: root), options: [.atomic])
        return data
    }

    /// Size + mtime, to tell our own writes from Dropbox's.
    static func fingerprint(of url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
        return "\(values.fileSize ?? -1)-\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
    }

    static func hasConflictedCopies(root: URL) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dataDirectory(for: root).path)) ?? []
        return names.contains(where: CurationMergeEngine.isConflictedCopy(fileName:))
    }
}

/// One complete sync of one root, computed off the main actor.
struct LibrarySyncComputation {
    /// This Mac's merge result (applied to the stores, saved as the ledger).
    var merged: LibraryCurationDocument
    /// What the shared file should hold.
    var fileDocument: LibraryCurationDocument
    var conflicts: [CurationConflict]
    var remoteMain: LibraryCurationDocument?
    var conflictedURLs: [URL]
    var blockingError: String?
    var wasFirstSync: Bool

    static func run(
        root: URL,
        ledgerURL: URL,
        current: CurationPortableState,
        now: Date,
        device: String
    ) -> LibrarySyncComputation {
        let ledger = LibrarySyncIO.loadLedger(at: ledgerURL)
        let remotes = LibrarySyncIO.readRemotes(root: root)
        var documents: [LibraryCurationDocument] = []
        if let main = remotes.main { documents.append(main) }
        documents.append(contentsOf: remotes.conflicted.map(\.document))
        let result = CurationMergeEngine.synchronize(
            ledger: ledger, current: current, remotes: documents, now: now, device: device
        )
        return LibrarySyncComputation(
            merged: result.document,
            fileDocument: result.fileDocument,
            conflicts: result.conflicts,
            remoteMain: remotes.main,
            conflictedURLs: remotes.conflicted.map(\.url),
            blockingError: remotes.blockingError,
            wasFirstSync: ledger == nil
        )
    }

    /// Saves the ledger, writes the library file when its content changed, then removes
    /// the conflicted copies that were merged. Returns the fingerprint of a file written.
    func persist(
        root: URL,
        ledgerURL: URL,
        now: Date,
        device: String,
        deviceName: String,
        appVersion: String
    ) throws -> (wroteFile: Bool, fingerprint: String?) {
        try LibrarySyncIO.saveLedger(merged, at: ledgerURL)
        guard blockingError == nil else { return (false, nil) }

        var wrote = false
        var fingerprint: String?
        let needsWrite: Bool
        if let remoteMain {
            needsWrite = !fileDocument.hasSameContent(as: remoteMain)
        } else {
            // Don't litter folders that have no curation with an empty file.
            needsWrite = !fileDocument.isEmpty
        }
        if needsWrite {
            var document = fileDocument
            document.updatedAt = now
            document.updatedBy = device
            document.updatedByName = deviceName
            document.appVersion = appVersion
            _ = try LibrarySyncIO.writeLibraryFile(document, root: root)
            wrote = true
            fingerprint = LibrarySyncIO.fingerprint(of: LibrarySyncIO.fileURL(for: root))
        }
        // Only now that the merged result is safely on disk.
        for url in conflictedURLs {
            do {
                try FileManager.default.removeItem(at: url)
                NSLog("PromptLibraryExplorer: merged and removed conflicted copy %@", url.lastPathComponent)
            } catch {
                NSLog("PromptLibraryExplorer: couldn't remove conflicted copy %@: %@", url.lastPathComponent, error.localizedDescription)
            }
        }
        return (wrote, fingerprint)
    }
}

// MARK: - Watching

/// Watches a directory for entries being added, removed or replaced (Dropbox replaces
/// files atomically, so the directory — not the file — is what changes).
final class CurationDirectoryWatcher {
    private var source: DispatchSourceFileSystemObject?
    let url: URL

    init?(url: URL, handler: @escaping @MainActor () -> Void) {
        self.url = url
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .extend, .link, .attrib],
            queue: .main
        )
        source.setEventHandler {
            MainActor.assumeIsolated { handler() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    func cancel() {
        source?.cancel()
        source = nil
    }

    deinit { cancel() }
}

// MARK: - Live sync

/// Status of the library data file for the current root, shown in Settings ▸ Data.
struct LibrarySyncStatus: Equatable {
    var libraryRoot: URL?
    var fileExists = false
    var lastSyncedAt: Date?
    var lastWriteAt: Date?
    var lastRemoteChangeAt: Date?
    /// Records where both Macs changed the same value at once (kept this Mac's), this session.
    var conflictsMerged = 0
    /// Dropbox conflicted copies merged and removed, this session.
    var conflictedCopiesMerged = 0
    /// Values brought in from other Macs, this session.
    var remoteChangesApplied = 0
    var lastError: String?
    var isSyncing = false
}

/// Keeps the current root's `.promptlibrary/curation.json` in sync with the local stores:
/// debounced writes after local changes, merges on open, on file changes and on app
/// activation, and a final flush at quit. The local stores stay the working copy.
@MainActor
final class CurationLibrarySync {
    private(set) var status = LibrarySyncStatus() {
        didSet { if status != oldValue { onStatusChange?(status) } }
    }
    var onStatusChange: ((LibrarySyncStatus) -> Void)?
    /// Called after values from another Mac were written into the stores.
    var onStoresChanged: (() -> Void)?

    private let stores: CurationStores
    private let ledgerDirectory: URL
    private let deviceID: String
    private var watcher: CurationDirectoryWatcher?
    private var debounceTask: Task<Void, Never>?
    private var isSyncing = false
    private var needsAnotherPass = false
    private var ownFingerprint: String?
    private(set) var isApplying = false
    private(set) var recentConflicts: [CurationConflict] = []
    /// A conflict the file keeps showing (until someone edits the value again) is
    /// logged and counted once.
    private var seenConflicts = Set<CurationConflict>()

    static let localChangeDelay: Duration = .seconds(2)
    static let remoteChangeDelay: Duration = .milliseconds(800)

    init(stores: CurationStores, ledgerDirectory: URL = LibrarySyncIO.defaultLedgerDirectory, deviceID: String) {
        self.stores = stores
        self.ledgerDirectory = ledgerDirectory
        self.deviceID = deviceID
    }

    var libraryRoot: URL? { status.libraryRoot }

    /// Starts syncing the library that `folder` (a newly opened root) belongs to.
    func open(root folder: URL) {
        let libraryRoot = LibrarySyncIO.libraryRoot(for: folder)
        if libraryRoot.path != status.libraryRoot?.path {
            close()
            status = LibrarySyncStatus(libraryRoot: libraryRoot)
            ownFingerprint = nil
            seenConflicts = []
        }
        startWatching()
        scheduleSync(after: .zero)
    }

    func close() {
        debounceTask?.cancel()
        debounceTask = nil
        watcher?.cancel()
        watcher = nil
        status = LibrarySyncStatus()
    }

    /// A local store changed: write the library file soon.
    func noteLocalChange() {
        guard status.libraryRoot != nil, !isApplying else { return }
        scheduleSync(after: Self.localChangeDelay)
    }

    func scheduleSync(after delay: Duration) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    /// Checks whether the library file changed on disk (another Mac) and syncs if so.
    func checkForRemoteChanges() {
        guard let root = status.libraryRoot else { return }
        let url = LibrarySyncIO.fileURL(for: root)
        let fingerprint = LibrarySyncIO.fingerprint(of: url)
        if (fingerprint != nil && fingerprint != ownFingerprint) || LibrarySyncIO.hasConflictedCopies(root: root) {
            scheduleSync(after: Self.remoteChangeDelay)
        }
    }

    func syncNow() async {
        guard let root = status.libraryRoot else { return }
        if isSyncing {
            needsAnotherPass = true
            return
        }
        isSyncing = true
        status.isSyncing = true
        defer {
            isSyncing = false
            status.isSyncing = false
            if needsAnotherPass {
                needsAnotherPass = false
                scheduleSync(after: .milliseconds(300))
            }
        }

        let rootPath = root.path
        let base = CurationLibraryAdapter.snapshot(root: rootPath, stores: stores)
        let ledgerURL = LibrarySyncIO.ledgerURL(for: rootPath, in: ledgerDirectory)
        let now = Date()
        let device = deviceID
        let computation = await Task.detached(priority: .utility) {
            LibrarySyncComputation.run(root: root, ledgerURL: ledgerURL, current: base, now: now, device: device)
        }.value
        guard status.libraryRoot?.path == rootPath else { return }

        // Values from other Macs go into the stores (skipping any the user changed meanwhile).
        isApplying = true
        let applied = CurationLibraryAdapter.apply(
            target: computation.merged.portableState, base: base, root: rootPath, stores: stores
        )
        isApplying = false
        if applied > 0 {
            onStoresChanged?()
            status.remoteChangesApplied += applied
            status.lastRemoteChangeAt = now
        }
        let newConflicts = computation.conflicts.filter { seenConflicts.insert($0).inserted }
        for conflict in newConflicts {
            NSLog("PromptLibraryExplorer: library sync conflict — %@", conflict.description)
        }
        recentConflicts = Array((newConflicts + recentConflicts).prefix(50))

        let deviceName = CurationDevice.machineName
        let appVersion = CurationDevice.appVersion
        do {
            let outcome = try await Task.detached(priority: .utility) {
                try computation.persist(
                    root: root, ledgerURL: ledgerURL, now: now, device: device,
                    deviceName: deviceName, appVersion: appVersion
                )
            }.value
            guard status.libraryRoot?.path == rootPath else { return }
            if outcome.wroteFile {
                ownFingerprint = outcome.fingerprint
                status.lastWriteAt = now
            } else if ownFingerprint == nil {
                ownFingerprint = LibrarySyncIO.fingerprint(of: LibrarySyncIO.fileURL(for: root))
            }
            status.conflictsMerged += newConflicts.count
            status.conflictedCopiesMerged += computation.conflictedURLs.count
            status.lastError = computation.blockingError
            status.lastSyncedAt = now
            status.fileExists = FileManager.default.fileExists(atPath: LibrarySyncIO.fileURL(for: root).path)
            if watcher == nil || (watcher?.url.lastPathComponent != LibrarySyncIO.directoryName && status.fileExists) {
                startWatching()
            }
        } catch {
            status.lastError = error.localizedDescription
            NSLog("PromptLibraryExplorer: library sync failed: %@", error.localizedDescription)
        }
    }

    /// Synchronous final pass at quit so a change made in the last 2 seconds is not lost.
    func flushSynchronously() {
        guard let root = status.libraryRoot, !isSyncing else { return }
        debounceTask?.cancel()
        let rootPath = root.path
        let base = CurationLibraryAdapter.snapshot(root: rootPath, stores: stores)
        let ledgerURL = LibrarySyncIO.ledgerURL(for: rootPath, in: ledgerDirectory)
        let now = Date()
        let computation = LibrarySyncComputation.run(root: root, ledgerURL: ledgerURL, current: base, now: now, device: deviceID)
        isApplying = true
        CurationLibraryAdapter.apply(target: computation.merged.portableState, base: base, root: rootPath, stores: stores)
        isApplying = false
        _ = try? computation.persist(
            root: root, ledgerURL: ledgerURL, now: now, device: deviceID,
            deviceName: CurationDevice.machineName, appVersion: CurationDevice.appVersion
        )
    }

    // MARK: Watching

    private func startWatching() {
        guard let root = status.libraryRoot else { return }
        watcher?.cancel()
        let dataDirectory = LibrarySyncIO.dataDirectory(for: root)
        // Before the folder exists (nothing synced yet), watch the root for it appearing.
        let target = FileManager.default.fileExists(atPath: dataDirectory.path) ? dataDirectory : root
        watcher = CurationDirectoryWatcher(url: target) { [weak self] in
            guard let self else { return }
            if target == root {
                guard FileManager.default.fileExists(atPath: dataDirectory.path) else { return }
                self.startWatching()
            }
            self.checkForRemoteChanges()
        }
    }
}
