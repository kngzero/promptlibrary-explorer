import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PromptLibraryExplorer

final class ExportPrivacyTests: TempDirectoryTestCase {
    private let secretPrompt = "a secret castle at dusk"
    private let a1111 = "a secret castle at dusk\nNegative prompt: blurry hands\nSteps: 30, Sampler: Euler a, CFG scale: 7, Seed: 123456789, Size: 8x6, Model: sdxl_base"
    private let comfyAPI = #"{"3":{"class_type":"KSampler","inputs":{"seed":987654321,"steps":20,"cfg":8,"sampler_name":"euler","positive":["6",0],"negative":["7",0],"model":["4",0]}},"4":{"class_type":"CheckpointLoaderSimple","inputs":{"ckpt_name":"secret_model.safetensors"}},"6":{"class_type":"CLIPTextEncode","inputs":{"text":"comfy secret prompt"}},"7":{"class_type":"CLIPTextEncode","inputs":{"text":"comfy negative"}}}"#
    private let comfyWorkflow = #"{"nodes":[{"id":6,"type":"CLIPTextEncode","widgets_values":["comfy secret prompt"]}],"links":[]}"#

    // MARK: Fixtures

    private func aiPNG() -> Data {
        PNGFixture.png(with: [
            PNGFixture.tEXt("parameters", a1111),
            PNGFixture.zTXt("prompt", comfyAPI),
            PNGFixture.iTXt("workflow", comfyWorkflow, compressed: true),
            PNGFixture.iTXt("Description", "described: \(secretPrompt)", compressed: false),
            PNGFixture.tEXt("Copyright", "© Test Artist"),
        ])
    }

