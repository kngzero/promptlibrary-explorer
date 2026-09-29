import CoreGraphics
import Foundation
import ImageIO

/// RGB + luminance histogram of one image (256 bins each), with clipping.
struct HistogramData: Equatable, Sendable {
    var red: [Int]
    var green: [Int]
    var blue: [Int]
    /// Rec. 709 luma of each pixel (0.2126 R + 0.7152 G + 0.0722 B), rounded.
    var luminance: [Int]
    var pixelCount: Int
    /// Pixels with any channel at 255.
    var highlightClippedCount: Int
    /// Pixels with any channel at 0.
    var shadowClippedCount: Int

    static let binCount = 256

    static var empty: HistogramData {
        HistogramData(
            red: Array(repeating: 0, count: binCount),
            green: Array(repeating: 0, count: binCount),
            blue: Array(repeating: 0, count: binCount),
            luminance: Array(repeating: 0, count: binCount),
            pixelCount: 0,
            highlightClippedCount: 0,
            shadowClippedCount: 0
        )
    }

    var highlightClippedFraction: Double {
        pixelCount > 0 ? Double(highlightClippedCount) / Double(pixelCount) : 0
    }

    var shadowClippedFraction: Double {
        pixelCount > 0 ? Double(shadowClippedCount) / Double(pixelCount) : 0
    }

    /// Clipping worth flagging: more than 0.1 % of the pixels.
    static let clippingThreshold = 0.001

    var isHighlightClipped: Bool { highlightClippedFraction > Self.clippingThreshold }
    var isShadowClipped: Bool { shadowClippedFraction > Self.clippingThreshold }

    /// The tallest bin across the channels, ignoring the two end bins (a
    /// clipped spike would flatten everything else); used to scale the plot.
    var displayPeak: Int {
        func peak(_ bins: [Int]) -> Int { bins.dropFirst().dropLast().max() ?? 0 }
        return max(peak(red), peak(green), peak(blue), peak(luminance), 1)
    }
}

enum HistogramComputer {
    /// Rec. 709 luma bin for 8-bit R G B.
    static func lumaBin(r: Int, g: Int, b: Int) -> Int {
        let value = 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
        return min(255, max(0, Int(value.rounded())))
    }

    /// Counts tightly packed 8-bit RGBA (premultiplied is fine for opaque
    /// pixels; fully transparent pixels are skipped).
    static func compute(rgba: UnsafeBufferPointer<UInt8>, width: Int, height: Int, bytesPerRow: Int) -> HistogramData {
        var red = [Int](repeating: 0, count: 256)
        var green = [Int](repeating: 0, count: 256)
        var blue = [Int](repeating: 0, count: 256)
        var luma = [Int](repeating: 0, count: 256)
        var count = 0
        var highlights = 0
        var shadows = 0
        guard width > 0, height > 0, rgba.count >= bytesPerRow * (height - 1) + width * 4 else { return .empty }
        for y in 0..<height {
            let row = y * bytesPerRow
            for x in 0..<width {
                let i = row + x * 4
                let a = Int(rgba[i + 3])
                guard a > 0 else { continue }
                var r = Int(rgba[i]), g = Int(rgba[i + 1]), b = Int(rgba[i + 2])
                if a < 255 {
                    // Un-premultiply.
                    r = min(255, r * 255 / a)
                    g = min(255, g * 255 / a)
                    b = min(255, b * 255 / a)
                }
                red[r] += 1
                green[g] += 1
                blue[b] += 1
                luma[lumaBin(r: r, g: g, b: b)] += 1
                if r == 255 || g == 255 || b == 255 { highlights += 1 }
                if r == 0 || g == 0 || b == 0 { shadows += 1 }
                count += 1
            }
        }
        return HistogramData(
            red: red, green: green, blue: blue, luminance: luma,
            pixelCount: count, highlightClippedCount: highlights, shadowClippedCount: shadows
        )
    }

    /// Draws `image` into an sRGB RGBA buffer no larger than `maxDimension`
    /// on its long edge and counts it.
    static func compute(image: CGImage, maxDimension: Int = 512) -> HistogramData {
        let longest = max(image.width, image.height)
        guard longest > 0 else { return .empty }
        let scale = min(1, Double(maxDimension) / Double(longest))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let drawn: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return .empty }
        return buffer.withUnsafeBufferPointer { compute(rgba: $0, width: width, height: height, bytesPerRow: bytesPerRow) }
    }

    /// A ~`maxDimension` px downsample of the file (ImageIO, oriented), counted.
    /// PSDs whose extra channels aren't transparency are read directly
    /// (`PSDCompositeReader`): ImageIO would hide pixels behind a saved selection.
    static func compute(fileURL: URL, maxDimension: Int = 512) -> HistogramData? {
        if let psd = computePSDComposite(fileURL: fileURL, maxDimension: maxDimension) { return psd }
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return compute(image: image, maxDimension: maxDimension)
    }

    /// nil unless the file is a PSD that ImageIO would misread.
    static func computePSDComposite(fileURL: URL, maxDimension: Int) -> HistogramData? {
        guard fileURL.pathExtension.lowercased() == "psd",
              let data = try? Data(contentsOf: fileURL, options: .alwaysMapped),
              let header = PSDCompositeReader.header(of: data), header.imageIOMisreadsExtraChannel,
              let sample = PSDCompositeReader.sampledRGBA(of: data, header: header, maxDimension: maxDimension)
        else { return nil }
        return sample.pixels.withUnsafeBufferPointer {
            compute(rgba: $0, width: sample.width, height: sample.height, bytesPerRow: sample.width * 4)
        }
    }
}

/// Histograms computed off the main actor and cached per path + modification
/// date + size (a changed file gets a new histogram).
actor HistogramService {
    static let shared = HistogramService()

    private var cache: [String: HistogramData] = [:]
    private var order: [String] = []
    private var running: [String: Task<HistogramData?, Never>] = [:]
    private let capacity: Int

    init(capacity: Int = 64) {
        self.capacity = capacity
    }

    /// Cache key for a file: path, modification date and size.
    /// (Read through FileManager: URL resource values are cached per URL.)
    nonisolated static func cacheKey(for url: URL) -> String? {
        let path = url.standardizedFileURL.path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        return "\(path)|\(mtime)|\(size)"
    }

    /// The histogram of an image file (nil when it can't be decoded).
    func histogram(forFileAt url: URL) async -> HistogramData? {
        guard let key = Self.cacheKey(for: url) else { return nil }
        return await histogram(key: key) { HistogramComputer.compute(fileURL: url) }
    }

    /// The histogram of an in-memory image (a rendered board, a .plib's
    /// image), cached under `key`.
    func histogram(for image: CGImage, key: String) async -> HistogramData? {
        await histogram(key: "image|" + key) { HistogramComputer.compute(image: image) }
    }

    func cachedHistogram(forKey key: String) -> HistogramData? { cache[key] }

    var cachedCount: Int { cache.count }

    private func histogram(key: String, compute: @escaping @Sendable () -> HistogramData?) async -> HistogramData? {
        if let cached = cache[key] { return cached }
        if let task = running[key] { return await task.value }
        let task = Task.detached(priority: .userInitiated) { compute() }
        running[key] = task
        let result = await task.value
        running[key] = nil
        if let result { store(result, key: key) }
        return result
    }

    private func store(_ data: HistogramData, key: String) {
        if cache[key] == nil { order.append(key) }
        cache[key] = data
        while order.count > capacity {
            cache[order.removeFirst()] = nil
        }
    }
}
