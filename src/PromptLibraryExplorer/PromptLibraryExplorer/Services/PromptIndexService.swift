import Foundation

/// Maintains an in-memory index of file path -> prompt text for content search.
///
/// The index belongs to one folder at a time. A full build is started with
/// `beginBuild(folderPath:)`, fed with `index(path:prompt:generation:)` and sealed
/// with `finishBuild(generation:)`; only a sealed build counts as complete.
/// Opportunistic inserts (for example when a file is selected) go through
/// `index(path:prompt:)` and never mark the index complete.
actor PromptIndexService {
    static let shared = PromptIndexService()

    /// Maps file path to its prompt text (lowercased for fast search).
    private var index: [String: String] = [:]

    /// Folder whose files the current build covers.
    private(set) var indexedFolderPath: String?
    /// True once a build for `indexedFolderPath` ran to the end.
    private(set) var isComplete = false
    /// Bumped by every build start and every clear, so an abandoned build can't
    /// write into (or seal) a newer index.
    private var generation = 0

    private init() {}

    /// Index a file's prompt content outside of a full build.
    func index(path: String, prompt: String) {
        guard !prompt.isEmpty else { return }
        index[path] = prompt.lowercased()
    }

    /// Clears the index and starts a full build for `folderPath`.
    /// Returns the build's generation token.
    func beginBuild(folderPath: String) -> Int {
        index.removeAll()
        indexedFolderPath = folderPath
        isComplete = false
        generation &+= 1
        return generation
    }

    /// Index a file as part of the build identified by `generation`.
    /// Ignored when that build has been superseded.
    func index(path: String, prompt: String, generation: Int) {
        guard generation == self.generation, !prompt.isEmpty else { return }
        index[path] = prompt.lowercased()
    }

    /// Marks the build identified by `generation` as complete.
    func finishBuild(generation: Int) {
        guard generation == self.generation else { return }
        isComplete = true
    }

    /// True when a full build for exactly this folder completed.
    func isIndexComplete(for folderPath: String) -> Bool {
        isComplete && indexedFolderPath == folderPath
    }

    /// Remove a path from the index.
    func remove(path: String) {
        index.removeValue(forKey: path)
    }

    /// Clear the entire index and any build state.
    func clearIndex() {
        index.removeAll()
        indexedFolderPath = nil
        isComplete = false
        generation &+= 1
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
