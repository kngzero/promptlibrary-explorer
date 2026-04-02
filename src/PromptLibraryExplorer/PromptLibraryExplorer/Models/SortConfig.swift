import Foundation

enum SortField: String, CaseIterable {
    case type
    case name
    case custom
    case rating
}

enum SortDirection: String, CaseIterable {
    case asc
    case desc
}

struct SortConfig: Equatable {
    var field: SortField = .type
    var direction: SortDirection = .asc
}

struct FilterConfig: Equatable {
    var hideOther: Bool = true
    var hideJpg: Bool = false
    var hidePng: Bool = false

    var filterMinRating: Int = 0

    var activeCount: Int {
        [hideJpg, hidePng].filter { $0 }.count + (filterMinRating > 0 ? 1 : 0)
    }
}
