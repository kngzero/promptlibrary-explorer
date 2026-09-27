import Foundation

/// Everything the ingest inbox persists, in one JSON file.
struct IngestState: Codable, Equatable, Sendable {
    var sources: [IngestSource] = []
    var inbox: [InboxItem] = []
    var log: [IngestLogEvent] = []
    /// Inbox items after this are "new" (the sidebar badge).
    var lastSeen: Date?
    /// Items before this are hidden from the Inbox listing (Clear Inbox).
    var clearedAt: Date?
    /// Paths each source already handled, oldest first (capped), so a file is
    /// never ingested twice.
    var processed: [String: [String]] = [:]

    init() {}

    private enum CodingKeys: String, CodingKey { case sources, inbox, log, lastSeen, clearedAt, processed }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sources = (try? c.decodeIfPresent([IngestSource].self, forKey: .sources)) ?? []
        inbox = (try? c.decodeIfPresent([InboxItem].self, forKey: .inbox)) ?? []
        log = (try? c.decodeIfPresent([IngestLogEvent].self, forKey: .log)) ?? []
        lastSeen = try? c.decodeIfPresent(Date.self, forKey: .lastSeen)
        clearedAt = try? c.decodeIfPresent(Date.self, forKey: .clearedAt)
        processed = (try? c.decodeIfPresent([String: [String]].self, forKey: .processed)) ?? [:]
    }
}

/// Reads and writes `IngestState` (Application Support ▸ PromptLibraryExplorer ▸
/// ingest.json by default; tests pass a temp file).
struct IngestStore: Sendable {
    let fileURL: URL

    static let maxLogEvents = 200
    static let maxProcessedPerSource = 5000

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            self.fileURL = base
                .appendingPathComponent("PromptLibraryExplorer", isDirectory: true)
                .appendingPathComponent("ingest.json")
        }
    }

    func load() -> IngestState {
        guard let data = try? Data(contentsOf: fileURL) else { return IngestState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(IngestState.self, from: data)) ?? IngestState()
    }

    func save(_ state: IngestState) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(state) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
