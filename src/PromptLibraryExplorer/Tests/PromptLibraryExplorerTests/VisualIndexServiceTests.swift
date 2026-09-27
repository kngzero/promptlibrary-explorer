import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Vision
import XCTest
@testable import PromptLibraryExplorer

// MARK: - Fixtures

enum VisualFixture {
    /// Deterministic "scene": a two-colour gradient with a scatter of shapes, so it has
    /// real structure for dHash and the Vision feature print.
    static func scene(seed: UInt64, width: Int, height: Int) -> CGImage {
        var rng = SplitMix64(seed: seed)
        func unit() -> CGFloat { CGFloat(Double(rng.next() >> 11) / Double(1 << 53)) }
        func colour() -> CGColor { CGColor(srgbRed: unit(), green: unit(), blue: unit(), alpha: 1) }
        let context = makeContext(width: width, height: height)
        let w = CGFloat(width), h = CGFloat(height)
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [colour(), colour()] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: w * unit(), y: h), options: [])
        for index in 0..<14 {
            context.setFillColor(colour())
            let rect = CGRect(x: unit() * w * 0.8, y: unit() * h * 0.8, width: (0.1 + unit() * 0.35) * w, height: (0.1 + unit() * 0.35) * h)
            if index.isMultiple(of: 2) { context.fillEllipse(in: rect) } else { context.fill(rect) }
        }
        return context.makeImage()!
    }

    static func solid(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, width: Int = 64, height: Int = 64) -> CGImage {
        let context = makeContext(width: width, height: height)
        context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// Left half one colour, right half another.
    static func split(left: CGColor, right: CGColor, width: Int = 128, height: Int = 64) -> CGImage {
        let context = makeContext(width: width, height: height)
        context.setFillColor(left)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(right)
        context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        return context.makeImage()!
    }

    static func resized(_ image: CGImage, width: Int, height: Int) -> CGImage {
        let context = makeContext(width: width, height: height)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    static func png(_ image: CGImage) -> Data { encode(image, type: .png, options: [:]) }

    static func jpeg(_ image: CGImage, quality: Double = 0.75) -> Data {
        encode(image, type: .jpeg, options: [kCGImageDestinationLossyCompressionQuality: quality])
    }

    private static func encode(_ image: CGImage, type: UTType, options: [CFString: Any]) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    private static func makeContext(width: Int, height: Int) -> CGContext {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
    }
}

/// Thread-safe box for callbacks in tests.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
    func mutate(_ body: (inout Value) -> Void) { lock.lock(); body(&storage); lock.unlock() }
}

class VisualIndexTestCase: TempDirectoryTestCase {
    var library: URL!
    var service: VisualIndexService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        library = tempDir.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        service = VisualIndexService(databaseURL: tempDir.appendingPathComponent("db/visual-index.sqlite"))
    }

    override func tearDownWithError() throws {
        service = nil
        library = nil
        try super.tearDownWithError()
    }

    @discardableResult
    func put(_ relativePath: String, _ data: Data) throws -> String {
        let url = library.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url.path
    }

    func path(_ relativePath: String) -> String {
        library.appendingPathComponent(relativePath).path
    }
}

// MARK: - Tests

final class VisualIndexServiceTests: VisualIndexTestCase {

    func testDHashIsStableUnderResizeAndReencode() throws {
        let original = VisualFixture.scene(seed: 1, width: 1024, height: 768)
        let pngURL = URL(fileURLWithPath: try put("a.png", VisualFixture.png(original)))
        let jpegURL = URL(fileURLWithPath: try put("a_small.jpg", VisualFixture.jpeg(VisualFixture.resized(original, width: 400, height: 300), quality: 0.6)))
        let otherURL = URL(fileURLWithPath: try put("b.png", VisualFixture.png(VisualFixture.scene(seed: 2, width: 1024, height: 768))))

        func hash(_ url: URL) throws -> UInt64 {
            let frame = try XCTUnwrap(VisualSignatureExtractor.imageFrame(url: url))
            return try XCTUnwrap(VisualSignatureExtractor.dHash(frame.image))
        }
        let a = try hash(pngURL), resized = try hash(jpegURL), other = try hash(otherURL)
        XCTAssertLessThanOrEqual((a ^ resized).nonzeroBitCount, 4, "resize + JPEG re-encode should barely move the dHash")
        XCTAssertGreaterThanOrEqual((a ^ other).nonzeroBitCount, 12, "a different image should be far away")
        XCTAssertEqual(try hash(pngURL), a, "hashing is deterministic")
    }

