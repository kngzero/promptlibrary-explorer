import Foundation

// MARK: - Library data file format (schemaVersion 1)
//
// `<library root>/.promptlibrary/curation.json` holds the curation of the files under
// that root, keyed by ROOT-RELATIVE path, so the same file works on every Mac that
// syncs the folder (Dropbox paths differ between Macs). Every value carries its own
// stamp so two Macs can merge without a server:
//
//   {
//     "format": "com.artofficial.promptlibrary.library-curation",
//     "schemaVersion": 1,
//     "updatedAt": "2026-09-27T10:15:00.123Z", "updatedBy": "device-UUID",
//     "updatedByName": "Studio Mac", "appVersion": "1.4",
//     "files": {
//       "Shoot/a.png": {
//         "rating":   { "v": 4,            "t": 1727431200.123, "d": "device-UUID" },
//         "flag":     { "v": 1,            "t": ..., "d": ... },   // 1 pick, -1 reject
//         "tags":     { "v": ["Hero"],     "t": ..., "d": ... },   // tag NAMES
//         "favorite": { "t": ..., "d": ... }                        // no "v" = tombstone
//       }
//     },
//     "customOrders":   { "Shoot":  { "v": ["Shoot/b.png", "Shoot/a.png"], "t", "d" } },
//     "tags":           { "hero":   { "v": { "name": "Hero", "colorHex": "#EF4444" }, "t", "d" } },
//     "collections":    { "UUID":   { "v": { "name", "createdAt", "parentID", "items": [relative] }, "t", "d" } },
//     "collectionSets": { "UUID":   { "v": { "name", "createdAt", "parentID" }, "t", "d" } },
//     "smartFolders":   { "UUID":   { "v": { "name", "createdAt", "criteria", "tagNames" }, "t", "d" } },
//     "stacks":         { "UUID":   { "v": { "createdAt", "items": [relative], "cover": relative? }, "t", "d" } },
//     "stackExclusions": { "Shoot/a.png": { "v": true, "t", "d" } }   // kept out of automatic stacks
//   }
//
// "stacks" / "stackExclusions" were added without a schema bump (older apps ignore them;
// the ledger on a Mac that knows them writes them back on its next sync).
//
// "t" is seconds since 1970 when that Mac changed the value ("t": 0 marks values that
// existed before sync was first turned on), "d" the device. A record without "v" is a
// tombstone: the value was removed, so an older copy elsewhere must not resurrect it.
// Tombstones are pruned after 90 days. Merge: per record, the newer stamp wins; if both
// sides changed within 2 seconds the local value is kept (in this Mac's stores) and the
// conflict is logged, while the file itself gets a deterministic winner (newer stamp,
// then higher device id) so two Macs never keep rewriting it at each other.
// Per-file tags are stored as lowercased names (tag ids differ between Macs; the "tags"
// map gives each name its display spelling and colour); smart folder tag rules too.

/// A value with the time and device that last changed it. `value == nil` is a tombstone.
struct Stamped<Value: Codable & Equatable>: Codable, Equatable {
    var value: Value?
    var modifiedAt: Double
    var device: String

    var isTombstone: Bool { value == nil }

    enum CodingKeys: String, CodingKey {
        case value = "v"
        case modifiedAt = "t"
        case device = "d"
    }
}

struct LibraryFileRecord: Codable, Equatable {
    var rating: Stamped<Int>?
    var flag: Stamped<Int>?
    var tags: Stamped<[String]>?
    var favorite: Stamped<Bool>?

    var isEmpty: Bool { rating == nil && flag == nil && tags == nil && favorite == nil }
}

struct LibraryTagDefinition: Codable, Equatable {
    var name: String
    var colorHex: String
}

struct LibraryCollectionValue: Codable, Equatable {
    var name: String
    /// ISO 8601 string, so a value survives JSON round trips bit for bit.
    var createdAt: String
    var parentID: UUID?
    /// Root-relative member paths, in collection order.
    var items: [String]
}

struct LibrarySetValue: Codable, Equatable {
    var name: String
    var createdAt: String
    var parentID: UUID?
}

/// A manual version stack in the library data file (members root-relative).
struct LibraryStackValue: Codable, Equatable {
    var createdAt: String
    var items: [String]
    var cover: String?
}

