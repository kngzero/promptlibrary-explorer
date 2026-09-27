import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Streams frames into an animated GIF with ImageIO.
final class MediaGIFWriter {
    let url: URL
    private let destination: CGImageDestination
    private let frameProperties: CFDictionary
    private(set) var frameCount = 0

    /// `loopCount` 0 loops forever; 1 plays once.
    init(url: URL, expectedFrameCount: Int, delay: Double, loopCount: Int) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, max(expectedFrameCount, 1), nil
        ) else { throw MediaToolError.writeFailed(url.lastPathComponent) }
        self.url = url
        self.destination = destination
        let fileProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: max(loopCount, 0)],
        ]
        CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)
        frameProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay,
                kCGImagePropertyGIFUnclampedDelayTime: delay,
            ],
        ] as CFDictionary
    }

    func add(_ image: CGImage) {
        CGImageDestinationAddImage(destination, image, frameProperties)
        frameCount += 1
    }

    func finalize() throws {
        guard frameCount > 0, CGImageDestinationFinalize(destination) else {
            throw MediaToolError.writeFailed(url.lastPathComponent)
        }
    }
}

/// Options for a clip export.
struct MediaClipExportOptions: Equatable {
    enum Format: String, CaseIterable, Identifiable {
        case h264, hevc, gif
        var id: String { rawValue }
        var title: String {
            switch self {
            case .h264: return "MP4 (H.264)"
            case .hevc: return "MP4 (HEVC)"
            case .gif: return "Animated GIF"
            }
        }
        var fileExtension: String { self == .gif ? "gif" : "mp4" }
        var contentType: UTType { self == .gif ? .gif : .mpeg4Movie }
    }

    var format: Format = .h264
    /// GIF only.
    var gifFPS: Int = 12
    var gifMaxWidth: Int = 480
    var gifLoops: Bool = true

    static let gifFPSRange = 5...30
    static let gifWidths = [240, 320, 480, 640, 800, 1080]
}

/// Trims clips (MP4 via AVAssetExportSession, GIF via AVAssetImageGenerator + ImageIO).
/// Writes to a temporary sibling first and moves it into place, so a failed or cancelled
/// export leaves nothing behind, and never writes over the source.
enum MediaClipExporter {
    /// The export preset: passthrough (no re-encode) when the source codec already matches
    /// and the preset is compatible with MP4, otherwise a re-encode to the chosen codec.
    static func preset(for format: MediaClipExportOptions.Format, sourceCodec: FourCharCode, passthroughCompatible: Bool) -> String {
        let matches = (format == .h264 && sourceCodec == kCMVideoCodecType_H264)
            || (format == .hevc && sourceCodec == kCMVideoCodecType_HEVC)
        if matches, passthroughCompatible { return AVAssetExportPresetPassthrough }
        return format == .hevc ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
    }

