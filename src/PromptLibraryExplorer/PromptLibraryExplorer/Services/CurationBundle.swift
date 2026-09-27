import Foundation

// MARK: - Curation bundle format (schemaVersion 1)
//
// A curation bundle is one UTF-8 JSON object holding every piece of curation the app
// keeps outside the files themselves. It is what Export Curation Data… writes, what the
// rolling backups in ~/Library/Application Support/PromptLibraryExplorer/Backups are, and
// what Import… / Restore from Backup… read.
//
//   {
//     "format":        "com.artofficial.promptlibrary.curation-bundle",
//     "schemaVersion": 1,                    // bumped on incompatible changes
//     "appVersion":    "1.4 (12)",
//     "createdAt":     "2026-09-27T10:15:00.123Z",
//     "machineName":   "Studio Mac",
//     "deviceID":      "UUID",               // the Mac that wrote it
//     "reason":        "manual" | "daily" | "preImport" | "preRestore" | "migration" | "preReset",
//     "counts":        { "ratings": 12, "flags": 3, ... },   // summary, for listings
//     "roots":         [ { "id": 0, "path": "/Users/me/Dropbox/Library", "name": "Library" } ],
//     "files": [ {                           // one per file with any per-file curation
//        "path": "/Users/me/Dropbox/Library/a.png",       // absolute, as stored
//        "root": 0, "relativePath": "a.png",              // when under a known root
//        "rating": 4, "flag": 1 | -1, "tags": ["tag-UUID"], "favorite": true
//     } ],
//     "tags":          [ { "id": "UUID", "name": "Hero", "colorHex": "#EF4444" } ],
//     "customOrders":  [ { "folder": PathRef, "items": [PathRef] } ],
//     "smartFolders":  [ SmartFolder ],      // as stored by the app
//     "collections":   [ { "id", "name", "createdAt", "parentID", "items": [PathRef] } ],
//     "collectionSets":[ { "id", "name", "createdAt", "parentID" } ],
//     "snippets":      [ { "id", "title", "text", "category", "createdAt" } ],
//     "recentFolders": [ { "path", "name", "timestamp" } ],
//     "settings":      { "thumbnailSize": 5, "appearanceMode": "dark", ... }
//   }
//
// PathRef = { "path": absolute, "root": index into roots (optional), "relativePath": optional }.
// Every path is stored both ways, so a bundle made on one Mac can be imported on another
// whose Dropbox lives at a different absolute path: when the absolute path is missing,
// the relative path is resolved against a local root with the same folder name.
// Dates are ISO 8601 (fractional seconds optional). Unknown keys are ignored by readers;
// missing arrays read as empty. Finder colour labels are not in bundles: they live on
// the files themselves.

struct CurationBundle: Codable, Equatable {
    static let formatIdentifier = "com.artofficial.promptlibrary.curation-bundle"
    static let currentSchemaVersion = 1

    var format: String = CurationBundle.formatIdentifier
    var schemaVersion: Int = CurationBundle.currentSchemaVersion
    var appVersion: String
    var createdAt: Date
    var machineName: String
    var deviceID: String
    var reason: String
    var counts: CurationCounts
    var roots: [CurationBundleRoot] = []
    var files: [CurationBundleFile] = []
    var tags: [FileTag] = []
    var customOrders: [CurationBundleOrder] = []
    var smartFolders: [SmartFolder] = []
    var collections: [CurationBundleCollection] = []
    var collectionSets: [CollectionSet] = []
    var snippets: [PromptSnippet] = []
    var recentFolders: [RecentItem] = []
    var settings: [String: CurationSettingValue] = [:]

    init(
        appVersion: String,
        createdAt: Date,
        machineName: String,
        deviceID: String,
        reason: String,
        counts: CurationCounts = CurationCounts()
    ) {
        self.appVersion = appVersion
        self.createdAt = createdAt
        self.machineName = machineName
        self.deviceID = deviceID
        self.reason = reason
        self.counts = counts
    }

