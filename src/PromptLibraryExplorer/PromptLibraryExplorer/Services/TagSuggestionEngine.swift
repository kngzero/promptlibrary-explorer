import Foundation

/// One suggested tag. Suggestions are shown for review only; the app never applies one
/// without an explicit click (chip / Add All) or a confirmed Apply Suggested Tags… sheet.
struct TagSuggestion: Identifiable, Hashable, Sendable {
    enum Source: String, Sendable, Hashable {
        case content   // Vision classification
        case colour    // dominant colour family
        case model     // generation model name
    }

    let name: String
    let source: Source
    /// 0…1 (1 for colour / model).
    let confidence: Double

    var id: String { name.lowercased() }
}

/// Turns stored analysis into tag suggestions: Vision labels above a confidence threshold,
/// mapped to readable names with overly generic ones filtered, plus the colour family and
/// the model name.
enum TagSuggestionEngine {
    static let defaultThreshold = 0.35
    static let defaultContentLimit = 5

    /// Vision labels too broad to be useful as tags.
    static let genericLabels: Set<String> = [
        "structure", "material", "textile", "people", "adult", "child", "consumer_electronics",
        "machine", "container", "document", "text", "wood_processed", "furniture", "art",
        "illustrations", "graphic", "blue_sky", "sky", "outdoor", "indoor", "interior_room",
        "land", "liquid", "water_body", "plant", "vegetation", "object", "decoration", "clothing",
        "headgear", "footwear", "arm", "hand", "leg", "hair", "face", "skin", "light", "dark",
        "wall", "floor", "ceiling", "shape", "pattern", "screenshot", "tool", "equipment",
    ]

    /// Readable names for identifiers whose plain form reads oddly.
    static let readableOverrides: [String: String] = [
        "people_portrait": "portrait",
        "portrait_photography": "portrait",
        "cityscape": "cityscape",
        "night_sky": "night sky",
        "sunset_sunrise": "sunset",
        "fireworks": "fireworks",
        "motorcycle": "motorbike",
        "canine": "dog",
        "feline": "cat",
    ]

