import AVFoundation
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Vision

/// A file the visual index should (re)compute.
struct VisualIndexCandidate: Sendable, Hashable {
    let path: String
    let folder: String
    let mtime: Double
    let size: Int64
}

/// Everything computed for one file; nil fields mean "couldn't be computed" (the row is
/// still stored so an unreadable file isn't retried until it changes).
struct VisualIndexRecord: Sendable {
    let path: String
    let folder: String
    let mtime: Double
    let size: Int64
    var sha256: String?
    var dHash: UInt64?
    var featurePrint: Data?
    var colors: [DominantColor]
    var width: Int?
    var height: Int?
    var isVideo: Bool
}

/// Pure signature computation. Nonisolated and synchronous apart from video frame
/// extraction — call it from background tasks, never the main actor.
enum VisualSignatureExtractor {
    static let thumbnailMaxPixelSize = 512

    enum FileKind: Sendable { case image, video, document }

    static func kind(ofName name: String) -> FileKind? {
        if FileHelpers.isVideoFile(name) { return .video }
        if FileHelpers.isArtOfficialDocumentFile(name) { return .document }
        if FileHelpers.isImageFile(name) { return .image }
        return nil
    }

    /// Nil only when cancelled before finishing (partial work is discarded).
    static func record(for candidate: VisualIndexCandidate) async -> VisualIndexRecord? {
        guard !Task.isCancelled else { return nil }
        let url = URL(fileURLWithPath: candidate.path)
        let kind = kind(ofName: url.lastPathComponent)
        var record = VisualIndexRecord(
            path: candidate.path, folder: candidate.folder, mtime: candidate.mtime, size: candidate.size,
            sha256: nil, dHash: nil, featurePrint: nil, colors: [], width: nil, height: nil,
            isVideo: kind == .video
        )
        guard let kind else { return record }

        record.sha256 = sha256(of: url)
        guard !Task.isCancelled else { return nil }

        let frame: Frame?
        switch kind {
        case .image: frame = imageFrame(url: url)
        case .video: frame = await videoFrame(url: url)
        case .document: frame = documentFrame(url: url)
        }
        guard !Task.isCancelled else { return nil }
        guard let frame else { return record }
        record.width = frame.pixelWidth
        record.height = frame.pixelHeight
        apply(image: frame.image, to: &record)
        return record
    }

    /// dHash, colours and feature print from an already-decoded frame.
    static func apply(image: CGImage, to record: inout VisualIndexRecord) {
        autoreleasepool {
            record.dHash = dHash(image)
            record.colors = dominantColors(image)
            record.featurePrint = featurePrint(image)
        }
    }

    // MARK: Hash

    /// Streaming SHA-256 (1 MB reads), so huge videos never sit in memory.
    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            if Task.isCancelled { return nil }
            let chunk: Data? = autoreleasepool { try? handle.read(upToCount: 1 << 20) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Frames

    struct Frame {
        let image: CGImage
        let pixelWidth: Int?
        let pixelHeight: Int?
    }

    static func imageFrame(url: URL) -> Frame? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0
        else { return nil }
        var width: Int?
        var height: Int?
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
            height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
            if let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, (5...8).contains(orientation) {
                swap(&width, &height)
            }
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return Frame(image: image, pixelWidth: width, pixelHeight: height)
    }