    enum CodingKeys: String, CodingKey {
        case format, schemaVersion, appVersion, createdAt, machineName, deviceID, reason, counts
        case roots, files, tags, customOrders, smartFolders, collections, collectionSets
        case snippets, recentFolders, settings
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decodeIfPresent(String.self, forKey: .format) ?? ""
        guard format == Self.formatIdentifier else { throw CurationBundleError.notABundle }
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard schemaVersion <= Self.currentSchemaVersion else {
            throw CurationBundleError.newerSchema(schemaVersion)
        }
        appVersion = try c.decodeIfPresent(String.self, forKey: .appVersion) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        machineName = try c.decodeIfPresent(String.self, forKey: .machineName) ?? ""
        deviceID = try c.decodeIfPresent(String.self, forKey: .deviceID) ?? ""
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        counts = try c.decodeIfPresent(CurationCounts.self, forKey: .counts) ?? CurationCounts()
        roots = try c.decodeIfPresent([CurationBundleRoot].self, forKey: .roots) ?? []
        files = try c.decodeIfPresent([CurationBundleFile].self, forKey: .files) ?? []
        tags = try c.decodeIfPresent([FileTag].self, forKey: .tags) ?? []
        customOrders = try c.decodeIfPresent([CurationBundleOrder].self, forKey: .customOrders) ?? []
        smartFolders = try c.decodeIfPresent([SmartFolder].self, forKey: .smartFolders) ?? []
        collections = try c.decodeIfPresent([CurationBundleCollection].self, forKey: .collections) ?? []
        collectionSets = try c.decodeIfPresent([CollectionSet].self, forKey: .collectionSets) ?? []
        snippets = try c.decodeIfPresent([PromptSnippet].self, forKey: .snippets) ?? []
        recentFolders = try c.decodeIfPresent([RecentItem].self, forKey: .recentFolders) ?? []
        settings = try c.decodeIfPresent([String: CurationSettingValue].self, forKey: .settings) ?? [:]
    }

    // MARK: Coding

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(CurationDateFormat.string(from: date))
        }
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: seconds)
            }
            let string = try container.decode(String.self)
            guard let date = CurationDateFormat.date(from: string) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Bad date \(string)")
            }
            return date
        }
        return decoder
    }

    func encoded() throws -> Data {
        try Self.encoder().encode(self)
    }

    static func decode(_ data: Data) throws -> CurationBundle {
        do {
            return try decoder().decode(CurationBundle.self, from: data)
        } catch let error as CurationBundleError {
            throw error
        } catch {
            throw CurationBundleError.unreadable(error.localizedDescription)
        }
    }
}

enum CurationBundleError: LocalizedError, Equatable {
    case notABundle
    case newerSchema(Int)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .notABundle:
            return "This file isn't a PromptLibrary Explorer curation export."
        case let .newerSchema(version):
            return "This export was made by a newer version of the app (format \(version)). Update the app to import it."
        case let .unreadable(detail):
            return "The export couldn't be read: \(detail)"
        }
    }
}

enum CurationDateFormat {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let whole: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let lock = NSLock()

    static func string(from date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return fractional.string(from: date)
    }

    /// Whole seconds: collections are stored that way on disk, so values built from
    /// them compare equal across relaunches.
    static func wholeSecondString(from date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return whole.string(from: date)
    }

    static func date(from string: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return fractional.date(from: string) ?? whole.date(from: string)
    }
}

struct CurationBundleRoot: Codable, Equatable, Hashable {
    var id: Int
    var path: String
    var name: String
}

struct CurationPathRef: Codable, Equatable, Hashable {
    var path: String
    var root: Int?
    var relativePath: String?
}

struct CurationBundleFile: Codable, Equatable {
    var path: String
    var root: Int?
    var relativePath: String?
    var rating: Int?
    var flag: Int?
    var tags: [UUID]?
    var favorite: Bool?

    var ref: CurationPathRef { CurationPathRef(path: path, root: root, relativePath: relativePath) }
}

struct CurationBundleOrder: Codable, Equatable {
    var folder: CurationPathRef
    var items: [CurationPathRef]
}

struct CurationBundleCollection: Codable, Equatable {
    var id: UUID
    var name: String
    var createdAt: Date
    var parentID: UUID?
    var items: [CurationPathRef]
}

