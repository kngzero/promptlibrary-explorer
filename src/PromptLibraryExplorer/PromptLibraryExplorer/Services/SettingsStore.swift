import Foundation
import SwiftUI

/// Persisted app settings via @AppStorage.
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
    private static let hiddenFileTypesUnsetValue = "__unset__"

    @AppStorage("lastOpenedFolder") var lastOpenedFolder: String = ""
    @AppStorage("thumbnailSize") var thumbnailSize: Double = 5
    @AppStorage("sortField") var sortField: String = "type"
    @AppStorage("sortDirection") var sortDirection: String = "asc"
    @AppStorage("hiddenFileTypes") private var hiddenFileTypesValue: String = SettingsStore.hiddenFileTypesUnsetValue
    @AppStorage("hideOther") private var legacyHideOther: Bool = true
    @AppStorage("hideJpg") private var legacyHideJpg: Bool = false
    @AppStorage("hidePng") private var legacyHidePng: Bool = false
    @AppStorage("showStatusBar") var showStatusBar: Bool = true
    @AppStorage("thumbnailsOnly") var thumbnailsOnly: Bool = false
    @AppStorage("appearanceMode") var appearanceMode: String = AppAppearanceMode.dark.rawValue

    @AppStorage("confirmBeforeTrash") var confirmBeforeTrash: Bool = false
    @AppStorage("duplicateNamePolicy") var duplicateNamePolicy: String = DuplicateNamePolicy.keepBoth.rawValue
    @AppStorage("externalDragOperation") var externalDragOperation: String = ExternalDragOperation.copy.rawValue

    @AppStorage("filterMinRating") var filterMinRating: Int = 0
    @AppStorage("filterFlag") var filterFlag: String = FlagFilter.all.rawValue
    /// Comma-separated Finder label numbers.
    @AppStorage("filterLabels") var filterLabels: String = ""
    /// JSON-encoded `ColorFilter` ("" = no colour filter).
    @AppStorage("filterColor") var filterColor: String = ""

    // Visual search
    /// `VisualSearchScopeChoice` raw value shared by the Similar Images page,
    /// More Like This and palette search.
    @AppStorage("visualSearch.scope") var visualSearchScope: String = VisualSearchScopeChoice.folder.rawValue
    /// Last tolerance used in the colour filter / palette search.
    @AppStorage("visualSearch.colorTolerance") var colorTolerance: Double = ColorFilter.defaultTolerance
    /// Appearance: thin dominant-colour strip on grid tiles (off by default).
    @AppStorage("grid.showColorStrip") var showTileColorStrip: Bool = false

    // Culling
    @AppStorage("cullingMode") var cullingMode: Bool = false
    @AppStorage("cullAutoAdvance") var cullAutoAdvance: Bool = true
    @AppStorage("previewPaneCollapsed") var previewPaneCollapsed: Bool = false
    @AppStorage("searchMode") var searchMode: String = "filename"

    // Window restoration
    @AppStorage("browserViewMode") var viewMode: String = BrowserViewMode.grid.rawValue
    @AppStorage("browserGroupBy") var groupBy: String = GroupByField.none.rawValue
    @AppStorage("sidebarVisible") var sidebarVisible: Bool = true
    /// Folder that was showing when the app quit (may be below the root).
    @AppStorage("lastSelectedFolder") var lastSelectedFolder: String = ""
    /// Primary selected file in `lastSelectedFolder` when the app quit.
    @AppStorage("lastSelectedFilePath") var lastSelectedFilePath: String = ""

    static let customOrderKey = "promptlibrary.customSortOrder"
    static let ratingsKey = "promptlibrary.ratings"

    /// Where ratings and custom orders live. Injectable so curation backup /
    /// sync tests never touch the real defaults (the `@AppStorage` settings
    /// above always use `.standard`).
    let curationDefaults: UserDefaults

    init(curationDefaults: UserDefaults = .standard) {
        self.curationDefaults = curationDefaults
    }

    func loadCustomOrders() -> [String: [String]] {
        guard let data = curationDefaults.data(forKey: Self.customOrderKey),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { return [:] }
        return decoded
    }

    func saveCustomOrders(_ orders: [String: [String]]) {
        if let data = try? JSONEncoder().encode(orders) {
            curationDefaults.set(data, forKey: Self.customOrderKey)
            CurationStoreEvents.post(.customOrders)
        }
    }

    func loadRatings() -> [String: Int] {
        guard let data = curationDefaults.data(forKey: Self.ratingsKey),
              let decoded = try? JSONDecoder().decode([String: Int].self, from: data)
        else { return [:] }
        return decoded
    }

    func saveRatings(_ ratings: [String: Int]) {
        if let data = try? JSONEncoder().encode(ratings) {
            curationDefaults.set(data, forKey: Self.ratingsKey)
            CurationStoreEvents.post(.ratings)
        }
    }

    func loadFilterConfig() -> FilterConfig {
        let hiddenFileTypes: Set<FileTypeFilter>

        if hiddenFileTypesValue == Self.hiddenFileTypesUnsetValue {
            var migratedTypes = FilterConfig.defaultHiddenFileTypes
            if !legacyHideOther {
                migratedTypes.remove(.unsupported)
            }
            if legacyHideJpg {
                migratedTypes.insert(.jpg)
            }
            if legacyHidePng {
                migratedTypes.insert(.png)
            }

            hiddenFileTypes = migratedTypes
            saveHiddenFileTypes(migratedTypes)
        } else {
            hiddenFileTypes = decodeHiddenFileTypes(hiddenFileTypesValue)
        }

        return FilterConfig(
            hiddenFileTypes: hiddenFileTypes,
            filterMinRating: filterMinRating,
            flagFilter: FlagFilter(rawValue: filterFlag) ?? .all,
            labelFilter: Set(filterLabels.split(separator: ",").compactMap { Int($0) }.filter { (0...7).contains($0) }),
            colorFilter: ColorFilter(storageString: filterColor)
        )
    }

    func saveFilterConfig(_ config: FilterConfig) {
        saveHiddenFileTypes(config.hiddenFileTypes)
        filterMinRating = config.filterMinRating
        filterFlag = config.flagFilter.rawValue
        filterLabels = config.labelFilter.sorted().map(String.init).joined(separator: ",")
        filterColor = config.colorFilter?.storageString ?? ""
    }

    private func saveHiddenFileTypes(_ hiddenFileTypes: Set<FileTypeFilter>) {
        hiddenFileTypesValue = hiddenFileTypes
            .map(\.rawValue)
            .sorted()
            .joined(separator: ",")
    }

    private func decodeHiddenFileTypes(_ rawValue: String) -> Set<FileTypeFilter> {
        guard !rawValue.isEmpty else { return [] }
        return Set(
            rawValue
                .split(separator: ",")
                .compactMap { FileTypeFilter(rawValue: String($0)) }
        )
    }
}

