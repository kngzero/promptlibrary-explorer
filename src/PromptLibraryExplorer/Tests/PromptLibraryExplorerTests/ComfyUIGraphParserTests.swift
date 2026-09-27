import XCTest
@testable import PromptLibraryExplorer

final class ComfyUIGraphParserTests: TempDirectoryTestCase {
    private func field(_ extraction: ComfyUIGraphParser.Extraction, _ label: String) -> String? {
        extraction.fields.first { $0.label == label }?.value
    }

    /// SD1.5-style graph: prompt text from a primitive node, positive combined via
    /// ConditioningCombine, a LoraLoader between checkpoint and sampler.
    static let sd15Graph = """
    {
      "4": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": "dreamshaper_8.safetensors"}},
      "10": {"class_type": "LoraLoader", "inputs": {"model": ["4", 0], "clip": ["4", 1],
             "lora_name": "add_detail.safetensors", "strength_model": 0.8, "strength_clip": 0.8}},
      "20": {"class_type": "PrimitiveStringMultiline", "inputs": {"value": "a red fox in the snow"}},
      "6": {"class_type": "CLIPTextEncode", "inputs": {"text": ["20", 0], "clip": ["10", 1]}},
      "8": {"class_type": "CLIPTextEncode", "inputs": {"text": "golden hour lighting", "clip": ["10", 1]}},
      "9": {"class_type": "ConditioningCombine", "inputs": {"conditioning_1": ["6", 0], "conditioning_2": ["8", 0]}},
      "7": {"class_type": "CLIPTextEncode", "inputs": {"text": "blurry, lowres", "clip": ["10", 1]}},
      "5": {"class_type": "EmptyLatentImage", "inputs": {"width": 832, "height": 1216, "batch_size": 1}},
      "3": {"class_type": "KSampler", "inputs": {"seed": 123456789, "steps": 28, "cfg": 6.5,
            "sampler_name": "dpmpp_2m", "scheduler": "karras", "denoise": 1,
            "model": ["10", 0], "positive": ["9", 0], "negative": ["7", 0], "latent_image": ["5", 0]}}
    }
    """

    func testAPIGraphWithCombineLoraAndPrimitive() throws {
        let x = try XCTUnwrap(ComfyUIGraphParser.extract(apiGraphJSON: Self.sd15Graph))
        XCTAssertEqual(x.prompt, "a red fox in the snow\ngolden hour lighting")
        XCTAssertEqual(x.negativePrompt, "blurry, lowres")
        XCTAssertEqual(x.model, "dreamshaper_8.safetensors")

        let params = GenerationParameters(fields: x.fields)
        XCTAssertEqual(params.seed, "123456789")
        XCTAssertEqual(params.steps, "28")
        XCTAssertEqual(params.cfg, "6.5")
        XCTAssertEqual(params.sampler, "dpmpp_2m")
        XCTAssertEqual(params.width, 832)
        XCTAssertEqual(params.height, 1216)
        XCTAssertEqual(field(x, "Scheduler"), "karras")
        XCTAssertEqual(field(x, "LoRAs"), "add_detail.safetensors (0.8)")
        XCTAssertNil(field(x, "Denoising strength"), "denoise 1 is not reported")
        XCTAssertEqual(field(x, "Generator"), "ComfyUI")
    }

    func testAPIGraphWrappedInPromptKey() throws {
        let wrapped = "{\"prompt\": \(Self.sd15Graph), \"extra_data\": {}}"
        XCTAssertEqual(ComfyUIGraphParser.extract(apiGraphJSON: wrapped)?.negativePrompt, "blurry, lowres")
    }

    func testSDXLTextGAndTextL() throws {
        let graph = """
        {
          "4": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": "sd_xl_base_1.0.safetensors"}},
          "6": {"class_type": "CLIPTextEncodeSDXL", "inputs": {"text_g": "epic mountain landscape", "text_l": "oil painting",
                "clip": ["4", 1], "width": 4096, "height": 4096, "crop_w": 0, "crop_h": 0, "target_width": 4096, "target_height": 4096}},
          "7": {"class_type": "CLIPTextEncodeSDXL", "inputs": {"text_g": "ugly", "text_l": "ugly", "clip": ["4", 1]}},
          "5": {"class_type": "EmptyLatentImage", "inputs": {"width": 1024, "height": 1024, "batch_size": 1}},
          "3": {"class_type": "KSamplerAdvanced", "inputs": {"add_noise": "enable", "noise_seed": 42, "steps": 40, "cfg": 8,
                "sampler_name": "euler", "scheduler": "normal", "start_at_step": 0, "end_at_step": 10000,
                "model": ["4", 0], "positive": ["6", 0], "negative": ["7", 0], "latent_image": ["5", 0]}}
        }
        """
        let x = try XCTUnwrap(ComfyUIGraphParser.extract(apiGraphJSON: graph))
        XCTAssertEqual(x.prompt, "epic mountain landscape\noil painting")
        XCTAssertEqual(x.negativePrompt, "ugly")
        XCTAssertEqual(x.model, "sd_xl_base_1.0.safetensors")
        let params = GenerationParameters(fields: x.fields)
        XCTAssertEqual(params.seed, "42")
        XCTAssertEqual(params.steps, "40")
        XCTAssertEqual(params.cfg, "8")
        XCTAssertEqual(params.sampler, "euler")
        XCTAssertEqual(params.width, 1024)
        XCTAssertEqual(params.height, 1024)
    }

