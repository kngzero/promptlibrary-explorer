import Foundation

/// Maintains an in-memory index of file path -> prompt text for content search.
/// Entries are populated lazily as files are parsed and can be queried for substring matches.
actor PromptIndexService {
    static let shared = PromptIndexService()

    /// Maps file path to its prompt text (lowercased for fast search).
    private var index: [String: String] = [:]

    private init() {}

    /// Index a file's prompt content.
    func index(path: String, prompt: String) {
        guard !prompt.isEmpty else { return }
        index[path] = prompt.lowercased()
    }

    /// Remove a path from the index.
    func remove(path: String) {
        index.removeValue(forKey: path)
    }

    /// Clear the entire index.
    func clearIndex() {
        index.removeAll()
    }

    /// Returns the set of paths whose prompt contains the query.
    func search(query: String) -> Set<String> {
        let lowerQuery = query.lowercased()
        var matches: Set<String> = []
        for (path, promptText) in index where promptText.contains(lowerQuery) {
            matches.insert(path)
        }
        return matches
    }

    /// Returns the prompt text for a given path, if indexed.
    func prompt(for path: String) -> String? {
        index[path]
    }

    /// Returns the number of indexed entries.
    var count: Int {
        index.count
    }
}
