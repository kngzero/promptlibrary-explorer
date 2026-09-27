import AppKit
import AVFoundation
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Bounded concurrency

/// An async semaphore: at most `limit` bodies run at once; waiting is cancellable.
actor MediaWorkLimiter {
    /// Hover-scrub strips and frame grabs for the grid.
    static let frames = MediaWorkLimiter(limit: 2)
    /// Waveform peak extraction.
    static let waveforms = MediaWorkLimiter(limit: 2)

    private let limit: Int
    private var running = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    init(limit: Int) {
        self.limit = max(limit, 1)
    }

    func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await body()
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if running < limit {
            running += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func release() {
        if waiters.isEmpty {
            running -= 1
        } else {
            // Hand the slot straight to the next waiter (running stays the same).
            waiters.removeFirst().continuation.resume()
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

// MARK: - Errors

enum MediaToolError: LocalizedError {
    case noVideoTrack
    case noAudioTrack
    case frameUnavailable
    case writeFailed(String)
    case wouldOverwriteSource
    case exportFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "The file has no video track."
        case .noAudioTrack: return "The file has no audio track."
        case .frameUnavailable: return "That frame couldn't be read."
        case let .writeFailed(name): return "Couldn't write \(name)."
        case .wouldOverwriteSource: return "Choose a different name: the original is never overwritten."
        case let .exportFailed(message): return message
        case .cancelled: return "Cancelled."
        }
    }
}

// MARK: - Frame extraction

/// AVAssetImageGenerator helpers. Everything is `nonisolated` and async, so callers on
/// the main actor never block; cancelling the calling task stops generation.
enum MediaFrameExtractor {
    struct VideoInfo: Sendable {
        let duration: Double
        let naturalSize: CGSize
        let hasVideo: Bool
        let hasAudio: Bool
        /// kCMVideoCodecType_* of the first video track, 0 if none.
        let codec: FourCharCode
        let nominalFrameRate: Float
    }

    static func info(for url: URL) async throws -> VideoInfo {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        var size = CGSize.zero
        var codec: FourCharCode = 0
        var fps: Float = 0
        if let track = videoTracks.first {
            let (natural, transform, descriptions, rate) = try await track.load(
                .naturalSize, .preferredTransform, .formatDescriptions, .nominalFrameRate
            )
            let rect = CGRect(origin: .zero, size: natural).applying(transform)
            size = CGSize(width: abs(rect.width), height: abs(rect.height))
            if let description = descriptions.first {
                codec = CMFormatDescriptionGetMediaSubType(description)
            }
            fps = rate
        }
        return VideoInfo(
            duration: duration.isFinite ? duration : 0,
            naturalSize: size,
            hasVideo: !videoTracks.isEmpty,
            hasAudio: !audioTracks.isEmpty,
            codec: codec,
            nominalFrameRate: fps
        )
    }

    static func generator(
        for asset: AVAsset,
        maximumSize: CGSize = .zero,
        tolerance: CMTime = .zero
    ) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maximumSize
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        return generator
    }

    /// One frame at `seconds` (exact, full resolution unless `maxPixelSize` is given).
    static func frame(at seconds: Double, url: URL, maxPixelSize: CGFloat? = nil) async throws -> CGImage {
        let asset = AVURLAsset(url: url)
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else { throw MediaToolError.noVideoTrack }
        let duration = try await asset.load(.duration).seconds
        let size = maxPixelSize.map { CGSize(width: $0, height: $0) } ?? .zero
        let generator = generator(for: asset, maximumSize: size)
        let clamped = clampedTime(seconds, duration: duration)
        do {
            return try await generator.image(at: CMTime(seconds: clamped, preferredTimescale: 600)).image
        } catch {
            try Task.checkCancellation()
            // Very short clips / the last instant: fall back to a tolerant request.
            generator.requestedTimeToleranceBefore = .positiveInfinity
            generator.requestedTimeToleranceAfter = .positiveInfinity
            do {
                return try await generator.image(at: CMTime(seconds: clamped, preferredTimescale: 600)).image
            } catch {
                throw MediaToolError.frameUnavailable
            }
        }
    }

    /// Frames at `times` (seconds). Missing frames are nil; cancelling stops early.
    /// `tolerance` > 0 lets the decoder use nearby keyframes (much faster for strips).
    static func frames(
        at times: [Double],
        url: URL,
        maxPixelSize: CGFloat?,
        tolerance: Double = 0
    ) async throws -> [CGImage?] {
        guard !times.isEmpty else { return [] }
        let asset = AVURLAsset(url: url)
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else { throw MediaToolError.noVideoTrack }
        let duration = try await asset.load(.duration).seconds
        let size = maxPixelSize.map { CGSize(width: $0, height: $0) } ?? .zero
        let tol = tolerance > 0 ? CMTime(seconds: tolerance, preferredTimescale: 600) : .zero
        let generator = generator(for: asset, maximumSize: size, tolerance: tol)
        let cmTimes = times.map { CMTime(seconds: clampedTime($0, duration: duration), preferredTimescale: 600) }

        var results = [CGImage?](repeating: nil, count: times.count)
        var answered = [Bool](repeating: false, count: times.count)
        var sequential = 0
        for await result in generator.images(for: cmTimes) {
            try Task.checkCancellation()
            // Match by requested time (equal times — a tiny clip — fill in order).
            let index = cmTimes.indices.first { !answered[$0] && cmTimes[$0] == result.requestedTime }
                ?? answered.firstIndex(of: false)
                ?? sequential
            sequential += 1
            guard index < results.count else { continue }
            answered[index] = true
            if let image = try? result.image {
                results[index] = image
            }
        }
        try Task.checkCancellation()
        // Short clips can fail exact requests near the end: reuse the nearest good frame.
        if results.contains(where: { $0 == nil }), let fallback = results.compactMap({ $0 }).first {
            var last = fallback
            for i in results.indices {
                if let image = results[i] { last = image } else { results[i] = last }
            }
        } else if results.allSatisfy({ $0 == nil }) {
            let single = try? await frame(at: 0, url: url, maxPixelSize: maxPixelSize)
            if let single { results = results.map { _ in single } }
        }
        return results
    }

    /// Keeps a request a hair before the end, where there's always a frame to show.
    static func clampedTime(_ seconds: Double, duration: Double) -> Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        let lastSafe = max(duration - 0.001, 0)
        return min(max(seconds.isFinite ? seconds : 0, 0), lastSafe)
    }

    /// The frame used by "Save Middle Frame" (the clip's midpoint).
    static func middleTime(duration: Double) -> Double {
        duration.isFinite && duration > 0 ? duration / 2 : 0
    }
}

