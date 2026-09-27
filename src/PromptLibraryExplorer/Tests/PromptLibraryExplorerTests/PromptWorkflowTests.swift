import XCTest
@testable import PromptLibraryExplorer

// Prompt workflows: token diff, lineage, builder formatting and weights,
// ComfyUI graph edits, A1111 request bodies, generator clients (mocked
// transport — no network), and statistics aggregation.

// MARK: - Token diff

final class PromptTokenDiffTests: XCTestCase {
    func testTokenizeSplitsPunctuationAndWeights() {
        XCTAssertEqual(
            PromptTokenDiff.tokenize("(red dress:1.2), 8k  photo"),
            ["(", "red", "dress", ":", "1.2", ")", ",", "8k", "photo"]
        )
    }

    func testIdenticalPromptsAreAllEqual() {
        let diff = PromptTokenDiff.diff(old: "a cat, on a mat", new: "a cat, on a mat")
        XCTAssertTrue(diff.allSatisfy { $0.op == .equal })
        XCTAssertEqual(PromptTokenDiff.render(diff, including: [.equal]), "a cat, on a mat")
    }

    func testAddedAndRemovedWords() {
        let diff = PromptTokenDiff.diff(old: "a red fox in the snow", new: "a white fox in deep snow at dusk")
        XCTAssertEqual(PromptTokenDiff.render(diff, including: [.equal]), "a fox in snow")
        XCTAssertEqual(PromptTokenDiff.render(diff, including: [.removed]), "red the")
        XCTAssertEqual(PromptTokenDiff.render(diff, including: [.added]), "white deep at dusk")
        // Old side reconstructs from equal + removed, new side from equal + added.
        XCTAssertEqual(PromptTokenDiff.render(diff, including: [.equal, .removed]), "a red fox in the snow")
        XCTAssertEqual(PromptTokenDiff.render(diff, including: [.equal, .added]), "a white fox in deep snow at dusk")
        // Removed tokens come before the added ones in the same gap.
        let red = diff.firstIndex(of: PromptDiffToken(text: "red", op: .removed))!
        let white = diff.firstIndex(of: PromptDiffToken(text: "white", op: .added))!
        XCTAssertLessThan(red, white)
    }

    func testCaseInsensitiveMatchKeepsNewText() {
        let diff = PromptTokenDiff.diff(old: "Portrait of a Woman", new: "portrait of a woman")
        XCTAssertTrue(diff.allSatisfy { $0.op == .equal })
        XCTAssertEqual(diff.first?.text, "portrait")
    }

    func testRepeatedWordsAndEmptySides() {
        let diff = PromptTokenDiff.diff(old: "very very big", new: "very big")
        XCTAssertEqual(PromptTokenDiff.changeCounts(diff).removed, 1)
        XCTAssertEqual(PromptTokenDiff.changeCounts(diff).added, 0)

        XCTAssertEqual(PromptTokenDiff.diff(old: "", new: "new words").map(\.op), [.added, .added])
        XCTAssertEqual(PromptTokenDiff.diff(old: "old words", new: "").map(\.op), [.removed, .removed])
    }

    func testWeightChangeIsATokenChange() {
        let diff = PromptTokenDiff.diff(old: "(red:1.2), sky", new: "(red:1.4), sky")
        XCTAssertEqual(PromptTokenDiff.render(diff, including: [.removed]), "1.2")
        XCTAssertEqual(PromptTokenDiff.render(diff, including: [.added]), "1.4")
        XCTAssertEqual(PromptTokenDiff.render(diff, including: [.equal, .added]), "(red:1.4), sky")
    }

    func testParameterChanges() {
        let a = GenerationParameters(model: "sdxl", sampler: "Euler a", seed: "1", steps: "20", cfg: "7", width: 1024, height: 1024)
        let b = GenerationParameters(model: "sdxl", sampler: "DPM++ 2M", seed: "2", steps: "20", cfg: "7", width: 832, height: 1216)
        let changes = PromptTokenDiff.parameterChanges(old: a, new: b)
        XCTAssertEqual(changes.map(\.label), ["Seed", "Sampler", "Size"])
        XCTAssertEqual(changes.first, PromptParamChange(label: "Seed", old: "1", new: "2"))
        XCTAssertEqual(changes.last?.new, "832×1216")
        XCTAssertTrue(PromptTokenDiff.parameterChanges(old: a, new: a).isEmpty)
    }

