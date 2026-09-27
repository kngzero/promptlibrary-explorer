import Foundation

// MARK: - Prompt usage statistics (Library ▸ Prompt Statistics)

/// One file's facts for statistics: index row plus the user's rating and flag.
struct PromptStatsRow: Sendable, Hashable {
    let path: String
    let date: Date?
    let prompt: String
    let model: String?
    let sampler: String?
    let steps: String?
    let cfg: String?
    var rating: Int = 0
    /// -1 reject, 0 unflagged, 1 pick (FileFlag raw values).
    var flag: Int = 0
}

struct PromptStatsCount: Identifiable, Hashable, Sendable {
    var id: String { label }
    let label: String
    let count: Int
}

struct PromptStatsGroupQuality: Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String
    let count: Int
    let ratedCount: Int
    /// Mean stars over rated files; nil when none are rated.
    let averageRating: Double?
    let pickCount: Int
    let rejectCount: Int
    /// Picks / files.
    var pickRate: Double { count > 0 ? Double(pickCount) / Double(count) : 0 }
}

struct PromptStatsMonth: Identifiable, Hashable, Sendable {
    var id: String { month }
    /// "yyyy-MM".
    let month: String
    let total: Int
    let byModel: [String: Int]
}

struct PromptStatsReport: Sendable {
    var fileCount = 0
    var promptCount = 0
    var topTokens: [PromptStatsCount] = []
    /// Two- and three-word phrases.
    var topPhrases: [PromptStatsCount] = []
    /// Models by file count (most used first).
    var models: [PromptStatsCount] = []
    /// Oldest first, gaps filled with zero months.
    var months: [PromptStatsMonth] = []
    var samplers: [PromptStatsCount] = []
    var steps: [PromptStatsCount] = []
    var cfg: [PromptStatsCount] = []
    var qualityByModel: [PromptStatsGroupQuality] = []
    var qualityBySampler: [PromptStatsGroupQuality] = []
    /// "yyyy-MM-dd", oldest first, over the last `dayWindow` days ending at the newest file.
    var days: [PromptStatsCount] = []

    var isEmpty: Bool { fileCount == 0 }
}

enum PromptStatsService {
    static let unknownModel = "Unknown"
    static let monthWindow = 24
    static let dayWindow = 60

