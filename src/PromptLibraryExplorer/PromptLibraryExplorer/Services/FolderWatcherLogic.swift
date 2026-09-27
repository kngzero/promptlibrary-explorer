import Foundation

// MARK: - Live folder updates: pure pieces
//
// Everything here is free of FSEvents and timers so it can be tested with plain
// values: event flags, coalescing, the ignore rules, and the "has this file
// finished being written?" gate (with an injectable clock and stat function).

/// What FSEvents said happened to one path (cumulative within its latency window).
struct FolderWatchEventFlags: OptionSet, Sendable, Hashable {
    let rawValue: UInt32

    static let created = FolderWatchEventFlags(rawValue: 1 << 0)
    static let removed = FolderWatchEventFlags(rawValue: 1 << 1)
    static let renamed = FolderWatchEventFlags(rawValue: 1 << 2)
    static let modified = FolderWatchEventFlags(rawValue: 1 << 3)
    /// Metadata only: extended attributes (Finder tags), inode metadata, Finder info, owner.
    static let metadataOnly = FolderWatchEventFlags(rawValue: 1 << 4)
    static let isFile = FolderWatchEventFlags(rawValue: 1 << 5)
    static let isDirectory = FolderWatchEventFlags(rawValue: 1 << 6)
    /// The watched root itself was moved, renamed or deleted.
    static let rootChanged = FolderWatchEventFlags(rawValue: 1 << 7)
    /// FSEvents dropped events under this directory: rescan it.
    static let mustScanSubdirectories = FolderWatchEventFlags(rawValue: 1 << 8)
    /// A volume was mounted or unmounted at this path.
    static let volumeChanged = FolderWatchEventFlags(rawValue: 1 << 9)

    /// Content or existence changed (not just an xattr / Finder tag update).
    var isContentChange: Bool {
        !intersection([.created, .removed, .renamed, .modified, .rootChanged, .mustScanSubdirectories, .volumeChanged]).isEmpty
    }
}

struct FolderWatchEvent: Sendable, Hashable {
    let path: String
    let flags: FolderWatchEventFlags
}

/// Paths the watchers never act on: hidden items (the app's own `.promptlibrary/`
/// data, `.plx-*` temp files, AppleDouble `._*`, `.DS_Store`, Dropbox's
/// `.dropbox.cache`), partial downloads, and XMP sidecars the app writes itself.
enum FolderWatchIgnoreRules {
    static let ignoredSuffixes = [".tmp", ".part", ".partial", ".crdownload", ".download", ".opdownload", "~", ".xmp"]
    static let ignoredNames: Set<String> = ["Icon\r", "Thumbs.db", "desktop.ini"]

    /// True when any component of `path` below `root` (or the whole path when no
    /// root is given) is hidden, or the name is a temp / partial / sidecar file.
    static func isIgnored(_ path: String, under root: String? = nil) -> Bool {
        var relative = path
        if let root, path.hasPrefix(root) {
            relative = String(path.dropFirst(root.count))
        }
        let components = relative.split(separator: "/", omittingEmptySubsequences: true)
        for component in components where component.hasPrefix(".") {
            return true
        }
        guard let name = components.last.map(String.init) else { return false }
        if ignoredNames.contains(name) { return true }
        let lower = name.lowercased()
        if lower.hasPrefix("~$") { return true }
        return ignoredSuffixes.contains { lower.hasSuffix($0) }
    }
}

/// The result of coalescing a burst of events.
struct FolderChangeBatch: Equatable, Sendable {
    /// Distinct paths with a content change, in first-seen order.
    var paths: [String] = []
    /// Directories to rescan (FSEvents dropped events, or a volume changed).
    var rescanDirectories: [String] = []
    /// A watched root moved or disappeared.
    var rootChanged = false

    var isEmpty: Bool { paths.isEmpty && rescanDirectories.isEmpty && !rootChanged }
}

/// Merges FSEvents callbacks into one batch per quiet period: each path once,
/// ignore rules and metadata-only events (Finder tags, xattrs) filtered out.
struct FolderEventCoalescer {
    private(set) var batch = FolderChangeBatch()
    private var seen = Set<String>()
    private var seenRescan = Set<String>()
    /// Watched roots, so ignore rules only look at components below them.
    var roots: [String]

    init(roots: [String] = []) {
        self.roots = roots
    }

    var isEmpty: Bool { batch.isEmpty }

    mutating func add(_ events: [FolderWatchEvent]) {
        for event in events {
            if event.flags.contains(.rootChanged) {
                batch.rootChanged = true
                continue
            }
            if event.flags.contains(.mustScanSubdirectories) || event.flags.contains(.volumeChanged) {
                if seenRescan.insert(event.path).inserted { batch.rescanDirectories.append(event.path) }
                continue
            }
            guard event.flags.isContentChange else { continue }
            let path = Self.trimmed(event.path)
            let root = roots.first { path == $0 || path.hasPrefix($0 + "/") }
            if FolderWatchIgnoreRules.isIgnored(path, under: root) { continue }
            if seen.insert(path).inserted { batch.paths.append(path) }
        }
    }

