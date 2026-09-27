import AppKit
import ArtOfficialFormats
import CryptoKit
import Foundation
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Three-tier thumbnail cache: NSCache (memory) -> disk cache -> QLThumbnailGenerator.
@MainActor
final class ThumbnailService {
    static let shared = ThumbnailService()
    nonisolated private static let cacheVersion = "v2"

    /// Disk entries untouched for this long are pruned.
    nonisolated private static let diskMaxAge: TimeInterval = 30 * 24 * 60 * 60
    /// Disk cache is trimmed oldest-first to stay under this size.
    nonisolated private static let diskMaxBytes: Int64 = 500 * 1024 * 1024

    // MARK: - Tier 1: In-memory caches

    /// Grid thumbnails: many small images.
    private let memoryCache = NSCache<NSString, NSImage>()
    /// Lightbox/detail previews: few, very large images (up to ~64 MB decoded each).
    private let previewCache = NSCache<NSString, NSImage>()

    /// Memoized cache keys, keyed by the file signature (path + mtime + size + pixel size),
    /// so repeat lookups skip the SHA-256 hashing.
    private var keyMemo: [String: String] = [:]

    // MARK: - Tier 2: Disk cache

    /// On-disk thumbnail cache location. Nonisolated so cache reporting can measure it off the main actor.
    nonisolated static let diskCacheDirectory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("com.artofficial.promptlibrary-explorer/thumbnails")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private init() {
        memoryCache.countLimit = 500
        memoryCache.totalCostLimit = 256 * 1024 * 1024
        previewCache.countLimit = 12
        previewCache.totalCostLimit = 384 * 1024 * 1024

        Task.detached(priority: .background) {
            Self.pruneDiskCache()
        }
    }

    // MARK: - Public API

    /// Returns an in-memory cached thumbnail, or nil for a miss. Never touches the disk cache
    /// synchronously; use `thumbnail(for:size:)` to also consult disk and generate.
    func cachedThumbnail(for url: URL, size: CGFloat) -> NSImage? {
        guard let signature = Self.fileSignature(for: url, size: size) else { return nil }
        let key = memoizedKey(for: signature)
        return memoryCache.object(forKey: key as NSString)
    }