    func testLineageOrdersByDateAndDiffsAgainstPrevious() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        func input(_ name: String, _ offset: TimeInterval?, _ prompt: String, seed: String) -> PromptLineageInput {
            PromptLineageInput(
                path: "/lib/\(name)", name: name, date: offset.map { base.addingTimeInterval($0) },
                prompt: prompt, negative: "", parameters: GenerationParameters(seed: seed)
            )
        }
        let steps = PromptLineageBuilder.build([
            input("c.png", 200, "a fox, snow, dusk", seed: "3"),
            input("undated.png", nil, "a fox", seed: "4"),
            input("a.png", 0, "a fox", seed: "1"),
            input("b.png", 100, "a fox, snow", seed: "2"),
        ])
        XCTAssertEqual(steps.map(\.input.name), ["a.png", "b.png", "c.png", "undated.png"])
        XCTAssertNil(steps[0].promptDiff)
        XCTAssertEqual(PromptTokenDiff.render(steps[1].promptDiff!, including: [.added]), ", snow")
        XCTAssertEqual(steps[1].parameterChanges, [PromptParamChange(label: "Seed", old: "1", new: "2")])
        XCTAssertEqual(PromptTokenDiff.render(steps[3].promptDiff!, including: [.removed]), ", snow, dusk")
    }
}

// MARK: - Builder

final class PromptBuilderServiceTests: XCTestCase {
    func testParsePhrasesAndWeights() {
        let phrases = PromptBuilderService.phrases(in: "a cat, (red hat:1.3), [blurry], (soft light), (a, b:0.8)")
        XCTAssertEqual(phrases.map(\.text), ["a cat", "red hat", "blurry", "soft light", "a, b"])
        XCTAssertEqual(phrases.map(\.weight), [1, 1.3, 0.9, 1.1, 0.8])
    }

    func testWeightSyntax() {
        XCTAssertEqual(PromptBuilderService.weighted("red hat", weight: 1.2), "(red hat:1.2)")
        XCTAssertEqual(PromptBuilderService.weighted("red hat", weight: 1.0), "red hat")
        XCTAssertEqual(PromptBuilderService.weighted("red hat", weight: 5), "(red hat:2.0)")
        XCTAssertEqual(PromptBuilderService.weighted("red hat", weight: 0.95), "(red hat:0.95)")
    }

    func testAdjustWeightRewritesOnlyThatPhrase() {
        var prompt = "a cat, red hat, night"
        prompt = PromptBuilderService.adjustWeight(by: 0.1, forPhraseAt: 1, in: prompt)
        XCTAssertEqual(prompt, "a cat, (red hat:1.1), night")
        prompt = PromptBuilderService.adjustWeight(by: 0.1, forPhraseAt: 1, in: prompt)
        XCTAssertEqual(prompt, "a cat, (red hat:1.2), night")
        prompt = PromptBuilderService.adjustWeight(by: -0.2, forPhraseAt: 1, in: prompt)
        XCTAssertEqual(prompt, "a cat, red hat, night")
        prompt = PromptBuilderService.adjustWeight(by: -0.1, forPhraseAt: 2, in: prompt)
        XCTAssertEqual(prompt, "a cat, red hat, (night:0.9)")
        XCTAssertEqual(PromptBuilderService.stripWeights(prompt), "a cat, red hat, night")
    }

    func testAppendPhrase() {
        XCTAssertEqual(PromptBuilderService.appendPhrase("dusk", to: ""), "dusk")
        XCTAssertEqual(PromptBuilderService.appendPhrase("dusk", to: "a fox, "), "a fox, dusk")
        XCTAssertEqual(PromptBuilderService.appendPhrase("  ", to: "a fox"), "a fox")
    }

    func testPhrasesFromLibrarySnippet() {
        let phrases = PromptBuilderService.phrases(fromSnippet: "…portrait, «red» dress, studio light, deep «red» lips…")
        XCTAssertEqual(phrases, ["red dress", "deep red lips"])
    }

