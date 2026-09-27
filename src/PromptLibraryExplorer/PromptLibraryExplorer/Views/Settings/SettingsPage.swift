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
    case export
    case libraryIndex
    case organize
    case data
    case storage

    var id: String { rawValue }

    var group: SettingsPageGroup {
        switch self {
        case .appearance:
            return .general
        case .filters, .fileOperations, .export, .libraryIndex:
            return .library
        case .organize, .data, .storage:
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
        case .export:
            return "Export"
        case .libraryIndex:
            return "Search Index"
        case .organize:
            return "Organize"
        case .data:
            return "Data"
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
        case .export:
            return "square.and.arrow.up.on.square"
        case .libraryIndex:
            return "text.magnifyingglass"
        case .organize:
            return "calendar.badge.clock"
        case .data:
            return "externaldrive.badge.checkmark"
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
        case .export:
            return "Presets for exporting copies: format, size, metadata, names, destination and watermark."
        case .libraryIndex:
            return "The full-text prompt index behind library search and the command palette."
        case .organize:
            return "Reshape the current folder into dated subfolders, or flatten it back out."
        case .data:
            return "Back up, export and sync your ratings, flags, tags, collections and more between Macs."
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
