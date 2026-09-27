import Foundation

/// Formats a prompt can be copied as. Mirrors `PromptExportFormat` (Views/Shared/PromptExportView.swift)
/// as pure functions, plus `plain` (positive prompt only) and `json`.
enum PromptCopyFormat: String, CaseIterable, Identifiable {
    case plain
    case midjourney
    case stableDiffusion
    case dalle
    case json

    var id: String { rawValue }

    var title: String {
        switch self {
        case .plain: return "Plain Text"
        case .midjourney: return "Midjourney"
        case .stableDiffusion: return "Stable Diffusion"
        case .dalle: return "DALL-E"
        case .json: return "JSON"
        }
    }

    var systemImage: String {
        switch self {
        case .plain: return "doc.plaintext"
        case .midjourney: return "sparkle"
        case .stableDiffusion: return "wand.and.stars"
        case .dalle: return "paintbrush"
        case .json: return "curlybraces"
        }
    }
}

enum PromptFormatService {
    static func format(_ entry: PromptEntry, as format: PromptCopyFormat) -> String {
        let prompt = entry.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let negative = entry.blindPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let params = GenerationParameters(fields: entry.embeddedMetadata)
        let entryModel = entry.generationInfo.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = (entryModel.isEmpty || entryModel == "N/A") ? (params.model ?? "") : entryModel
        let ratio = entry.generationInfo.aspectRatio.rawValue
        let hasRatio = ratio != "N/A"

        switch format {
        case .plain:
            return prompt

        case .midjourney:
            var result = "/imagine prompt: \(prompt)"
            if hasRatio { result += " --ar \(ratio)" }
            if !negative.isEmpty { result += " --no \(negative)" }
            if let seed = params.seed, !seed.isEmpty, Int(seed) != nil { result += " --seed \(seed)" }
            return result

        case .stableDiffusion:
            var result = prompt
            if !negative.isEmpty { result += "\nNegative prompt: \(negative)" }
            var parts: [String] = []
            parts.append("Steps: \(params.steps ?? "20")")
            parts.append("Sampler: \(params.sampler ?? "Euler a")")
            parts.append("CFG scale: \(params.cfg ?? "7")")
            if let seed = params.seed { parts.append("Seed: \(seed)") }
            if let w = params.width, let h = params.height {
                parts.append("Size: \(w)x\(h)")
            } else if hasRatio {
                let (w, h) = sdDimensions(for: ratio)
                parts.append("Size: \(w)x\(h)")
            }
            if !model.isEmpty { parts.append("Model: \(model)") }
            result += "\n" + parts.joined(separator: ", ")
            return result

        case .dalle:
            var result = prompt
            if hasRatio { result += "\n\nSize: \(dalleSize(for: ratio))" }
            return result

        case .json:
            var object: [String: Any] = ["prompt": prompt]
            if !negative.isEmpty { object["negativePrompt"] = negative }
            var parameters: [String: Any] = [:]
            if !model.isEmpty { parameters["model"] = model }
            if let v = params.sampler { parameters["sampler"] = v }
            if let v = params.seed { parameters["seed"] = Int(v).map { $0 as Any } ?? v }
            if let v = params.steps { parameters["steps"] = Int(v).map { $0 as Any } ?? v }
            if let v = params.cfg { parameters["cfg"] = Double(v).map { $0 as Any } ?? v }
            if let v = params.width { parameters["width"] = v }
            if let v = params.height { parameters["height"] = v }
            if hasRatio { parameters["aspectRatio"] = ratio }
            if !parameters.isEmpty { object["parameters"] = parameters }
            guard JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(
                      withJSONObject: object,
                      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                  ),
                  let string = String(data: data, encoding: .utf8)
            else { return prompt }
            return string
        }
    }

    private static func sdDimensions(for ratio: String) -> (Int, Int) {
        switch ratio {
        case "1:1": return (512, 512)
        case "16:9": return (768, 432)
        case "9:16": return (432, 768)
        case "4:3": return (640, 480)
        case "3:4": return (480, 640)
        default: return (512, 512)
        }
    }

    private static func dalleSize(for ratio: String) -> String {
        switch ratio {
        case "1:1": return "1024x1024"
        case "16:9": return "1792x1024"
        case "9:16": return "1024x1792"
        default: return "1024x1024"
        }
    }
}