    private var draft: PromptDraft {
        var d = PromptDraft(prompt: "a fox, (snow:1.2)", negative: "blurry")
        d.model = "sdxl_base"
        d.sampler = "Euler a"
        d.seed = "42"
        d.steps = "30"
        d.cfg = "6.5"
        d.width = "1024"
        d.height = "1024"
        return d
    }

    func testFormatStableDiffusionKeepsWeightsAndParameters() {
        XCTAssertEqual(
            PromptBuilderService.format(draft, as: .stableDiffusion),
            "a fox, (snow:1.2)\nNegative prompt: blurry\nSteps: 30, Sampler: Euler a, CFG scale: 6.5, Seed: 42, Size: 1024x1024, Model: sdxl_base"
        )
        XCTAssertEqual(PromptBuilderService.format(draft, as: .plain), "a fox, (snow:1.2)")
    }

    func testFormatMidjourneyAndDalleStripWeights() {
        XCTAssertEqual(PromptBuilderService.format(draft, as: .midjourney), "/imagine prompt: a fox, snow --ar 1:1 --no blurry --seed 42")
        XCTAssertEqual(PromptBuilderService.format(draft, as: .dalle), "a fox, snow\n\nSize: 1024x1024")
    }

    func testFormatJSON() throws {
        let json = PromptBuilderService.format(draft, as: .json)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(object["prompt"] as? String, "a fox, (snow:1.2)")
        XCTAssertEqual(object["negativePrompt"] as? String, "blurry")
        let parameters = try XCTUnwrap(object["parameters"] as? [String: Any])
        XCTAssertEqual(parameters["steps"] as? Int, 30)
        XCTAssertEqual(parameters["cfg"] as? Double, 6.5)
        XCTAssertEqual(parameters["model"] as? String, "sdxl_base")
        XCTAssertEqual(parameters["aspectRatio"] as? String, "1:1")
    }

    func testAspectRatioFromSize() {
        XCTAssertEqual(PromptBuilderService.aspectRatio(width: 1216, height: 832), .notAvailable)
        XCTAssertEqual(PromptBuilderService.aspectRatio(width: 1920, height: 1080), .sixteenToNine)
        XCTAssertEqual(PromptBuilderService.aspectRatio(width: 768, height: 1024), .threeToFour)
        XCTAssertEqual(PromptBuilderService.aspectRatio(width: nil, height: 10), .notAvailable)
    }
}

// MARK: - ComfyUI graph edits

final class PromptComfyGraphTests: XCTestCase {
    /// KSampler with a literal seed; positive text via a string primitive,
    /// combined with a second encoder.
    static let ksamplerGraph = ComfyUIGraphParserTests.sd15Graph

    /// Flux-style: SamplerCustomAdvanced ← CFGGuider/BasicGuider, RandomNoise seed,
    /// FluxGuidance between the encoder and the guider.
    static let customAdvancedGraph = """
    {"prompt": {
      "6": {"class_type": "CLIPTextEncode", "inputs": {"text": "a lighthouse at night", "clip": ["11", 0]}},
      "26": {"class_type": "FluxGuidance", "inputs": {"guidance": 3.5, "conditioning": ["6", 0]}},
      "22": {"class_type": "BasicGuider", "inputs": {"model": ["12", 0], "conditioning": ["26", 0]}},
      "25": {"class_type": "RandomNoise", "inputs": {"noise_seed": 987654321}},
      "16": {"class_type": "KSamplerSelect", "inputs": {"sampler_name": "euler"}},
      "17": {"class_type": "BasicScheduler", "inputs": {"scheduler": "simple", "steps": 20, "denoise": 1, "model": ["12", 0]}},
      "13": {"class_type": "SamplerCustomAdvanced", "inputs": {"noise": ["25", 0], "guider": ["22", 0], "sampler": ["16", 0],
             "sigmas": ["17", 0], "latent_image": ["5", 0]}},
      "12": {"class_type": "UNETLoader", "inputs": {"unet_name": "flux1-dev.safetensors"}},
      "11": {"class_type": "DualCLIPLoader", "inputs": {"clip_name1": "t5xxl.safetensors", "clip_name2": "clip_l.safetensors"}},
      "5": {"class_type": "EmptyLatentImage", "inputs": {"width": 1024, "height": 1024, "batch_size": 1}}
    }}
    """