    /// Generates a thumbnail asynchronously, populating both caches.
    func thumbnail(for url: URL, size: CGFloat) async -> NSImage? {
        let key = await resolveKey(for: url, size: size)

        // Check memory cache first
        if let cached = memoryCache.object(forKey: key as NSString) {
            return cached
        }

        // Check disk cache
        if let diskImage = await Self.loadFromDiskOffMain(key: key) {
            store(diskImage, key: key, in: memoryCache)
            return diskImage
        }

        if FileHelpers.isImageFile(url.lastPathComponent) {
            let scale = NSScreen.main?.backingScaleFactor ?? 2.0
            return await rasterImage(for: url, maxPixelSize: size * scale, key: key, cache: memoryCache)
        }

        if FileHelpers.isArtOfficialDocumentFile(url.lastPathComponent) {
            let scale = NSScreen.main?.backingScaleFactor ?? 2.0
            return await artOfficialImage(for: url, maxPixelSize: size * scale, key: key, cache: memoryCache)
        }

        // Tier 3: Generate via QLThumbnailGenerator
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: size, height: size),
            scale: NSScreen.main?.backingScaleFactor ?? 2.0,
            representationTypes: .thumbnail
        )

        do {
            let representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            let image = representation.nsImage
            store(image, key: key, in: memoryCache)
            Self.persistToDisk(representation.cgImage, key: key)
            return image
        } catch {
            // Fallback: load original and downsample
            let scale = NSScreen.main?.backingScaleFactor ?? 2.0
            return await rasterImage(for: url, maxPixelSize: size * scale, key: key, cache: memoryCache, persist: false)
        }
    }

    /// Loads the best-available preview image for lightbox/detail display.
    func previewImage(for url: URL, maxPixelSize: CGFloat = 4096) async -> NSImage? {
        let key = await resolveKey(for: url, size: maxPixelSize)

        if let cached = previewCache.object(forKey: key as NSString) {
            return cached
        }

        if let diskImage = await Self.loadFromDiskOffMain(key: key) {
            store(diskImage, key: key, in: previewCache)
            return diskImage
        }

        if FileHelpers.isImageFile(url.lastPathComponent) {
            return await rasterImage(for: url, maxPixelSize: maxPixelSize, key: key, cache: previewCache)
        }

        if FileHelpers.isArtOfficialDocumentFile(url.lastPathComponent) {
            return await artOfficialImage(for: url, maxPixelSize: maxPixelSize, key: key, cache: previewCache)
        }

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: maxPixelSize, height: maxPixelSize),
            scale: NSScreen.main?.backingScaleFactor ?? 2.0,
            representationTypes: .all
        )

        do {
            let representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            let image = representation.nsImage
            store(image, key: key, in: previewCache)
            Self.persistToDisk(representation.cgImage, key: key)
            return image
        } catch {
            return await rasterImage(for: url, maxPixelSize: maxPixelSize, key: key, cache: previewCache, persist: false)
        }
    }

    /// Clears all cached thumbnails.
    func clearCache() {
        memoryCache.removeAllObjects()
        previewCache.removeAllObjects()
        keyMemo.removeAll()
        // Rename (instant) then delete in the background, so a large cache doesn't block the UI.
        let fm = FileManager.default
        let dir = Self.diskCacheDirectory
        let doomed = dir.deletingLastPathComponent()
            .appendingPathComponent(".thumbnails-deleting-\(UUID().uuidString)")
        if (try? fm.moveItem(at: dir, to: doomed)) != nil {
            Task.detached(priority: .background) {
                try? FileManager.default.removeItem(at: doomed)
            }
        } else {
            try? fm.removeItem(at: dir)
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // MARK: - Keys

    /// Stats the file off the main actor, then hashes (memoized) on it.
    private func resolveKey(for url: URL, size: CGFloat) async -> String {
        let signature = await Task.detached(priority: .userInitiated) {
            Self.fileSignature(for: url, size: size) ?? Self.missingFileSignature(for: url, size: size)
        }.value
        return memoizedKey(for: signature)
    }

    private func memoizedKey(for signature: String) -> String {
        if let key = keyMemo[signature] { return key }
        if keyMemo.count > 5000 { keyMemo.removeAll(keepingCapacity: true) }
        let digest = SHA256.hash(data: Data(signature.utf8))
        let key = digest.map { String(format: "%02x", $0) }.joined()
        keyMemo[signature] = key
        return key
    }

    nonisolated private static func fileSignature(for url: URL, size: CGFloat) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else {
            return nil
        }
        return [
            cacheVersion + kindTag(for: url),
            url.standardizedFileURL.path,
            values.contentModificationDate?.timeIntervalSinceReferenceDate.description ?? "nil",
            values.fileSize.map(String.init) ?? "nil",
            String(Int(size))
        ].joined(separator: "|")
    }

    nonisolated private static func missingFileSignature(for url: URL, size: CGFloat) -> String {
        [cacheVersion + kindTag(for: url), url.standardizedFileURL.path, "nil", "nil", String(Int(size))].joined(separator: "|")
    }

    /// Art Official documents are rendered by this app; the tag keeps them from
    /// reusing a generic icon cached before the renderer existed.
    nonisolated private static func kindTag(for url: URL) -> String {
        FileHelpers.isArtOfficialDocumentFile(url.lastPathComponent) ? "-aodoc1" : ""
    }

    // MARK: - Memory

    private func store(_ image: NSImage, key: String, in cache: NSCache<NSString, NSImage>) {
        cache.setObject(image, forKey: key as NSString, cost: Self.estimatedCost(of: image))
    }

    /// Approximate decoded size in bytes (pixelsWide * pixelsHigh * 4).
    nonisolated private static func estimatedCost(of image: NSImage) -> Int {
        let pixels = image.representations
            .map { $0.pixelsWide * $0.pixelsHigh }
            .max() ?? 0
        if pixels > 0 { return pixels * 4 }
        return Int(image.size.width * image.size.height) * 4
    }

    // MARK: - Generation

    private func rasterImage(
        for url: URL,
        maxPixelSize: CGFloat,
        key: String,
        cache: NSCache<NSString, NSImage>,
        persist: Bool = true
    ) async -> NSImage? {
        guard let cgImage = await Self.downsampledCGImage(at: url, maxPixelSize: maxPixelSize) else {
            return nil
        }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        store(image, key: key, in: cache)
        if persist {
            Self.persistToDisk(cgImage, key: key)
        }
        return image
    }

    /// Mood board: the rendered board. Story project: the default project's cover or
    /// contact sheet. Parsed via `ArtOfficialDocumentParser`, rendered off the main actor.
    private func artOfficialImage(
        for url: URL,
        maxPixelSize: CGFloat,
        key: String,
        cache: NSCache<NSString, NSImage>
    ) async -> NSImage? {
        guard let document = await ArtOfficialDocumentParser.shared.parse(at: url) else { return nil }
        let pixels = Int(max(maxPixelSize, 64).rounded())
        let rendered = await Task.detached(priority: .userInitiated) {
            ArtOfficialRendering.overview(of: document, maxPixelSize: pixels)
        }.value
        guard let rendered else { return nil }
        let image = NSImage(cgImage: rendered, size: NSSize(width: rendered.width, height: rendered.height))
        store(image, key: key, in: cache)
        Self.persistToDisk(rendered, key: key)
        return image
    }

    nonisolated private static func downsampledCGImage(at url: URL, maxPixelSize: CGFloat) async -> CGImage? {
        await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: max(maxPixelSize, 1),
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
    }

    // MARK: - Disk

    nonisolated private static func diskURL(for key: String, ext: String) -> URL {
        diskCacheDirectory.appendingPathComponent(key).appendingPathExtension(ext)
    }

    /// Reads a disk entry (PNG for images with alpha, JPEG otherwise; older entries are JPEG).
    nonisolated private static func loadFromDiskOffMain(key: String) async -> NSImage? {
        await withCheckedContinuation { (continuation: CheckedContinuation<NSImage?, Never>) in
            DispatchQueue.global(qos: .utility).async {
                for ext in ["png", "jpg"] {
                    let url = diskURL(for: key, ext: ext)
                    guard FileManager.default.fileExists(atPath: url.path) else { continue }
                    if let image = NSImage(contentsOf: url) {
                        // Refresh the modification date so pruning is least-recently-used.
                        try? FileManager.default.setAttributes(
                            [.modificationDate: Date()],
                            ofItemAtPath: url.path
                        )
                        continuation.resume(returning: image)
                        return
                    }
                }
                continuation.resume(returning: nil)
            }
        }
    }

    /// Encodes and writes off the main actor. CGImage is immutable and Sendable.
    nonisolated private static func persistToDisk(_ cgImage: CGImage, key: String) {
        Task.detached(priority: .utility) {
            let hasAlpha: Bool
            switch cgImage.alphaInfo {
            case .none, .noneSkipFirst, .noneSkipLast: hasAlpha = false
            default: hasAlpha = true
            }

            let type: UTType = hasAlpha ? .png : .jpeg
            let url = diskURL(for: key, ext: hasAlpha ? "png" : "jpg")

            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                data as CFMutableData, type.identifier as CFString, 1, nil
            ) else { return }

            let properties: [CFString: Any] = hasAlpha ? [:] : [kCGImageDestinationLossyCompressionQuality: 0.8]
            CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return }

            try? (data as Data).write(to: url, options: .atomic)
        }
    }

    /// Removes entries older than `diskMaxAge`, then trims oldest-first to `diskMaxBytes`.
    nonisolated private static func pruneDiskCache() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let files = try? fm.contentsOfDirectory(
            at: diskCacheDirectory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-diskMaxAge)
        var survivors: [(url: URL, date: Date, bytes: Int64)] = []
        var totalBytes: Int64 = 0

        for url in files {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true
            else { continue }

            let date = values.contentModificationDate ?? .distantPast
            if date < cutoff {
                try? fm.removeItem(at: url)
                continue
            }

            let bytes = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            survivors.append((url, date, bytes))
            totalBytes += bytes
        }

        guard totalBytes > diskMaxBytes else { return }

        for file in survivors.sorted(by: { $0.date < $1.date }) {
            try? fm.removeItem(at: file.url)
            totalBytes -= file.bytes
            if totalBytes <= diskMaxBytes { break }
        }
    }
}
