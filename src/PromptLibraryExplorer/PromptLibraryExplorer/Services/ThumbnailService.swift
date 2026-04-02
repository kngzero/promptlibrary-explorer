import AppKit
import CryptoKit
import Foundation
import QuickLookThumbnailing

/// Three-tier thumbnail cache: NSCache (memory) -> disk cache -> QLThumbnailGenerator.
@MainActor
final class ThumbnailService {
    static let shared = ThumbnailService()

    // MARK: - Tier 1: In-memory cache

    private let memoryCache = NSCache<NSString, NSImage>()

    // MARK: - Tier 2: Disk cache

    private let diskCacheURL: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("com.artofficial.promptlibrary-explorer/thumbnails")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private init() {
        memoryCache.countLimit = 500
    }

    // MARK: - Public API

    /// Returns a cached thumbnail if available (Tier 1 or Tier 2), or nil for a cache miss.
    func cachedThumbnail(for url: URL, size: CGFloat) -> NSImage? {
        let key = cacheKey(for: url, size: size)

        // Tier 1: memory
        if let cached = memoryCache.object(forKey: key as NSString) {
            return cached
        }

        // Tier 2: disk
        let diskPath = diskCacheURL.appendingPathComponent(key).appendingPathExtension("jpg")
        if let diskImage = NSImage(contentsOf: diskPath) {
            memoryCache.setObject(diskImage, forKey: key as NSString)
            return diskImage
        }

        return nil
    }

    /// Generates a thumbnail asynchronously, populating both caches.
    func thumbnail(for url: URL, size: CGFloat) async -> NSImage? {
        let key = cacheKey(for: url, size: size)

        // Check memory cache first
        if let cached = memoryCache.object(forKey: key as NSString) {
            return cached
        }

        // Check disk cache
        let diskPath = diskCacheURL.appendingPathComponent(key).appendingPathExtension("jpg")
        if let diskImage = NSImage(contentsOf: diskPath) {
            memoryCache.setObject(diskImage, forKey: key as NSString)
            return diskImage
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

            // Populate Tier 1
            memoryCache.setObject(image, forKey: key as NSString)

            // Populate Tier 2 (async, non-blocking)
            Task.detached(priority: .utility) {
                if let tiffData = image.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiffData),
                   let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
                {
                    try? jpegData.write(to: diskPath)
                }
            }

            return image
        } catch {
            // Fallback: load original and downsample
            return await fallbackThumbnail(for: url, size: size, key: key)
        }
    }

    /// Loads the best-available preview image for lightbox/detail display.
    func previewImage(for url: URL, maxPixelSize: CGFloat = 4096) async -> NSImage? {
        if let image = NSImage(contentsOf: url) {
            return image
        }

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: maxPixelSize, height: maxPixelSize),
            scale: NSScreen.main?.backingScaleFactor ?? 2.0,
            representationTypes: .all
        )

        do {
            let representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            return representation.nsImage
        } catch {
            let key = cacheKey(for: url, size: maxPixelSize)
            return await fallbackThumbnail(for: url, size: maxPixelSize, key: key)
        }
    }

    /// Clears all cached thumbnails.
    func clearCache() {
        memoryCache.removeAllObjects()
        try? FileManager.default.removeItem(at: diskCacheURL)
        try? FileManager.default.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)
    }

    // MARK: - Private

    private func cacheKey(for url: URL, size: CGFloat) -> String {
        let resourceValues = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let fileSignature = [
            url.standardizedFileURL.path,
            resourceValues?.contentModificationDate?.timeIntervalSinceReferenceDate.description ?? "nil",
            resourceValues?.fileSize.map(String.init) ?? "nil",
            String(Int(size))
        ].joined(separator: "|")

        let digest = SHA256.hash(data: Data(fileSignature.utf8))
        let key = digest.map { String(format: "%02x", $0) }.joined()
        return key
    }

    private func fallbackThumbnail(for url: URL, size: CGFloat, key: String) async -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: size * (NSScreen.main?.backingScaleFactor ?? 2.0),
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        memoryCache.setObject(nsImage, forKey: key as NSString)
        return nsImage
    }
}
