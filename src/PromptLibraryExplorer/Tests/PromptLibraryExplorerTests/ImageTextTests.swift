import AppKit
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PromptLibraryExplorer

final class ImageTextTests: TempDirectoryTestCase {
    /// White bitmap with black `text` drawn by CoreText.
    private func renderedTextImage(_ text: String, width: Int = 1200, height: Int = 400, fontSize: CGFloat = 120) -> CGImage {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = CGPoint(x: 60, y: CGFloat(height) / 2 - fontSize / 3)
        CTLineDraw(line, context)
        return context.makeImage()!
    }

    private func writePNG(_ image: CGImage, name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    // MARK: Vision OCR

    func testRecognisesRenderedText() throws {
        let url = try writePNG(renderedTextImage("HELLO WORLD"), name: "sign.png")
        let result = try XCTUnwrap(ImageTextRecognizer.analyze(url: url, recognizeText: true, classify: false))
        let text = try XCTUnwrap(result.text)
        XCTAssertTrue(text.uppercased().contains("HELLO"), "recognised: \(text)")
        XCTAssertNil(result.labels, "classification didn't run")
    }

    func testClassificationRunsOnRequest() throws {
        let url = try writePNG(renderedTextImage("TEST"), name: "cls.png")
        let result = try XCTUnwrap(ImageTextRecognizer.analyze(url: url, recognizeText: false, classify: true))
        XCTAssertNil(result.text)
        let labels = try XCTUnwrap(result.labels)
        XCTAssertLessThanOrEqual(labels.count, ImageTextRecognizer.storedLabelLimit)
        XCTAssertEqual(labels, labels.sorted { $0.confidence >= $1.confidence })
    }

    func testCleanedTextFiltersNoise() {
        let text = ImageTextRecognizer.cleanedText([
            ("  OPEN   LATE ", 0.9),
            ("open late", 0.8),        // duplicate (case-insensitive)
            ("~ ~", 0.9),              // no letters or digits
            ("x", 0.95),               // too short
            ("gibberish", 0.2),        // not confident
            ("Café 24", 0.6),
        ])
        XCTAssertEqual(text, "OPEN LATE\nCafé 24")
    }

    func testImageTextSearchMatchesEveryWord() {
        XCTAssertTrue(ImageTextSearch.matches("GRAND OPENING\nCafé Noir", query: "cafe grand"))
        XCTAssertFalse(ImageTextSearch.matches("GRAND OPENING", query: "grand closing"))
        XCTAssertFalse(ImageTextSearch.matches("anything", query: "   "))
    }

    // MARK: Store (mock analyser)

    private func makeService(calls: CallCounter) -> ImageTextService {
        ImageTextService(databaseURL: tempDir.appendingPathComponent("db/image-text.sqlite")) { url, options in
            calls.increment()
            let name = url.deletingPathExtension().lastPathComponent
            return ImageAnalysisResult(
                text: options.recognizeText ? (name.hasPrefix("sign") ? "SALE \(name)" : "") : nil,
                labels: options.classify ? [ImageLabel(identifier: "cat", confidence: 0.9)] : nil
            )
        }
    }

    func testAnalyzesLibraryIncrementallyAndFollowsMoves() async throws {
        let library = tempDir.appendingPathComponent("lib", isDirectory: true)
        try writeFile("lib/sign-a.png", PNGFixture.basePNG())
        try writeFile("lib/photo.png", PNGFixture.basePNG())
        try writeFile("lib/sub/sign-b.png", PNGFixture.basePNG())
        try writeFile("lib/notes.txt", Data("not an image".utf8))
        let calls = CallCounter()
        let service = makeService(calls: calls)

        let finished = await service.analyzeLibrary(root: library, options: ImageTextOptions())
        XCTAssertTrue(finished)
        XCTAssertEqual(calls.value, 3, "images only")
        let libPath = library.path
        let texts = await service.texts(inFolder: libPath)
        XCTAssertEqual(texts, ["\(libPath)/sign-a.png": "SALE sign-a"], "files without text aren't listed")
        let record = await service.record(forPath: "\(libPath)/photo.png")
        XCTAssertEqual(record?.text, "")
        XCTAssertEqual(record?.labels, [ImageLabel(identifier: "cat", confidence: 0.9)])

        _ = await service.analyzeLibrary(root: library, options: ImageTextOptions())
        XCTAssertEqual(calls.value, 3, "unchanged files are skipped")

        // Turning a part off and on: rows keep what they had, nothing is redone needlessly.
        _ = await service.analyzeLibrary(root: library, options: ImageTextOptions(recognizeText: true, classify: false))
        XCTAssertEqual(calls.value, 3)

        let old = "\(libPath)/sign-a.png", new = "\(libPath)/sub/sign-a-moved.png"
        try FileManager.default.moveItem(atPath: old, toPath: new)
        await service.movePath(from: old, to: new)
        let moved = await service.texts(forPaths: [new, old])
        XCTAssertEqual(moved, [new: "SALE sign-a"], "rows follow a move without re-analysis")
        XCTAssertEqual(calls.value, 3)

        await service.removeEntries(under: "\(libPath)/sub")
        let removed = await service.record(forPath: new)
        XCTAssertNil(removed)
        let stats = await service.stats(under: library)
        XCTAssertEqual(stats.analyzed, 1)
    }

    func testStoresTextHookAndRespectsCancellation() async throws {
        try writeFile("lib/sign-1.png", PNGFixture.basePNG())
        let calls = CallCounter()
        let service = makeService(calls: calls)
        let stored = PathCollector()
        await service.setOnTextStored { paths in stored.add(paths) }
        let records = await service.analyze(paths: [tempDir.appendingPathComponent("lib/sign-1.png").path], options: ImageTextOptions())
        XCTAssertEqual(records.values.first?.text, "SALE sign-1")
        XCTAssertEqual(stored.paths.count, 1, "the library index is told about stored text")

        let task = Task { await service.analyzeLibrary(root: tempDir.appendingPathComponent("lib"), options: ImageTextOptions()) }
        task.cancel()
        _ = await task.value   // must return promptly, whatever it managed
    }
}

/// Thread-safe counter for the mock analyser.
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}

final class PathCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var paths: [String] { lock.lock(); defer { lock.unlock() }; return stored }
    func add(_ paths: [String]) { lock.lock(); stored += paths; lock.unlock() }
}