    /// ControlNet pass-through: positive and negative both routed through ControlNetApplyAdvanced;
    /// the seed comes from a primitive node linked into the sampler.
    static let controlNetGraph = """
    {
      "1": {"class_type": "CLIPTextEncode", "inputs": {"text": "castle on a hill", "clip": ["9", 1]}},
      "2": {"class_type": "CLIPTextEncode", "inputs": {"text": "ugly", "clip": ["9", 1]}},
      "3": {"class_type": "ControlNetApplyAdvanced", "inputs": {"positive": ["1", 0], "negative": ["2", 0], "strength": 0.8,
            "control_net": ["8", 0], "image": ["7", 0]}},
      "4": {"class_type": "PrimitiveInt", "inputs": {"value": 5}},
      "5": {"class_type": "KSampler", "inputs": {"seed": ["4", 0], "steps": 25, "cfg": 7, "sampler_name": "euler",
            "scheduler": "normal", "denoise": 1, "model": ["9", 0], "positive": ["3", 0], "negative": ["3", 1], "latent_image": ["6", 0]}},
      "9": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": "v15.safetensors"}}
    }
    """

    func testParseRejectsUIWorkflow() {
        let ui = #"{"nodes": [{"id": 1, "type": "KSampler"}], "links": []}"#
        XCTAssertNil(PromptComfyGraph.parse(ui))
        XCTAssertTrue(PromptComfyGraph.isUIWorkflow(ui))
        XCTAssertFalse(PromptComfyGraph.isUIWorkflow(Self.controlNetGraph))
    }

    func testKSamplerSeedAndPrimitivePrompt() throws {
        let graph = try XCTUnwrap(PromptComfyGraph.parse(Self.ksamplerGraph))
        XCTAssertEqual(PromptComfyGraph.positivePrompt(in: graph), "a red fox in the snow")
        let result = PromptComfyGraph.edit(graph, seed: 42, positivePrompt: "a grey wolf")
        XCTAssertEqual(result.seedLocations, ["3.seed"])
        XCTAssertEqual(result.promptLocations, ["20.value"])
        let inputs = result.graph["3"]?["inputs"] as? [String: Any]
        XCTAssertEqual((inputs?["seed"] as? NSNumber)?.uint64Value, 42)
        XCTAssertEqual((result.graph["20"]?["inputs"] as? [String: Any])?["value"] as? String, "a grey wolf")
        // The negative encoder and the second positive encoder are untouched.
        XCTAssertEqual((result.graph["7"]?["inputs"] as? [String: Any])?["text"] as? String, "blurry, lowres")
        XCTAssertEqual((result.graph["8"]?["inputs"] as? [String: Any])?["text"] as? String, "golden hour lighting")
        // Round trip through the parser the app uses to read graphs.
        let body = try PromptComfyGraph.requestBody(graph: result.graph, clientID: "test")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["client_id"] as? String, "test")
        let prompt = try XCTUnwrap(object["prompt"] as? [String: Any])
        let reencoded = String(data: try JSONSerialization.data(withJSONObject: prompt), encoding: .utf8)!
        let extraction = try XCTUnwrap(ComfyUIGraphParser.extract(apiGraphJSON: reencoded))
        XCTAssertTrue(extraction.prompt.hasPrefix("a grey wolf"))
        XCTAssertEqual(extraction.fields.first { $0.label == "Seed" }?.value, "42")
    }

    func testSamplerCustomAdvancedThroughGuiderAndRandomNoise() throws {
        let graph = try XCTUnwrap(PromptComfyGraph.parse(Self.customAdvancedGraph))
        XCTAssertEqual(PromptComfyGraph.positivePrompt(in: graph), "a lighthouse at night")
        let result = PromptComfyGraph.edit(graph, seed: 7, positivePrompt: "a lighthouse in fog")
        XCTAssertEqual(result.seedLocations, ["25.noise_seed"])
        XCTAssertEqual(result.promptLocations, ["6.text"])
        XCTAssertEqual(((result.graph["25"]?["inputs"] as? [String: Any])?["noise_seed"] as? NSNumber)?.intValue, 7)
    }

    func testControlNetPassThroughAndLinkedSeed() throws {
        let graph = try XCTUnwrap(PromptComfyGraph.parse(Self.controlNetGraph))
        XCTAssertEqual(PromptComfyGraph.positivePrompt(in: graph), "castle on a hill")
        let result = PromptComfyGraph.edit(graph, seed: 99, positivePrompt: nil)
        XCTAssertEqual(result.seedLocations, ["4.value"])
        XCTAssertTrue(result.promptLocations.isEmpty)
        XCTAssertEqual((result.graph["1"]?["inputs"] as? [String: Any])?["text"] as? String, "castle on a hill")
        // The sampler still links to the primitive.
        XCTAssertNotNil((result.graph["5"]?["inputs"] as? [String: Any])?["seed"] as? [Any])
    }

    func testNoChangesWithoutOptions() throws {
        let graph = try XCTUnwrap(PromptComfyGraph.parse(Self.ksamplerGraph))
        let result = PromptComfyGraph.edit(graph, seed: nil, positivePrompt: nil)
        XCTAssertTrue(result.seedLocations.isEmpty && result.promptLocations.isEmpty)
        XCTAssertEqual(((result.graph["3"]?["inputs"] as? [String: Any])?["seed"] as? NSNumber)?.intValue, 123456789)
    }

    func testRandomSeedIsInRange() {
        for _ in 0..<50 { XCTAssertLessThanOrEqual(PromptComfyGraph.randomSeed(), PromptComfyGraph.maxSeed) }
    }
}