struct LibrarySmartFolderValue: Codable, Equatable {
    var name: String
    var createdAt: String
    /// Criteria with `tagIDs` emptied; the tag rule travels as `tagNames`.
    var criteria: SmartFolderCriteria
    var tagNames: [String]
}

/// The stamped library data file (and, with the same shape, this Mac's ledger of what it
/// last synced for a root).
struct LibraryCurationDocument: Codable, Equatable {
    static let formatIdentifier = "com.artofficial.promptlibrary.library-curation"
    static let currentSchemaVersion = 1

    var format: String = LibraryCurationDocument.formatIdentifier
    var schemaVersion: Int = LibraryCurationDocument.currentSchemaVersion
    var updatedAt: Date?
    var updatedBy: String?
    var updatedByName: String?
    var appVersion: String?
    var files: [String: LibraryFileRecord] = [:]
    var customOrders: [String: Stamped<[String]>] = [:]
    var tags: [String: Stamped<LibraryTagDefinition>] = [:]
    var collections: [String: Stamped<LibraryCollectionValue>] = [:]
    var collectionSets: [String: Stamped<LibrarySetValue>] = [:]
    var smartFolders: [String: Stamped<LibrarySmartFolderValue>] = [:]
    var stacks: [String: Stamped<LibraryStackValue>] = [:]
    var stackExclusions: [String: Stamped<Bool>] = [:]

    init() {}

    enum CodingKeys: String, CodingKey {
        case format, schemaVersion, updatedAt, updatedBy, updatedByName, appVersion
        case files, customOrders, tags, collections, collectionSets, smartFolders
        case stacks, stackExclusions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decodeIfPresent(String.self, forKey: .format) ?? ""
        guard format == Self.formatIdentifier else { throw LibraryCurationError.notALibraryFile }
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard schemaVersion <= Self.currentSchemaVersion else {
            throw LibraryCurationError.newerSchema(schemaVersion)
        }
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        updatedBy = try c.decodeIfPresent(String.self, forKey: .updatedBy)
        updatedByName = try c.decodeIfPresent(String.self, forKey: .updatedByName)
        appVersion = try c.decodeIfPresent(String.self, forKey: .appVersion)
        files = try c.decodeIfPresent([String: LibraryFileRecord].self, forKey: .files) ?? [:]
        customOrders = try c.decodeIfPresent([String: Stamped<[String]>].self, forKey: .customOrders) ?? [:]
        tags = try c.decodeIfPresent([String: Stamped<LibraryTagDefinition>].self, forKey: .tags) ?? [:]
        collections = try c.decodeIfPresent([String: Stamped<LibraryCollectionValue>].self, forKey: .collections) ?? [:]
        collectionSets = try c.decodeIfPresent([String: Stamped<LibrarySetValue>].self, forKey: .collectionSets) ?? [:]
        smartFolders = try c.decodeIfPresent([String: Stamped<LibrarySmartFolderValue>].self, forKey: .smartFolders) ?? [:]
        stacks = (try? c.decodeIfPresent([String: Stamped<LibraryStackValue>].self, forKey: .stacks)) ?? [:]
        stackExclusions = (try? c.decodeIfPresent([String: Stamped<Bool>].self, forKey: .stackExclusions)) ?? [:]
    }

    /// True when the synced content (not the header) is the same.
    func hasSameContent(as other: LibraryCurationDocument) -> Bool {
        files == other.files && customOrders == other.customOrders && tags == other.tags
            && collections == other.collections && collectionSets == other.collectionSets
            && smartFolders == other.smartFolders
            && stacks == other.stacks && stackExclusions == other.stackExclusions
    }

    var isEmpty: Bool {
        files.isEmpty && customOrders.isEmpty && tags.isEmpty && collections.isEmpty
            && collectionSets.isEmpty && smartFolders.isEmpty
            && stacks.isEmpty && stackExclusions.isEmpty
    }

    static func decode(_ data: Data) throws -> LibraryCurationDocument {
        do {
            return try CurationBundle.decoder().decode(LibraryCurationDocument.self, from: data)
        } catch let error as LibraryCurationError {
            throw error
        } catch {
            throw LibraryCurationError.unreadable(error.localizedDescription)
        }
    }