    /// Returns the batch so far and starts a new one.
    mutating func drain() -> FolderChangeBatch {
        let result = batch
        batch = FolderChangeBatch()
        seen.removeAll(keepingCapacity: true)
        seenRescan.removeAll(keepingCapacity: true)
        return result
    }

    static func trimmed(_ path: String) -> String {
        var result = path
        while result.count > 1 && result.hasSuffix("/") { result.removeLast() }
        return result
    }
}

/// Size + modification time of a file, as the stability gate sees it.
struct FileStatSnapshot: Equatable, Sendable {
    var size: Int64
    var mtime: Double
    var isDirectory = false

    static func read(_ path: String) -> FileStatSnapshot? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let isDirectory = (attributes[.type] as? FileAttributeType) == .typeDirectory
        return FileStatSnapshot(size: size, mtime: mtime, isDirectory: isDirectory)
    }
}

/// Waits for files to finish being written: a file is ready once its size and
/// modification time have stayed the same for `stableInterval` (generators write
/// large PNGs and MP4s progressively). Empty files need `emptyFileInterval`.
/// Pure: the caller supplies the time and the stat function.
struct FileStabilityGate {
    struct Pending: Equatable {
        var snapshot: FileStatSnapshot
        var stableSince: Date
        var firstSeen: Date
    }

    var stableInterval: TimeInterval = 1.0
    /// A 0-byte file is usually a placeholder about to be written.
    var emptyFileInterval: TimeInterval = 5.0
    /// Files still changing after this long are released anyway.
    var maximumWait: TimeInterval = 30 * 60

    private(set) var pending: [String: Pending] = [:]

    init(stableInterval: TimeInterval = 1.0, emptyFileInterval: TimeInterval = 5.0, maximumWait: TimeInterval = 30 * 60) {
        self.stableInterval = stableInterval
        self.emptyFileInterval = emptyFileInterval
        self.maximumWait = maximumWait
    }

    var isEmpty: Bool { pending.isEmpty }
    var count: Int { pending.count }

    /// Starts (or restarts) watching `path`. Returns false when it doesn't exist.
    @discardableResult
    mutating func track(_ path: String, now: Date, stat: (String) -> FileStatSnapshot?) -> Bool {
        guard let snapshot = stat(path) else {
            pending.removeValue(forKey: path)
            return false
        }
        if var existing = pending[path] {
            if existing.snapshot != snapshot {
                existing.snapshot = snapshot
                existing.stableSince = now
                pending[path] = existing
            }
        } else {
            pending[path] = Pending(snapshot: snapshot, stableSince: now, firstSeen: now)
        }
        return true
    }

    mutating func forget(_ path: String) {
        pending.removeValue(forKey: path)
    }

    /// Re-stats every pending file: returns the ones that finished writing and
    /// the ones that vanished (both leave the gate).
    mutating func poll(now: Date, stat: (String) -> FileStatSnapshot?) -> (ready: [String], vanished: [String]) {
        var ready: [String] = []
        var vanished: [String] = []
        for path in pending.keys.sorted() {
            guard var entry = pending[path] else { continue }
            guard let snapshot = stat(path) else {
                pending.removeValue(forKey: path)
                vanished.append(path)
                continue
            }
            if snapshot != entry.snapshot {
                entry.snapshot = snapshot
                entry.stableSince = now
                if now.timeIntervalSince(entry.firstSeen) >= maximumWait {
                    pending.removeValue(forKey: path)
                    ready.append(path)
                } else {
                    pending[path] = entry
                }
                continue
            }
            let required = (snapshot.size == 0 && !snapshot.isDirectory) ? emptyFileInterval : stableInterval
            if now.timeIntervalSince(entry.stableSince) >= required {
                pending.removeValue(forKey: path)
                ready.append(path)
            }
        }
        return (ready, vanished)
    }
}

/// Paths the app itself just wrote, ignored by the ingest watchers for a short
/// while so a copy or move the app made never looks like a new arrival.
struct RecentWriteSuppressor {
    var window: TimeInterval = 10
    private var expiries: [String: Date] = [:]

    init(window: TimeInterval = 10) {
        self.window = window
    }

    mutating func note(_ path: String, now: Date) {
        expiries[path] = now.addingTimeInterval(window)
    }

    mutating func isSuppressed(_ path: String, now: Date) -> Bool {
        expiries = expiries.filter { $0.value > now }
        return expiries[path] != nil
    }
}