/// Per-kind totals, stored in the bundle header and shown in import previews.
struct CurationCounts: Codable, Equatable, Sendable {
    var ratings = 0
    var flags = 0
    var taggedFiles = 0
    var tags = 0
    var favorites = 0
    var customOrders = 0
    var smartFolders = 0
    var collections = 0
    var collectionSets = 0
    var snippets = 0
    var recentFolders = 0
    var settings = 0

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value(_ key: CodingKeys) -> Int { (try? c.decodeIfPresent(Int.self, forKey: key)) ?? 0 }
        ratings = value(.ratings)
        flags = value(.flags)
        taggedFiles = value(.taggedFiles)
        tags = value(.tags)
        favorites = value(.favorites)
        customOrders = value(.customOrders)
        smartFolders = value(.smartFolders)
        collections = value(.collections)
        collectionSets = value(.collectionSets)
        snippets = value(.snippets)
        recentFolders = value(.recentFolders)
        settings = value(.settings)
    }

    /// "12 ratings · 3 flags · …", skipping zeros.
    var summary: String {
        let parts: [(Int, String, String)] = [
            (ratings, "rating", "ratings"), (flags, "flag", "flags"),
            (taggedFiles, "tagged file", "tagged files"), (tags, "tag", "tags"),
            (favorites, "favorite", "favorites"), (collections, "collection", "collections"),
            (collectionSets, "set", "sets"), (smartFolders, "smart folder", "smart folders"),
            (snippets, "snippet", "snippets"), (customOrders, "custom order", "custom orders"),
        ]
        let text = parts.filter { $0.0 > 0 }.map { "\($0.0) \($0.0 == 1 ? $0.1 : $0.2)" }
        return text.isEmpty ? "No curation data" : text.joined(separator: " · ")
    }

    var total: Int {
        ratings + flags + taggedFiles + tags + favorites + customOrders + smartFolders
            + collections + collectionSets + snippets
    }
}

// MARK: - Export

enum CurationBundleBuilder {
    /// Snapshots every store into a bundle. `roots` are the library roots paths are made
    /// relative to (the longest matching root wins).
    @MainActor
    static func make(
        from stores: CurationStores,
        roots rootURLs: [URL],
        reason: String,
        now: Date = Date(),
        machineName: String = CurationDevice.machineName,
        deviceID: String,
        appVersion: String = CurationDevice.appVersion
    ) -> CurationBundle {
        var bundle = CurationBundle(
            appVersion: appVersion,
            createdAt: now,
            machineName: machineName,
            deviceID: deviceID,
            reason: reason
        )

        var seenRoots = Set<String>()
        let rootPaths = rootURLs
            .map { CurationPaths.trimmedRoot($0.standardizedFileURL.path) }
            .filter { seenRoots.insert($0).inserted }
        bundle.roots = rootPaths.enumerated().map {
            CurationBundleRoot(id: $0.offset, path: $0.element, name: ($0.element as NSString).lastPathComponent)
        }
        // Longest root first so nested roots resolve to the innermost one.
        let rootsByLength = bundle.roots.sorted { $0.path.count > $1.path.count }
        func ref(_ path: String) -> CurationPathRef {
            for root in rootsByLength {
                if let relative = CurationPaths.relative(path, to: root.path) {
                    return CurationPathRef(path: path, root: root.id, relativePath: relative)
                }
            }
            return CurationPathRef(path: path)
        }

        let ratings = stores.settings.loadRatings().filter { $0.value > 0 }
        let flags = stores.flags.load().flags
        let assignments = stores.tags.loadAssignments().filter { !$0.value.isEmpty }
        let favorites = stores.favorites.loadFavorites()

        let allPaths = Set(ratings.keys).union(flags.keys).union(assignments.keys).union(favorites)
        bundle.files = allPaths.sorted().map { path in
            let pathRef = ref(path)
            return CurationBundleFile(
                path: path,
                root: pathRef.root,
                relativePath: pathRef.relativePath,
                rating: ratings[path],
                flag: flags[path].map(\.rawValue),
                tags: assignments[path],
                favorite: favorites.contains(path) ? true : nil
            )
        }
        bundle.tags = stores.tags.loadTags()
        bundle.customOrders = stores.settings.loadCustomOrders()
            .sorted { $0.key < $1.key }
            .map { CurationBundleOrder(folder: ref($0.key), items: $0.value.map(ref)) }
        bundle.smartFolders = stores.smartFolders.loadSmartFolders()
        bundle.collections = stores.collections.all().map {
            CurationBundleCollection(
                id: $0.id, name: $0.name, createdAt: $0.createdAt, parentID: $0.parentID,
                items: $0.paths.map(ref)
            )
        }
        bundle.collectionSets = stores.collections.allSets()
        bundle.snippets = stores.snippets.all()
        bundle.recentFolders = stores.recents.loadAllRecentFolders()
        for key in CurationSettingsKeys.all {
            if let raw = stores.settingsDefaults.object(forKey: key), let value = CurationSettingValue(plistValue: raw) {
                bundle.settings[key] = value
            }
        }

        var counts = CurationCounts()
        counts.ratings = ratings.count
        counts.flags = flags.count
        counts.taggedFiles = assignments.count
        counts.tags = bundle.tags.count
        counts.favorites = favorites.count
        counts.customOrders = bundle.customOrders.count
        counts.smartFolders = bundle.smartFolders.count
        counts.collections = bundle.collections.count
        counts.collectionSets = bundle.collectionSets.count
        counts.snippets = bundle.snippets.count
        counts.recentFolders = bundle.recentFolders.count
        counts.settings = bundle.settings.count
        bundle.counts = counts
        return bundle
    }
}