    /// English function words plus prompt boilerplate that says nothing about content.
    static let stopwords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "of", "in", "on", "at", "to", "for", "with", "by", "from", "as", "is",
        "are", "was", "were", "be", "been", "being", "it", "its", "this", "that", "these", "those", "into", "onto",
        "over", "under", "up", "down", "out", "off", "very", "so", "than", "then", "there", "their", "his", "her",
        "he", "she", "they", "them", "we", "you", "your", "our", "i", "me", "my", "no", "not", "all", "any", "some",
        "each", "while", "which", "who", "whom", "what", "where", "when", "has", "have", "had", "do", "does", "did",
        "can", "could", "would", "should", "will", "just", "only", "also", "more", "most", "such", "about", "around",
        "through", "behind", "between", "against", "above", "below", "near", "like", "s", "t",
    ]

    /// Lower-cased word tokens of one comma/period-delimited segment sequence.
    /// Numbers-only tokens (weights, seeds) are dropped; stopwords are kept so
    /// n-grams don't bridge them ("woman in red" never yields "woman red").
    static func segments(of prompt: String) -> [[String]] {
        let separators = CharacterSet(charactersIn: ",.;:|()[]{}<>\n\r!?\"")
        return prompt.lowercased()
            .components(separatedBy: separators)
            .map { segment in
                segment
                    .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'-")).inverted)
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'-")) }
                    .filter { !$0.isEmpty && !$0.allSatisfy(\.isNumber) }
            }
            .filter { !$0.isEmpty }
    }

    /// Content words (no stopwords, at least 2 characters).
    static func tokens(of prompt: String) -> [String] {
        segments(of: prompt).flatMap { $0 }.filter { $0.count >= 2 && !stopwords.contains($0) }
    }

    /// n-grams within segments where no word is a stopword.
    static func ngrams(of prompt: String, n: Int) -> [String] {
        guard n >= 2 else { return tokens(of: prompt) }
        var result: [String] = []
        for words in segments(of: prompt) where words.count >= n {
            for start in 0...(words.count - n) {
                let gram = Array(words[start..<(start + n)])
                guard gram.allSatisfy({ $0.count >= 2 && !stopwords.contains($0) }) else { continue }
                result.append(gram.joined(separator: " "))
            }
        }
        return result
    }

    static func normalizedModel(_ raw: String?) -> String {
        guard var name = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, name.uppercased() != "N/A" else {
            return unknownModel
        }
        // "models/sdxl/juggernaut.safetensors" → "juggernaut"
        if let slash = name.lastIndex(where: { $0 == "/" || $0 == "\\" }) { name = String(name[name.index(after: slash)...]) }
        for ext in [".safetensors", ".ckpt", ".pt", ".pth", ".gguf", ".bin"] where name.lowercased().hasSuffix(ext) {
            name = String(name.dropLast(ext.count))
        }
        return name.isEmpty ? unknownModel : name
    }

    /// Numeric bucket label ("7", "7.5", "30").
    static func numericLabel(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), let value = Double(raw), value.isFinite else { return nil }
        if value.rounded() == value { return String(Int(value)) }
        return String(format: "%.1f", value)
    }

    static func report(for rows: [PromptStatsRow], top: Int = 30, calendar: Calendar = .current) -> PromptStatsReport {
        var report = PromptStatsReport()
        report.fileCount = rows.count
        guard !rows.isEmpty else { return report }

        var tokenCounts: [String: Int] = [:]
        var phraseCounts: [String: Int] = [:]
        var modelCounts: [String: Int] = [:]
        var samplerCounts: [String: Int] = [:]
        var stepCounts: [String: Int] = [:]
        var cfgCounts: [String: Int] = [:]
        var monthCounts: [String: [String: Int]] = [:]
        var dayCounts: [String: Int] = [:]
        var modelRows: [String: [PromptStatsRow]] = [:]
        var samplerRows: [String: [PromptStatsRow]] = [:]
        var newest: Date?

        let monthFormatter = DateFormatter()
        monthFormatter.calendar = calendar
        monthFormatter.timeZone = calendar.timeZone
        monthFormatter.locale = Locale(identifier: "en_US_POSIX")
        monthFormatter.dateFormat = "yyyy-MM"
        let dayFormatter = DateFormatter()
        dayFormatter.calendar = calendar
        dayFormatter.timeZone = calendar.timeZone
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"

        for row in rows {
            let prompt = row.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !prompt.isEmpty {
                report.promptCount += 1
                // Document frequency: a word counts once per file.
                for token in Set(tokens(of: prompt)) { tokenCounts[token, default: 0] += 1 }
                for phrase in Set(ngrams(of: prompt, n: 2) + ngrams(of: prompt, n: 3)) { phraseCounts[phrase, default: 0] += 1 }
            }
            let model = normalizedModel(row.model)
            modelCounts[model, default: 0] += 1
            modelRows[model, default: []].append(row)
            if let sampler = row.sampler?.trimmingCharacters(in: .whitespaces), !sampler.isEmpty {
                samplerCounts[sampler, default: 0] += 1
                samplerRows[sampler, default: []].append(row)
            }
            if let steps = numericLabel(row.steps) { stepCounts[steps, default: 0] += 1 }
            if let cfg = numericLabel(row.cfg) { cfgCounts[cfg, default: 0] += 1 }
            if let date = row.date {
                monthCounts[monthFormatter.string(from: date), default: [:]][model, default: 0] += 1
                dayCounts[dayFormatter.string(from: date), default: 0] += 1
                if newest.map({ date > $0 }) ?? true { newest = date }
            }
        }

        func ranked(_ counts: [String: Int], limit: Int, minimum: Int = 1) -> [PromptStatsCount] {
            counts.filter { $0.value >= minimum }
                .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .prefix(limit)
                .map { PromptStatsCount(label: $0.key, count: $0.value) }
        }
        func numericOrder(_ counts: [String: Int], limit: Int) -> [PromptStatsCount] {
            // The most common values, shown in numeric order.
            ranked(counts, limit: limit)
                .sorted { (Double($0.label) ?? 0) < (Double($1.label) ?? 0) }
        }

        report.topTokens = ranked(tokenCounts, limit: top)
        // A phrase in a single file isn't a pattern.
        report.topPhrases = ranked(phraseCounts, limit: top, minimum: report.promptCount > 1 ? 2 : 1)
        report.models = ranked(modelCounts, limit: 100)
        report.samplers = ranked(samplerCounts, limit: 12)
        report.steps = numericOrder(stepCounts, limit: 12)
        report.cfg = numericOrder(cfgCounts, limit: 12)
        report.qualityByModel = quality(of: modelRows)
        report.qualityBySampler = quality(of: samplerRows)

        if let newest {
            // Months: the last `monthWindow` months ending at the newest file, gaps zero-filled.
            if let lastMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: newest)) {
                let oldestKey = monthCounts.keys.min() ?? monthFormatter.string(from: lastMonth)
                var months: [PromptStatsMonth] = []
                var cursor = lastMonth
                for _ in 0..<monthWindow {
                    let key = monthFormatter.string(from: cursor)
                    let byModel = monthCounts[key] ?? [:]
                    months.append(PromptStatsMonth(month: key, total: byModel.values.reduce(0, +), byModel: byModel))
                    if key <= oldestKey { break }
                    guard let previous = calendar.date(byAdding: .month, value: -1, to: cursor) else { break }
                    cursor = previous
                }
                report.months = months.reversed()
            }
            // Days: the last `dayWindow` days ending at the newest file.
            let lastDay = calendar.startOfDay(for: newest)
            var days: [PromptStatsCount] = []
            for offset in stride(from: dayWindow - 1, through: 0, by: -1) {
                guard let day = calendar.date(byAdding: .day, value: -offset, to: lastDay) else { continue }
                let key = dayFormatter.string(from: day)
                days.append(PromptStatsCount(label: key, count: dayCounts[key] ?? 0))
            }
            report.days = days
        }
        return report
    }

    private static func quality(of groups: [String: [PromptStatsRow]]) -> [PromptStatsGroupQuality] {
        groups.map { name, rows in
            let rated = rows.filter { $0.rating > 0 }
            return PromptStatsGroupQuality(
                name: name,
                count: rows.count,
                ratedCount: rated.count,
                averageRating: rated.isEmpty ? nil : Double(rated.reduce(0) { $0 + $1.rating }) / Double(rated.count),
                pickCount: rows.filter { $0.flag > 0 }.count,
                rejectCount: rows.filter { $0.flag < 0 }.count
            )
        }
        .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }

    /// Paths whose normalized model is `model` / whose sampler is `sampler`.
    static func paths(in rows: [PromptStatsRow], model: String? = nil, sampler: String? = nil) -> [String] {
        rows.filter { row in
            if let model, normalizedModel(row.model) != model { return false }
            if let sampler, row.sampler?.trimmingCharacters(in: .whitespaces) != sampler { return false }
            return true
        }
        .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        .map(\.path)
    }
}
