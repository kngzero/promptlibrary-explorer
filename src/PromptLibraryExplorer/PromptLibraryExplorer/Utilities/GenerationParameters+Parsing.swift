import Foundation

extension GenerationParameters {
    var isEmpty: Bool {
        model == nil && sampler == nil && seed == nil && steps == nil && cfg == nil && width == nil && height == nil
    }

    /// `self`, with every nil field taken from `other`.
    func filling(from other: GenerationParameters) -> GenerationParameters {
        var result = self
        result.model = model ?? other.model
        result.sampler = sampler ?? other.sampler
        result.seed = seed ?? other.seed
        result.steps = steps ?? other.steps
        result.cfg = cfg ?? other.cfg
        result.width = width ?? other.width
        result.height = height ?? other.height
        return result
    }

    /// Reads parameters out of parsed metadata fields (A1111 parameter blocks,
    /// ComfyUI graphs, snapshot metadata...). `model` is the parser's own model
    /// guess, used when no field names one.
    static func parsed(from fields: [PromptMetadataField], model: String?) -> GenerationParameters {
        var result = GenerationParameters()

        func clean(_ value: String) -> String? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.uppercased() != "N/A" else { return nil }
            return trimmed
        }

        for field in fields {
            let key = field.label
                .lowercased()
                .unicodeScalars
                .filter { CharacterSet.alphanumerics.contains($0) }
                .map(String.init)
                .joined()
            guard let value = clean(field.value) else { continue }

            switch key {
            case "model", "modelname", "checkpoint", "ckptname", "basemodel":
                if result.model == nil { result.model = value }
            case "sampler", "samplername":
                if result.sampler == nil { result.sampler = value }
            case "seed", "noiseseed":
                if result.seed == nil { result.seed = value }
            case "steps":
                if result.steps == nil { result.steps = value }
            case "cfg", "cfgscale", "guidancescale", "guidance":
                if result.cfg == nil { result.cfg = value }
            case "size", "resolution", "dimensions":
                if result.width == nil || result.height == nil, let size = parseSize(value) {
                    result.width = size.width
                    result.height = size.height
                }
            case "width":
                if result.width == nil { result.width = Int(value) }
            case "height":
                if result.height == nil { result.height = Int(value) }
            default:
                break
            }
        }

        if result.model == nil, let model, let cleaned = clean(model) {
            result.model = cleaned
        }
        return result
    }

    private static func parseSize(_ value: String) -> (width: Int, height: Int)? {
        let parts = value.lowercased()
            .replacingOccurrences(of: "×", with: "x")
            .split(whereSeparator: { $0 == "x" || $0 == "*" || $0 == " " })
            .compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        return (parts[0], parts[1])
    }
}
