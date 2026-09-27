import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PromptLibraryExplorer

// Histogram computation on synthetic images (known bins), clipping, and the
// path + mtime cache. Temp files only.

final class HistogramTests: XCTestCase {
    /// An opaque sRGB image filled per pixel by `color(x, y)`.
    private func makeImage(width: Int, height: Int, color: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
        var data = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = color(x, y)
                let i = (y * width + x) * 4
                data[i] = r
                data[i + 1] = g
                data[i + 2] = b
                data[i + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(data) as CFData)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    func testSolidRedFillsKnownBins() {
        let image = makeImage(width: 10, height: 10) { _, _ in (255, 0, 0) }
        let data = HistogramComputer.compute(image: image)
        XCTAssertEqual(data.pixelCount, 100)
        XCTAssertEqual(data.red[255], 100)
        XCTAssertEqual(data.green[0], 100)
        XCTAssertEqual(data.blue[0], 100)
        XCTAssertEqual(data.red.reduce(0, +), 100)
        // Rec. 709: 0.2126 × 255 = 54.2 → bin 54.
        XCTAssertEqual(data.luminance[54], 100)
        XCTAssertEqual(data.luminance.reduce(0, +), 100)
        // Pure red is clipped at both ends (R at 255, G and B at 0).
        XCTAssertEqual(data.highlightClippedCount, 100)
        XCTAssertEqual(data.shadowClippedCount, 100)
        XCTAssertTrue(data.isHighlightClipped)
        XCTAssertTrue(data.isShadowClipped)
    }

    func testGrayRampHasOnePixelPerBin() {
        let image = makeImage(width: 256, height: 1) { x, _ in (UInt8(x), UInt8(x), UInt8(x)) }
        let data = HistogramComputer.compute(image: image)
        XCTAssertEqual(data.pixelCount, 256)
        for bin in 0..<256 {
            XCTAssertEqual(data.red[bin], 1, "red bin \(bin)")
            XCTAssertEqual(data.green[bin], 1, "green bin \(bin)")
            XCTAssertEqual(data.blue[bin], 1, "blue bin \(bin)")
            XCTAssertEqual(data.luminance[bin], 1, "luma of a gray equals its value (bin \(bin))")
        }
        XCTAssertEqual(data.highlightClippedCount, 1)
        XCTAssertEqual(data.shadowClippedCount, 1)
        XCTAssertEqual(data.highlightClippedFraction, 1.0 / 256, accuracy: 1e-9)
    }

    func testMidGrayIsNotClipped() {
        let image = makeImage(width: 8, height: 8) { _, _ in (128, 128, 128) }
        let data = HistogramComputer.compute(image: image)
        XCTAssertEqual(data.luminance[128], 64)
        XCTAssertFalse(data.isHighlightClipped)
        XCTAssertFalse(data.isShadowClipped)
        XCTAssertEqual(data.highlightClippedFraction, 0)
    }

    func testHalfWhiteHalfBlackSplitsIntoEndBins() {
        let image = makeImage(width: 4, height: 2) { x, _ in x < 2 ? (0, 0, 0) : (255, 255, 255) }
        let data = HistogramComputer.compute(image: image)
        XCTAssertEqual(data.luminance[0], 4)
        XCTAssertEqual(data.luminance[255], 4)
        XCTAssertEqual(data.highlightClippedFraction, 0.5, accuracy: 1e-9)
        XCTAssertEqual(data.shadowClippedFraction, 0.5, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(data.displayPeak, 1, "end bins are ignored for scaling, never zero")
    }

    func testLargeImagesAreDownsampledToAbout512() {
        let image = makeImage(width: 2048, height: 1024) { _, _ in (10, 200, 30) }
        let data = HistogramComputer.compute(image: image, maxDimension: 512)
        XCTAssertEqual(data.pixelCount, 512 * 256)
        XCTAssertEqual(data.green[200], 512 * 256)
    }

    func testLumaBin() {
        XCTAssertEqual(HistogramComputer.lumaBin(r: 0, g: 255, b: 0), 182)  // 0.7152 × 255 = 182.4
        XCTAssertEqual(HistogramComputer.lumaBin(r: 0, g: 0, b: 255), 18)   // 0.0722 × 255 = 18.4
        XCTAssertEqual(HistogramComputer.lumaBin(r: 255, g: 255, b: 255), 255)
    }

    // MARK: File cache (path + mtime)

    private func writePNG(_ image: CGImage, to url: URL) throws {
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    func testFileHistogramIsCachedPerModificationDate() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("HistogramTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("swatch.png")
        try writePNG(makeImage(width: 16, height: 16) { _, _ in (255, 255, 255) }, to: url)

        let service = HistogramService(capacity: 8)
        let firstResult = await service.histogram(forFileAt: url)
        let first = try XCTUnwrap(firstResult)
        XCTAssertEqual(first.luminance[255], 256)
        let keyBefore = try XCTUnwrap(HistogramService.cacheKey(for: url))
        let cached = await service.cachedHistogram(forKey: keyBefore)
        XCTAssertEqual(cached, first)

        // Rewrite the file (black) with a later modification date: a new key, a new histogram.
        try writePNG(makeImage(width: 16, height: 16) { _, _ in (0, 0, 0) }, to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: url.path)
        let keyAfter = try XCTUnwrap(HistogramService.cacheKey(for: url))
        XCTAssertNotEqual(keyBefore, keyAfter)
        let secondResult = await service.histogram(forFileAt: url)
        let second = try XCTUnwrap(secondResult)
        XCTAssertEqual(second.luminance[0], 256)
        let count = await service.cachedCount
        XCTAssertEqual(count, 2)
    }

    func testCacheIsBounded() async {
        let service = HistogramService(capacity: 2)
        let image = makeImage(width: 2, height: 2) { _, _ in (1, 2, 3) }
        for index in 0..<5 {
            _ = await service.histogram(for: image, key: "k\(index)")
        }
        let count = await service.cachedCount
        XCTAssertEqual(count, 2)
        let oldest = await service.cachedHistogram(forKey: "image|k0")
        XCTAssertNil(oldest)
        let newest = await service.cachedHistogram(forKey: "image|k4")
        XCTAssertNotNil(newest)
    }
}
