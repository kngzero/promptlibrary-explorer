import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

/// Decodes images (and video poster frames) at a requested resolution for the
/// viewing tools — Compare and the lightbox loupe — off the main actor.
/// Never more than the native size; a small memory cache (by path, mtime and
/// decoded size) keeps the few large decodes these tools need. Nothing is
/// written to disk.
enum ViewingImageLoader {
    /// Native (oriented) pixel size and file size.
    struct Info: Equatable, Sendable {
        var pixelSize: CGSize?
        var fileSize: Int64?
    }

    /// Reads the pixel size (EXIF orientation applied) and file size.
    static func info(forPath path: String) async -> Info {
        await Task.detached(priority: .userInitiated) { () -> Info in
            let url = URL(fileURLWithPath: path)
            let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
            if FileHelpers.isVideoFile(url.lastPathComponent) {
                return Info(pixelSize: await videoPixelSize(url: url), fileSize: fileSize)
            }
            // Edited images compare as edited (EditRenderer).
            if let recipe = EditRecipeIndex.shared.recipe(for: path) {
                return Info(pixelSize: EditRenderer.editedPixelSize(url: url, recipe: recipe), fileSize: fileSize)
            }
            return Info(pixelSize: imagePixelSize(url: url), fileSize: fileSize)
        }.value
    }

    static func imagePixelSize(url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue
        else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        // Orientations 5–8 rotate by 90°.
        return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    static func videoPixelSize(url: URL) async -> CGSize? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (natural, transform) = try? await track.load(.naturalSize, .preferredTransform)
        else { return nil }
        let rect = CGRect(origin: .zero, size: natural).applying(transform)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }

    // MARK: Decoding

    private static let cache: NSCache<NSString, CGImageBox> = {
        let cache = NSCache<NSString, CGImageBox>()
        cache.countLimit = 12
        cache.totalCostLimit = 768 * 1024 * 1024
        return cache
    }()

    final class CGImageBox: @unchecked Sendable {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private static func cacheKey(path: String, longEdge: Int) -> String {
        let url = URL(fileURLWithPath: path)
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
        return EditCacheKey.signature("\(path)|\(mtime)|\(longEdge)", recipe: EditRecipeIndex.shared.recipe(for: path))
    }

    /// The image at `path` decoded to at most `maxPixelSize` on its long edge
    /// (pass the native long edge for full resolution). Videos give a poster
    /// frame from early in the clip.
    static func decode(path: String, maxPixelSize: CGFloat) async -> CGImage? {
        let longEdge = max(1, Int(maxPixelSize.rounded()))
        let key = cacheKey(path: path, longEdge: longEdge) as NSString
        if let cached = cache.object(forKey: key) { return cached.image }
        let image: CGImage? = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            let url = URL(fileURLWithPath: path)
            if FileHelpers.isVideoFile(url.lastPathComponent) {
                return await posterFrame(url: url, maxPixelSize: CGFloat(longEdge))
            }
            if let recipe = EditRecipeIndex.shared.recipe(for: path) {
                return EditRenderer.render(url: url, recipe: recipe, maxPixelSize: CGFloat(longEdge))
            }
            return downsample(url: url, maxPixelSize: CGFloat(longEdge))
        }.value
        guard !Task.isCancelled, let image else { return image }
        cache.setObject(CGImageBox(image), forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }

    static func downsample(url: URL, maxPixelSize: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: max(maxPixelSize, 1),
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func posterFrame(url: URL, maxPixelSize: CGFloat) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        let seconds = duration.isFinite && duration > 0 ? min(1, duration / 2) : 0
        return try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }
}
