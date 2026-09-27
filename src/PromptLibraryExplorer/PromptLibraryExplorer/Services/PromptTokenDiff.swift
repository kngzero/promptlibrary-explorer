import Foundation

// MARK: - Token-level prompt diff (Prompt Lineage)
//
// PromptDiffView's comparison is set-based (words unique to each side), which
// can't show order or repeated words. Lineage needs a real sequence diff, so
// this is a longest-common-subsequence diff over prompt tokens.

enum PromptDiffOp: String, Equatable, Hashable, Sendable {
    case equal, added, removed
}

struct PromptDiffToken: Equatable, Hashable, Sendable {
    let text: String
    let op: PromptDiffOp
}

enum PromptTokenDiff {
    /// Characters that are tokens of their own (prompt punctuation and SD weight syntax).
    static let punctuation: Set<Character> = [",", ";", "(", ")", "[", "]", "{", "}", ":", "|", "<", ">"]

    /// Beyond this many cells the middle section is shown as a replacement
    /// (all removed, then all added) instead of running the quadratic LCS.
    static let maxLCSCells = 4_000_000

    /// Words and punctuation tokens; whitespace separates and is dropped.
    /// "(red dress:1.2), 8k" → ["(", "red", "dress", ":", "1.2", ")", ",", "8k"].
    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for character in text {
            if character.isWhitespace {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else if punctuation.contains(character) {
                if !current.isEmpty { tokens.append(current); current = "" }
                tokens.append(String(character))
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    static func diff(old: String, new: String) -> [PromptDiffToken] {
        diff(oldTokens: tokenize(old), newTokens: tokenize(new))
    }

    /// Case-insensitive LCS diff. Equal tokens carry the new text; removed tokens
    /// are placed before the added tokens of the same gap.
    static func diff(oldTokens a: [String], newTokens b: [String]) -> [PromptDiffToken] {
        let keyA = a.map { $0.lowercased() }
        let keyB = b.map { $0.lowercased() }

        // Common prefix / suffix first: lineage steps usually differ in a few words.
        var prefix = 0
        while prefix < keyA.count, prefix < keyB.count, keyA[prefix] == keyB[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < keyA.count - prefix, suffix < keyB.count - prefix,
              keyA[keyA.count - 1 - suffix] == keyB[keyB.count - 1 - suffix]
        {
            suffix += 1
        }

        var result: [PromptDiffToken] = b[0..<prefix].map { PromptDiffToken(text: $0, op: .equal) }
        let midA = Array(keyA[prefix..<(keyA.count - suffix)])
        let midB = Array(keyB[prefix..<(keyB.count - suffix)])
        let textA = Array(a[prefix..<(a.count - suffix)])
        let textB = Array(b[prefix..<(b.count - suffix)])

        if midA.isEmpty {
            result += textB.map { PromptDiffToken(text: $0, op: .added) }
        } else if midB.isEmpty {
            result += textA.map { PromptDiffToken(text: $0, op: .removed) }
        } else if midA.count * midB.count > maxLCSCells {
            result += textA.map { PromptDiffToken(text: $0, op: .removed) }
            result += textB.map { PromptDiffToken(text: $0, op: .added) }
        } else {
            result += lcsDiff(keyA: midA, keyB: midB, textA: textA, textB: textB)
        }
        result += b[(b.count - suffix)...].map { PromptDiffToken(text: $0, op: .equal) }
        return result
    }

    private static func lcsDiff(keyA: [String], keyB: [String], textA: [String], textB: [String]) -> [PromptDiffToken] {
        let n = keyA.count, m = keyB.count
        // lengths[i][j] = LCS of keyA[i...] and keyB[j...], flattened.
        var lengths = [Int32](repeating: 0, count: (n + 1) * (m + 1))
        let width = m + 1
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lengths[i * width + j] = keyA[i] == keyB[j]
                    ? lengths[(i + 1) * width + j + 1] + 1
                    : max(lengths[(i + 1) * width + j], lengths[i * width + j + 1])
            }
        }
        var result: [PromptDiffToken] = []
        var removed: [PromptDiffToken] = []
        var added: [PromptDiffToken] = []
        func flush() {
            result += removed
            result += added
            removed.removeAll()
            added.removeAll()
        }
        var i = 0, j = 0
        while i < n, j < m {
            if keyA[i] == keyB[j] {
                flush()
                result.append(PromptDiffToken(text: textB[j], op: .equal))
                i += 1; j += 1
            } else if lengths[(i + 1) * width + j] >= lengths[i * width + j + 1] {
                removed.append(PromptDiffToken(text: textA[i], op: .removed))
                i += 1
            } else {
                added.append(PromptDiffToken(text: textB[j], op: .added))
                j += 1
            }
        }
        while i < n { removed.append(PromptDiffToken(text: textA[i], op: .removed)); i += 1 }
        while j < m { added.append(PromptDiffToken(text: textB[j], op: .added)); j += 1 }
        flush()
        return result
    }

    /// Whether a space goes between two rendered tokens ("red, blue", "(red:1.2)").
    static func needsSpace(between previous: String?, and next: String) -> Bool {
        guard let previous else { return false }
        if [",", ";", ")", "]", "}", ":", ">"].contains(next) { return false }
        if ["(", "[", "{", ":", "<"].contains(previous) { return false }
        return true
    }

    /// Plain text of the tokens with `op` in `ops` (for tests and copy).
    static func render(_ tokens: [PromptDiffToken], including ops: Set<PromptDiffOp>) -> String {
        var output = ""
        var previous: String?
        for token in tokens where ops.contains(token.op) {
            if needsSpace(between: previous, and: token.text) { output += " " }
            output += token.text
            previous = token.text
        }
        return output
    }

    static func changeCounts(_ tokens: [PromptDiffToken]) -> (added: Int, removed: Int) {
        func isWord(_ t: PromptDiffToken) -> Bool { !(t.text.count == 1 && punctuation.contains(t.text.first!)) }
        return (
            tokens.filter { $0.op == .added && isWord($0) }.count,
            tokens.filter { $0.op == .removed && isWord($0) }.count
        )
    }
}

// MARK: - Parameter changes

struct PromptParamChange: Equatable, Hashable, Sendable {
    let label: String
    let old: String?
    let new: String?
}

extension PromptTokenDiff {
    /// Seed / steps / CFG / sampler / model / size differences, in that order.
    static func parameterChanges(old: GenerationParameters, new: GenerationParameters) -> [PromptParamChange] {
        func size(_ p: GenerationParameters) -> String? {
            guard let w = p.width, let h = p.height else { return nil }
            return "\(w)×\(h)"
        }
        let pairs: [(String, String?, String?)] = [
            ("Seed", old.seed, new.seed),
            ("Steps", old.steps, new.steps),
            ("CFG", old.cfg, new.cfg),
            ("Sampler", old.sampler, new.sampler),
            ("Model", old.model, new.model),
            ("Size", size(old), size(new)),
        ]
        return pairs.compactMap { label, a, b in
            let a = a?.trimmingCharacters(in: .whitespacesAndNewlines).promptNilIfEmpty
            let b = b?.trimmingCharacters(in: .whitespacesAndNewlines).promptNilIfEmpty
            guard a?.lowercased() != b?.lowercased() else { return nil }
            return PromptParamChange(label: label, old: a, new: b)
        }
    }
}

extension String {
    /// nil for an empty string.
    var promptNilIfEmpty: String? { isEmpty ? nil : self }
}
