import CoreGraphics
import Foundation

/// Palette helpers for mood boards.
public enum MoodboardPalette {
    /// Web/Mac "Default" preset.
    public static let defaultPalette: [String] = ["#FFFFFF", "#F3F4F6", "#E5E7EB", "#D1D5DB", "#9CA3AF", "#6B7280", "#1F2937"]

    /// Extracts up to `count` dominant colours (deterministic k-means on a 32x32
    /// downsample of each image, farthest-point seeding). Result is `#RRGGBB`,
    /// ordered light -> dark like the built-in presets. Empty when there are no pixels.
    public static func extract(from images: [CGImage], count: Int) -> [String] {
        let k = max(1, min(count, 16))
        var pixels: [SIMD3<Double>] = []
        for image in images.prefix(24) {
            pixels.append(contentsOf: samplePixels(image, side: 32))
        }
        guard !pixels.isEmpty else { return [] }

        // Farthest-point seeding from the mean-nearest pixel -> deterministic.
        var mean = SIMD3<Double>(0, 0, 0)
        for p in pixels { mean += p }
        mean /= Double(pixels.count)
        var centers: [SIMD3<Double>] = [pixels.min { dist($0, mean) < dist($1, mean) }!]
        var nearest = pixels.map { dist($0, centers[0]) }
        while centers.count < k {
            guard let (idx, d) = nearest.enumerated().max(by: { $0.element < $1.element }).map({ ($0.offset, $0.element) }),
                  d > 1e-6 else { break }
            centers.append(pixels[idx])
            for i in pixels.indices { nearest[i] = min(nearest[i], dist(pixels[i], pixels[idx])) }
        }

        var assignment = [Int](repeating: 0, count: pixels.count)
        for _ in 0..<12 {
            var changed = false
            for i in pixels.indices {
                var best = 0
                var bestD = Double.greatestFiniteMagnitude
                for (c, center) in centers.enumerated() {
                    let d = dist(pixels[i], center)
                    if d < bestD { bestD = d; best = c }
                }
                if assignment[i] != best { assignment[i] = best; changed = true }
            }
            var sums = [SIMD3<Double>](repeating: .zero, count: centers.count)
            var counts = [Int](repeating: 0, count: centers.count)
            for i in pixels.indices { sums[assignment[i]] += pixels[i]; counts[assignment[i]] += 1 }
            for c in centers.indices where counts[c] > 0 { centers[c] = sums[c] / Double(counts[c]) }
            if !changed { break }
        }
        var counts = [Int](repeating: 0, count: centers.count)
        for a in assignment { counts[a] += 1 }

        var seen = Set<String>()
        return centers.indices
            .filter { counts[$0] > 0 }
            .sorted { luminance(centers[$0]) > luminance(centers[$1]) }
            .map { Hex.string(r: centers[$0].x, g: centers[$0].y, b: centers[$0].z) }
            .filter { seen.insert($0).inserted }
    }

    static func samplePixels(_ image: CGImage, side: Int) -> [SIMD3<Double>] {
        guard image.width > 0, image.height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = ctx.data else { return [] }
        let buf = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var out: [SIMD3<Double>] = []
        out.reserveCapacity(side * side)
        for i in 0..<(side * side) {
            let a = Double(buf[i * 4 + 3]) / 255
            guard a > 0.5 else { continue }   // skip transparent pixels
            out.append(SIMD3(Double(buf[i * 4]) / 255 / a, Double(buf[i * 4 + 1]) / 255 / a, Double(buf[i * 4 + 2]) / 255 / a))
        }
        return out
    }

    private static func dist(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        let d = a - b
        return (d * d).sum()
    }

    static func luminance(_ c: SIMD3<Double>) -> Double {
        0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
    }
}