/// Helpers for metadata stores keyed by absolute file path (ratings, flags,
/// tags, favorites, custom sort orders). When a file or folder is renamed or moved,
/// its own key and every key underneath it (for folders) must follow it.
enum MetadataPathKeys {
    /// True when `path` is `root` itself or lives inside it.
    static func isSameOrDescendant(_ path: String, of root: String) -> Bool {
        path == root || path.hasPrefix(directoryPrefix(root))
    }

    /// The rewritten path when `path` is `oldPath` or lives inside it, else nil.
    static func rewrite(_ path: String, from oldPath: String, to newPath: String) -> String? {
        if path == oldPath { return newPath }
        let oldPrefix = directoryPrefix(oldPath)
        guard path.hasPrefix(oldPrefix) else { return nil }
        return directoryPrefix(newPath) + path.dropFirst(oldPrefix.count)
    }

    /// Returns `dictionary` with every key under `oldPath` moved under `newPath`,
    /// or nil when nothing matched.
    static func migratingKeys<Value>(
        of dictionary: [String: Value],
        from oldPath: String,
        to newPath: String
    ) -> [String: Value]? {
        var result = dictionary
        var changed = false
        for (key, value) in dictionary {
            guard let rewritten = rewrite(key, from: oldPath, to: newPath), rewritten != key else { continue }
            result.removeValue(forKey: key)
            result[rewritten] = value
            changed = true
        }
        return changed ? result : nil
    }

    private static func directoryPrefix(_ path: String) -> String {
        path.hasSuffix("/") ? path : path + "/"
    }
}
