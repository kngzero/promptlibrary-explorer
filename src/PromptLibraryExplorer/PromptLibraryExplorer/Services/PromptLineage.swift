import Foundation

// MARK: - Prompt Lineage (pure model)

/// One file's prompt and parameters, as read for a lineage chain.
struct PromptLineageInput: Sendable, Hashable {
    let path: String
    let name: String
    /// Creation date, else modification date.
    let date: Date?
    let prompt: String
    let negative: String
    let parameters: GenerationParameters
}

/// A step of the chain: the file plus what changed since the previous step.
struct PromptLineageStep: Identifiable, Sendable, Hashable {
    var id: String { input.path }
    let index: Int
    let input: PromptLineageInput
    /// Diff vs the previous step's prompt; nil for the first step.
    let promptDiff: [PromptDiffToken]?
    let negativeDiff: [PromptDiffToken]?
    let parameterChanges: [PromptParamChange]

    var isFirst: Bool { promptDiff == nil }
}

enum PromptLineageBuilder {
    /// The most files a chain shows (each step loads a prompt and a thumbnail).
    static let maxSteps = 60

    /// Orders by date (undated last), then name, and diffs each step against the one before.
    static func build(_ inputs: [PromptLineageInput]) -> [PromptLineageStep] {
        let ordered = inputs.sorted { a, b in
            switch (a.date, b.date) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
        var steps: [PromptLineageStep] = []
        var previous: PromptLineageInput?
        for (index, input) in ordered.prefix(maxSteps).enumerated() {
            if let previous {
                steps.append(PromptLineageStep(
                    index: index,
                    input: input,
                    promptDiff: PromptTokenDiff.diff(old: previous.prompt, new: input.prompt),
                    negativeDiff: previous.negative.isEmpty && input.negative.isEmpty
                        ? []
                        : PromptTokenDiff.diff(old: previous.negative, new: input.negative),
                    parameterChanges: PromptTokenDiff.parameterChanges(old: previous.parameters, new: input.parameters)
                ))
            } else {
                steps.append(PromptLineageStep(index: index, input: input, promptDiff: nil, negativeDiff: nil, parameterChanges: []))
            }
            previous = input
        }
        return steps
    }
}

// MARK: - Parameters of a loaded entry

extension PromptEntry {
    /// Generation parameters as the app shows them: parsed metadata fields, the
    /// entry's model when no field names one, and the pixel size as a fallback.
    var promptWorkflowParameters: GenerationParameters {
        var params = GenerationParameters(fields: embeddedMetadata)
        let model = generationInfo.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if params.model == nil, !model.isEmpty, model != "N/A" { params.model = model }
        if params.width == nil || params.height == nil, let w = fileMetadata?.width, let h = fileMetadata?.height {
            params.width = w
            params.height = h
        }
        return params
    }
}