    private func aiJPEG() -> Data {
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.9,
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifUserComment: a1111,
                kCGImagePropertyExifLensModel: "Test Lens 50mm",
            ],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFImageDescription: secretPrompt,
                kCGImagePropertyTIFFMake: "TestMake",
            ],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 51.5, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 0.12, kCGImagePropertyGPSLongitudeRef: "W",
            ],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCKeywords: ["castle"]],
        ]
        CGImageDestinationAddImage(dest, makeCGImage(width: 16, height: 12), props as CFDictionary)
        precondition(CGImageDestinationFinalize(dest))
        return data as Data
    }

    /// RGBA8 bytes of the decoded image, for pixel-identity checks.
    private func decodedPixels(_ data: Data) throws -> [UInt8] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixels
    }

    private func assertNoAIMetadata(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let parsed = ImageMetadataParser.readMetadataUncached(at: url)
        XCTAssertEqual(parsed.prompt, "", "prompt remained", file: file, line: line)
        XCTAssertTrue(parsed.negativePrompt?.isEmpty ?? true, "negative prompt remained", file: file, line: line)
        XCTAssertNil(parsed.comfyPromptJSON, file: file, line: line)
        XCTAssertNil(parsed.comfyWorkflowJSON, file: file, line: line)
        let params = parsed.generationParameters
        XCTAssertNil(params.seed, file: file, line: line)
        XCTAssertNil(params.steps, file: file, line: line)
        XCTAssertNil(params.sampler, file: file, line: line)
        XCTAssertNil(params.cfg, file: file, line: line)
        for field in parsed.fields {
            XCTAssertFalse(field.value.contains("secret"), "\(field.label) still holds generation text", file: file, line: line)
        }
        let raw = try Data(contentsOf: url)
        let latin1 = String(data: raw, encoding: .isoLatin1) ?? ""
        XCTAssertFalse(latin1.contains("secret"), "raw bytes still contain the prompt", file: file, line: line)
        XCTAssertFalse(latin1.contains("123456789"), "raw bytes still contain the seed", file: file, line: line)
        XCTAssertTrue(ExportMetadata.leakedAIMetadata(at: url, policy: .stripAI).isEmpty, file: file, line: line)
    }

    // MARK: PNG

    func testFixturesReallyCarryAIMetadata() throws {
        let png = try writeFile("in.png", aiPNG())
        let parsed = ImageMetadataParser.readMetadataUncached(at: png)
        XCTAssertEqual(parsed.prompt, secretPrompt)
        XCTAssertNotNil(parsed.comfyPromptJSON)
        XCTAssertFalse(ExportMetadata.leakedAIMetadata(at: png, policy: .stripAI).isEmpty)

        let jpeg = try writeFile("in.jpg", aiJPEG())
        XCTAssertEqual(ImageMetadataParser.readMetadataUncached(at: jpeg).generationParameters.seed, "123456789")
    }

    func testStripAIFromPNGRemovesEveryTextChunkButKeepsPixelsAndCredits() throws {
        let original = aiPNG()
        let output = try ExportMetadata.strippedPNG(original, policy: .stripAI, parsed: nil)
        let url = try writeFile("out.png", output)
        try assertNoAIMetadata(url)

        let keywords = PNGFixture.chunks(output).compactMap(PNGFixture.keyword(of:))
        XCTAssertFalse(keywords.contains("parameters"))
        XCTAssertFalse(keywords.contains("prompt"))
        XCTAssertFalse(keywords.contains("workflow"))
        XCTAssertFalse(keywords.contains("Description"))
        XCTAssertTrue(keywords.contains("Copyright"), "credits survive Strip AI")

        // IDAT bytes are copied verbatim, so the decoded pixels are identical.
        let idat: (Data) -> [Data] = { PNGFixture.chunks($0).filter { $0.type == "IDAT" }.map(\.raw) }
        XCTAssertEqual(idat(output), idat(original))
        XCTAssertEqual(try decodedPixels(output), try decodedPixels(original))
    }

    func testStripAllFromPNGRemovesCreditsToo() throws {
        let output = try ExportMetadata.strippedPNG(aiPNG(), policy: .stripAll, parsed: nil)
        XCTAssertTrue(PNGFixture.chunks(output).allSatisfy { !["tEXt", "zTXt"].contains($0.type) })
        XCTAssertFalse(PNGFixture.chunks(output).compactMap(PNGFixture.keyword(of:)).contains("Copyright"))
    }

    func testKeepOnlySynthesisesJustTheChosenFields() throws {
        let original = aiPNG()
        let sourceURL = try writeFile("keep.png", original)
        let parsed = ImageMetadataParser.readMetadataUncached(at: sourceURL)
        let policy = ExportMetadataPolicy(mode: .keepOnly, keptFields: [.prompt, .model])
        let output = try ExportMetadata.strippedPNG(original, policy: policy, parsed: parsed)
        let url = try writeFile("kept.png", output)

        let reparsed = ImageMetadataParser.readMetadataUncached(at: url)
        XCTAssertEqual(reparsed.prompt, secretPrompt)
        XCTAssertEqual(reparsed.generationParameters.model, "sdxl_base")
        XCTAssertNil(reparsed.generationParameters.seed)
        XCTAssertNil(reparsed.generationParameters.steps)
        XCTAssertTrue(reparsed.negativePrompt?.isEmpty ?? true)
        XCTAssertNil(reparsed.comfyPromptJSON)
        XCTAssertTrue(ExportMetadata.leakedAIMetadata(at: url, policy: policy).isEmpty)
        XCTAssertEqual(try decodedPixels(output), try decodedPixels(original))
    }

    // MARK: JPEG

    func testStripAIFromJPEGIsLosslessAndClean() throws {
        let original = aiJPEG()
        let output = try ExportMetadata.losslessRewrite(original, policy: .stripAI, parsed: nil)
        let url = try writeFile("out.jpg", output)
        try assertNoAIMetadata(url)

        XCTAssertEqual(JPEGFixture.scanData(output), JPEGFixture.scanData(original), "compressed image data untouched")
        XCTAssertEqual(try decodedPixels(output), try decodedPixels(original))

        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithData(output as CFData, nil)!, 0, nil) as? [CFString: Any])
        XCTAssertNil(props[kCGImagePropertyGPSDictionary], "GPS removed")
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        XCTAssertEqual(tiff?[kCGImagePropertyTIFFMake] as? String, "TestMake", "camera data is not AI metadata")
    }

    // MARK: Engine

    func testSharingExportLeavesOriginalAndWritesCleanCopy() async throws {
        let original = aiPNG()
        let source = try writeFile("src/art.png", original)
        let destination = tempDir.appendingPathComponent("out/art.png")
        let job = ExportJobItem(source: source, kind: .image, destination: destination, action: .write, format: .png)
        let summary = await ExportEngine.run(items: [job], preset: .sharing) { _, _, _ in }

        XCTAssertEqual(summary.written.count, 1)
        XCTAssertEqual(try Data(contentsOf: source), original, "the original is never modified")
        try assertNoAIMetadata(destination)
        XCTAssertEqual(try decodedPixels(try Data(contentsOf: destination)), try decodedPixels(original))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["art.png"], "no temp files left behind")
    }

    func testReencodedExportStripsToo() async throws {
        let source = try writeFile("src/art.png", aiPNG())
        var preset = ExportPreset.webJPEG2048
        preset.sizing = ExportSizing(mode: .scale, scalePercent: 50)
        let destination = tempDir.appendingPathComponent("out/art.jpg")
        let job = ExportJobItem(source: source, kind: .image, destination: destination, action: .write, format: .jpeg)
        let summary = await ExportEngine.run(items: [job], preset: preset) { _, _, _ in }
        XCTAssertEqual(summary.written.count, 1, "\(summary.failed)")
        try assertNoAIMetadata(destination)
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(destination as CFURL, nil)!, 0, nil) as? [CFString: Any])
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 4)
        XCTAssertEqual(props[kCGImagePropertyPixelHeight] as? Int, 3)
    }

    func testKeepAllReencodeCarriesParametersIntoJPEG() async throws {
        let source = try writeFile("src/art.png", aiPNG())
        var preset = ExportPreset.fullResPNG
        preset.format = .jpeg
        let destination = tempDir.appendingPathComponent("out/art.jpg")
        let job = ExportJobItem(source: source, kind: .image, destination: destination, action: .write, format: .jpeg)
        let summary = await ExportEngine.run(items: [job], preset: preset) { _, _, _ in }
        XCTAssertEqual(summary.written.count, 1, "\(summary.results.map(\.outcome))")
        let parsed = ImageMetadataParser.readMetadataUncached(at: destination)
        XCTAssertEqual(parsed.prompt, secretPrompt)
        XCTAssertEqual(parsed.generationParameters.seed, "123456789")
    }

    func testOverwriteMovesTheOldFileAsideAndSkipLeavesIt() async throws {
        let source = try writeFile("src/art.png", PNGFixture.basePNG())
        let existing = try writeFile("out/art.png", Data("old".utf8))
        let skip = ExportJobItem(source: source, kind: .image, destination: existing, action: .skip, format: .png)
        let skipped = await ExportEngine.run(items: [skip], preset: .fullResPNG) { _, _, _ in }
        XCTAssertEqual(skipped.skipped.count, 1)
        XCTAssertEqual(try Data(contentsOf: existing), Data("old".utf8))

        // A plain write never replaces a file that appeared after planning.
        let write = ExportJobItem(source: source, kind: .image, destination: existing, action: .write, format: .png)
        let written = await ExportEngine.run(items: [write], preset: .fullResPNG) { _, _, _ in }
        XCTAssertEqual(written.written.first?.destination?.lastPathComponent, "art 2.png")
        XCTAssertEqual(try Data(contentsOf: existing), Data("old".utf8))
    }

    func testDocumentsAreSkippedUnlessRenderedPreviewsAreOn() async throws {
        let board = try writeFile("src/board.mlmboard", Data("{}".utf8))
        let job = ExportJobItem(source: board, kind: .document, destination: tempDir.appendingPathComponent("out/board.png"), action: .write, format: .png)
        let summary = await ExportEngine.run(items: [job], preset: .fullResPNG) { _, _, _ in }
        XCTAssertEqual(summary.skipped.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("out/board.png").path))
    }
}
