import Foundation

enum SortField: String, CaseIterable, Identifiable {
    case type
    case name
    case custom
    case rating
    case flag
    case label
    case dateModified
    case dateCreated
    case size

    var id: String { rawValue }

    var title: String {
        switch self {
        case .type: return "Kind"
        case .name: return "Name"
        case .custom: return "Custom Order"
        case .rating: return "Rating"
        case .flag: return "Flag"
        case .label: return "Label"
        case .dateModified: return "Date Modified"
        case .dateCreated: return "Date Created"
        case .size: return "Size"
        }
    }

    var systemImage: String {
        switch self {
        case .type: return "square.grid.2x2"
        case .name: return "textformat.abc"
        case .custom: return "line.3.horizontal.decrease.circle"
        case .rating: return "star.fill"
        case .flag: return "flag.fill"
        case .label: return "circle.fill"
        case .dateModified: return "clock"
        case .dateCreated: return "calendar"
        case .size: return "internaldrive"
        }
    }

    /// Whether the field has an ascending/descending choice.
    var supportsDirection: Bool { self != .custom }
}

enum SortDirection: String, CaseIterable {
    case asc
    case desc

    var title: String {
        switch self {
        case .asc: return "Ascending"
        case .desc: return "Descending"
        }
    }
}

/// How the content browser lays out the listing.
enum BrowserViewMode: String, CaseIterable, Identifiable {
    case grid
    case list

    var id: String { rawValue }

    var title: String {
        switch self {
        case .grid: return "Grid"
        case .list: return "List"
        }
    }

    var systemImage: String {
        switch self {
        case .grid: return "square.grid.2x2"
        case .list: return "list.bullet"
        }
    }
}

/// Field the listing is grouped by (sections in the content browser).
enum GroupByField: String, CaseIterable, Identifiable {
    case none
    case model
    case sampler
    case seed
    case day
    case type
    case flag
    case label

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .model: return "Model"
        case .sampler: return "Sampler"
        case .seed: return "Seed"
        case .day: return "Day Modified"
        case .type: return "Kind"
        case .flag: return "Flag"
        case .label: return "Label"
        }
    }
}

/// One section of the grouped listing. `indices` point into `processedFolderContents`
/// and keep that list's order.
struct ContentGroup: Identifiable, Hashable {
    let id: String
    let title: String
    let indices: [Int]
}

struct SortConfig: Equatable {
    var field: SortField = .type
    var direction: SortDirection = .asc
}

enum FileTypeFilter: String, CaseIterable, Hashable {
    case plib
    case aoe
    case moodboard
    case story
    case png
    case jpg
    case webp
    case gif
    case otherImages
    case video
    case audio
    case unsupported

    var displayName: String {
        switch self {
        case .plib: return "Prompt Library (.plib)"
        case .aoe: return "Art Official Elements (.aoe)"
        case .moodboard: return "Mood Boards (.mlmboard)"
        case .story: return "Story Projects (.stry)"
        case .png: return "PNG Images"
        case .jpg: return "JPEG Images"
        case .webp: return "WebP Images"
        case .gif: return "GIF Images"
        case .otherImages: return "Other Images"
        case .video: return "Videos"
        case .audio: return "Audio"
        case .unsupported: return "Unsupported Files"
        }
    }
}

struct FilterConfig: Equatable {
    static let defaultHiddenFileTypes: Set<FileTypeFilter> = [.unsupported]

    var hiddenFileTypes: Set<FileTypeFilter> = Self.defaultHiddenFileTypes

    var filterMinRating: Int = 0

    /// Pick / reject filter.
    var flagFilter: FlagFilter = .all

    /// Finder label numbers to show (any of; 0 = no label). Empty = no filter.
    var labelFilter: Set<Int> = []

    var activeCount: Int {
        hiddenFileTypes.subtracting(Self.defaultHiddenFileTypes).count
            + (filterMinRating > 0 ? 1 : 0)
            + (flagFilter != .all ? 1 : 0)
            + (labelFilter.isEmpty ? 0 : 1)
    }

    /// True when the flag and label filters let a file with these values through.
    func passesCullFilters(flag: FileFlag, labelNumber: Int?) -> Bool {
        guard flagFilter.includes(flag) else { return false }
        return labelFilter.isEmpty || labelFilter.contains(FinderLabel(labelNumber: labelNumber).rawValue)
    }

    func hides(_ fileType: FileTypeFilter) -> Bool {
        hiddenFileTypes.contains(fileType)
    }

    mutating func setHidden(_ hidden: Bool, for fileType: FileTypeFilter) {
        if hidden {
            hiddenFileTypes.insert(fileType)
        } else {
            hiddenFileTypes.remove(fileType)
        }
    }
}