// MARK: - A1111

final class PromptA1111Tests: TempDirectoryTestCase {
    func testRequestFromParameters() throws {
        let params = GenerationParameters(model: "juggernautXL", sampler: "dpmpp_2m_karras", seed: "1234", steps: "35", cfg: "5.5", width: 1023, height: 1216)
        let body = PromptA1111.request(prompt: " a fox ", negative: "blurry", parameters: params)
        XCTAssertEqual(body.prompt, "a fox")
        XCTAssertEqual(body.negative_prompt, "blurry")
        XCTAssertEqual(body.steps, 35)
        XCTAssertEqual(body.cfg_scale, 5.5)
        XCTAssertEqual(body.sampler_name, "DPM++ 2M")
        XCTAssertEqual(body.scheduler, "Karras")
        XCTAssertEqual(body.seed, 1234)
        XCTAssertEqual(body.width, 1016)
        XCTAssertEqual(body.height, 1216)
        XCTAssertNil(body.override_settings)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
        XCTAssertEqual(json["cfg_scale"] as? Double, 5.5)
        XCTAssertEqual(json["sampler_name"] as? String, "DPM++ 2M")
        XCTAssertNil(json["override_settings"], "nil options are omitted, not sent as null")
        XCTAssertEqual(json["send_images"] as? Bool, true)
        XCTAssertEqual(json["save_images"] as? Bool, false)
    }

    func testDefaultsRandomSeedAndModelOverride() {
        let empty = PromptA1111.request(prompt: "x", negative: "", parameters: GenerationParameters())
        XCTAssertEqual([empty.steps, empty.width, empty.height], [20, 512, 512])
        XCTAssertEqual(empty.cfg_scale, 7)
        XCTAssertEqual(empty.seed, -1)
        XCTAssertNil(empty.sampler_name)

        let params = GenerationParameters(model: "sd_xl_base_1.0.safetensors", sampler: "Euler a", seed: "5")
        let body = PromptA1111.request(prompt: "x", negative: "", parameters: params, randomSeed: true, useModel: true)
        XCTAssertEqual(body.seed, -1)
        XCTAssertEqual(body.sampler_name, "Euler a")
        XCTAssertEqual(body.override_settings, ["sd_model_checkpoint": "sd_xl_base_1.0.safetensors"])
        XCTAssertEqual(body.override_settings_restore_afterwards, true)
    }

    func testDecodeImagesAndProgress() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        let reply = try JSONSerialization.data(withJSONObject: [
            "images": [png.base64EncodedString(), "data:image/png;base64," + png.base64EncodedString()], "info": "{}",
        ])
        XCTAssertEqual(try PromptA1111.decodeImages(from: reply), [png, png])
        XCTAssertThrowsError(try PromptA1111.decodeImages(from: Data("{}".utf8)))

