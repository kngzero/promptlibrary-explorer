import Foundation
import SystemConfiguration

// MARK: - Change notifications

/// The curation stores (ratings, flags, tags, favorites, custom orders, smart folders,
/// collections, sets, snippets) that post `CurationStoreEvents.didChange` when they save.
enum CurationStoreKind: String, CaseIterable, Sendable {
    case ratings
    case flags
    case tags
    case tagAssignments
    case favorites
    case customOrders
    case smartFolders
    case collections
    case collectionSets
    case snippets
    case stacks
}

/// Every curation store posts this after it writes, so the curation controller can
/// debounce a library-file sync, a Finder tag push and sidecar writes. Posted on the
/// thread that saved; observers hop to the main queue.
enum CurationStoreEvents {
    static let didChange = Notification.Name("PromptLibraryExplorer.curationStoreDidChange")
    static let kindKey = "kind"

    static func post(_ kind: CurationStoreKind) {
        NotificationCenter.default.post(name: didChange, object: nil, userInfo: [kindKey: kind.rawValue])
    }
}

// MARK: - Store set

/// The full set of curation stores the backup, import and library sync code reads and
/// writes. `live` is the app's singletons; tests build `isolated` stores on a
/// `UserDefaults` suite and a temp folder so real user data is never touched.
@MainActor
struct CurationStores {
    let settings: SettingsStore
    let flags: FlagStore
    let tags: TagService
    let favorites: FavoritesService
    let smartFolders: SmartFolderService
    let collections: CollectionService
    let snippets: SnippetService
    let recents: RecentHistoryService
    /// Where the app's own preferences (`CurationSettingsKeys.all`) are read and restored.
    let settingsDefaults: UserDefaults
    /// Manual version stacks and automatic-stack exclusions.
    var stacks: StackStore = StackStore()

    static var live: CurationStores {
        CurationStores(
            settings: .shared,
            flags: FlagStore(),
            tags: .shared,
            favorites: .shared,
            smartFolders: .shared,
            collections: .shared,
            snippets: .shared,
            recents: .shared,
            settingsDefaults: .standard,
            stacks: StackStore()
        )
    }

    static func isolated(defaults: UserDefaults, directory: URL) -> CurationStores {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return CurationStores(
            settings: SettingsStore(curationDefaults: defaults),
            flags: FlagStore(defaults: defaults),
            tags: TagService(defaults: defaults),
            favorites: FavoritesService(defaults: defaults),
            smartFolders: SmartFolderService(defaults: defaults),
            collections: CollectionService(directory: directory),
            snippets: SnippetService(directory: directory),
            recents: RecentHistoryService(defaults: defaults),
            settingsDefaults: defaults,
            stacks: StackStore(defaults: defaults)
        )
    }
}

/// App preferences carried by curation bundles. Window/session state (last folder,
/// selection) and machine-specific paths are deliberately left out.
enum CurationSettingsKeys {
    static let all: [String] = [
        "thumbnailSize", "sortField", "sortDirection", "hiddenFileTypes", "showStatusBar",
        "thumbnailsOnly", "appearanceMode", "confirmBeforeTrash", "duplicateNamePolicy",
        "externalDragOperation", "filterMinRating", "filterFlag", "filterLabels", "filterColor",
        "visualSearch.scope", "visualSearch.colorTolerance", "grid.showColorStrip",
        "cullingMode", "cullAutoAdvance", "previewPaneCollapsed", "searchMode",
        "browserViewMode", "browserGroupBy", "sidebarVisible", "visualIndex.enabled",
        CurationPreferences.librarySyncKey, CurationPreferences.finderTagsKey, CurationPreferences.xmpKey,
        "imageText.recognizeText", "imageText.suggestTags",
    ]
}

/// A property-list scalar stored in a curation bundle's `settings` object.
enum CurationSettingValue: Codable, Equatable, Sendable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    init?(plistValue value: Any) {
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number) {
                self = .double(number.doubleValue)
            } else {
                self = .int(number.intValue)
            }
        } else if let string = value as? String {
            self = .string(string)
        } else {
            return nil
        }
    }

    /// JSON can't tell 7 from 7.0, so whole-number doubles equal the matching int.
    static func == (lhs: CurationSettingValue, rhs: CurationSettingValue) -> Bool {
        switch (lhs, rhs) {
        case let (.bool(a), .bool(b)): return a == b
        case let (.string(a), .string(b)): return a == b
        case let (.int(a), .int(b)): return a == b
        case let (.double(a), .double(b)): return a == b
        case let (.int(a), .double(b)), let (.double(b), .int(a)): return Double(a) == b
        default: return false
        }
    }

    var plistValue: Any {
        switch self {
        case let .bool(value): return value
        case let .int(value): return value
        case let .double(value): return value
        case let .string(value): return value
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .bool(value): try container.encode(value)
        case let .int(value): try container.encode(value)
        case let .double(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        }
    }
}

/// Persisted switches for the Settings ▸ Data page.
enum CurationPreferences {
    static let librarySyncKey = "curation.librarySync.enabled"
    static let finderTagsKey = "curation.finderTags.enabled"
    static let xmpKey = "curation.xmp.enabled"
    static let extraBackupFolderKey = "curation.backup.extraFolder"
    static let deviceIDKey = "curation.deviceID"
    static let migratedSchemaKey = "curation.migratedSchema"
    static let lastBackupKey = "curation.backup.last"
}

/// Identity of this Mac for library-file stamps and backup names.
enum CurationDevice {
    /// A stable random id, created once per user account on this Mac.
    static func id(defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: CurationPreferences.deviceIDKey), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: CurationPreferences.deviceIDKey)
        return fresh
    }

    /// The Sharing name ("Kareem's MacBook Pro"). `Host.current()` can block on DNS.
    static let machineName: String = {
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty {
            return name
        }
        return "Mac"
    }()

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (short?, build?) where short != build: return "\(short) (\(build))"
        case let (short?, _): return short
        default: return "dev"
        }
    }
}

// MARK: - Path helpers

/// Root-relative paths used by bundles and library files.
enum CurationPaths {
    /// `path` relative to `root` ("" for the root itself), or nil when outside it.
    static func relative(_ path: String, to root: String) -> String? {
        let root = trimmedRoot(root)
        if path == root { return "" }
        let prefix = root == "/" ? "/" : root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    static func absolute(_ relative: String, in root: String) -> String {
        let root = trimmedRoot(root)
        guard !relative.isEmpty else { return root }
        return root == "/" ? "/" + relative : root + "/" + relative
    }

    static func trimmedRoot(_ root: String) -> String {
        guard root.count > 1, root.hasSuffix("/") else { return root }
        return String(root.dropLast())
    }
}
