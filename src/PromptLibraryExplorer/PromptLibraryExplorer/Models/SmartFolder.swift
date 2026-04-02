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

struct SmartFolderCriteria: Codable, Hashable {
    var searchQuery: String = ""
    var fileTypes: Set<SmartFolderFileType> = []
    var minRating: Int = 0
    var dateRange: SmartFolderDateRange = .any

    var isActive: Bool {
        !searchQuery.isEmpty || !fileTypes.isEmpty || minRating > 0 || dateRange != .any
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