// MARK: - Import

enum CurationImportMode: String, CaseIterable, Identifiable, Sendable {
    /// Keep everything here and add the export's data; where both have a value for the
    /// same file or object, the export's wins.
    case merge
    /// Make the stores exactly the export (anything not in it is removed).
    case replace

    var id: String { rawValue }

    var title: String {
        switch self {
        case .merge: return "Merge"
        case .replace: return "Replace"
        }
    }

    var explanation: String {
        switch self {
        case .merge:
            return "Keep everything you have and add the export's ratings, flags, tags, collections and more. Where both have a value for the same file, the export's is used."
        case .replace:
            return "Make your curation exactly what the export holds. Anything that isn't in it is removed."
        }
    }
}

/// What an import would do to one kind of data.
struct CurationImportKindChange: Identifiable, Equatable {
    let id: String
    let title: String
    var incoming = 0
    var added = 0
    var changed = 0
    var removed = 0

    var hasChanges: Bool { added + changed + removed > 0 }
}

/// Resolves a bundle's paths on this Mac.
struct CurationPathResolver {
    /// Local library roots a bundle root can map to (matched by folder name).
    var localRoots: [URL]
    var fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }

    func resolve(_ ref: CurationPathRef, roots: [CurationBundleRoot]) -> String {
        if fileExists(ref.path) { return ref.path }
        guard let rootID = ref.root, let relative = ref.relativePath,
              let bundleRoot = roots.first(where: { $0.id == rootID })
        else { return ref.path }
        for local in localRoots {
            let localPath = CurationPaths.trimmedRoot(local.standardizedFileURL.path)
            guard (localPath as NSString).lastPathComponent == bundleRoot.name, localPath != bundleRoot.path else { continue }
            let candidate = CurationPaths.absolute(relative, in: localPath)
            if fileExists(candidate) { return candidate }
        }
        return ref.path
    }
}

/// The bundle's content in store form, with paths resolved for this Mac.
struct CurationResolvedBundle {
    var ratings: [String: Int] = [:]
    var flags: [String: FileFlag] = [:]
    var assignments: [String: [UUID]] = [:]
    var favorites: Set<String> = []
    var tags: [FileTag] = []
    var customOrders: [String: [String]] = [:]
    var smartFolders: [SmartFolder] = []
    var collections: [FileCollection] = []
    var sets: [CollectionSet] = []
    var snippets: [PromptSnippet] = []
    var recents: [RecentItem] = []
    var settings: [String: CurationSettingValue] = [:]