    /// Exports `range` of `source` to `destination`. `progress` gets 0…1 on the main actor.
    /// Returns true when the export was a passthrough (no re-encode).
    @discardableResult
    static func export(
        source: URL,
        range: MediaTrimRange,
        options: MediaClipExportOptions,
        to destination: URL,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> Bool {
        guard !MediaExportNaming.isSameFile(destination, source) else { throw MediaToolError.wouldOverwriteSource }
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString)-partial.\(options.format.fileExtension)")
        defer { try? FileManager.default.removeItem(at: temp) }

        let passthrough: Bool
        if options.format == .gif {
            try await exportGIF(source: source, range: range, options: options, to: temp, progress: progress)
            passthrough = false
        } else {
            passthrough = try await exportMovie(source: source, range: range, format: options.format, to: temp, progress: progress)
        }
        try Task.checkCancellation()
        guard !MediaExportNaming.isSameFile(destination, source) else { throw MediaToolError.wouldOverwriteSource }
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            // Only reached when the user confirmed Replace in a save panel.
            _ = try fm.replaceItemAt(destination, withItemAt: temp)
        } else {
            try fm.moveItem(at: temp, to: destination)
        }
        await progress(1)
        return passthrough
    }

    // MARK: MP4

    private final class SessionBox: @unchecked Sendable {
        let session: AVAssetExportSession
        init(_ session: AVAssetExportSession) { self.session = session }
    }

    private static func exportMovie(
        source: URL,
        range: MediaTrimRange,
        format: MediaClipExportOptions.Format,
        to temp: URL,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> Bool {
        let asset = AVURLAsset(url: source)
        let info = try await MediaFrameExtractor.info(for: source)
        guard info.hasVideo else { throw MediaToolError.noVideoTrack }
        let passthroughOK = await AVAssetExportSession.compatibility(
            ofExportPreset: AVAssetExportPresetPassthrough, with: asset, outputFileType: .mp4
        )
        var presetName = preset(for: format, sourceCodec: info.codec, passthroughCompatible: passthroughOK)
        if presetName != AVAssetExportPresetPassthrough {
            let compatible = await AVAssetExportSession.compatibility(ofExportPreset: presetName, with: asset, outputFileType: .mp4)
            if !compatible, format == .hevc {
                presetName = AVAssetExportPresetHighestQuality   // no HEVC encoder: fall back to H.264
            }
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: presetName) else {
            throw MediaToolError.exportFailed("This clip can't be exported as MP4.")
        }
        session.outputURL = temp
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        if !range.isFullClip {
            session.timeRange = range.timeRange
        }
        let box = SessionBox(session)

        try await withTaskCancellationHandler {
            let poll = Task.detached(priority: .utility) {
                while !Task.isCancelled {
                    let value = Double(box.session.progress)
                    await progress(value * 0.98)
                    try? await Task.sleep(nanoseconds: 150_000_000)
                }
            }
            defer { poll.cancel() }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                box.session.exportAsynchronously { continuation.resume() }
            }
            switch box.session.status {
            case .completed:
                return
            case .cancelled:
                throw MediaToolError.cancelled
            default:
                throw MediaToolError.exportFailed(box.session.error?.localizedDescription ?? "The export failed.")
            }
        } onCancel: {
            box.session.cancelExport()
        }
        return presetName == AVAssetExportPresetPassthrough
    }

    // MARK: GIF

    /// Pixel size for GIF frames: at most `maxWidth` wide, never upscaled, even dimensions.
    static func gifFrameSize(natural: CGSize, maxWidth: Int) -> CGSize {
        guard natural.width > 0, natural.height > 0 else { return CGSize(width: maxWidth, height: maxWidth) }
        let width = min(CGFloat(maxWidth), natural.width)
        let height = (natural.height * width / natural.width).rounded()
        return CGSize(width: width.rounded(), height: max(height, 1))
    }

    static func exportGIF(
        source: URL,
        range: MediaTrimRange,
        options: MediaClipExportOptions,
        to url: URL,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws {
        let info = try await MediaFrameExtractor.info(for: source)
        guard info.hasVideo else { throw MediaToolError.noVideoTrack }
        let fps = min(max(options.gifFPS, MediaClipExportOptions.gifFPSRange.lowerBound), MediaClipExportOptions.gifFPSRange.upperBound)
        let times = MediaTimeMath.gifFrameTimes(start: range.start, length: range.length, fps: fps)
        let delay = range.length > 0 ? range.length / Double(times.count) : 1.0 / Double(fps)
        let size = gifFrameSize(natural: info.naturalSize, maxWidth: options.gifMaxWidth)

        let work = Task.detached(priority: .userInitiated) {
            let writer = try MediaGIFWriter(url: url, expectedFrameCount: times.count, delay: delay, loopCount: options.gifLoops ? 0 : 1)
            let asset = AVURLAsset(url: source)
            // Half a frame of tolerance: exact enough, much faster than zero tolerance.
            let generator = MediaFrameExtractor.generator(
                for: asset,
                maximumSize: size,
                tolerance: CMTime(seconds: 0.5 / Double(fps), preferredTimescale: 600)
            )
            let cmTimes = times.map { CMTime(seconds: MediaFrameExtractor.clampedTime($0, duration: info.duration), preferredTimescale: 600) }
            var last: CGImage?
            var missingLeading = 0
            var done = 0
            for await result in generator.images(for: cmTimes) {
                try Task.checkCancellation()
                if let image = try? result.image { last = image }
                if let frame = last {
                    // Frames that failed before the first good one repeat it, so the
                    // GIF always has one frame per requested time.
                    for _ in 0...missingLeading { writer.add(frame) }
                    missingLeading = 0
                } else {
                    missingLeading += 1
                }
                done += 1
                if done % 4 == 0 { await progress(Double(done) / Double(times.count) * 0.95) }
            }
            try Task.checkCancellation()
            if writer.frameCount == 0 {
                let single = try await MediaFrameExtractor.frame(at: range.start, url: source, maxPixelSize: max(size.width, size.height))
                writer.add(single)
            }
            try writer.finalize()
        }
        try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }
}