    /// "hot_air_balloon" → "hot air balloon".
    static func readableName(forIdentifier identifier: String) -> String {
        if let override = readableOverrides[identifier] { return override }
        return identifier
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Content labels at or above `threshold`, generic ones dropped, readable, strongest
    /// first, at most `limit`, unique by readable name.
    static func contentSuggestions(
        from labels: [ImageLabel],
        threshold: Double = defaultThreshold,
        limit: Int = defaultContentLimit
    ) -> [TagSuggestion] {
        var seen = Set<String>()
        var result: [TagSuggestion] = []
        for label in labels.sorted(by: { $0.confidence != $1.confidence ? $0.confidence > $1.confidence : $0.identifier < $1.identifier }) {
            guard label.confidence >= threshold, !genericLabels.contains(label.identifier) else { continue }
            let name = readableName(forIdentifier: label.identifier)
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { continue }
            result.append(TagSuggestion(name: name, source: .content, confidence: label.confidence))
            if result.count >= limit { break }
        }
        return result
    }

    /// The heaviest dominant colour's family ("red", "blue" …); neutrals aren't suggested.
    static func colourSuggestion(from colors: [DominantColor]) -> TagSuggestion? {
        guard let first = colors.first, first.weight >= 0.2, let family = ColorFamily(hex: first.hex) else { return nil }
        switch family {
        case .neutral: return nil
        default: return TagSuggestion(name: family.title.lowercased(), source: .colour, confidence: 1)
        }
    }

    /// A readable model name: file extension, hash suffixes and version noise removed.
    static func modelSuggestion(from model: String?) -> TagSuggestion? {
        guard var name = model?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, name != "N/A" else { return nil }
        name = (name as NSString).lastPathComponent
        name = name.replacingOccurrences(of: #"\.(safetensors|ckpt|pt|pth|bin|gguf|sft)$"#, with: "", options: [.regularExpression, .caseInsensitive])
        name = name.replacingOccurrences(of: #"\s*[\[\(][0-9a-fA-F]{6,}[\]\)]"#, with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard name.count >= 2, name.count <= 48 else { return nil }
        return TagSuggestion(name: name, source: .model, confidence: 1)
    }

    /// Everything suggested for one file, minus tags it already has (case-insensitive).
    static func suggestions(
        labels: [ImageLabel]?,
        colors: [DominantColor],
        model: String?,
        existingTagNames: [String],
        threshold: Double = defaultThreshold,
        contentLimit: Int = defaultContentLimit
    ) -> [TagSuggestion] {
        let existing = Set(existingTagNames.map { $0.lowercased() })
        var seen = existing
        var result: [TagSuggestion] = []
        let all = contentSuggestions(from: labels ?? [], threshold: threshold, limit: contentLimit)
            + [colourSuggestion(from: colors), modelSuggestion(from: model)].compactMap { $0 }
        for suggestion in all where seen.insert(suggestion.id).inserted {
            result.append(suggestion)
        }
        return result
    }
}

// MARK: - Batch review (Apply Suggested Tags…)

/// A reviewable plan: per file, suggested tags with a checkbox each. Applying needs an
/// explicit confirmation; without it nothing changes.
struct TagSuggestionPlan: Equatable, Sendable {
    struct Choice: Identifiable, Equatable, Sendable {
        let suggestion: TagSuggestion
        var isChecked: Bool
        var id: String { suggestion.id }
    }

    struct Row: Identifiable, Equatable, Sendable {
        let path: String
        var choices: [Choice]
        var id: String { path }
        var name: String { (path as NSString).lastPathComponent }
    }

    var rows: [Row] = []

    init(rows: [Row] = []) {
        self.rows = rows
    }

    /// Every suggestion starts checked; the sheet is where the user unchecks.
    init(suggestions: [(path: String, suggestions: [TagSuggestion])]) {
        rows = suggestions
            .filter { !$0.suggestions.isEmpty }
            .map { Row(path: $0.path, choices: $0.suggestions.map { Choice(suggestion: $0, isChecked: true) }) }
    }

    var checkedCount: Int { rows.reduce(0) { $0 + $1.choices.filter(\.isChecked).count } }
    var fileCount: Int { rows.filter { $0.choices.contains(where: \.isChecked) }.count }

    mutating func toggle(path: String, suggestionID: String) {
        guard let r = rows.firstIndex(where: { $0.path == path }),
              let c = rows[r].choices.firstIndex(where: { $0.id == suggestionID })
        else { return }
        rows[r].choices[c].isChecked.toggle()
    }

    mutating func setAll(_ checked: Bool) {
        for r in rows.indices {
            for c in rows[r].choices.indices { rows[r].choices[c].isChecked = checked }
        }
    }

    /// Path → tag names to add (checked only).
    var assignments: [String: [String]] {
        var result: [String: [String]] = [:]
        for row in rows {
            let names = row.choices.filter(\.isChecked).map(\.suggestion.name)
            if !names.isEmpty { result[row.path] = names }
        }
        return result
    }
}

enum TagSuggestionApplyOutcome: Equatable {
    /// Nothing was changed: the user hasn't confirmed.
    case needsConfirmation
    case applied(files: Int, tags: Int, createdTags: [String])
}

enum TagSuggestionApplier {
    /// Adds the plan's checked tags. Without `confirmed` it changes nothing. Tags are
    /// matched to existing ones by name (case-insensitive) and created when missing;
    /// existing assignments are kept (suggestions only ever add).
    @discardableResult
    static func apply(_ plan: TagSuggestionPlan, confirmed: Bool, tags service: TagService) -> TagSuggestionApplyOutcome {
        guard confirmed else { return .needsConfirmation }
        let wanted = plan.assignments
        guard !wanted.isEmpty else { return .applied(files: 0, tags: 0, createdTags: []) }
        var tags = service.loadTags()
        var idByName: [String: UUID] = [:]
        for tag in tags where idByName[tag.name.lowercased()] == nil { idByName[tag.name.lowercased()] = tag.id }
        var created: [String] = []
        func id(for name: String) -> UUID {
            let key = name.lowercased()
            if let id = idByName[key] { return id }
            let tag = FileTag(name: name, colorHex: FinderTagMerge.defaultColour(for: name))
            tags.append(tag)
            idByName[key] = tag.id
            created.append(name)
            return tag.id
        }
        var assignments = service.loadAssignments()
        var added = 0
        for (path, names) in wanted {
            var ids = assignments[path] ?? []
            for name in names {
                let tagID = id(for: name)
                if !ids.contains(tagID) {
                    ids.append(tagID)
                    added += 1
                }
            }
            assignments[path] = ids
        }
        if !created.isEmpty { service.saveTags(tags) }
        service.saveAssignments(assignments)
        return .applied(files: wanted.count, tags: added, createdTags: created)
    }
}