    func testFeaturePrintDistanceMatchesVision() throws {
        let a = VisualFixture.scene(seed: 11, width: 512, height: 384)
        let b = VisualFixture.scene(seed: 12, width: 512, height: 384)
        let obsA = try XCTUnwrap(VisualSignatureExtractor.featurePrintObservation(a))
        let obsB = try XCTUnwrap(VisualSignatureExtractor.featurePrintObservation(b))
        var vision: Float = 0
        try obsA.computeDistance(&vision, to: obsB)
        let ours = VisualVectorMath.distance(
            try XCTUnwrap(VisualSignatureExtractor.vector(from: XCTUnwrap(VisualSignatureExtractor.featurePrint(a)))),
            try XCTUnwrap(VisualSignatureExtractor.vector(from: XCTUnwrap(VisualSignatureExtractor.featurePrint(b))))
        )
        XCTAssertEqual(ours, vision, accuracy: max(0.001, vision * 0.001))
    }

    func testColorJSONRoundTrip() {
        let colors = [DominantColor(hex: "#FF0000", weight: 0.5), DominantColor(hex: "#0A0B0C", weight: 0.125)]
        let text = VisualIndexService.encodeColors(colors)
        XCTAssertEqual(text, ##"[{"hex":"#FF0000","weight":0.500},{"hex":"#0A0B0C","weight":0.125}]"##)
        XCTAssertEqual(VisualIndexService.decodeColors(text), colors)
        XCTAssertEqual(VisualIndexService.decodeColors(##"[ {"weight": 0.25, "hex": "#123456"} ]"##), [DominantColor(hex: "#123456", weight: 0.25)], "any JSON key order")
        XCTAssertEqual(VisualIndexService.decodeColors("[]"), [])
        XCTAssertEqual(OKLab(hex: "#f00")?.hex, "#FF0000")
        XCTAssertEqual(OKLab(hex: " 00ff00 ")?.hex, "#00FF00")
        XCTAssertNil(OKLab(hex: "#12345"))
        XCTAssertNil(OKLab(hex: "red"))
        XCTAssertNil(OKLab(hex: "12#3456"))
    }

    func testExactAndVisualSetDetection() async throws {
        let scene = VisualFixture.scene(seed: 3, width: 900, height: 600)
        let pngData = VisualFixture.png(scene)
        try put("a.png", pngData)
        try put("a copy.png", pngData)                                     // identical bytes
        try put("a.jpg", VisualFixture.jpeg(scene))                         // re-encoded
        try put("a_small.png", VisualFixture.png(VisualFixture.resized(scene, width: 450, height: 300)))
        try put("b.png", VisualFixture.png(VisualFixture.scene(seed: 4, width: 900, height: 600)))
        try put("c.png", VisualFixture.png(VisualFixture.scene(seed: 5, width: 900, height: 600)))
        try put("notes.txt", Data("not media".utf8))

        let finished = await service.indexLibrary(root: library)
        XCTAssertTrue(finished)
        let stats = await service.stats(under: library)
        XCTAssertEqual(stats.indexed, 6, "text files are skipped")
        XCTAssertEqual(stats.total, 6)

        let sets = await service.similarSets(in: .folder(library), strictness: 0.5, includeVideos: true)
        let exact = sets.filter { $0.kind == .exact }
        let visual = sets.filter { $0.kind == .visual }
        XCTAssertEqual(exact.map(\.paths), [[path("a copy.png"), path("a.png")]])
        XCTAssertEqual(visual.count, 1, "\(sets)")
        XCTAssertEqual(Set(visual.first?.paths ?? []), Set(["a.png", "a copy.png", "a.jpg", "a_small.png"].map(path)))

        let identicalOnly = await service.similarSets(in: .folder(library), strictness: 1, includeVideos: true)
        XCTAssertEqual(identicalOnly.map(\.kind), [.exact])

        let again = await service.similarSets(in: .folder(library), strictness: 0.5, includeVideos: true)
        XCTAssertEqual(again.map(\.id), sets.map(\.id), "set ids are stable")
    }

    func testSetOrderIsFolderThenNameNeverSize() async throws {
        let scene = VisualFixture.scene(seed: 6, width: 600, height: 400)
        // The biggest file sorts last by name; subfolders sort after their parent.
        try put("Zebra/z_master_upscale.png", VisualFixture.png(VisualFixture.resized(scene, width: 2400, height: 1600)))
        try put("Alpha/b.png", VisualFixture.png(VisualFixture.resized(scene, width: 300, height: 200)))
        try put("Alpha/a10.png", VisualFixture.png(scene))
        try put("Alpha/a2.jpg", VisualFixture.jpeg(scene))
        await service.indexLibrary(root: library)

        let sets = await service.similarSets(in: .library(library), strictness: 0.4, includeVideos: true)
        XCTAssertEqual(sets.count, 1, "\(sets)")
        XCTAssertEqual(sets.first?.paths, ["Alpha/a2.jpg", "Alpha/a10.png", "Alpha/b.png", "Zebra/z_master_upscale.png"].map(path))

        let folderOnly = await service.similarSets(in: .folder(library.appendingPathComponent("Alpha")), strictness: 0.4, includeVideos: true)
        XCTAssertEqual(folderOnly.first?.paths, ["Alpha/a2.jpg", "Alpha/a10.png", "Alpha/b.png"].map(path), "folder scope = direct children only")
    }

    func testMoreLikeThisRanksResizedCopyAboveUnrelated() async throws {
        let scene = VisualFixture.scene(seed: 7, width: 800, height: 600)
        try put("query.png", VisualFixture.png(scene))
        try put("resized.jpg", VisualFixture.jpeg(VisualFixture.resized(scene, width: 320, height: 240)))
        try put("other1.png", VisualFixture.png(VisualFixture.scene(seed: 8, width: 800, height: 600)))
        try put("other2.png", VisualFixture.png(VisualFixture.scene(seed: 9, width: 800, height: 600)))
        try put("sub/deep.png", VisualFixture.png(VisualFixture.resized(scene, width: 400, height: 300)))
        await service.indexLibrary(root: library)

        let hits = await service.moreLikeThis(path: path("query.png"), in: .folder(library), limit: 10)
        XCTAssertEqual(hits.first?.path, path("resized.jpg"))
        XCTAssertEqual(hits.count, 3, "folder scope, query excluded")
        XCTAssertFalse(hits.contains { $0.path == path("query.png") })
        XCTAssertLessThan(hits[0].distance, hits[1].distance)

        let library = await service.moreLikeThis(path: path("query.png"), in: .library(self.library), limit: 2)
        XCTAssertEqual(Set(library.map(\.path)), Set([path("resized.jpg"), path("sub/deep.png")]))
    }

    func testDominantColorsFindRedAndBlue() throws {
        let image = VisualFixture.split(
            left: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1),
            right: CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        )
        let colors = VisualSignatureExtractor.dominantColors(image)
        let red = try XCTUnwrap(OKLab(hex: "#FF0000")), blue = try XCTUnwrap(OKLab(hex: "#0000FF"))
        func share(near target: OKLab) -> Double {
            colors.filter { OKLab(hex: $0.hex)!.distance(to: target) < 0.05 }.reduce(0) { $0 + $1.weight }
        }
        XCTAssertEqual(share(near: red), 0.5, accuracy: 0.1, "\(colors)")
        XCTAssertEqual(share(near: blue), 0.5, accuracy: 0.1, "\(colors)")
        XCTAssertLessThanOrEqual(colors.count, 5)
        XCTAssertEqual(colors.map(\.weight), colors.map(\.weight).sorted(by: >))
        XCTAssertEqual(OKLab(hex: "#3366CC")?.hex, "#3366CC", "OKLab round-trips")
    }

    func testColorMatches() async throws {
        try put("solid_red.png", VisualFixture.png(VisualFixture.solid(1, 0, 0)))
        try put("red_blue.png", VisualFixture.png(VisualFixture.split(
            left: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1),
            right: CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        )))
        try put("green.png", VisualFixture.png(VisualFixture.solid(0, 0.8, 0)))
        try put("dark_red.png", VisualFixture.png(VisualFixture.solid(0.85, 0.05, 0.05)))
        await service.indexLibrary(root: library)

        let reds = await service.colorMatches(palette: ["#FF0000"], tolerance: 0.3, in: .folder(library), limit: 10)
        XCTAssertEqual(reds.first?.path, path("solid_red.png"))
        XCTAssertTrue(reds.contains { $0.path == path("red_blue.png") })
        XCTAssertFalse(reds.contains { $0.path == path("green.png") })

        let strict = await service.colorMatches(palette: ["ff0000"], tolerance: 0, in: .folder(library), limit: 10)
        XCTAssertEqual(strict.first?.path, path("solid_red.png"))
        XCTAssertFalse(strict.contains { $0.path == path("green.png") })
        XCTAssertTrue(strict.contains { $0.path == path("solid_red.png") })

        let both = await service.colorMatches(palette: ["#FF0000", "#0000FF"], tolerance: 0.2, in: .folder(library), limit: 10)
        XCTAssertEqual(both.first?.path, path("red_blue.png"), "a two-colour palette prefers the image with both")

        let invalid = await service.colorMatches(palette: ["nope"], tolerance: 1, in: .folder(library), limit: 10)
        XCTAssertTrue(invalid.isEmpty)

        let colors = await service.dominantColors(forPaths: [path("green.png")])
        XCTAssertEqual(colors[path("green.png")]?.count, 1)
    }

    func testSignaturesForPaths() async throws {
        let image = VisualFixture.scene(seed: 21, width: 640, height: 480)
        try put("s.png", VisualFixture.png(image))
        await service.indexLibrary(root: library)
        let signatures = await service.signatures(forPaths: [path("s.png"), path("missing.png")])
        let signature = try XCTUnwrap(signatures[path("s.png")])
        XCTAssertEqual(signature.pixelWidth, 640)
        XCTAssertEqual(signature.pixelHeight, 480)
        XCTAssertEqual(signature.sha256.count, 64)
        XCTAssertNotNil(signature.featurePrint)
        XCTAssertFalse(signature.isVideo)
        XCTAssertFalse(signature.dominantColors.isEmpty)
        XCTAssertNil(signatures[path("missing.png")])
    }

    func testIncrementalIndexSkipsUnchangedAndDropsDeleted() async throws {
        try put("one.png", VisualFixture.png(VisualFixture.scene(seed: 31, width: 200, height: 200)))
        try put("two.png", VisualFixture.png(VisualFixture.scene(seed: 32, width: 200, height: 200)))
        await service.indexLibrary(root: library)
        let first = await service.computedSignatureCount
        XCTAssertEqual(first, 2)

        await service.indexLibrary(root: library)
        let unchanged = await service.computedSignatureCount
        XCTAssertEqual(unchanged, 2, "nothing changed → nothing recomputed")

        try FileManager.default.removeItem(atPath: path("two.png"))
        try put("three.png", VisualFixture.png(VisualFixture.scene(seed: 33, width: 200, height: 200)))
        await service.indexLibrary(root: library)
        let after = await service.computedSignatureCount
        XCTAssertEqual(after, 3)
        let signatures = await service.signatures(forPaths: [path("one.png"), path("two.png"), path("three.png")])
        XCTAssertEqual(Set(signatures.keys), Set([path("one.png"), path("three.png")]))

        await service.markStale(under: library)
        await service.indexLibrary(root: library)
        let rebuilt = await service.computedSignatureCount
        XCTAssertEqual(rebuilt, 5, "a re-index recomputes every file once")
    }

    func testMovePathAndRemoveEntries() async throws {
        try put("a.png", VisualFixture.png(VisualFixture.scene(seed: 41, width: 200, height: 150)))
        try put("dir/b.png", VisualFixture.png(VisualFixture.scene(seed: 42, width: 200, height: 150)))
        try put("dir/inner/c.png", VisualFixture.png(VisualFixture.scene(seed: 43, width: 200, height: 150)))
        try put("dirty/d.png", VisualFixture.png(VisualFixture.scene(seed: 44, width: 200, height: 150)))
        await service.indexLibrary(root: library)

        await service.movePath(from: path("a.png"), to: path("renamed.png"))
        var signatures = await service.signatures(forPaths: [path("a.png"), path("renamed.png")])
        XCTAssertEqual(Array(signatures.keys), [path("renamed.png")])
        let moved = await service.moreLikeThis(path: path("dirty/d.png"), in: .folder(library), limit: 10)
        XCTAssertEqual(moved.map(\.path), [path("renamed.png")], "folder column follows the move")

        await service.movePath(from: path("dir"), to: path("Moved"))
        signatures = await service.signatures(forPaths: [path("dir/b.png"), path("dir/inner/c.png"), path("Moved/b.png"), path("Moved/inner/c.png"), path("dirty/d.png")])
        XCTAssertEqual(Set(signatures.keys), Set([path("Moved/b.png"), path("Moved/inner/c.png"), path("dirty/d.png")]), "descendants move; sibling prefix untouched")
        let inner = await service.similarSets(in: .folder(library.appendingPathComponent("Moved/inner")), strictness: 0, includeVideos: true)
        XCTAssertTrue(inner.isEmpty)
        let innerStats = await service.stats(under: library.appendingPathComponent("Moved/inner"))
        XCTAssertEqual(innerStats.indexed, 1)

        await service.removeEntries(under: path("Moved"))
        signatures = await service.signatures(forPaths: [path("Moved/b.png"), path("Moved/inner/c.png"), path("dirty/d.png")])
        XCTAssertEqual(Array(signatures.keys), [path("dirty/d.png")])

        await service.reset()
        let stats = await service.stats(under: nil)
        XCTAssertEqual(stats.indexed, 0)
    }

    func testCancelledBuildKeepsFinishedWorkAndResumeDoesNotRecompute() async throws {
        let count = 60
        for index in 0..<count {
            try put(String(format: "img%03d.png", index), VisualFixture.png(VisualFixture.scene(seed: UInt64(100 + index), width: 256, height: 192)))
        }
        let service = self.service!
        let root = library!
        let taskBox = LockedBox<Task<Bool, Never>?>(nil)
        let started = LockedBox(false)
        let task = Task.detached {
            await service.indexLibrary(root: root) { update in
                if update.done > 0 { started.value = true }
            }
        }
        taskBox.value = task
        // Pause as soon as the first file lands.
        for _ in 0..<2000 where !started.value { try await Task.sleep(nanoseconds: 2_000_000) }
        task.cancel()
        let finished = await task.value
        let firstRun = await service.computedSignatureCount
        let stored = await service.stats(under: root).indexed
        XCTAssertEqual(stored, firstRun, "every finished signature was written before stopping")
        if finished { throw XCTSkip("indexing finished before the pause landed") }
        XCTAssertLessThan(firstRun, count)

        let totals = LockedBox<[Int]>([])
        let resumed = await service.indexLibrary(root: root) { update in totals.mutate { $0.append(update.total) } }
        XCTAssertTrue(resumed)
        let total = await service.computedSignatureCount
        XCTAssertEqual(total, count, "resume computes only the files the first run didn't finish")
        XCTAssertEqual(totals.value.first, count - firstRun)
    }

    func testRemovalDuringBuildDoesNotResurrectRows() async throws {
        // Root files are processed first (walk order), the subfolder last.
        for index in 0..<40 {
            try put(String(format: "root%03d.png", index), VisualFixture.png(VisualFixture.scene(seed: UInt64(300 + index), width: 256, height: 192)))
        }
        for index in 0..<6 {
            try put("Doomed/d\(index).png", VisualFixture.png(VisualFixture.scene(seed: UInt64(400 + index), width: 256, height: 192)))
        }
        let service = self.service!
        let root = library!
        let task = Task.detached { await service.indexLibrary(root: root) }
        for _ in 0..<2000 {
            if await service.computedSignatureCount > 0 { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        await service.removeEntries(under: path("Doomed"))
        let computedAtRemoval = await service.computedSignatureCount
        _ = await task.value
        if computedAtRemoval >= 46 { throw XCTSkip("build finished before the removal landed") }

        let doomed = await service.stats(under: library.appendingPathComponent("Doomed"))
        XCTAssertEqual(doomed.indexed, 0, "records extracted for a removed folder are dropped, not written back")
        let rootStats = await service.stats(under: library)
        XCTAssertEqual(rootStats.indexed, 40)
    }

    func testHammingIndexFindsExactlyTheBruteForceNeighbours() {
        var rng = SplitMix64(seed: 77)
        var hashes: [UInt64] = (0..<400).map { _ in rng.next() }
        // Plant near neighbours at known distances.
        for index in 0..<100 {
            var hash = hashes[index]
            for _ in 0..<(index % 13) { hash ^= 1 << (rng.next() % 64) }
            hashes.append(hash)
        }
        let index = HammingIndex(hashes: hashes)
        var scratch = HammingIndex.Scratch(count: hashes.count)
        for radius in [0, 3, 8, 12] {
            for query in stride(from: 0, to: hashes.count, by: 7) {
                var found = Set<Int>()
                index.neighbours(of: query, radius: radius, scratch: &scratch) { candidate, distance in
                    XCTAssertEqual(distance, (hashes[candidate] ^ hashes[query]).nonzeroBitCount)
                    found.insert(candidate)
                }
                let expected = Set(hashes.indices.filter { $0 != query && (hashes[$0] ^ hashes[query]).nonzeroBitCount <= radius })
                XCTAssertEqual(found, expected, "radius \(radius) query \(query)")
            }
        }
    }

    func testStrictnessMapping() {
        let loose = VisualIndexService.Thresholds(strictness: 0)
        let strict = VisualIndexService.Thresholds(strictness: 0.9)
        XCTAssertEqual(loose.hammingRadius, 14)
        XCTAssertEqual(strict.hammingRadius, 3)
        XCTAssertGreaterThan(loose.featureDistance, strict.featureDistance)
        XCTAssertFalse(strict.exactOnly)
        XCTAssertTrue(VisualIndexService.Thresholds(strictness: 1).exactOnly)
    }
}
