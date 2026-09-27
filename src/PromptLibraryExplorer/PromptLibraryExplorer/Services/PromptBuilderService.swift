import Foundation

// MARK: - Prompt Builder (pure model)

/// What the Prompt Builder composes: prompt, negative prompt and a parameter
/// block. Parameters are strings as typed; blank means "not set".
struct PromptDraft: Equatable, Codable, Sendable {
    var prompt = ""
    var negative = ""
    var model = ""
    var sampler = ""
    var seed = ""
    var steps = ""
    var cfg = ""
    var width = ""
    var height = ""

    /// The file the draft was started from (for Re-run in ComfyUI and the output folder).
    var sourcePath: String?
    /// The source file's ComfyUI API graph, when it has one.
    var comfyGraphJSON: String?

    var parameters: GenerationParameters {
        func clean(_ s: String) -> String? { s.trimmingCharacters(in: .whitespacesAndNewlines).promptNilIfEmpty }
        return GenerationParameters(
            model: clean(model),
            sampler: clean(sampler),
            seed: clean(seed),
            steps: clean(steps),
            cfg: clean(cfg),
            width: Int(width.trimmingCharacters(in: .whitespaces)),
            height: Int(height.trimmingCharacters(in: .whitespaces))
        )
    }

    init() {}

    init(prompt: String, negative: String = "", parameters: GenerationParameters = GenerationParameters()) {
        self.prompt = prompt
        self.negative = negative
        model = parameters.model ?? ""
        sampler = parameters.sampler ?? ""
        seed = parameters.seed ?? ""
        steps = parameters.steps ?? ""
        cfg = parameters.cfg ?? ""
        width = parameters.width.map(String.init) ?? ""
        height = parameters.height.map(String.init) ?? ""
    }
}

/// A comma-separated phrase of a prompt, with its SD attention weight.
struct PromptPhrase: Equatable, Hashable, Sendable {
    /// The phrase without weight syntax.
    let text: String
    /// 1 when unweighted.
    let weight: Double
}

enum PromptBuilderService {
    static let weightStep = 0.1
    static let weightRange: ClosedRange<Double> = 0.1...2.0

    // MARK: Drafts

    static func draft(from entry: PromptEntry) -> PromptDraft {
        var draft = PromptDraft(
            prompt: entry.prompt,
            negative: entry.blindPrompt ?? "",
            parameters: entry.promptWorkflowParameters
        )
        draft.sourcePath = entry.sourcePath
        draft.comfyGraphJSON = entry.comfyPromptJSON
        return draft
    }

    /// A PromptEntry carrying the draft, so PromptFormatService formats it
    /// exactly like a file's prompt.
    static func entry(for draft: PromptDraft, prompt: String? = nil) -> PromptEntry {
        let params = draft.parameters
        var fields: [PromptMetadataField] = []
        if let v = params.model { fields.append(.init(label: "Model", value: v)) }
        if let v = params.sampler { fields.append(.init(label: "Sampler", value: v)) }
        if let v = params.seed { fields.append(.init(label: "Seed", value: v)) }
        if let v = params.steps { fields.append(.init(label: "Steps", value: v)) }
        if let v = params.cfg { fields.append(.init(label: "CFG scale", value: v)) }
        if let w = params.width, let h = params.height { fields.append(.init(label: "Size", value: "\(w)x\(h)")) }
        let negative = draft.negative.trimmingCharacters(in: .whitespacesAndNewlines)
        return PromptEntry(
            prompt: prompt ?? draft.prompt,
            blindPrompt: negative.isEmpty ? nil : negative,
            generationInfo: GenerationInfo(
                aspectRatio: aspectRatio(width: params.width, height: params.height),
                model: params.model ?? "N/A",
                timestamp: "",
                numberOfImages: 1
            ),
            images: [],
            referenceImages: [],
            rawImages: [],
            rawReferenceImages: [],
            embeddedMetadata: fields
        )
    }

    /// The draft in `format`. Midjourney and DALL-E don't understand SD
    /// `(phrase:1.2)` weights, so those previews carry the bare phrases.
    static func format(_ draft: PromptDraft, as format: PromptCopyFormat) -> String {
        switch format {
        case .midjourney, .dalle:
            return PromptFormatService.format(entry(for: draft, prompt: stripWeights(draft.prompt)), as: format)
        case .plain, .stableDiffusion, .json:
            return PromptFormatService.format(entry(for: draft), as: format)
        }
    }

    static func aspectRatio(width: Int?, height: Int?) -> AspectRatio {
        guard let width, let height, width > 0, height > 0 else { return .notAvailable }
        let ratio = Double(width) / Double(height)
        let known: [(Double, AspectRatio)] = [
            (1, .oneToOne), (16.0 / 9, .sixteenToNine), (9.0 / 16, .nineToSixteen), (4.0 / 3, .fourToThree), (3.0 / 4, .threeToFour),
        ]
        for (value, aspect) in known where abs(ratio - value) / value < 0.02 { return aspect }
        return .notAvailable
    }