    func encoded() throws -> Data {
        let encoder = CurationBundle.encoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

enum LibraryCurationError: LocalizedError, Equatable {
    case notALibraryFile
    case newerSchema(Int)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .notALibraryFile: return "The library data file isn't in the expected format."
        case let .newerSchema(version):
            return "The library data file was written by a newer version of the app (format \(version)). Sync is paused for this library until you update."
        case let .unreadable(detail): return "The library data file couldn't be read: \(detail)"
        }
    }
}

// MARK: - Unstamped state

struct PortableFileValues: Equatable {
    var rating: Int?
    var flag: Int?
    var tags: [String]?
    var favorite: Bool?

    var isEmpty: Bool { rating == nil && flag == nil && tags == nil && favorite == nil }
}

/// The curation for one root as plain values (what the stores hold now, root-relative).
struct CurationPortableState: Equatable {
    var files: [String: PortableFileValues] = [:]
    var customOrders: [String: [String]] = [:]
    var tags: [String: LibraryTagDefinition] = [:]
    var collections: [String: LibraryCollectionValue] = [:]
    var collectionSets: [String: LibrarySetValue] = [:]
    var smartFolders: [String: LibrarySmartFolderValue] = [:]
    var stacks: [String: LibraryStackValue] = [:]
    var stackExclusions: [String: Bool] = [:]
}

extension LibraryCurationDocument {
    /// The live (non-tombstone) values.
    var portableState: CurationPortableState {
        var state = CurationPortableState()
        for (key, record) in files {
            let values = PortableFileValues(
                rating: record.rating?.value,
                flag: record.flag?.value,
                tags: record.tags?.value,
                favorite: record.favorite?.value
            )
            if !values.isEmpty { state.files[key] = values }
        }
        state.customOrders = customOrders.compactMapValues(\.value)
        state.tags = tags.compactMapValues(\.value)
        state.collections = collections.compactMapValues(\.value)
        state.collectionSets = collectionSets.compactMapValues(\.value)
        state.smartFolders = smartFolders.compactMapValues(\.value)
        state.stacks = stacks.compactMapValues(\.value)
        state.stackExclusions = stackExclusions.compactMapValues(\.value)
        return state
    }
}

// MARK: - Merge engine

/// One merge decision worth logging: both sides changed the same record within the
/// conflict window and the local value was kept.
struct CurationConflict: Equatable, Hashable, CustomStringConvertible {
    let kind: String
    let key: String
    let localDevice: String
    let remoteDevice: String
    var localStamp: Double = 0
    var remoteStamp: Double = 0

    var description: String { "\(kind) \"\(key)\": kept this Mac's value over \(remoteDevice)'s" }
}

enum CurationMergeEngine {
    /// Changes on two Macs closer together than this are treated as simultaneous.
    static let conflictWindow: TimeInterval = 2
    /// Tombstones older than this are dropped.
    static let tombstoneLifetime: TimeInterval = 90 * 24 * 3600
    /// Stamp for values that existed before this Mac first synced a root: any real
    /// change elsewhere wins over them, and they still fill gaps.
    static let baselineStamp: Double = 0

    static func roundedStamp(_ date: Date) -> Double {
        (date.timeIntervalSince1970 * 1000).rounded() / 1000
    }

    // MARK: Record merge

    /// Merges one record. `preferLocal` is this Mac's view (a simultaneous change keeps
    /// the local value); without it, simultaneous changes resolve deterministically —
    /// the same answer on every Mac — which is what goes into the shared file.
    static func merge<V>(
        local: Stamped<V>?,
        remote: Stamped<V>?,
        kind: String,
        key: String,
        preferLocal: Bool = true,
        conflicts: inout [CurationConflict]
    ) -> Stamped<V>? {
        guard let local else { return remote }
        guard let remote else { return local }
        if local.value == remote.value {
            // Same value: keep the newer stamp so tombstone ages stay honest.
            return remote.modifiedAt > local.modifiedAt ? remote : local
        }
        if abs(local.modifiedAt - remote.modifiedAt) <= conflictWindow {
            conflicts.append(CurationConflict(
                kind: kind, key: key, localDevice: local.device, remoteDevice: remote.device,
                localStamp: local.modifiedAt, remoteStamp: remote.modifiedAt
            ))
            if preferLocal { return local }
            if local.modifiedAt != remote.modifiedAt { return remote.modifiedAt > local.modifiedAt ? remote : local }
            return remote.device > local.device ? remote : local
        }
        return remote.modifiedAt > local.modifiedAt ? remote : local
    }