    init(_ bundle: CurationBundle, resolver: CurationPathResolver) {
        func path(_ ref: CurationPathRef) -> String { resolver.resolve(ref, roots: bundle.roots) }
        for file in bundle.files {
            let resolved = path(file.ref)
            if let rating = file.rating, rating > 0 { ratings[resolved] = min(5, rating) }
            if let raw = file.flag, let flag = FileFlag(rawValue: raw), flag != .unflagged { flags[resolved] = flag }
            if let tagIDs = file.tags, !tagIDs.isEmpty { assignments[resolved] = tagIDs }
            if file.favorite == true { favorites.insert(resolved) }
        }
        tags = bundle.tags
        for order in bundle.customOrders {
            customOrders[path(order.folder)] = order.items.map(path)
        }
        smartFolders = bundle.smartFolders
        collections = bundle.collections.map {
            FileCollection(id: $0.id, name: $0.name, paths: $0.items.map(path), createdAt: $0.createdAt, parentID: $0.parentID)
        }
        sets = bundle.collectionSets
        snippets = bundle.snippets
        recents = bundle.recentFolders
        settings = bundle.settings
    }
}

enum CurationImporter {
    /// Per-kind preview of what `apply` would change.
    @MainActor
    static func plan(
        _ bundle: CurationBundle,
        into stores: CurationStores,
        mode: CurationImportMode,
        includeSettings: Bool,
        resolver: CurationPathResolver
    ) -> [CurationImportKindChange] {
        let incoming = CurationResolvedBundle(bundle, resolver: resolver)
        let replace = mode == .replace

        func dictionaryChange<V: Equatable>(_ id: String, _ title: String, local: [String: V], new: [String: V]) -> CurationImportKindChange {
            var change = CurationImportKindChange(id: id, title: title, incoming: new.count)
            for (key, value) in new {
                if let existing = local[key] {
                    if existing != value { change.changed += 1 }
                } else {
                    change.added += 1
                }
            }
            if replace { change.removed = local.keys.filter { new[$0] == nil }.count }
            return change
        }

        func identified<T: Identifiable & Equatable>(_ id: String, _ title: String, local: [T], new: [T]) -> CurationImportKindChange
            where T.ID: Hashable
        {
            let localByID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let newByID = Dictionary(new.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var change = CurationImportKindChange(id: id, title: title, incoming: new.count)
            for (key, value) in newByID {
                if let existing = localByID[key] {
                    if existing != value { change.changed += 1 }
                } else {
                    change.added += 1
                }
            }
            if replace { change.removed = localByID.keys.filter { newByID[$0] == nil }.count }
            return change
        }

        let localAssignments = stores.tags.loadAssignments().filter { !$0.value.isEmpty }
        let mergedAssignmentsPreview: [String: [UUID]] = replace
            ? incoming.assignments
            : incoming.assignments.reduce(into: [:]) { result, pair in
                let existing = localAssignments[pair.key] ?? []
                var merged = existing
                for id in pair.value where !merged.contains(id) { merged.append(id) }
                result[pair.key] = merged
            }
        let localFavorites = Dictionary(stores.favorites.loadFavorites().map { ($0, true) }, uniquingKeysWith: { a, _ in a })
        let newFavorites = Dictionary(incoming.favorites.map { ($0, true) }, uniquingKeysWith: { a, _ in a })

        var changes: [CurationImportKindChange] = [
            dictionaryChange("ratings", "Ratings", local: stores.settings.loadRatings().filter { $0.value > 0 }, new: incoming.ratings),
            dictionaryChange("flags", "Flags", local: stores.flags.load().flags, new: incoming.flags),
            dictionaryChange("taggedFiles", "Tagged files", local: localAssignments, new: mergedAssignmentsPreview),
            identified("tags", "Tags", local: stores.tags.loadTags(), new: incoming.tags),
            dictionaryChange("favorites", "Favorites", local: localFavorites, new: newFavorites),
            dictionaryChange("customOrders", "Custom orders", local: stores.settings.loadCustomOrders(), new: incoming.customOrders),
            identified("smartFolders", "Smart folders", local: stores.smartFolders.loadSmartFolders(), new: incoming.smartFolders),
            identified("collections", "Collections", local: stores.collections.all(), new: incoming.collections),
            identified("collectionSets", "Collection sets", local: stores.collections.allSets(), new: incoming.sets),
            identified("snippets", "Snippets", local: stores.snippets.all(), new: incoming.snippets),
        ]
        changes[2].incoming = incoming.assignments.count
        if includeSettings {
            var change = CurationImportKindChange(id: "settings", title: "App settings", incoming: incoming.settings.count)
            for (key, value) in incoming.settings {
                let local = stores.settingsDefaults.object(forKey: key).flatMap(CurationSettingValue.init(plistValue:))
                if local == nil { change.added += 1 } else if local != value { change.changed += 1 }
            }
            changes.append(change)
        }
        return changes
    }

    /// Writes the bundle into the stores. Take a backup first (the controller does).
    @MainActor
    static func apply(
        _ bundle: CurationBundle,
        to stores: CurationStores,
        mode: CurationImportMode,
        includeSettings: Bool,
        resolver: CurationPathResolver
    ) {
        let incoming = CurationResolvedBundle(bundle, resolver: resolver)
        let replace = mode == .replace

        // Ratings
        var ratings = replace ? [:] : stores.settings.loadRatings()
        for (path, value) in incoming.ratings { ratings[path] = value }
        stores.settings.saveRatings(ratings)

        // Flags
        var flags = replace ? FlagBook() : stores.flags.load()
        for (path, flag) in incoming.flags { flags.set(flag, for: path) }
        stores.flags.save(flags)

        // Tag definitions, then assignments (unknown ids are dropped so nothing dangles).
        var tags = replace ? [] : stores.tags.loadTags()
        for tag in incoming.tags {
            if let index = tags.firstIndex(where: { $0.id == tag.id }) {
                tags[index] = tag
            } else {
                tags.append(tag)
            }
        }
        stores.tags.saveTags(tags)
        let knownTagIDs = Set(tags.map(\.id))
        var assignments = replace ? [:] : stores.tags.loadAssignments()
        for (path, ids) in incoming.assignments {
            var merged = assignments[path] ?? []
            for id in ids where !merged.contains(id) { merged.append(id) }
            assignments[path] = merged
        }
        assignments = assignments.compactMapValues { ids in
            let kept = ids.filter(knownTagIDs.contains)
            return kept.isEmpty ? nil : kept
        }
        stores.tags.saveAssignments(assignments)

        // Favorites
        var favorites = replace ? [] : stores.favorites.loadFavorites()
        favorites.formUnion(incoming.favorites)
        stores.favorites.saveFavorites(favorites)

        // Custom orders
        var orders = replace ? [:] : stores.settings.loadCustomOrders()
        for (folder, items) in incoming.customOrders { orders[folder] = items }
        stores.settings.saveCustomOrders(orders)

        // Smart folders
        stores.smartFolders.saveSmartFolders(mergedByID(
            local: replace ? [] : stores.smartFolders.loadSmartFolders(), incoming: incoming.smartFolders
        ))

        // Collections & sets
        stores.collections.replaceAll(
            collections: mergedByID(local: replace ? [] : stores.collections.all(), incoming: incoming.collections),
            sets: mergedByID(local: replace ? [] : stores.collections.allSets(), incoming: incoming.sets)
        )

        // Snippets
        stores.snippets.replaceAll(mergedByID(local: replace ? [] : stores.snippets.all(), incoming: incoming.snippets))

        // Recent folders: the export's first, then ours.
        var recents = incoming.recents
        if !replace {
            let known = Set(recents.map(\.path))
            recents.append(contentsOf: stores.recents.loadAllRecentFolders().filter { !known.contains($0.path) })
        }
        stores.recents.replaceRecentFolders(recents)

        if includeSettings {
            for (key, value) in incoming.settings where CurationSettingsKeys.all.contains(key) {
                stores.settingsDefaults.set(value.plistValue, forKey: key)
            }
        }
    }

    /// `local` with every `incoming` element replacing the one with its id (or appended).
    static func mergedByID<T: Identifiable>(local: [T], incoming: [T]) -> [T] where T.ID: Hashable {
        var result = local
        var indexByID: [T.ID: Int] = [:]
        for (index, element) in result.enumerated() { indexByID[element.id] = index }
        for element in incoming {
            if let index = indexByID[element.id] {
                result[index] = element
            } else {
                indexByID[element.id] = result.count
                result.append(element)
            }
        }
        return result
    }
}