    // MARK: Phrases and weights

    /// Top-level comma-separated phrases (commas inside brackets don't split).
    static func phrases(in prompt: String) -> [PromptPhrase] {
        splitTopLevel(prompt).map { parseWeighted($0) }
    }

    /// "(red dress:1.2)" → ("red dress", 1.2); "(red dress)" → 1.1; "[red dress]" → 0.9.
    static func parseWeighted(_ raw: String) -> PromptPhrase {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("("), text.hasSuffix(")"), text.count >= 2, isBalancedInner(text) {
            let inner = String(text.dropFirst().dropLast())
            if let colon = inner.lastIndex(of: ":"),
               let weight = Double(inner[inner.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            {
                return PromptPhrase(text: String(inner[..<colon]).trimmingCharacters(in: .whitespaces), weight: weight)
            }
            return PromptPhrase(text: inner.trimmingCharacters(in: .whitespaces), weight: 1.1)
        }
        if text.hasPrefix("["), text.hasSuffix("]"), text.count >= 2, isBalancedInner(text) {
            return PromptPhrase(text: String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces), weight: 0.9)
        }
        return PromptPhrase(text: text, weight: 1)
    }

    /// `phrase` in SD weight syntax; weight 1 gives the bare phrase.
    static func weighted(_ phrase: String, weight: Double) -> String {
        let text = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let clamped = min(max(weight, weightRange.lowerBound), weightRange.upperBound)
        let rounded = (clamped * 100).rounded() / 100
        guard abs(rounded - 1) > 0.0001, !text.isEmpty else { return text }
        return "(\(text):\(formatWeight(rounded)))"
    }

    static func formatWeight(_ weight: Double) -> String {
        var s = String(format: "%.2f", weight)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s += "0" }
        return s
    }

    /// Rewrites phrase `index` of `prompt` with `weight`; the other phrases are
    /// kept verbatim and re-joined with ", ".
    static func setWeight(_ weight: Double, forPhraseAt index: Int, in prompt: String) -> String {
        var parts = splitTopLevel(prompt)
        guard parts.indices.contains(index) else { return prompt }
        parts[index] = weighted(parseWeighted(parts[index]).text, weight: weight)
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: ", ")
    }

    static func adjustWeight(by delta: Double, forPhraseAt index: Int, in prompt: String) -> String {
        let parts = splitTopLevel(prompt)
        guard parts.indices.contains(index) else { return prompt }
        return setWeight(parseWeighted(parts[index]).weight + delta, forPhraseAt: index, in: prompt)
    }

    /// Removes `(phrase:w)` weights (and bare emphasis brackets around whole phrases).
    static func stripWeights(_ prompt: String) -> String {
        splitTopLevel(prompt)
            .map { parseWeighted($0).text }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    /// Appends `phrase` as a new comma-separated phrase.
    static func appendPhrase(_ phrase: String, to prompt: String) -> String {
        let addition = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !addition.isEmpty else { return prompt }
        var base = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return addition }
        while base.hasSuffix(",") { base.removeLast() }
        return base + ", " + addition
    }

    /// Phrases of a library-search snippet ("…red «dress», blue sky…") that contain a match.
    static func phrases(fromSnippet snippet: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for segment in snippet.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == ";" }) {
            guard segment.contains("«") else { continue }
            let clean = segment
                .replacingOccurrences(of: "«", with: "")
                .replacingOccurrences(of: "»", with: "")
                .replacingOccurrences(of: "…", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters.subtracting(CharacterSet(charactersIn: "()[]"))))
            guard !clean.isEmpty, clean.count <= 120, seen.insert(clean.lowercased()).inserted else { continue }
            result.append(clean)
        }
        return result
    }

    // MARK: Private

    private static func splitTopLevel(_ prompt: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        for character in prompt {
            switch character {
            case "(", "[", "{", "<": depth += 1; current.append(character)
            case ")", "]", "}", ">": depth = max(0, depth - 1); current.append(character)
            case "," where depth == 0, "\n" where depth == 0:
                parts.append(current)
                current = ""
            default:
                current.append(character)
            }
        }
        parts.append(current)
        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// True when the outer brackets of `text` enclose the whole phrase ("(a) (b)" is not).
    private static func isBalancedInner(_ text: String) -> Bool {
        var depth = 0
        for (offset, character) in text.enumerated() {
            if character == "(" || character == "[" { depth += 1 }
            if character == ")" || character == "]" {
                depth -= 1
                if depth == 0, offset != text.count - 1 { return false }
            }
        }
        return depth == 0
    }
}