    /// The frame at the middle of the clip; the first frame for clips under a second.
    static func videoFrame(url: URL) async -> Frame? {
        let asset = AVURLAsset(url: url)
        let seconds = (try? await asset.load(.duration))?.seconds ?? 0
        var width: Int?
        var height: Int?
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let (naturalSize, transform) = try? await track.load(.naturalSize, .preferredTransform)
        {
            let size = naturalSize.applying(transform)
            width = Int(abs(size.width).rounded())
            height = Int(abs(size.height).rounded())
        }
        let time = seconds.isFinite && seconds >= 1
            ? CMTime(seconds: seconds / 2, preferredTimescale: 600)
            : .zero
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: thumbnailMaxPixelSize, height: thumbnailMaxPixelSize)
        let tolerance = time == .zero ? CMTime.zero : CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        guard let image = try? await generator.image(at: time).image else { return nil }
        return Frame(image: image, pixelWidth: width ?? image.width, pixelHeight: height ?? image.height)
    }

    /// Mood board render / Story contact sheet.
    static func documentFrame(url: URL) -> Frame? {
        autoreleasepool {
            guard let document = ArtOfficialDocument.read(from: url),
                  let image = ArtOfficialRendering.overview(of: document, maxPixelSize: thumbnailMaxPixelSize)
            else { return nil }
            return Frame(image: image, pixelWidth: nil, pixelHeight: nil)
        }
    }

    // MARK: dHash

    /// 64-bit difference hash: the image is box-filtered to a 9×8 grayscale grid (drawn
    /// at 72×64 first, over white, so resampling doesn't alias), and bit (row, col) is
    /// set when cell (row, col) is brighter than its right-hand neighbour. Bit 63 is
    /// the top-left comparison.
    static func dHash(_ image: CGImage) -> UInt64? {
        let width = 72, height = 64
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height)

        var cells = [Int](repeating: 0, count: 9 * 8)
        for y in 0..<height {
            let row = y / 8
            for x in 0..<width {
                cells[row * 9 + x / 8] += Int(pixels[y * width + x])
            }
        }
        var hash: UInt64 = 0
        for row in 0..<8 {
            for col in 0..<8 {
                hash <<= 1
                if cells[row * 9 + col] > cells[row * 9 + col + 1] { hash |= 1 }
            }
        }
        return hash
    }

    // MARK: Colours

    /// Up to five dominant colours from a 32×32 sRGB downsample, clustered in OKLab.
    /// Mostly transparent pixels are ignored.
    static func dominantColors(_ image: CGImage) -> [DominantColor] {
        oklabSamples(image).map { VisualPalette.dominantColors(samples: $0) } ?? []
    }

    static func oklabSamples(_ image: CGImage, side: Int = 32) -> [OKLab]? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var samples: [OKLab] = []
        samples.reserveCapacity(side * side)
        for index in 0..<(side * side) {
            let alpha = Double(pixels[index * 4 + 3])
            guard alpha >= 128 else { continue }
            let scale = 255 / alpha
            samples.append(OKLab(
                red: min(255, Double(pixels[index * 4]) * scale),
                green: min(255, Double(pixels[index * 4 + 1]) * scale),
                blue: min(255, Double(pixels[index * 4 + 2]) * scale)
            ))
        }
        return samples
    }

    // MARK: Feature print

    /// Side of the square the image is resampled to before the feature print. Feeding
    /// Vision one fixed input size makes prints of the same picture at different
    /// resolutions far more consistent (resize-only distances drop ~5×).
    static let featurePrintInputSide = 224

    /// Vision feature print (latest revision) as its raw Float32 vector — distance is
    /// the Euclidean distance `VNFeaturePrintObservation.computeDistance` computes.
    static func featurePrint(_ image: CGImage) -> Data? {
        guard let observation = featurePrintObservation(image), let vector = vector(of: observation) else { return nil }
        return vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func featurePrintObservation(_ image: CGImage) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = featurePrintRevision
        let input = squareResample(image, side: featurePrintInputSide) ?? image
        let handler = VNImageRequestHandler(cgImage: input, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        return request.results?.first
    }

    /// Stored with the index; prints from another revision aren't comparable.
    static let featurePrintRevision = VNGenerateImageFeaturePrintRequest.currentRevision

    private static func squareResample(_ image: CGImage, side: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()
    }

    /// Raw Float32 vector stored by `featurePrint`.
    static func vector(from data: Data) -> [Float]? {
        let count = data.count / MemoryLayout<Float>.size
        guard count > 0 else { return nil }
        return data.withUnsafeBytes { raw in
            [Float](unsafeUninitializedCapacity: count) { buffer, initialized in
                _ = raw.copyBytes(to: buffer)
                initialized = count
            }
        }
    }

    static func vector(of observation: VNFeaturePrintObservation) -> [Float]? {
        let count = observation.elementCount
        guard count > 0 else { return nil }
        switch observation.elementType {
        case .float:
            return observation.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self).prefix(count)) }
        case .double:
            return observation.data.withUnsafeBytes { $0.bindMemory(to: Double.self).prefix(count).map { Float($0) } }
        default:
            return nil
        }
    }
}