        let progress = try JSONSerialization.data(withJSONObject: [
            "progress": 0.4, "eta_relative": 3.5, "state": ["sampling_step": 8, "sampling_steps": 20],
        ])
        XCTAssertEqual(PromptA1111.progress(from: progress), A1111Progress(fraction: 0.4, etaSeconds: 3.5, step: 8, totalSteps: 20))
    }

    func testSaveNeverOverwrites() throws {
        let source = tempDir.appendingPathComponent("fox.png")
        try Data([1]).write(to: source)
        let folder = PromptA1111.defaultOutputFolder(forSource: source)
        XCTAssertEqual(folder.lastPathComponent, "A1111 Output")
        XCTAssertEqual(folder.deletingLastPathComponent().standardizedFileURL, tempDir.standardizedFileURL)

        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let first = try PromptA1111.save(images: [png], to: folder, baseName: "fox a1111 5")
        let second = try PromptA1111.save(images: [png, png], to: folder, baseName: "fox a1111 5")
        XCTAssertEqual(first.map(\.lastPathComponent), ["fox a1111 5.png"])
        XCTAssertEqual(second.map(\.lastPathComponent), ["fox a1111 5 2.png", "fox a1111 5 3.png"])
        XCTAssertEqual(GeneratorJobModel.outputBaseName(source: "fox.png", seed: -1), "fox a1111")
    }
}

// MARK: - Clients (mock transport)