// MARK: - Image writing / strips

enum MediaImageFormat: String, CaseIterable, Identifiable {
    case png, jpeg

    var id: String { rawValue }
    var title: String { self == .png ? "PNG" : "JPEG" }
    var fileExtension: String { self == .png ? "png" : "jpg" }
    var type: UTType { self == .png ? .png : .jpeg }

    init(fileExtension: String) {
        let ext = fileExtension.lowercased()
        self = (ext == "jpg" || ext == "jpeg") ? .jpeg : .png
    }
}

enum MediaImageWriter {
    static func data(for image: CGImage, format: MediaImageFormat, quality: Double = 0.92) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, format.type.identifier as CFString, 1, nil
        ) else { return nil }
        let properties: [CFString: Any] = format == .jpeg ? [kCGImageDestinationLossyCompressionQuality: quality] : [:]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    static func write(_ image: CGImage, to url: URL, format: MediaImageFormat) throws {
        guard let data = data(for: image, format: format) else {
            throw MediaToolError.writeFailed(url.lastPathComponent)
        }
        try data.write(to: url, options: .atomic)
    }
}

enum MediaStripRenderer {
    /// Lays `frames` out as a contact strip: up to `columns` per row, `spacing` px gaps, each
    /// frame optionally captioned with its timecode. Drawn with CoreGraphics / CoreText, so
    /// it's safe off the main actor.
    static func contactStrip(
        frames: [(image: CGImage, seconds: Double)],
        columns: Int,
        spacing: CGFloat = 8,
        captions: Bool = true
    ) -> CGImage? {
        guard let first = frames.first?.image else { return nil }
        let columns = max(1, min(columns, frames.count))
        let rows = Int((Double(frames.count) / Double(columns)).rounded(.up))
        let cellWidth = CGFloat(first.width)
        let cellHeight = CGFloat(first.height)
        let captionHeight: CGFloat = captions ? max(18, cellHeight * 0.1) : 0
        let width = CGFloat(columns) * cellWidth + CGFloat(columns + 1) * spacing
        let height = CGFloat(rows) * (cellHeight + captionHeight) + CGFloat(rows + 1) * spacing
        guard let context = CGContext(
            data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 0.08, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let fontSize = max(10, captionHeight * 0.62)
        let font = CTFontCreateWithName("Menlo" as CFString, fontSize, nil)
        for (offset, frame) in frames.enumerated() {
            let column = offset % columns
            let row = offset / columns
            let x = spacing + CGFloat(column) * (cellWidth + spacing)
            // CoreGraphics origin is bottom-left: row 0 is at the top.
            let yTop = height - spacing - CGFloat(row) * (cellHeight + captionHeight + spacing)
            let imageRect = CGRect(x: x, y: yTop - cellHeight, width: cellWidth, height: cellHeight)
            context.draw(frame.image, in: aspectFit(frame.image, in: imageRect))
            if captions {
                let text = MediaTimeMath.displayTimecode(frame.seconds)
                let attributes: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.85, alpha: 1),
                ]
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
                context.textPosition = CGPoint(x: x + 2, y: yTop - cellHeight - captionHeight + (captionHeight - fontSize) / 2 + 2)
                CTLineDraw(line, context)
            }
        }
        return context.makeImage()
    }

    private static func aspectFit(_ image: CGImage, in rect: CGRect) -> CGRect {
        let scale = min(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// Joins equally sized frames left-to-right (the hover-scrub disk cache format).
    static func horizontalStrip(_ frames: [CGImage]) -> CGImage? {
        guard let first = frames.first else { return nil }
        let w = first.width, h = first.height
        guard let context = CGContext(
            data: nil, width: w * frames.count, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        for (index, frame) in frames.enumerated() {
            context.draw(frame, in: CGRect(x: index * w, y: 0, width: w, height: h))
        }
        return context.makeImage()
    }

    /// Splits a `horizontalStrip` back into `count` frames.
    static func split(_ strip: CGImage, count: Int) -> [CGImage] {
        guard count > 0 else { return [] }
        let w = strip.width / count
        guard w > 0 else { return [] }
        return (0..<count).compactMap { strip.cropping(to: CGRect(x: $0 * w, y: 0, width: w, height: strip.height)) }
    }
}

// MARK: - Hover-scrub strips

/// ~12 small frames per video for hover scrubbing, generated lazily (first hover) and cached
/// in memory and in ThumbnailService's disk cache (keyed by path + mtime + size).
enum MediaScrubStripService {
    /// Longest side of each strip frame, in pixels (one size for every tile size).
    static let framePixelSize: CGFloat = 320

    final class Strip: @unchecked Sendable {
        let frames: [NSImage]
        init(frames: [NSImage]) { self.frames = frames }
    }

    nonisolated(unsafe) private static let memory: NSCache<NSString, Strip> = {
        let cache = NSCache<NSString, Strip>()
        cache.countLimit = 80
        return cache
    }()

    private static func variant(count: Int, pixels: CGFloat) -> String {
        "scrub1-\(count)-\(Int(pixels))"
    }

    /// Memory-only lookup (never touches disk). Safe from any thread (NSCache).
    static func cachedStrip(for url: URL, count: Int = MediaTimeMath.scrubFrameCount) -> Strip? {
        guard let key = ThumbnailService.mediaCacheKey(for: url, variant: variant(count: count, pixels: framePixelSize)) else {
            return nil
        }
        return memory.object(forKey: key as NSString)
    }

    /// Memory → disk → generate. Cancellable; returns nil for files without video.
    static func strip(
        for url: URL,
        count: Int = MediaTimeMath.scrubFrameCount,
        pixelSize: CGFloat = framePixelSize
    ) async -> Strip? {
        let variant = variant(count: count, pixels: pixelSize)
        let key = await Task.detached(priority: .userInitiated) {
            ThumbnailService.mediaCacheKey(for: url, variant: variant)
        }.value
        guard let key else { return nil }
        if let cached = memory.object(forKey: key as NSString) { return cached }

        if let stored = await ThumbnailService.loadMediaCacheImage(key: key) {
            let frames = MediaScrubStripService.split(stored, count: count)
            if frames.count == count {
                let strip = Strip(frames: frames.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) })
                memory.setObject(strip, forKey: key as NSString)
                return strip
            }
        }
        guard !Task.isCancelled else { return nil }
        // Hover scrub never downloads an online-only cloud file.
        guard CloudFileStatus.isLocallyAvailable(url) else { return nil }

        let images: [CGImage]? = try? await MediaWorkLimiter.frames.run {
            let info = try await MediaFrameExtractor.info(for: url)
            guard info.hasVideo else { throw MediaToolError.noVideoTrack }
            let times = MediaTimeMath.stripTimes(duration: info.duration, count: count)
            let tolerance = info.duration > 0 ? info.duration / Double(count) / 2 : 0
            let frames = try await MediaFrameExtractor.frames(at: times, url: url, maxPixelSize: pixelSize, tolerance: tolerance)
            let resolved = frames.compactMap { $0 }
            guard resolved.count == count else { throw MediaToolError.frameUnavailable }
            return Self.normalized(resolved)
        }
        guard let images, !Task.isCancelled else { return nil }

        let strip = Strip(frames: images.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) })
        memory.setObject(strip, forKey: key as NSString)
        if let joined = MediaStripRenderer.horizontalStrip(images) {
            ThumbnailService.storeMediaCacheImage(joined, key: key)
        }
        return strip
    }

    private static func split(_ image: CGImage, count: Int) -> [CGImage] {
        MediaStripRenderer.split(image, count: count)
    }

    /// Frames can differ by a pixel (keyframe vs exact decode); the disk strip needs one size.
    private static func normalized(_ frames: [CGImage]) -> [CGImage] {
        guard let first = frames.first else { return frames }
        let w = first.width, h = first.height
        return frames.map { frame in
            guard frame.width != w || frame.height != h else { return frame }
            guard let context = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return frame }
            context.draw(frame, in: CGRect(x: 0, y: 0, width: w, height: h))
            return context.makeImage() ?? frame
        }
    }
}
