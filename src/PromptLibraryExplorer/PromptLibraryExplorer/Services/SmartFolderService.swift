import Foundation

final class SmartFolderService {
    static let shared = SmartFolderService()

    private static let storageKey = "promptlibrary.smartFolders"

    private init() {}

    func loadSmartFolders() -> [SmartFolder] {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let folders = try? JSONDecoder().decode([SmartFolder].self, from: data)
        else { return [] }
        return folders
    }

    func saveSmartFolders(_ folders: [SmartFolder]) {
        if let data = try? JSONEncoder().encode(folders) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    func addSmartFolder(_ folder: SmartFolder) {
        var folders = loadSmartFolders()
        folders.append(folder)
        saveSmartFolders(folders)
    }

    func removeSmartFolder(id: UUID) {
        var folders = loadSmartFolders()
        folders.removeAll { $0.id == id }
        saveSmartFolders(folders)
    }

    func updateSmartFolder(_ folder: SmartFolder) {
        var folders = loadSmartFolders()
        if let index = folders.firstIndex(where: { $0.id == folder.id }) {
            folders[index] = folder
        }
        saveSmartFolders(folders)
    }

    /// Filters entries based on smart folder criteria
    func filterEntries(
        _ entries: [FileEntry],
        criteria: SmartFolderCriteria,
        ratingLookup: (String) -> Int
    ) -> [FileEntry] {
        entries.filter { entry in
            guard !entry.isDirectory else { return false }

            // Search query
            if !criteria.searchQuery.isEmpty {
                let query = criteria.searchQuery.lowercased()
                if !entry.name.lowercased().contains(query) {
                    return false
                }
            }

            // File type filter
            if !criteria.fileTypes.isEmpty {
                let matchesAny = criteria.fileTypes.contains { $0.matches(entry.name) }
                if !matchesAny { return false }
            }

            // Rating filter
            if criteria.minRating > 0 {
                if ratingLookup(entry.path) < criteria.minRating {
                    return false
                }
            }

            // Date filter
            if let startDate = criteria.dateRange.startDate {
                let attrs = try? FileManager.default.attributesOfItem(atPath: entry.path)
                let modDate = attrs?[.modificationDate] as? Date ?? Date.distantPast
                if modDate < startDate { return false }
            }

            return true
        }
    }
}