    func testFluxSamplerCustomAdvanced() throws {
        let graph = """
        {
          "1": {"class_type": "UNETLoader", "inputs": {"unet_name": "flux1-dev.safetensors", "weight_dtype": "default"}},
          "2": {"class_type": "DualCLIPLoader", "inputs": {"clip_name1": "t5xxl.safetensors", "clip_name2": "clip_l.safetensors", "type": "flux"}},
          "3": {"class_type": "CLIPTextEncode", "inputs": {"text": "a neon city at night", "clip": ["2", 0]}},
          "4": {"class_type": "FluxGuidance", "inputs": {"conditioning": ["3", 0], "guidance": 3.5}},
          "5": {"class_type": "BasicGuider", "inputs": {"model": ["1", 0], "conditioning": ["4", 0]}},
          "6": {"class_type": "RandomNoise", "inputs": {"noise_seed": 777}},
          "7": {"class_type": "KSamplerSelect", "inputs": {"sampler_name": "euler"}},
          "8": {"class_type": "BasicScheduler", "inputs": {"model": ["1", 0], "scheduler": "simple", "steps": 20, "denoise": 1}},
          "9": {"class_type": "EmptySD3LatentImage", "inputs": {"width": 1024, "height": 768, "batch_size": 1}},
          "10": {"class_type": "SamplerCustomAdvanced", "inputs": {"noise": ["6", 0], "guider": ["5", 0], "sampler": ["7", 0],
                 "sigmas": ["8", 0], "latent_image": ["9", 0]}}
        }
        """
        let x = try XCTUnwrap(ComfyUIGraphParser.extract(apiGraphJSON: graph))
        XCTAssertEqual(x.prompt, "a neon city at night")
        XCTAssertNil(x.negativePrompt)
        XCTAssertEqual(x.model, "flux1-dev.safetensors")
        let params = GenerationParameters(fields: x.fields)
        XCTAssertEqual(params.seed, "777")
        XCTAssertEqual(params.steps, "20")
        XCTAssertEqual(params.sampler, "euler")
        XCTAssertEqual(params.width, 1024)
        XCTAssertEqual(params.height, 768)
        XCTAssertEqual(field(x, "Guidance"), "3.5")
        XCTAssertEqual(field(x, "Scheduler"), "simple")
        XCTAssertNil(field(x, "CFG scale"), "BasicGuider has no cfg")
    }

    static let workflowJSON = """
    {
      "nodes": [
        {"id": 4, "type": "CheckpointLoaderSimple", "widgets_values": ["realistic_vision.safetensors"]},
        {"id": 6, "type": "CLIPTextEncode", "inputs": [{"name": "clip", "type": "CLIP", "link": 1}],
         "widgets_values": ["portrait of an astronaut"]},
        {"id": 7, "type": "CLIPTextEncode", "inputs": [{"name": "clip", "type": "CLIP", "link": 2}],
         "widgets_values": ["cartoon, drawing"]},
        {"id": 5, "type": "EmptyLatentImage", "widgets_values": [768, 512, 1]},
        {"id": 12, "type": "LoraLoader", "widgets_values": ["film_grain.safetensors", 0.6, 0.6]},
        {"id": 3, "type": "KSampler", "inputs": [
            {"name": "model", "type": "MODEL", "link": 3},
            {"name": "positive", "type": "CONDITIONING", "link": 4},
            {"name": "negative", "type": "CONDITIONING", "link": 5},
            {"name": "latent_image", "type": "LATENT", "link": 6}],
         "widgets_values": [98765, "randomize", 25, 7.5, "euler_ancestral", "normal", 1]}
      ],
      "links": [[1, 4, 1, 6, 0, "CLIP"], [2, 4, 1, 7, 0, "CLIP"], [3, 4, 0, 3, 0, "MODEL"],
                [4, 6, 0, 3, 1, "CONDITIONING"], [5, 7, 0, 3, 2, "CONDITIONING"], [6, 5, 0, 3, 3, "LATENT"]]
    }
    """

