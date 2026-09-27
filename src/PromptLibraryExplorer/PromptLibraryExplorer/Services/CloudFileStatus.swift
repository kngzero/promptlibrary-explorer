import Darwin
import Foundation

// MARK: - Cloud placeholders (iCloud Drive, Dropbox / Google Drive File Provider)

/// Whether a file's bytes are on this Mac.
///
/// On macOS 12+ every File Provider backed folder (`~/Library/CloudStorage/Dropbox`,
/// Google Drive, iCloud Drive since Sonoma) keeps "online-only" files as *dataless*
/// files: the inode, name, size and dates are real, but reading the contents makes
/// the kernel ask the provider to download the whole file first. The reliable,
/// provider-independent check is the `SF_DATALESS` flag from `lstat` (verified on
/// Google Drive's File Provider: `ls -lO` shows `compressed,dataless`, `st_blocks` is 0,
/// `ubiquitousItemDownloadingStatus` is `.notDownloaded`). The ubiquitous resource keys
/// add the "downloading…" state and cover legacy iCloud items.
///
/// Background work (thumbnails, prompt parsing, library/visual indexing, hover scrub)
/// must check `CloudFileStatus.isLocallyAvailable(_:)` first: touching a dataless file's
/// contents would silently download it.
enum CloudAvailability: String, Sendable, Equatable {
    /// Contents are on disk (or the file isn't in a cloud folder at all).
    case local
    /// Online-only placeholder: reading it would download it.
    case cloudOnly
    /// The provider is fetching it right now.
    case downloading
}

/// The raw facts the availability decision is made from; injectable for tests.
struct CloudResourceSnapshot: Sendable, Equatable {
    /// `SF_DATALESS` is set (`lstat` flags).
    var isDataless: Bool = false
    /// `URLResourceKey.isUbiquitousItemKey`; nil when not read.
    var isUbiquitous: Bool?
    /// `URLResourceKey.ubiquitousItemDownloadingStatusKey` raw value; nil when not read.
    var downloadingStatus: String?
    /// `URLResourceKey.ubiquitousItemIsDownloadingKey`; nil when not read.
    var isDownloading: Bool?
}

/// Reads a file's cloud facts. `fast` asks for the cheapest check that can still tell
/// "safe to read" (one `lstat`); the full read adds the ubiquitous resource keys.
protocol CloudFileStatusProviding: Sendable {
    func snapshot(forPath path: String, fast: Bool) -> CloudResourceSnapshot?
}

/// The real file system.
struct SystemCloudFileStatusProvider: CloudFileStatusProviding {
    /// `SF_DATALESS` from <sys/stat.h> (not exported to Swift on every SDK).
    static let datalessFlag: UInt32 = 0x4000_0000

    func snapshot(forPath path: String, fast: Bool) -> CloudResourceSnapshot? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        var snapshot = CloudResourceSnapshot(isDataless: (info.st_flags & Self.datalessFlag) != 0)
        // Directories are never "downloaded"; their listing is always available.
        if (info.st_mode & S_IFMT) == S_IFDIR { return snapshot }
        guard !fast else { return snapshot }
        let keys: Set<URLResourceKey> = [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsDownloadingKey,
        ]
        if let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys) {
            snapshot.isUbiquitous = values.isUbiquitousItem
            snapshot.downloadingStatus = values.ubiquitousItemDownloadingStatus?.rawValue
            snapshot.isDownloading = values.ubiquitousItemIsDownloading
        }
        return snapshot
    }
}

enum CloudFileStatus {
    // MARK: Provider (injectable)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _provider: any CloudFileStatusProviding = SystemCloudFileStatusProvider()

    static var provider: any CloudFileStatusProviding {
        lock.lock()
        defer { lock.unlock() }
        return _provider
    }

    /// Swaps the provider in, returning the previous one (sync, so async callers
    /// never hold the lock across a suspension).
    private static func exchangeProvider(_ provider: any CloudFileStatusProviding) -> any CloudFileStatusProviding {
        lock.lock()
        defer { lock.unlock() }
        let previous = _provider
        _provider = provider
        return previous
    }

    /// Tests only: runs `body` with `provider` answering every check, then restores the
    /// previous provider.
    static func withProvider<T>(_ provider: any CloudFileStatusProviding, _ body: () throws -> T) rethrows -> T {
        let previous = exchangeProvider(provider)
        defer { _ = exchangeProvider(previous) }
        return try body()
    }

    /// Async variant of `withProvider` for tests that await the guarded services.
    static func withProvider<T>(_ provider: any CloudFileStatusProviding, _ body: () async throws -> T) async rethrows -> T {
        let previous = exchangeProvider(provider)
        defer { _ = exchangeProvider(previous) }
        return try await body()
    }

    // MARK: Decisions (pure)

    /// Availability from a snapshot. A dataless file is online-only whatever the
    /// ubiquitous keys say (they can lag); a ubiquitous item that reports
    /// `.notDownloaded` is too (legacy iCloud). "Downloading" wins over online-only.
    static func availability(from snapshot: CloudResourceSnapshot) -> CloudAvailability {
        let notDownloaded = snapshot.isUbiquitous == true
            && snapshot.downloadingStatus == URLUbiquitousItemDownloadingStatus.notDownloaded.rawValue
        guard snapshot.isDataless || notDownloaded else { return .local }
        return snapshot.isDownloading == true ? .downloading : .cloudOnly
    }

    // MARK: Checks

    /// True when reading the file's contents won't trigger a download. Cheap (one
    /// `lstat`); missing files count as available so callers keep their own
    /// "file not found" handling.
    static func isLocallyAvailable(_ url: URL) -> Bool {
        isLocallyAvailable(path: url.path)
    }

    static func isLocallyAvailable(path: String) -> Bool {
        guard let snapshot = provider.snapshot(forPath: path, fast: true) else { return true }
        return !snapshot.isDataless
    }

    /// Full availability (adds the ubiquitous keys: "downloading", legacy iCloud).
    static func availability(for url: URL) -> CloudAvailability {
        guard let snapshot = provider.snapshot(forPath: url.path, fast: false) else { return .local }
        return availability(from: snapshot)
    }

    /// For `FileSystemService.readDirectory`: files only, the fast check.
    static func isCloudOnly(path: String, isDirectory: Bool) -> Bool {
        guard !isDirectory else { return false }
        return !isLocallyAvailable(path: path)
    }
}
