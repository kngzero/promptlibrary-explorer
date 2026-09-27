import Foundation

/// A snapshot of everything the app currently caches.
struct CacheStatistics: Equatable {
    var thumbnailFileCount: Int = 0
    var thumbnailDiskBytes: Int64 = 0
    var plibEntries: Int = 0
    var aoeEntries: Int = 0
    var imageMetadataEntries: Int = 0
    var audioMetadataEntries: Int = 0
    var promptIndexEntries: Int = 0

    /// Total number of parsed records held in memory across every parser and the search index.
    var memoryEntryCount: Int {
        plibEntries + aoeEntries + imageMetadataEntries + audioMetadataEntries + promptIndexEntries
    }

    var isEmpty: Bool {
        thumbnailFileCount == 0 && thumbnailDiskBytes == 0 && memoryEntryCount == 0
    }

    var formattedDiskSize: String {
        ByteCountFormatter.string(fromByteCount: thumbnailDiskBytes, countStyle: .file)
    }
}

/// Measures and clears the caches the app maintains: the thumbnail cache (memory + disk)
/// and the in-memory parser and prompt-index caches.
///
/// User data — favorites, tags, ratings, smart folders, recent folders — lives in
/// UserDefaults and is never touched here.
enum CacheService {
    /// Gathers a fresh snapshot of cache usage. Disk measurement runs off the main actor.
    static func statistics() async -> CacheStatistics {
        var stats = CacheStatistics()

        let disk = await diskUsage(of: ThumbnailService.diskCacheDirectory)
        stats.thumbnailFileCount = disk.fileCount
        stats.thumbnailDiskBytes = disk.bytes

        stats.plibEntries = await PlibParser.shared.cachedCount
        stats.aoeEntries = await AoeParser.shared.cachedCount
        stats.imageMetadataEntries = await ImageMetadataParser.shared.cachedCount
        stats.audioMetadataEntries = await AudioMetadataParser.shared.cachedCount
        stats.promptIndexEntries = await PromptIndexService.shared.count

        return stats
    }

    /// Empties every cache. Files on disk are only removed from the app's own cache directory.
    static func clearAll() async {
        await PlibParser.shared.clearCache()
        await AoeParser.shared.clearCache()
        await ImageMetadataParser.shared.clearCache()
        await AudioMetadataParser.shared.clearCache()
        await PromptIndexService.shared.clearIndex()
        await MainActor.run {
            ThumbnailService.shared.clearCache()
        }
    }

    // MARK: - Private

    private static func diskUsage(of directory: URL) async -> (fileCount: Int, bytes: Int64) {
        await withCheckedContinuation { (continuation: CheckedContinuation<(fileCount: Int, bytes: Int64), Never>) in
            DispatchQueue.global(qos: .utility).async {
                let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]

                guard let enumerator = FileManager.default.enumerator(
                    at: directory,
                    includingPropertiesForKeys: Array(keys),
                    options: [.skipsHiddenFiles]
                ) else {
                    continuation.resume(returning: (0, 0))
                    return
                }

                var fileCount = 0
                var bytes: Int64 = 0

                for case let url as URL in enumerator {
                    guard let values = try? url.resourceValues(forKeys: keys),
                          values.isRegularFile == true
                    else { continue }

                    fileCount += 1
                    bytes += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
                }

                continuation.resume(returning: (fileCount, bytes))
            }
        }
    }
}

// MARK: - Bounded LRU

/// A small least-recently-used cache for actor-isolated parser state. Not thread-safe on its own;
/// owners (actors) provide isolation.
struct LRUCache<Value> {
    private var storage: [String: Value] = [:]
    /// Keys from least to most recently used.
    private var order: [String] = []
    let capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    var count: Int { storage.count }

    mutating func value(forKey key: String) -> Value? {
        guard let value = storage[key] else { return nil }
        touch(key)
        return value
    }

    mutating func setValue(_ value: Value, forKey key: String) {
        if storage.updateValue(value, forKey: key) != nil {
            touch(key)
        } else {
            order.append(key)
        }
        while storage.count > capacity, !order.isEmpty {
            storage.removeValue(forKey: order.removeFirst())
        }
    }

    mutating func removeValue(forKey key: String) {
        guard storage.removeValue(forKey: key) != nil else { return }
        order.removeAll { $0 == key }
    }

    mutating func removeAll() {
        storage.removeAll()
        order.removeAll()
    }

    private mutating func touch(_ key: String) {
        if let index = order.lastIndex(of: key) {
            order.remove(at: index)
        }
        order.append(key)
    }
}

/// A parsed entry plus the file signature it was parsed from, so edits on disk invalidate it.
struct ParsedFileCacheEntry<Value> {
    let value: Value
    let modificationDate: Date?
    let fileSize: Int?

    static func signature(of url: URL) -> (Date?, Int?) {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return (values?.contentModificationDate, values?.fileSize)
    }

    func matches(_ signature: (Date?, Int?)) -> Bool {
        modificationDate == signature.0 && fileSize == signature.1
    }
}
