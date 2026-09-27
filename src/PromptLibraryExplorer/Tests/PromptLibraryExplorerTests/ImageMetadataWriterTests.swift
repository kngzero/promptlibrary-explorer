import ImageIO
import XCTest
@testable import PromptLibraryExplorer

final class ImageMetadataWriterTests: TempDirectoryTestCase {
    private typealias Meta = ImageMetadataWriter.PromptMetadata

    private func meta(
        prompt: String = "", negative: String = "", model: String = "", steps: String = "",
        sampler: String = "", cfg: String = "", seed: String = ""
    ) -> Meta {
        Meta(prompt: prompt, negativePrompt: negative, model: model, steps: steps, sampler: sampler, cfgScale: cfg, seed: seed)
    }

    private func parametersText(_ url: URL) throws -> String? {
        let data = try Data(contentsOf: url)
        let chunks = PNGFixture.textChunks(data, keyword: "parameters")
        XCTAssertLessThanOrEqual(chunks.count, 1, "parameters chunk duplicated")
        return chunks.first.flatMap(PNGFixture.text(of:))
    }

    // MARK: A1111

    func testA1111RoundTripOnPlainPNG() throws {
        let url = try writeFile("plain.png", PNGFixture.basePNG())
        try ImageMetadataWriter.write(
            meta(prompt: "a cat on a sofa", negative: "blurry", model: "sdxl_base", steps: "30",
                 sampler: "Euler a", cfg: "7", seed: "42"),
            to: url
        )

        XCTAssertEqual(
            try parametersText(url),
            "a cat on a sofa\nNegative prompt: blurry\nSteps: 30, Sampler: Euler a, CFG scale: 7, Seed: 42, Model: sdxl_base"
        )

        let existing = try XCTUnwrap(ImageMetadataWriter.existingMetadata(at: url))
        XCTAssertEqual(existing.prompt, "a cat on a sofa")
        XCTAssertEqual(existing.negativePrompt, "blurry")
        XCTAssertEqual(existing.model, "sdxl_base")
        XCTAssertEqual(existing.steps, "30")
        XCTAssertEqual(existing.sampler, "Euler a")
        XCTAssertEqual(existing.cfgScale, "7")
        XCTAssertEqual(existing.seed, "42")

        let parsed = ImageMetadataParser.readMetadataUncached(at: url)
        XCTAssertEqual(parsed.prompt, "a cat on a sofa")
        XCTAssertEqual(parsed.negativePrompt, "blurry")
        XCTAssertEqual(parsed.model, "sdxl_base")
        let params = parsed.generationParameters
        XCTAssertEqual(params.seed, "42")
        XCTAssertEqual(params.steps, "30")
        XCTAssertEqual(params.cfg, "7")
        XCTAssertEqual(params.sampler, "Euler a")

        // Image still decodes at the same size.
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 8)
        XCTAssertEqual(props[kCGImagePropertyPixelHeight] as? Int, 6)
    }

    private static let richParameters = """
    old prompt, detailed
    Negative prompt: bad hands
    Steps: 20, Sampler: DPM++ 2M Karras, CFG scale: 5, Seed: 123, Size: 512x768, Model hash: abc123, Model: foo_v2, Clip skip: 2, Lora hashes: "detail: 111aaa, style: 222bbb", Version: v1.9.4
    """

    func testWritePreservesUnknownParametersInOrder() throws {
        let url = try writeFile("rich.png", PNGFixture.png(with: [PNGFixture.tEXt("parameters", Self.richParameters)]))

        var m = try XCTUnwrap(ImageMetadataWriter.existingMetadata(at: url))
        XCTAssertEqual(m.prompt, "old prompt, detailed")
        XCTAssertEqual(m.model, "foo_v2")
        m.prompt = "new prompt"
        m.seed = "999"
        try ImageMetadataWriter.write(m, to: url, mode: .replace)

        XCTAssertEqual(try parametersText(url), """
        new prompt
        Negative prompt: bad hands
        Steps: 20, Sampler: DPM++ 2M Karras, CFG scale: 5, Seed: 999, Size: 512x768, Model hash: abc123, Model: foo_v2, Clip skip: 2, Lora hashes: "detail: 111aaa, style: 222bbb", Version: v1.9.4
        """)
    }

    func testReplaceModeRemovesEmptiedFields() throws {
        let url = try writeFile("rich.png", PNGFixture.png(with: [PNGFixture.tEXt("parameters", Self.richParameters)]))
        var m = try XCTUnwrap(ImageMetadataWriter.existingMetadata(at: url))
        m.negativePrompt = ""
        m.seed = ""
        try ImageMetadataWriter.write(m, to: url, mode: .replace)

        let text = try XCTUnwrap(parametersText(url))
        XCTAssertFalse(text.contains("Negative prompt"))
        XCTAssertFalse(text.contains("Seed:"))
        XCTAssertTrue(text.contains("Size: 512x768"), "unknown params must survive")
        XCTAssertTrue(PNGFixture.textChunks(try Data(contentsOf: url), keyword: "negative_prompt").isEmpty)
    }

    func testMergeNonEmptyKeepsExistingValues() throws {
        let url = try writeFile("rich.png", PNGFixture.png(with: [PNGFixture.tEXt("parameters", Self.richParameters)]))
        try ImageMetadataWriter.write(meta(model: "brand_new_model"), to: url, mode: .mergeNonEmpty)

        let existing = try XCTUnwrap(ImageMetadataWriter.existingMetadata(at: url))
        XCTAssertEqual(existing.prompt, "old prompt, detailed")
        XCTAssertEqual(existing.negativePrompt, "bad hands")
        XCTAssertEqual(existing.seed, "123")
        XCTAssertEqual(existing.steps, "20")
        XCTAssertEqual(existing.model, "brand_new_model")
        let text = try XCTUnwrap(parametersText(url))
        XCTAssertTrue(text.contains("Model hash: abc123, Model: brand_new_model, Clip skip: 2"))
    }

    func testWritingTwiceDoesNotDuplicateChunks() throws {
        let url = try writeFile("plain.png", PNGFixture.basePNG())
        try ImageMetadataWriter.write(meta(prompt: "one", seed: "1"), to: url)
        try ImageMetadataWriter.write(meta(prompt: "two", seed: "2"), to: url)
        let data = try Data(contentsOf: url)
        XCTAssertEqual(PNGFixture.textChunks(data, keyword: "parameters").count, 1)
        XCTAssertEqual(PNGFixture.textChunks(data, keyword: "prompt").count, 1)
        XCTAssertEqual(ImageMetadataWriter.existingMetadata(at: url)?.prompt, "two")
    }

    func testNonLatin1PromptIsWrittenAsITXt() throws {
        let url = try writeFile("plain.png", PNGFixture.basePNG())
        try ImageMetadataWriter.write(meta(prompt: "猫 🐈 on a roof", steps: "10"), to: url)
        let chunk = try XCTUnwrap(PNGFixture.textChunks(try Data(contentsOf: url), keyword: "parameters").first)
        XCTAssertEqual(chunk.type, "iTXt")
        XCTAssertEqual(ImageMetadataParser.readMetadataUncached(at: url).prompt, "猫 🐈 on a roof")
    }

    // MARK: ComfyUI

    func testComfyUIChunksSurviveByteForByte() throws {
        let apiJSON = #"{"3":{"class_type":"KSampler","inputs":{"seed":5,"steps":20,"cfg":7,"sampler_name":"euler","positive":["6",0],"negative":["7",0],"model":["4",0],"latent_image":["5",0]}},"4":{"class_type":"CheckpointLoaderSimple","inputs":{"ckpt_name":"x.safetensors"}},"6":{"class_type":"CLIPTextEncode","inputs":{"text":"comfy positive","clip":["4",1]}},"7":{"class_type":"CLIPTextEncode","inputs":{"text":"comfy negative","clip":["4",1]}},"5":{"class_type":"EmptyLatentImage","inputs":{"width":8,"height":6}}}"#
        let workflowJSON = #"{"nodes":[],"links":[],"version":0.4}"#
        let promptChunk = PNGFixture.tEXt("prompt", apiJSON)
        let workflowChunk = PNGFixture.tEXt("workflow", workflowJSON)
        let url = try writeFile("comfy.png", PNGFixture.png(with: [promptChunk, workflowChunk]))

        try ImageMetadataWriter.write(meta(prompt: "user edited prompt", seed: "77"), to: url)
        try ImageMetadataWriter.write(meta(prompt: "user edited again", seed: "78"), to: url)

        let data = try Data(contentsOf: url)
        let prompts = PNGFixture.textChunks(data, keyword: "prompt")
        let workflows = PNGFixture.textChunks(data, keyword: "workflow")
        XCTAssertEqual(prompts.count, 1, "a second `prompt` keyword must not be added next to a ComfyUI graph")
        XCTAssertEqual(workflows.count, 1)
        XCTAssertEqual(prompts.first?.raw, promptChunk)
        XCTAssertEqual(workflows.first?.raw, workflowChunk)
        XCTAssertEqual(PNGFixture.textChunks(data, keyword: "parameters").count, 1)

        // The A1111 block now wins over the graph for display.
        let parsed = ImageMetadataParser.readMetadataUncached(at: url)
        XCTAssertEqual(parsed.prompt, "user edited again")
        XCTAssertEqual(parsed.comfyPromptJSON, apiJSON)
        XCTAssertEqual(parsed.comfyWorkflowJSON, workflowJSON)
    }

    // MARK: Malformed input

    func testTruncatedPNGThrowsAndLeavesFileUntouched() throws {
        let full = PNGFixture.png(with: [PNGFixture.tEXt("parameters", "hello\nSteps: 1")])
        let idat = try XCTUnwrap(PNGFixture.chunks(full).first { $0.type == "IDAT" })
        let cut = full.prefix(idat.raw.startIndex + idat.raw.count / 2)
        let url = try writeFile("truncated.png", Data(cut))

        XCTAssertThrowsError(try ImageMetadataWriter.write(meta(prompt: "x"), to: url))
        assertFileUnchanged(url, Data(cut))
    }

    func testBadChunkLengthThrowsAndLeavesFileUntouched() throws {
        var data = PNGFixture.png(with: [PNGFixture.tEXt("Software", "test")])
        let text = try XCTUnwrap(PNGFixture.chunks(data).first { $0.type == "tEXt" })
        data.replaceSubrange(text.raw.startIndex..<(text.raw.startIndex + 4), with: bigEndian(0x7FFF_0000))
        let url = try writeFile("badlength.png", data)

        XCTAssertThrowsError(try ImageMetadataWriter.write(meta(prompt: "x"), to: url)) { error in
            guard case ImageMetadataWriter.WriterError.malformedPNG = error else {
                return XCTFail("expected malformedPNG, got \(error)")
            }
        }
        assertFileUnchanged(url, data)
    }

    func testGarbageChunkTypeThrows() throws {
        var data = PNGFixture.png(with: [PNGFixture.tEXt("Software", "test")])
        let text = try XCTUnwrap(PNGFixture.chunks(data).first { $0.type == "tEXt" })
        data.replaceSubrange((text.raw.startIndex + 4)..<(text.raw.startIndex + 8), with: Data([0x00, 0x01, 0xFF, 0x20]))
        let url = try writeFile("badtype.png", data)
        XCTAssertThrowsError(try ImageMetadataWriter.write(meta(prompt: "x"), to: url))
        assertFileUnchanged(url, data)
    }

    func testNotAPNGThrows() throws {
        let data = Data("definitely not a png file".utf8)
        let url = try writeFile("fake.png", data)
        XCTAssertThrowsError(try ImageMetadataWriter.write(meta(prompt: "x"), to: url))
        assertFileUnchanged(url, data)
    }

    func testUnsupportedExtensionThrows() throws {
        let url = try writeFile("image.webp", Data([1, 2, 3]))
        XCTAssertThrowsError(try ImageMetadataWriter.write(meta(prompt: "x"), to: url)) { error in
            guard case ImageMetadataWriter.WriterError.unsupportedFormat("webp") = error else {
                return XCTFail("unexpected \(error)")
            }
        }
    }

    func testUndecodableOwnedChunkThrowsRatherThanDiscarding() throws {
        // zTXt "parameters" whose payload isn't valid zlib.
        var payload = Data("parameters".utf8)
        payload.append(contentsOf: [0, 0, 0x78, 0x9C, 0xDE, 0xAD, 0xBE, 0xEF])
        let data = PNGFixture.png(with: [PNGFixture.chunk(type: "zTXt", payload: payload)])
        let url = try writeFile("badz.png", data)
        XCTAssertThrowsError(try ImageMetadataWriter.write(meta(prompt: "x"), to: url))
        assertFileUnchanged(url, data)
    }

    func testBytesAfterIENDArePreserved() throws {
        var data = PNGFixture.basePNG()
        let trailer = Data("TRAILING-APPENDED-DATA\u{0}\u{1}\u{2}".utf8)
        data.append(trailer)
        let url = try writeFile("trailer.png", data)

        try ImageMetadataWriter.write(meta(prompt: "with trailer", steps: "5"), to: url)
        let written = try Data(contentsOf: url)
        XCTAssertEqual(written.suffix(trailer.count), trailer)
        let iend = try XCTUnwrap(PNGFixture.chunks(written).last)
        XCTAssertEqual(iend.type, "IEND")
        XCTAssertEqual(iend.raw.endIndex, written.count - trailer.count)
        XCTAssertEqual(ImageMetadataWriter.existingMetadata(at: url)?.prompt, "with trailer")
    }

    func testUnrelatedChunksKeptByteForByte() throws {
        let original = PNGFixture.png(with: [PNGFixture.tEXt("Software", "SomeTool 1.0"), PNGFixture.tEXt("parameters", "p\nSteps: 3")])
        let url = try writeFile("keep.png", original)
        try ImageMetadataWriter.write(meta(prompt: "q", steps: "4"), to: url)
        let before = PNGFixture.chunks(original).filter { PNGFixture.keyword(of: $0) != "parameters" && $0.type != "IEND" }
        let after = PNGFixture.chunks(try Data(contentsOf: url))
        for chunk in before {
            XCTAssertTrue(after.contains { $0.raw == chunk.raw }, "\(chunk.type) chunk changed or dropped")
        }
    }

    // MARK: Compressed text

    func testReadsZTXtParameters() throws {
        let url = try writeFile("z.png", PNGFixture.png(with: [
            PNGFixture.zTXt("parameters", "zipped prompt\nNegative prompt: zneg\nSteps: 12, Seed: 5, Model: zmodel"),
        ]))
        let parsed = ImageMetadataParser.readMetadataUncached(at: url)
        XCTAssertEqual(parsed.prompt, "zipped prompt")
        XCTAssertEqual(parsed.negativePrompt, "zneg")
        XCTAssertEqual(parsed.model, "zmodel")
        XCTAssertEqual(ImageMetadataWriter.existingMetadata(at: url)?.seed, "5")
    }

    func testReadsCompressedITXtParameters() throws {
        let url = try writeFile("i.png", PNGFixture.png(with: [
            PNGFixture.iTXt("parameters", "ünïcødé prompt\nSteps: 9, Seed: 8", compressed: true),
        ]))
        XCTAssertEqual(ImageMetadataParser.readMetadataUncached(at: url).prompt, "ünïcødé prompt")
        XCTAssertEqual(ImageMetadataWriter.existingMetadata(at: url)?.steps, "9")
    }

    func testReadsHighlyCompressiblePayload() throws {
        let longPrompt = String(repeating: "masterpiece best quality ", count: 12_000) + "end"
        let text = longPrompt + "\nSteps: 20, Seed: 1"
        let chunk = PNGFixture.zTXt("parameters", text)
        XCTAssertGreaterThan(Double(text.utf8.count) / Double(chunk.count), 32, "fixture should exceed 32:1")
        let url = try writeFile("big.png", PNGFixture.png(with: [chunk]))

        let parsed = ImageMetadataParser.readMetadataUncached(at: url)
        XCTAssertEqual(parsed.prompt.count, longPrompt.count)
        XCTAssertEqual(parsed.prompt, longPrompt)
        XCTAssertEqual(ImageMetadataWriter.existingMetadata(at: url)?.prompt, longPrompt)
    }

    func testRewritingZTXtReplacesItWithSingleParametersChunk() throws {
        let url = try writeFile("z.png", PNGFixture.png(with: [PNGFixture.zTXt("parameters", "old\nSteps: 2, Size: 64x64")]))
        try ImageMetadataWriter.write(meta(prompt: "new", steps: "2"), to: url)
        let chunks = PNGFixture.textChunks(try Data(contentsOf: url), keyword: "parameters")
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first?.type, "tEXt")
        XCTAssertEqual(chunks.first.flatMap(PNGFixture.text(of:)), "new\nSteps: 2, Size: 64x64")
    }

    // MARK: JPEG

    func testJPEGWriteKeepsScanDataAndIsReadable() throws {
        let original = JPEGFixture.baseJPEG()
        let url = try writeFile("photo.jpg", original)
        let originalScan = try XCTUnwrap(JPEGFixture.scanData(original))

        try ImageMetadataWriter.write(
            meta(prompt: "a jpeg lighthouse", negative: "fog", model: "jpgmodel", steps: "25", seed: "314"),
            to: url
        )

        let written = try Data(contentsOf: url)
        XCTAssertNotEqual(written, original)
        XCTAssertEqual(JPEGFixture.scanData(written), originalScan, "compressed image data must be byte-identical")

        let source = try XCTUnwrap(CGImageSourceCreateWithData(written as CFData, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        XCTAssertEqual(tiff?[kCGImagePropertyTIFFImageDescription] as? String, "a jpeg lighthouse")

        let existing = try XCTUnwrap(ImageMetadataWriter.existingMetadata(at: url))
        XCTAssertEqual(existing.prompt, "a jpeg lighthouse")
        XCTAssertEqual(existing.negativePrompt, "fog")
        XCTAssertEqual(existing.seed, "314")
        XCTAssertEqual(existing.model, "jpgmodel")

        let parsed = ImageMetadataParser.readMetadataUncached(at: url)
        XCTAssertEqual(parsed.prompt, "a jpeg lighthouse")
        XCTAssertEqual(parsed.generationParameters.steps, "25")
    }

    func testJPEGMergeKeepsPreviousValues() throws {
        let url = try writeFile("photo.jpeg", JPEGFixture.baseJPEG())
        try ImageMetadataWriter.write(meta(prompt: "first", steps: "10", seed: "1"), to: url)
        try ImageMetadataWriter.write(meta(model: "later-model"), to: url, mode: .mergeNonEmpty)
        let existing = try XCTUnwrap(ImageMetadataWriter.existingMetadata(at: url))
        XCTAssertEqual(existing.prompt, "first")
        XCTAssertEqual(existing.seed, "1")
        XCTAssertEqual(existing.model, "later-model")
    }
}
