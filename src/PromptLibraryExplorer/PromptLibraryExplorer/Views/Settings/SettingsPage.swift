import SwiftUI

/// One page in the settings window's sidebar.
///
/// Adding a page is a three-step change: add a case here, place it in a
/// `SettingsPageGroup`, and return its view from `SettingsView.page(for:)`.
/// The sidebar, ordering, titles and page chrome all follow from this enum.
/// Declaration order is the order pages appear within their group.
enum SettingsPage: String, CaseIterable, Identifiable, Hashable {
    case appearance
    case filters
    case fileOperations
    case libraryIndex
    case organize
    case storage

    var id: String { rawValue }

    var group: SettingsPageGroup {
        switch self {
        case .appearance:
            return .general
        case .filters, .fileOperations, .libraryIndex:
            return .library
        case .organize, .storage:
            return .maintenance
        }
    }

    var title: String {
        switch self {
        case .appearance:
            return "Appearance"
        case .filters:
            return "Filters"
        case .fileOperations:
            return "File Operations"
        case .libraryIndex:
            return "Search Index"
        case .organize:
            return "Organize"
        case .storage:
            return "Storage"
        }
    }

    var icon: String {
        switch self {
        case .appearance:
            return "circle.lefthalf.filled"
        case .filters:
            return "line.3.horizontal.decrease.circle"
        case .fileOperations:
            return "doc.badge.gearshape"
        case .libraryIndex:
            return "text.magnifyingglass"
        case .organize:
            return "calendar.badge.clock"
        case .storage:
            return "internaldrive.fill"
        }
    }

    /// Sits under the page title as the one-line explanation of the page.
    var summary: String {
        switch self {
        case .appearance:
            return "Theme and colour behaviour across the whole app."
        case .filters:
            return "Which files the explorer shows you, in every folder."
        case .fileOperations:
            return "What happens when files are deleted, collide by name, or leave the app."
        case .libraryIndex:
            return "The full-text prompt index behind library search and the command palette."
        case .organize:
            return "Reshape the current folder into dated subfolders, or flatten it back out."
        case .storage:
            return "Inspect and reclaim the space taken by thumbnails and parsed metadata."
        }
    }
}

/// A titled block of pages in the settings sidebar.
enum SettingsPageGroup: String, CaseIterable, Identifiable, Hashable {
    case general = "General"
    case library = "Library"
    case maintenance = "Maintenance"

    var id: String { rawValue }

    var title: String { rawValue }

    var pages: [SettingsPage] {
        SettingsPage.allCases.filter { $0.group == self }
    }
}
