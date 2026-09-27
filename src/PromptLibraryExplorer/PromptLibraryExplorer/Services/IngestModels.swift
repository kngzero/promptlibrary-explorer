import Foundation

// MARK: - Ingest inbox: persisted model
//
// A watched SOURCE folder (ComfyUI output, Downloads/Midjourney…) has rules that
// apply to NEW files appearing in it. Nothing here ever deletes a file: a
// duplicate is linked, never removed, and the source is left alone.

/// File kinds a source accepts.
struct IngestFileKinds: OptionSet, Codable, Hashable, Sendable {
    let rawValue: Int

    static let images = IngestFileKinds(rawValue: 1 << 0)
    static let videos = IngestFileKinds(rawValue: 1 << 1)
    static let audio = IngestFileKinds(rawValue: 1 << 2)
    /// Art Official documents: Mood boards, Story projects, .plib and .aoe snapshots.
    static let documents = IngestFileKinds(rawValue: 1 << 3)

    static let all: IngestFileKinds = [.images, .videos, .audio, .documents]

    static let choices: [(kind: IngestFileKinds, title: String)] = [
        (.images, "Images"), (.videos, "Videos"), (.audio, "Audio"), (.documents, "Art Official documents"),
    ]
}

/// What happens to a new file.
enum IngestAction: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Just surface it in the Inbox.
    case leaveInPlace
    /// Copy into the destination; the source file stays.
    case copy
    /// Move into the destination (undoable).
    case move

    var id: String { rawValue }

    var title: String {
        switch self {
        case .leaveInPlace: return "Leave in place"
        case .copy: return "Copy to library folder"
        case .move: return "Move to library folder"
        }
    }

    var explanation: String {
        switch self {
        case .leaveInPlace:
            return "The file stays where it is and shows up in the Inbox."
        case .copy:
            return "A copy goes into the destination; the original is untouched."
        case .move:
            return "The file moves into the destination. Edit ▸ Undo moves it back."
        }
    }
}

/// Rules applied to each new file of a source.
struct IngestRules: Codable, Equatable, Sendable {
    var kinds: IngestFileKinds = .all
    /// Smaller files are ignored (0 = no minimum).
    var minimumSizeBytes: Int64 = 0
    /// Glob patterns (`*`, `?`, `[…]`) matched against the file name and the path
    /// inside the source, case-insensitively. Matching files are ignored.
    var ignorePatterns: [String] = []

    var action: IngestAction = .leaveInPlace
    /// Library folder for Copy / Move (nil = the open library root).
    var destinationPath: String?
    var usesDatedSubfolders = false
    /// Date format per folder level, `/` between levels (`yyyy/MM-dd` → 2026/09-27).
    var datedSubfolderTemplate = IngestRules.defaultDatedTemplate

    /// Batch Rename template (`{date}_{model}_{counter:3}`…); empty keeps the name.
    var renameTemplate = ""

    /// Tags added to every new file (created when missing).
    var fixedTags: [String] = []
    /// Also tag with the model / checkpoint name read from the file's metadata.
    var tagWithModelName = false
    /// Collection the new files are added to.
    var collectionID: UUID?

    static let defaultDatedTemplate = "yyyy/MM-dd"

    init() {}

    private enum CodingKeys: String, CodingKey {
        case kinds, minimumSizeBytes, ignorePatterns, action, destinationPath, usesDatedSubfolders
        case datedSubfolderTemplate, renameTemplate, fixedTags, tagWithModelName, collectionID
    }

    // Tolerant decoding: fields added later default instead of failing the whole store.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kinds = (try? c.decodeIfPresent(IngestFileKinds.self, forKey: .kinds)) ?? .all
        minimumSizeBytes = (try? c.decodeIfPresent(Int64.self, forKey: .minimumSizeBytes)) ?? 0
        ignorePatterns = (try? c.decodeIfPresent([String].self, forKey: .ignorePatterns)) ?? []
        action = (try? c.decodeIfPresent(IngestAction.self, forKey: .action)) ?? .leaveInPlace
        destinationPath = try? c.decodeIfPresent(String.self, forKey: .destinationPath)
        usesDatedSubfolders = (try? c.decodeIfPresent(Bool.self, forKey: .usesDatedSubfolders)) ?? false
        datedSubfolderTemplate = (try? c.decodeIfPresent(String.self, forKey: .datedSubfolderTemplate)) ?? Self.defaultDatedTemplate
        renameTemplate = (try? c.decodeIfPresent(String.self, forKey: .renameTemplate)) ?? ""
        fixedTags = (try? c.decodeIfPresent([String].self, forKey: .fixedTags)) ?? []
        tagWithModelName = (try? c.decodeIfPresent(Bool.self, forKey: .tagWithModelName)) ?? false
        collectionID = try? c.decodeIfPresent(UUID.self, forKey: .collectionID)
    }
}

/// A watched source folder.
struct IngestSource: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var path: String
    var name: String
    var isEnabled = true
    var includeSubfolders = true
    /// On launch, process files that arrived while the app wasn't running.
    var processWhileClosed = true
    var rules = IngestRules()
    /// When the source was added: only files arriving after this are "new".
    var createdAt: Date
    /// Files that arrived before this were already considered (catch-up scans).
    var lastScan: Date?

    init(id: UUID = UUID(), path: String, name: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.path = path
        self.name = name ?? URL(fileURLWithPath: path).lastPathComponent
        self.createdAt = createdAt
        self.lastScan = createdAt
    }

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    private enum CodingKeys: String, CodingKey {
        case id, path, name, isEnabled, includeSubfolders, processWhileClosed, rules, createdAt, lastScan
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        path = try c.decode(String.self, forKey: .path)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? URL(fileURLWithPath: path).lastPathComponent
        isEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? true
        includeSubfolders = (try? c.decodeIfPresent(Bool.self, forKey: .includeSubfolders)) ?? true
        processWhileClosed = (try? c.decodeIfPresent(Bool.self, forKey: .processWhileClosed)) ?? true
        rules = (try? c.decodeIfPresent(IngestRules.self, forKey: .rules)) ?? IngestRules()
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date()
        lastScan = try? c.decodeIfPresent(Date.self, forKey: .lastScan)
    }
}

/// How a file entered the Inbox.
enum IngestOutcomeKind: String, Codable, Sendable {
    case surfaced, renamed, copied, moved, duplicate
}

/// One recently ingested file (the Inbox listing shows these, newest first).
struct InboxItem: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    /// Where the file is now (the copy / moved file / the existing duplicate).
    var path: String
    /// Where it appeared.
    var originalPath: String
    var sourceID: UUID
    var date: Date
    var outcome: IngestOutcomeKind
}

/// One line of the ingest log.
struct IngestLogEvent: Codable, Identifiable, Equatable, Sendable {
    enum Level: String, Codable, Sendable { case info, warning, error }

    var id = UUID()
    var date: Date
    var level: Level
    var sourceName: String?
    var message: String
    var path: String?
}