    func testWorkflowOnlyExtraction() throws {
        let x = try XCTUnwrap(ComfyUIGraphParser.extract(workflowJSON: Self.workflowJSON))
        XCTAssertEqual(x.prompt, "portrait of an astronaut")
        XCTAssertEqual(x.negativePrompt, "cartoon, drawing")
        XCTAssertEqual(x.model, "realistic_vision.safetensors")
        let params = GenerationParameters(fields: x.fields)
        XCTAssertEqual(params.seed, "98765")
        XCTAssertEqual(params.steps, "25")
        XCTAssertEqual(params.cfg, "7.5")
        XCTAssertEqual(params.sampler, "euler_ancestral")
        XCTAssertEqual(params.width, 768)
        XCTAssertEqual(params.height, 512)
        XCTAssertEqual(field(x, "LoRAs"), "film_grain.safetensors (0.6)")
    }

    func testInvalidJSONReturnsNil() {
        XCTAssertNil(ComfyUIGraphParser.extract(apiGraphJSON: "{not json"))
        XCTAssertNil(ComfyUIGraphParser.extract(apiGraphJSON: #"{"a": 1}"#))
        XCTAssertNil(ComfyUIGraphParser.extract(workflowJSON: #"{"nodes": []}"#))
    }

    func testSamplerWithoutTextFallsBackToEncodersInNodeOrder() throws {
        let graph = """
        {"2": {"class_type": "CLIPTextEncode", "inputs": {"text": "second encoder"}},
         "1": {"class_type": "CLIPTextEncode", "inputs": {"text": "first encoder"}},
         "9": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": "m.ckpt"}}}
        """
        let x = try XCTUnwrap(ComfyUIGraphParser.extract(apiGraphJSON: graph))
        XCTAssertEqual(x.prompt, "first encoder")
        XCTAssertEqual(x.negativePrompt, "second encoder")
        XCTAssertEqual(x.model, "m.ckpt")
    }

    // MARK: End to end through the PNG parser

    func testParserUsesAPIGraphFromPNGPromptChunk() throws {
        let url = try writeFile("comfy.png", PNGFixture.png(with: [PNGFixture.tEXt("prompt", Self.sd15Graph)]))
        let parsed = ImageMetadataParser.readMetadataUncached(at: url)
        XCTAssertEqual(parsed.prompt, "a red fox in the snow\ngolden hour lighting")
        XCTAssertEqual(parsed.negativePrompt, "blurry, lowres")
        XCTAssertEqual(parsed.model, "dreamshaper_8.safetensors")
        XCTAssertEqual(parsed.generationParameters.seed, "123456789")
        XCTAssertEqual(parsed.generationParameters.width, 832)
        XCTAssertNotNil(parsed.comfyPromptJSON)
    }

    func testParserFallsBackToWorkflowChunk() throws {
        let url = try writeFile("wf.png", PNGFixture.png(with: [PNGFixture.zTXt("workflow", Self.workflowJSON)]))
        let parsed = ImageMetadataParser.readMetadataUncached(at: url)
        XCTAssertNil(parsed.comfyPromptJSON)
        XCTAssertNotNil(parsed.comfyWorkflowJSON)
        XCTAssertEqual(parsed.prompt, "portrait of an astronaut")
        XCTAssertEqual(parsed.negativePrompt, "cartoon, drawing")
        XCTAssertEqual(parsed.generationParameters.steps, "25")
        XCTAssertEqual(parsed.generationParameters.sampler, "euler_ancestral")
    }

    func testA1111QuotedParameterValueIsShownIntact() throws {
        let text = """
        prompt text
        Steps: 20, Seed: 3, Lora hashes: "detail: 111aaa, style: 222bbb", Version: v1.9.4
        """
        let url = try writeFile("quoted.png", PNGFixture.png(with: [PNGFixture.tEXt("parameters", text)]))
        let parsed = ImageMetadataParser.readMetadataUncached(at: url)
        XCTAssertEqual(parsed.generationParameters.seed, "3")
        XCTAssertEqual(parsed.fields.first { $0.label == "Lora hashes" }?.value, #""detail: 111aaa, style: 222bbb""#)
        XCTAssertNil(parsed.fields.first { $0.label == "style" }, "a fake `style` field was split out of the quoted value")
    }
}
