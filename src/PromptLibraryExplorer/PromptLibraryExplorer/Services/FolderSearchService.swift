import Foundation

/// Finds folders by name anywhere under a root, off the main thread.
enum FolderSearchService {
    struct Match: Identifiable, Hashable, Sendable {
        var id: String { url.path }
        let url: URL
        let name: String
        /// Path of the enclosing folder relative to the search root ("" for direct children).
        let relativeParent: String
    }

    /// Case-insensitive name match. Skips hidden folders and packages, stops after
    /// `limit` matches, and checks for cancellation as it walks.
    static func findFolders(matching query: String, under root: URL, limit: Int = 300) async -> [Match] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }

        // Nonisolated async: runs on the global executor, and the caller's
        // cancellation reaches the walk (a detached task would keep going).
        do {
            let rootPath = root.standardizedFileURL.path
            let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { return [] }

            var matches: [Match] = []
            while let url = enumerator.nextObject() as? URL {
                if Task.isCancelled { return [] }
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isDirectory == true, values.isPackage != true else { continue }

                let name = url.lastPathComponent
                guard name.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil else { continue }

                let parentPath = url.deletingLastPathComponent().standardizedFileURL.path
                var relative = parentPath.hasPrefix(rootPath) ? String(parentPath.dropFirst(rootPath.count)) : parentPath
                if relative.hasPrefix("/") { relative.removeFirst() }
                matches.append(Match(url: url, name: name, relativeParent: relative))
                if matches.count >= limit { break }
            }

            // Shallow matches first, then by name.
            return matches.sorted { lhs, rhs in
                let lDepth = lhs.relativeParent.isEmpty ? 0 : lhs.relativeParent.split(separator: "/").count
                let rDepth = rhs.relativeParent.isEmpty ? 0 : rhs.relativeParent.split(separator: "/").count
                if lDepth != rDepth { return lDepth < rDepth }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
    }
}