private final class MockTransport: PromptHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    let handler: @Sendable (URLRequest) throws -> (Int, Data)

    init(handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)) { self.handler = handler }

    var requests: [URLRequest] { lock.withLock { _requests } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { _requests.append(request) }
        let (status, data) = try handler(request)
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

final class PromptGeneratorClientTests: XCTestCase {
    func testEndpointValidation() throws {
        XCTAssertEqual(try GeneratorEndpoint.url(base: "http://127.0.0.1:8188/", path: "/prompt").absoluteString, "http://127.0.0.1:8188/prompt")
        XCTAssertEqual(try GeneratorEndpoint.url(base: " https://box.local/sd ", path: "sdapi/v1/txt2img").absoluteString, "https://box.local/sd/sdapi/v1/txt2img")
        XCTAssertThrowsError(try GeneratorEndpoint.url(base: "file:///etc", path: "/prompt"))
        XCTAssertThrowsError(try GeneratorEndpoint.url(base: "127.0.0.1:8188", path: "/prompt"))
        XCTAssertThrowsError(try GeneratorEndpoint.url(base: "", path: "/prompt"))
    }

    func testComfyQueuePostsGraphAndReturnsID() async throws {
        let transport = MockTransport { _ in (200, Data(#"{"prompt_id": "abc-123", "number": 3, "node_errors": {}}"#.utf8)) }
        let client = ComfyUIClient(baseURL: "http://127.0.0.1:8188", transport: transport)
        let graph = try XCTUnwrap(PromptComfyGraph.parse(PromptComfyGraphTests.controlNetGraph))
        let id = try await client.queue(graph: graph, clientID: "client-1")
        XCTAssertEqual(id, "abc-123")

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:8188/prompt")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertGreaterThan(request.timeoutInterval, 0)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["client_id"] as? String, "client-1")
        XCTAssertEqual((body["prompt"] as? [String: Any])?.count, graph.count)
    }

    func testComfyErrorsAreReadable() async throws {
        let transport = MockTransport { _ in (400, Data(#"{"error": {"message": "Prompt outputs failed validation", "details": "bad ckpt"}}"#.utf8)) }
        let client = ComfyUIClient(baseURL: "http://127.0.0.1:8188", transport: transport)
        let graph = try XCTUnwrap(PromptComfyGraph.parse(PromptComfyGraphTests.controlNetGraph))
        do {
            _ = try await client.queue(graph: graph)
            XCTFail("expected an error")
        } catch let error as GeneratorError {
            XCTAssertEqual(error, .http(status: 400, message: "Prompt outputs failed validation — bad ckpt"))
        }

        let offline = ComfyUIClient(baseURL: "http://127.0.0.1:8188", transport: MockTransport { _ in throw URLError(.cannotConnectToHost) })
        do {
            _ = try await offline.testConnection()
            XCTFail("expected an error")
        } catch let error as GeneratorError {
            guard case .unreachable = error else { return XCTFail("\(error)") }
        }
    }

    func testA1111Txt2ImgProgressAndInterrupt() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let transport = MockTransport { request in
            switch request.url?.path {
            case "/sdapi/v1/txt2img":
                return (200, try JSONSerialization.data(withJSONObject: ["images": [png.base64EncodedString()]]))
            case "/sdapi/v1/progress":
                return (200, Data(#"{"progress": 0.5, "eta_relative": 2}"#.utf8))
            case "/sdapi/v1/interrupt":
                return (200, Data())
            default:
                return (404, Data(#"{"detail": "Not Found"}"#.utf8))
            }
        }
        let client = A1111Client(baseURL: "http://127.0.0.1:7860", transport: transport)
        let body = PromptA1111.request(prompt: "fox", negative: "", parameters: GenerationParameters(steps: "12"))
        let images = try await client.txt2img(body)
        XCTAssertEqual(images, [png])
        let progress = try await client.progress()
        XCTAssertEqual(progress?.fraction, 0.5)
        try await client.interrupt()

        let paths = transport.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }
        XCTAssertEqual(paths, ["POST /sdapi/v1/txt2img", "GET /sdapi/v1/progress", "POST /sdapi/v1/interrupt"])
        XCTAssertEqual(transport.requests[1].url?.query, "skip_current_image=true")
        let sent = try JSONDecoder().decode(A1111Txt2ImgRequest.self, from: XCTUnwrap(transport.requests[0].httpBody))
        XCTAssertEqual(sent.steps, 12)

        do {
            _ = try await client.testConnection()
            XCTFail("expected 404")
        } catch let error as GeneratorError {
            XCTAssertEqual(error, .http(status: 404, message: "Not Found"))
        }
    }

    @MainActor
    func testSettingsUseInjectedDefaults() {
        let suite = "PromptWorkflowTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = GeneratorSettings(defaults: defaults)
        XCTAssertEqual(settings.comfyBaseURL, "http://127.0.0.1:8188")
        XCTAssertEqual(settings.a1111BaseURL, "http://127.0.0.1:7860")
        settings.a1111BaseURL = "http://gpu.local:7861"
        XCTAssertEqual(GeneratorSettings(defaults: defaults).a1111BaseURL, "http://gpu.local:7861")
    }
}

// MARK: - Statistics

final class PromptStatsServiceTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ string: String) -> Date {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        return f.date(from: string + "T12:00:00Z")!
    }

    private var rows: [PromptStatsRow] {
        [
            PromptStatsRow(path: "/l/1.png", date: date("2026-07-01"), prompt: "a woman in red dress, studio light, (red dress:1.2)",
                           model: "models/juggernaut.safetensors", sampler: "Euler a", steps: "30", cfg: "7", rating: 5, flag: 1),
            PromptStatsRow(path: "/l/2.png", date: date("2026-07-02"), prompt: "red dress on a mannequin, studio light",
                           model: "juggernaut", sampler: "Euler a", steps: "30", cfg: "7.0", rating: 3, flag: 0),
            PromptStatsRow(path: "/l/3.png", date: date("2026-09-10"), prompt: "a fox in the snow",
                           model: "flux1-dev", sampler: "euler", steps: "20", cfg: "1", rating: 0, flag: -1),
            PromptStatsRow(path: "/l/4.png", date: nil, prompt: "", model: nil, sampler: nil, steps: nil, cfg: nil),
        ]
    }

    func testTokensDropStopwordsAndNumbers() {
        XCTAssertEqual(PromptStatsService.tokens(of: "A woman in the (red:1.2) dress, 8k, 1024"), ["woman", "red", "dress", "8k"])
    }

    func testNGramsStayWithinSegmentsAndSkipStopwords() {
        XCTAssertEqual(PromptStatsService.ngrams(of: "woman in red dress, studio light", n: 2), ["red dress", "studio light"])
        XCTAssertEqual(PromptStatsService.ngrams(of: "soft studio light, x", n: 3), ["soft studio light"])
    }

    func testReportCountsOncePerFile() {
        let report = PromptStatsService.report(for: rows, calendar: calendar)
        XCTAssertEqual(report.fileCount, 4)
        XCTAssertEqual(report.promptCount, 3)
        // "red" appears twice in file 1 but counts once per file.
        XCTAssertEqual(report.topTokens.first, PromptStatsCount(label: "dress", count: 2))
        XCTAssertEqual(report.topTokens.first { $0.label == "red" }?.count, 2)
        XCTAssertEqual(report.topPhrases.map(\.label), ["red dress", "studio light"])
        XCTAssertTrue(report.topPhrases.allSatisfy { $0.count == 2 })
    }

    func testModelsSamplersAndDistributions() {
        let report = PromptStatsService.report(for: rows, calendar: calendar)
        // Most used first, ties by name.
        XCTAssertEqual(report.models.map(\.label), ["juggernaut", "Unknown", "flux1-dev"])
        XCTAssertEqual(report.models.first, PromptStatsCount(label: "juggernaut", count: 2))
        XCTAssertEqual(report.samplers.map(\.label), ["Euler a", "euler"])
        XCTAssertEqual(report.steps, [PromptStatsCount(label: "20", count: 1), PromptStatsCount(label: "30", count: 2)])
        XCTAssertEqual(report.cfg.first { $0.label == "7" }?.count, 2, "7 and 7.0 are one bucket")
    }

    func testRatingAndPickRateByModel() throws {
        let report = PromptStatsService.report(for: rows, calendar: calendar)
        let jugg = try XCTUnwrap(report.qualityByModel.first { $0.name == "juggernaut" })
        XCTAssertEqual(jugg.count, 2)
        XCTAssertEqual(jugg.ratedCount, 2)
        XCTAssertEqual(try XCTUnwrap(jugg.averageRating), 4, accuracy: 0.001)
        XCTAssertEqual(jugg.pickCount, 1)
        XCTAssertEqual(jugg.pickRate, 0.5, accuracy: 0.001)
        let flux = try XCTUnwrap(report.qualityByModel.first { $0.name == "flux1-dev" })
        XCTAssertNil(flux.averageRating, "unrated files don't count as zero stars")
        XCTAssertEqual(flux.rejectCount, 1)
        XCTAssertEqual(PromptStatsService.paths(in: rows, model: "juggernaut"), ["/l/2.png", "/l/1.png"])
        XCTAssertEqual(PromptStatsService.paths(in: rows, sampler: "euler"), ["/l/3.png"])
    }

    func testMonthsAndDaysAreZeroFilled() {
        let report = PromptStatsService.report(for: rows, calendar: calendar)
        XCTAssertEqual(report.months.map(\.month), ["2026-07", "2026-08", "2026-09"])
        XCTAssertEqual(report.months.map(\.total), [2, 0, 1])
        XCTAssertEqual(report.months[0].byModel, ["juggernaut": 2])
        XCTAssertEqual(report.days.count, PromptStatsService.dayWindow)
        XCTAssertEqual(report.days.last, PromptStatsCount(label: "2026-09-10", count: 1))
        XCTAssertEqual(report.days.reduce(0) { $0 + $1.count }, 1, "July is outside the 60-day window")
    }

    func testEmptyReport() {
        XCTAssertTrue(PromptStatsService.report(for: []).isEmpty)
        XCTAssertEqual(PromptStatsService.normalizedModel("  "), PromptStatsService.unknownModel)
        XCTAssertEqual(PromptStatsService.normalizedModel("C:\\models\\dreamshaper_8.ckpt"), "dreamshaper_8")
    }
}

// MARK: - Library index rows

final class PromptStatsIndexTests: TempDirectoryTestCase {
    func testStatsRowsReadPromptAndParameters() async throws {
        let library = tempDir.appendingPathComponent("lib", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let plib = library.appendingPathComponent("one.plib")
        let json = #"{"prompt": "a red fox, snow", "generationInfo": {"model": "sdxl", "aspectRatio": "1:1", "timestamp": "", "numberOfImages": 0}, "images": []}"#
        try Data(json.utf8).write(to: plib)

        let service = LibraryIndexService(databaseURL: tempDir.appendingPathComponent("index.sqlite"))
        await service.indexLibrary(root: library, progress: nil)
        let rows = await service.statsRows(under: library)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.model, "sdxl")
        XCTAssertTrue(rows.first?.prompt.contains("a red fox") == true)
        let byPath = await service.statsRows(under: nil, paths: [plib.path, "/missing.png"])
        XCTAssertEqual(byPath.map(\.path), [plib.path])
    }
}