    private static func mergeMaps<V>(
        _ local: [String: Stamped<V>],
        _ remote: [String: Stamped<V>],
        kind: String,
        preferLocal: Bool,
        conflicts: inout [CurationConflict]
    ) -> [String: Stamped<V>] {
        var result = local
        for (key, remoteValue) in remote {
            result[key] = merge(local: local[key], remote: remoteValue, kind: kind, key: key, preferLocal: preferLocal, conflicts: &conflicts)
        }
        return result
    }

    /// Merges `remote` into `local`. Only the synced content is merged; the header comes
    /// from `local`.
    static func merge(
        local: LibraryCurationDocument,
        remote: LibraryCurationDocument,
        preferLocal: Bool = true,
        conflicts: inout [CurationConflict]
    ) -> LibraryCurationDocument {
        var result = local
        for (key, remoteRecord) in remote.files {
            let localRecord = local.files[key] ?? LibraryFileRecord()
            var merged = LibraryFileRecord()
            merged.rating = merge(local: localRecord.rating, remote: remoteRecord.rating, kind: "rating", key: key, preferLocal: preferLocal, conflicts: &conflicts)
            merged.flag = merge(local: localRecord.flag, remote: remoteRecord.flag, kind: "flag", key: key, preferLocal: preferLocal, conflicts: &conflicts)
            merged.tags = merge(local: localRecord.tags, remote: remoteRecord.tags, kind: "tags", key: key, preferLocal: preferLocal, conflicts: &conflicts)
            merged.favorite = merge(local: localRecord.favorite, remote: remoteRecord.favorite, kind: "favorite", key: key, preferLocal: preferLocal, conflicts: &conflicts)
            result.files[key] = merged.isEmpty ? nil : merged
        }
        result.customOrders = mergeMaps(local.customOrders, remote.customOrders, kind: "custom order", preferLocal: preferLocal, conflicts: &conflicts)
        result.tags = mergeMaps(local.tags, remote.tags, kind: "tag", preferLocal: preferLocal, conflicts: &conflicts)
        result.collections = mergeMaps(local.collections, remote.collections, kind: "collection", preferLocal: preferLocal, conflicts: &conflicts)
        result.collectionSets = mergeMaps(local.collectionSets, remote.collectionSets, kind: "collection set", preferLocal: preferLocal, conflicts: &conflicts)
        result.smartFolders = mergeMaps(local.smartFolders, remote.smartFolders, kind: "smart folder", preferLocal: preferLocal, conflicts: &conflicts)
        result.stacks = mergeMaps(local.stacks, remote.stacks, kind: "stack", preferLocal: preferLocal, conflicts: &conflicts)
        result.stackExclusions = mergeMaps(local.stackExclusions, remote.stackExclusions, kind: "stack exclusion", preferLocal: preferLocal, conflicts: &conflicts)
        return result
    }

    // MARK: Local stamping

