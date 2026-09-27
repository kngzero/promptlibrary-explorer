import Foundation

final class SmartFolderService {
    static let shared = SmartFolderService()

    static let storageKey = "promptlibrary.smartFolders"

    private let defaults: UserDefaults

    /// `defaults` is injectable for tests; the app uses `shared`.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadSmartFolders() -> [SmartFolder] {
        guard let data = defaults.data(forKey: Self.storageKey),
              let folders = try? JSONDecoder().decode([SmartFolder].self, from: data)
        else { return [] }
        return folders
    }

    func saveSmartFolders(_ folders: [SmartFolder]) {
        if let data = try? JSONEncoder().encode(folders) {
            defaults.set(data, forKey: Self.storageKey)
            CurationStoreEvents.post(.smartFolders)
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

    typealias SmartFolderContext = SmartFolderFilterContext

    /// Filters entries based on smart folder criteria (legacy API; ratings only).
    func filterEntries(
        _ entries: [FileEntry],
        criteria: SmartFolderCriteria,
        ratingLookup: (String) -> Int
    ) -> [FileEntry] {
        var ratings: [String: Int] = [:]
        if criteria.minRating > 0 {
            for entry in entries where !entry.isDirectory {
                ratings[entry.path] = ratingLookup(entry.path)
            }
        }
        return Self.filter(entries, criteria: criteria, context: SmartFolderFilterContext(ratings: ratings))
    }

    /// Filters entries by every active rule (`matchMode == .all`) or at least one (`.any`).
    /// Directories never match. With no active rules every file matches.
    static func filter(
        _ entries: [FileEntry],
        criteria: SmartFolderCriteria,
        context: SmartFolderFilterContext
    ) -> [FileEntry] {
        let rules = activeRules(for: criteria, context: context)
        return entries.filter { entry in
            guard !entry.isDirectory else { return false }
            guard !rules.isEmpty else { return true }
            switch criteria.matchMode {
            case .all: return rules.allSatisfy { $0(entry) }
            case .any: return rules.contains { $0(entry) }
            }
        }
    }

    private static func activeRules(
        for criteria: SmartFolderCriteria,
        context: SmartFolderFilterContext
    ) -> [(FileEntry) -> Bool] {
        var rules: [(FileEntry) -> Bool] = []

        let query = criteria.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            rules.append { entry in
                if entry.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil { return true }
                if let prompt = context.promptByPath[entry.path],
                   prompt.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                {
                    return true
                }
                return false
            }
        }

        if !criteria.fileTypes.isEmpty {
            let types = criteria.fileTypes
            rules.append { entry in types.contains { $0.matches(entry.name) } }
        }

        if criteria.minRating > 0 {
            let minimum = criteria.minRating
            rules.append { entry in (context.ratings[entry.path] ?? 0) >= minimum }
        }

        if let startDate = criteria.dateRange.startDate {
            rules.append { entry in (modifiedDate(of: entry) ?? .distantPast) >= startDate }
        }

        if !criteria.tagIDs.isEmpty {
            let wanted = criteria.tagIDs
            rules.append { entry in
                guard let tags = context.tagsByPath[entry.path] else { return false }
                return !tags.isDisjoint(with: wanted)
            }
        }

        if criteria.favoritesOnly {
            rules.append { entry in context.favorites.contains(entry.path) }
        }

        let model = criteria.modelContains.trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.isEmpty {
            rules.append { entry in
                guard let value = context.modelByPath[entry.path] else { return false }
                return value.range(of: model, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }

        if criteria.requiresPrompt {
            rules.append { entry in hasText(context.promptByPath[entry.path]) }
        }

        if criteria.requiresNegativePrompt {
            rules.append { entry in hasText(context.negativeByPath[entry.path]) }
        }

        if criteria.flag != .all {
            let flagFilter = criteria.flag
            rules.append { entry in flagFilter.includes(context.flags[entry.path] ?? .unflagged) }
        }

        if !criteria.labels.isEmpty {
            let labels = criteria.labels
            rules.append { entry in labels.contains(FinderLabel(labelNumber: entry.labelNumber).rawValue) }
        }

        if let colorRule = criteria.dominantColor {
            // Files the visual index hasn't reached yet have no colours and don't match.
            rules.append { entry in
                PaletteMatcher.matches(context.dominantColorsByPath[entry.path] ?? [], filter: colorRule)
            }
        }

        return rules
    }

    private static func hasText(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Uses `FileEntry.modifiedDate` when the listing provides it (read reflectively so this
    /// compiles whether or not the property exists), otherwise asks the file system.
    private static func modifiedDate(of entry: FileEntry) -> Date? {
        for child in Mirror(reflecting: entry).children where child.label == "modifiedDate" {
            if let date = child.value as? Date { return date }
            if let optional = child.value as? Date?, let date = optional { return date }
        }
        let values = try? entry.url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate
    }
}

/// Lookup tables the smart folder rules evaluate against. All keyed by absolute path.
struct SmartFolderFilterContext {
    var tagsByPath: [String: Set<UUID>]
    var favorites: Set<String>
    var ratings: [String: Int]
    /// Positive prompt text.
    var promptByPath: [String: String]
    var negativeByPath: [String: String]
    var modelByPath: [String: String]
    /// Pick / reject flags (unflagged files have no entry).
    var flags: [String: FileFlag]
    /// Dominant colours from the visual index (unindexed files have no entry).
    var dominantColorsByPath: [String: [DominantColor]]

    init(
        tagsByPath: [String: Set<UUID>] = [:],
        favorites: Set<String> = [],
        ratings: [String: Int] = [:],
        promptByPath: [String: String] = [:],
        negativeByPath: [String: String] = [:],
        modelByPath: [String: String] = [:],
        flags: [String: FileFlag] = [:],
        dominantColorsByPath: [String: [DominantColor]] = [:]
    ) {
        self.tagsByPath = tagsByPath
        self.favorites = favorites
        self.ratings = ratings
        self.promptByPath = promptByPath
        self.negativeByPath = negativeByPath
        self.modelByPath = modelByPath
        self.flags = flags
        self.dominantColorsByPath = dominantColorsByPath
    }
}

typealias SmartFolderContext = SmartFolderFilterContext
