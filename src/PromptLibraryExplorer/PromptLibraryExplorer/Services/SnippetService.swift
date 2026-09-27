import Foundation

struct PromptSnippet: Codable, Identifiable, Hashable {
    var id: UUID
    var title: String
    var text: String
    var category: String
    var createdAt: Date

    init(id: UUID = UUID(), title: String, text: String, category: String, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.text = text
        self.category = category
        self.createdAt = createdAt
    }
}

@MainActor
final class SnippetService {
    static let shared = SnippetService()

    private static let fileName = "snippets.json"
    private var snippets: [PromptSnippet]

    private init() {
        snippets = CollectionServiceStorage.load([PromptSnippet].self, from: Self.fileName) ?? []
    }

    func all() -> [PromptSnippet] { snippets }

    @discardableResult
    func add(title: String, text: String, category: String) -> PromptSnippet {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let snippet = PromptSnippet(
            title: trimmedTitle.isEmpty ? Self.defaultTitle(for: text) : trimmedTitle,
            text: text,
            category: category.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        snippets.append(snippet)
        persist()
        return snippet
    }

    func update(_ snippet: PromptSnippet) {
        guard let index = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        var updated = snippet
        updated.category = snippet.category.trimmingCharacters(in: .whitespacesAndNewlines)
        guard snippets[index] != updated else { return }
        snippets[index] = updated
        persist()
    }

    func delete(id: UUID) {
        let before = snippets.count
        snippets.removeAll { $0.id == id }
        if snippets.count != before { persist() }
    }

    /// Case- and diacritic-insensitive search over title, text and category. Every
    /// whitespace-separated term must match. An empty query returns everything.
    func search(_ query: String) -> [PromptSnippet] {
        let terms = query
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !terms.isEmpty else { return snippets }
        return snippets.filter { snippet in
            let haystack = "\(snippet.title)\n\(snippet.text)\n\(snippet.category)"
            return terms.allSatisfy {
                haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }

    var categories: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for snippet in snippets {
            let category = snippet.category
            guard !category.isEmpty, seen.insert(category.lowercased()).inserted else { continue }
            result.append(category)
        }
        return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // MARK: - Private

    private func persist() {
        CollectionServiceStorage.save(snippets, to: Self.fileName)
    }

    private static func defaultTitle(for text: String) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace }).prefix(6).joined(separator: " ")
        return words.isEmpty ? "Untitled Snippet" : words
    }
}
