import Foundation

struct SmartFolder: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var criteria: SmartFolderCriteria
    var createdAt: Date

    init(name: String, criteria: SmartFolderCriteria) {
        self.id = UUID()
        self.name = name
        self.criteria = criteria
        self.createdAt = Date()
    }
}

enum SmartFolderMatchMode: String, Codable, CaseIterable, Hashable {
    case all
    case any

    var displayName: String {
        switch self {
        case .all: return "All Rules"
        case .any: return "Any Rule"
        }
    }
}

struct SmartFolderCriteria: Codable, Hashable {
    var searchQuery: String = ""
    var fileTypes: Set<SmartFolderFileType> = []
    var minRating: Int = 0
    var dateRange: SmartFolderDateRange = .any
    var tagIDs: Set<UUID> = []
    var favoritesOnly = false
    var modelContains = ""
    var requiresPrompt = false
    var requiresNegativePrompt = false
    var matchMode: SmartFolderMatchMode = .all

    typealias MatchMode = SmartFolderMatchMode

    var isActive: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !fileTypes.isEmpty
            || minRating > 0
            || dateRange != .any
            || !tagIDs.isEmpty
            || favoritesOnly
            || !modelContains.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || requiresPrompt
            || requiresNegativePrompt
    }

    enum CodingKeys: String, CodingKey {
        case searchQuery, fileTypes, minRating, dateRange
        case tagIDs, favoritesOnly, modelContains, requiresPrompt, requiresNegativePrompt, matchMode
    }
}

extension SmartFolderCriteria {
    /// Backward-compatible: folders saved before a field existed (or with an unknown enum value)
    /// still decode, falling back to the defaults.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        searchQuery = (try? c.decodeIfPresent(String.self, forKey: .searchQuery)) ?? ""
        if let rawTypes = try? c.decodeIfPresent([String].self, forKey: .fileTypes) {
            fileTypes = Set(rawTypes.compactMap(SmartFolderFileType.init(rawValue:)))
        }
        minRating = (try? c.decodeIfPresent(Int.self, forKey: .minRating)) ?? 0
        if let raw = try? c.decodeIfPresent(String.self, forKey: .dateRange) {
            dateRange = SmartFolderDateRange(rawValue: raw) ?? .any
        }
        tagIDs = (try? c.decodeIfPresent(Set<UUID>.self, forKey: .tagIDs)) ?? []
        favoritesOnly = (try? c.decodeIfPresent(Bool.self, forKey: .favoritesOnly)) ?? false
        modelContains = (try? c.decodeIfPresent(String.self, forKey: .modelContains)) ?? ""
        requiresPrompt = (try? c.decodeIfPresent(Bool.self, forKey: .requiresPrompt)) ?? false
        requiresNegativePrompt = (try? c.decodeIfPresent(Bool.self, forKey: .requiresNegativePrompt)) ?? false
        if let raw = try? c.decodeIfPresent(String.self, forKey: .matchMode) {
            matchMode = SmartFolderMatchMode(rawValue: raw) ?? .all
        }
    }
}

enum SmartFolderFileType: String, Codable, CaseIterable, Hashable {
    case plib
    case aoe
    case png
    case jpg
    case webp
    case gif
    case other

    var displayName: String {
        switch self {
        case .plib: return ".plib"
        case .aoe: return ".aoe"
        case .png: return "PNG"
        case .jpg: return "JPEG"
        case .webp: return "WebP"
        case .gif: return "GIF"
        case .other: return "Other"
        }
    }

    func matches(_ fileName: String) -> Bool {
        let lower = fileName.lowercased()
        switch self {
        case .plib: return lower.hasSuffix(".plib")
        case .aoe: return lower.hasSuffix(".aoe")
        case .png: return lower.hasSuffix(".png")
        case .jpg: return lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg")
        case .webp: return lower.hasSuffix(".webp")
        case .gif: return lower.hasSuffix(".gif")
        case .other:
            return !SmartFolderFileType.allCases.filter({ $0 != .other }).contains(where: { $0.matches(fileName) })
                && !FileHelpers.isImageFile(lower)
        }
    }
}

enum SmartFolderDateRange: String, Codable, CaseIterable, Hashable {
    case any
    case today
    case lastWeek
    case lastMonth
    case lastYear

    var displayName: String {
        switch self {
        case .any: return "Any Time"
        case .today: return "Today"
        case .lastWeek: return "Last 7 Days"
        case .lastMonth: return "Last 30 Days"
        case .lastYear: return "Last Year"
        }
    }

    var startDate: Date? {
        let calendar = Calendar.current
        let now = Date()
        switch self {
        case .any: return nil
        case .today: return calendar.startOfDay(for: now)
        case .lastWeek: return calendar.date(byAdding: .day, value: -7, to: now)
        case .lastMonth: return calendar.date(byAdding: .day, value: -30, to: now)
        case .lastYear: return calendar.date(byAdding: .year, value: -1, to: now)
        }
    }
}