    /// Brings `ledger` (what this Mac last synced) up to date with `current` (what the
    /// stores hold now): every value that changed gets `now` and this device; every value
    /// that disappeared becomes a tombstone. With no ledger (first sync of this root on
    /// this Mac) the current values are stamped `baselineStamp` so a library file that
    /// already exists is merged into, never overwritten.
    static func stamp(
        ledger: LibraryCurationDocument?,
        current: CurationPortableState,
        now: Date,
        device: String
    ) -> LibraryCurationDocument {
        let time = ledger == nil ? baselineStamp : roundedStamp(now)
        var result = ledger ?? LibraryCurationDocument()

        func stamped<V>(_ previous: Stamped<V>?, _ value: V?) -> Stamped<V>? {
            if let previous {
                if previous.value == value { return previous }
                // A value that was never there needs no tombstone… unless one exists.
                return Stamped(value: value, modifiedAt: time, device: device)
            }
            guard let value else { return nil }
            return Stamped(value: value, modifiedAt: time, device: device)
        }

        let fileKeys = Set(result.files.keys).union(current.files.keys)
        for key in fileKeys {
            let previous = result.files[key] ?? LibraryFileRecord()
            let values = current.files[key] ?? PortableFileValues()
            var record = LibraryFileRecord()
            record.rating = stamped(previous.rating, values.rating)
            record.flag = stamped(previous.flag, values.flag)
            record.tags = stamped(previous.tags, values.tags)
            record.favorite = stamped(previous.favorite, values.favorite)
            result.files[key] = record.isEmpty ? nil : record
        }

        func stampMap<V>(_ previous: [String: Stamped<V>], _ values: [String: V]) -> [String: Stamped<V>] {
            var output: [String: Stamped<V>] = [:]
            for key in Set(previous.keys).union(values.keys) {
                output[key] = stamped(previous[key], values[key])
            }
            return output
        }
        result.customOrders = stampMap(result.customOrders, current.customOrders)
        result.tags = stampMap(result.tags, current.tags)
        result.collections = stampMap(result.collections, current.collections)
        result.collectionSets = stampMap(result.collectionSets, current.collectionSets)
        result.smartFolders = stampMap(result.smartFolders, current.smartFolders)
        result.stacks = stampMap(result.stacks, current.stacks)
        result.stackExclusions = stampMap(result.stackExclusions, current.stackExclusions)
        return result
    }

    // MARK: Tombstones

    static func pruningTombstones(_ document: LibraryCurationDocument, now: Date) -> LibraryCurationDocument {
        let cutoff = now.timeIntervalSince1970 - tombstoneLifetime
        func keep<V>(_ value: Stamped<V>?) -> Stamped<V>? {
            guard let value else { return nil }
            return value.isTombstone && value.modifiedAt < cutoff ? nil : value
        }
        var result = document
        result.files = document.files.compactMapValues { record in
            let pruned = LibraryFileRecord(
                rating: keep(record.rating), flag: keep(record.flag),
                tags: keep(record.tags), favorite: keep(record.favorite)
            )
            return pruned.isEmpty ? nil : pruned
        }
        result.customOrders = document.customOrders.compactMapValues { keep($0) }
        result.tags = document.tags.compactMapValues { keep($0) }
        result.collections = document.collections.compactMapValues { keep($0) }
        result.collectionSets = document.collectionSets.compactMapValues { keep($0) }
        result.smartFolders = document.smartFolders.compactMapValues { keep($0) }
        result.stacks = document.stacks.compactMapValues { keep($0) }
        result.stackExclusions = document.stackExclusions.compactMapValues { keep($0) }
        return result
    }

    // MARK: Conflicted copies

    /// Dropbox's "curation (Studio Mac's conflicted copy 2026-09-27).json" and similar.
    static func isConflictedCopy(fileName: String) -> Bool {
        let lower = fileName.lowercased()
        return lower.hasPrefix("curation") && lower.hasSuffix(".json") && lower != "curation.json"
            && lower.contains("conflicted copy")
    }

    /// Full sync step without I/O: stamp local changes, merge the library file and any
    /// conflicted copies, prune tombstones. `document` is this Mac's result (its stores
    /// and ledger); `fileDocument` is what the shared file should hold — the same except
    /// that simultaneous edits resolve the same way on every Mac.
    static func synchronize(
        ledger: LibraryCurationDocument?,
        current: CurationPortableState,
        remotes: [LibraryCurationDocument],
        now: Date,
        device: String
    ) -> (document: LibraryCurationDocument, fileDocument: LibraryCurationDocument, conflicts: [CurationConflict]) {
        let stamped = stamp(ledger: ledger, current: current, now: now, device: device)
        var document = stamped
        var fileDocument = stamped
        var conflicts: [CurationConflict] = []
        var ignored: [CurationConflict] = []
        for remote in remotes {
            document = merge(local: document, remote: remote, preferLocal: true, conflicts: &conflicts)
            fileDocument = merge(local: fileDocument, remote: remote, preferLocal: false, conflicts: &ignored)
        }
        return (pruningTombstones(document, now: now), pruningTombstones(fileDocument, now: now), conflicts)
    }
}
