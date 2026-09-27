import Foundation
import ImageIO
import SQLite3

// MARK: - Public value types

struct LibrarySearchHit: Sendable, Hashable, Identifiable {
    var id: String { path }
    let path: String
    let fileName: String
    let folderPath: String
    /// Prompt excerpt with the match; plain text, matched terms wrapped in «».
    let snippet: String
    /// bm25 rank (lower is better).
    let rank: Double
}

struct GenerationParameters: Sendable, Hashable {
    var model: String?
    var sampler: String?
    var seed: String?
    var steps: String?
    var cfg: String?
    var width: Int?
    var height: Int?

    init(
        model: String? = nil,
        sampler: String? = nil,
        seed: String? = nil,
        steps: String? = nil,
        cfg: String? = nil,
        width: Int? = nil,
        height: Int? = nil
    ) {
        self.model = model
        self.sampler = sampler
        self.seed = seed
        self.steps = steps
        self.cfg = cfg
        self.width = width
        self.height = height
    }

    /// Builds parameters from display fields (A1111 parameter blocks, ComfyUI extraction, etc.).
    init(fields: [PromptMetadataField]) {
        self.init()
        for field in fields {
            let key = Self.canonical(field.label)
            let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            switch key {
            case "model", "modelname", "sdmodel", "checkpoint", "ckptname", "unetname":
                if model == nil { model = value }
            case "sampler", "samplername":
                if sampler == nil { sampler = value }
            case "seed", "noiseseed":
                if seed == nil { seed = value }
            case "steps":
                if steps == nil { steps = value }
            case "cfgscale", "cfg", "guidancescale":
                if cfg == nil { cfg = value }
            case "size":
                if width == nil || height == nil, let (w, h) = Self.sizeFromString(value) {
                    width = w
                    height = h
                }
            case "width":
                if width == nil { width = Int(value) }
            case "height":
                if height == nil { height = Int(value) }
            default:
                break
            }
        }
    }

    fileprivate var hasAnyValue: Bool {
        model != nil || sampler != nil || seed != nil || steps != nil || cfg != nil || width != nil || height != nil
    }

    fileprivate static func sizeFromString(_ value: String) -> (Int, Int)? {
        let parts = value.lowercased()
            .replacingOccurrences(of: "×", with: "x")
            .split(separator: "x")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]), w > 0, h > 0 else { return nil }
        return (w, h)
    }

    private static func canonical(_ value: String) -> String {
        String(value.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}

struct LibraryIndexStats: Sendable {
    let fileCount: Int
    let lastIndexed: Date?
}

// MARK: - Service

/// Persistent full-text index of prompts across a library, backed by SQLite FTS5.
/// All work happens on this actor, never on the main thread.
actor LibraryIndexService {
    static let shared = LibraryIndexService()

    private var db: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]
    private var didAttemptOpen = false
    private let databaseURL: URL

    init(databaseURL: URL? = nil) {
        if let databaseURL {
            self.databaseURL = databaseURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            self.databaseURL = base
                .appendingPathComponent("PromptLibraryExplorer", isDirectory: true)
                .appendingPathComponent("library-index.sqlite")
        }
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        if let db { sqlite3_close_v2(db) }
    }

    // MARK: Indexing

    func indexLibrary(root: URL, progress: (@Sendable (_ done: Int, _ total: Int) -> Void)?) async {
        guard openIfNeeded() else { return }
        let rootPath = Self.normalizedPath(root.path)

        let candidates = Self.walk(rootPath: rootPath)
        guard !Task.isCancelled, let candidates else { return }

        let existing = existingSignatures(under: rootPath)
        var toIndex: [LibraryIndexCandidate] = []
        var seen = Set<String>()
        seen.reserveCapacity(candidates.count)
        for candidate in candidates {
            seen.insert(candidate.path)
            if let signature = existing[candidate.path],
               abs(signature.mtime - candidate.mtime) < 0.0005,
               signature.size == candidate.size
            {
                continue
            }
            toIndex.append(candidate)
        }

        // Remove rows for files that disappeared.
        let stale = existing.keys.filter { !seen.contains($0) }
        if !stale.isEmpty {
            transaction {
                for path in stale { deleteRow(path: path) }
            }
        }

        let total = toIndex.count
        progress?(0, total)

        var done = 0
        let batchSize = 200
        var start = 0
        while start < total {
            if Task.isCancelled { return }
            let batch = Array(toIndex[start..<min(start + batchSize, total)])
            let records = await Self.extractRecords(batch)
            if Task.isCancelled { return }
            transaction {
                for record in records { upsert(record) }
            }
            done += batch.count
            start += batchSize
            progress?(done, total)
        }

        guard !Task.isCancelled else { return }
        exec("INSERT OR REPLACE INTO roots(root, last_indexed) VALUES(?, ?)", [.text(rootPath), .double(Date().timeIntervalSince1970)])
    }

    // MARK: Queries

    func search(_ query: String, under root: URL?, limit: Int = 200) async -> [LibrarySearchHit] {
        guard openIfNeeded(), let match = Self.ftsQuery(from: query) else { return [] }
        var sql = """
        SELECT f.path, f.name, f.folder,
               snippet(prompts, 2, '«', '»', '…', 24),
               bm25(prompts, 0.0, 2.0, 1.0, 0.0),
               snippet(prompts, 1, '«', '»', '…', 24)
        FROM prompts JOIN files f ON f.id = prompts.rowid
        WHERE prompts MATCH ?
        """
        var bindings: [SQLValue] = [.text(match)]
        if let root {
            let (lower, upper) = Self.descendantRange(Self.normalizedPath(root.path))
            sql += " AND f.path > ? AND f.path < ?"
            bindings += [.text(lower), .text(upper)]
        }
        sql += " ORDER BY bm25(prompts, 0.0, 2.0, 1.0, 0.0) LIMIT ?"
        bindings.append(.int(Int64(max(1, limit))))

        var hits: [LibrarySearchHit] = []
        self.query(sql, bindings) { stmt in
            hits.append(LibrarySearchHit(
                path: Self.columnText(stmt, 0) ?? "",
                fileName: Self.columnText(stmt, 1) ?? "",
                folderPath: Self.columnText(stmt, 2) ?? "",
                snippet: Self.bestSnippet(prompt: Self.columnText(stmt, 3), name: Self.columnText(stmt, 5)),
                rank: sqlite3_column_double(stmt, 4)
            ))
        }
        return hits
    }

    func parameters(forPaths paths: [String]) async -> [String: GenerationParameters] {
        guard openIfNeeded(), !paths.isEmpty else { return [:] }
        var result: [String: GenerationParameters] = [:]
        let chunkSize = 400
        var index = 0
        while index < paths.count {
            let chunk = Array(paths[index..<min(index + chunkSize, paths.count)])
            index += chunkSize
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let sql = "SELECT path, model, sampler, seed, steps, cfg, width, height FROM files WHERE path IN (\(placeholders))"
            // Not cached: the placeholder count varies.
            queryUncached(sql, chunk.map { .text($0) }) { stmt in
                let params = GenerationParameters(
                    model: Self.columnText(stmt, 1),
                    sampler: Self.columnText(stmt, 2),
                    seed: Self.columnText(stmt, 3),
                    steps: Self.columnText(stmt, 4),
                    cfg: Self.columnText(stmt, 5),
                    width: Self.columnInt(stmt, 6),
                    height: Self.columnInt(stmt, 7)
                )
                if params.hasAnyValue, let path = Self.columnText(stmt, 0) {
                    result[path] = params
                }
            }
        }
        return result
    }

    func movePath(from oldPath: String, to newPath: String) async {
        guard openIfNeeded() else { return }
        let old = Self.normalizedPath(oldPath)
        let new = Self.normalizedPath(newPath)
        guard old != new else { return }
        let offset = Int64(old.unicodeScalars.count + 1)
        let (lower, upper) = Self.descendantRange(old)
        let newURL = URL(fileURLWithPath: new)
        let newName = newURL.lastPathComponent
        let newFolder = newURL.deletingLastPathComponent().path

        transaction {
            // Anything already at the destination is replaced.
            deleteRow(path: new)
            let (newLower, newUpper) = Self.descendantRange(new)
            deleteRange(lower: newLower, upper: newUpper)

            exec("UPDATE files SET path = ?, folder = ?, name = ? WHERE path = ?",
                 [.text(new), .text(newFolder), .text(newName), .text(old)])
            exec("UPDATE prompts SET path = ?, name = ? WHERE rowid = (SELECT id FROM files WHERE path = ?)",
                 [.text(new), .text(newName), .text(new)])

            exec("""
                 UPDATE files SET path = ? || substr(path, ?), folder = ? || substr(folder, ?)
                 WHERE path > ? AND path < ?
                 """,
                 [.text(new), .int(offset), .text(new), .int(offset), .text(lower), .text(upper)])
            let (movedLower, movedUpper) = Self.descendantRange(new)
            exec("""
                 UPDATE prompts SET path = (SELECT path FROM files WHERE files.id = prompts.rowid)
                 WHERE rowid IN (SELECT id FROM files WHERE path > ? AND path < ?)
                 """,
                 [.text(movedLower), .text(movedUpper)])
            exec("UPDATE roots SET root = ? WHERE root = ?", [.text(new), .text(old)])
        }
    }

    func removeEntries(under path: String) async {
        guard openIfNeeded() else { return }
        let normalized = Self.normalizedPath(path)
        let (lower, upper) = Self.descendantRange(normalized)
        transaction {
            deleteRow(path: normalized)
            deleteRange(lower: lower, upper: upper)
        }
    }

    func stats(under root: URL?) async -> LibraryIndexStats {
        guard openIfNeeded() else { return LibraryIndexStats(fileCount: 0, lastIndexed: nil) }
        var count = 0
        var last: Double?
        if let root {
            let rootPath = Self.normalizedPath(root.path)
            let (lower, upper) = Self.descendantRange(rootPath)
            query("SELECT COUNT(*) FROM files WHERE path > ? AND path < ?", [.text(lower), .text(upper)]) { stmt in
                count = Int(sqlite3_column_int64(stmt, 0))
            }
            // The most recent index of this root or any ancestor root covers it.
            query("SELECT root, last_indexed FROM roots", []) { stmt in
                guard let indexedRoot = Self.columnText(stmt, 0) else { return }
                if rootPath == indexedRoot || rootPath.hasPrefix(indexedRoot == "/" ? "/" : indexedRoot + "/") {
                    let value = sqlite3_column_double(stmt, 1)
                    last = max(last ?? 0, value)
                }
            }
        } else {
            query("SELECT COUNT(*) FROM files", []) { stmt in
                count = Int(sqlite3_column_int64(stmt, 0))
            }
            query("SELECT MAX(last_indexed) FROM roots", []) { stmt in
                if sqlite3_column_type(stmt, 0) != SQLITE_NULL {
                    last = sqlite3_column_double(stmt, 0)
                }
            }
        }
        return LibraryIndexStats(fileCount: count, lastIndexed: last.map { Date(timeIntervalSince1970: $0) })
    }

    func reset() async {
        guard openIfNeeded() else { return }
        transaction {
            exec("DELETE FROM files", [])
            exec("DELETE FROM prompts", [])
            exec("DELETE FROM roots", [])
        }
        exec("VACUUM", [])
    }

    // MARK: - Database plumbing

    enum SQLValue {
        case text(String)
        case int(Int64)
        case double(Double)
        case null
    }

    private func openIfNeeded() -> Bool {
        if db != nil { return true }
        if didAttemptOpen { return false }
        didAttemptOpen = true

        try? FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close_v2(handle) }
            return false
        }
        db = handle
        sqlite3_busy_timeout(handle, 3000)

        let schema = """
        PRAGMA journal_mode = WAL;
        PRAGMA synchronous = NORMAL;
        PRAGMA temp_store = MEMORY;
        CREATE TABLE IF NOT EXISTS files(
            id INTEGER PRIMARY KEY,
            path TEXT NOT NULL UNIQUE,
            folder TEXT,
            name TEXT,
            mtime REAL,
            size INTEGER,
            model TEXT,
            sampler TEXT,
            seed TEXT,
            steps TEXT,
            cfg TEXT,
            width INTEGER,
            height INTEGER
        );
        CREATE INDEX IF NOT EXISTS files_folder ON files(folder);
        CREATE VIRTUAL TABLE IF NOT EXISTS prompts USING fts5(
            path UNINDEXED, name, prompt, negative,
            tokenize = 'unicode61 remove_diacritics 2'
        );
        CREATE TABLE IF NOT EXISTS roots(root TEXT PRIMARY KEY, last_indexed REAL);
        """
        if sqlite3_exec(handle, schema, nil, nil, nil) != SQLITE_OK {
            sqlite3_close_v2(handle)
            db = nil
            return false
        }
        return true
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func statement(_ sql: String) -> OpaquePointer? {
        if let cached = statements[sql] {
            sqlite3_reset(cached)
            sqlite3_clear_bindings(cached)
            return cached
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        statements[sql] = stmt
        return stmt
    }

    private static func bind(_ values: [SQLValue], to stmt: OpaquePointer) {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let string): sqlite3_bind_text(stmt, index, string, -1, transient)
            case .int(let int): sqlite3_bind_int64(stmt, index, int)
            case .double(let double): sqlite3_bind_double(stmt, index, double)
            case .null: sqlite3_bind_null(stmt, index)
            }
        }
    }

    @discardableResult
    private func exec(_ sql: String, _ values: [SQLValue]) -> Bool {
        guard let stmt = statement(sql) else { return false }
        Self.bind(values, to: stmt)
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW { rc = sqlite3_step(stmt) }
        sqlite3_reset(stmt)
        return rc == SQLITE_DONE
    }

    private func query(_ sql: String, _ values: [SQLValue], row: (OpaquePointer) -> Void) {
        guard let stmt = statement(sql) else { return }
        Self.bind(values, to: stmt)
        while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
        sqlite3_reset(stmt)
    }

    private func queryUncached(_ sql: String, _ values: [SQLValue], row: (OpaquePointer) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        Self.bind(values, to: stmt)
        while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
    }

    private func transaction(_ body: () -> Void) {
        sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
        body()
        if sqlite3_exec(db, "COMMIT", nil, nil, nil) != SQLITE_OK {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
        }
    }

    private func deleteRow(path: String) {
        exec("DELETE FROM prompts WHERE rowid = (SELECT id FROM files WHERE path = ?)", [.text(path)])
        exec("DELETE FROM files WHERE path = ?", [.text(path)])
    }

    private func deleteRange(lower: String, upper: String) {
        exec("DELETE FROM prompts WHERE rowid IN (SELECT id FROM files WHERE path > ? AND path < ?)", [.text(lower), .text(upper)])
        exec("DELETE FROM files WHERE path > ? AND path < ?", [.text(lower), .text(upper)])
    }

    private func existingSignatures(under rootPath: String) -> [String: (mtime: Double, size: Int64)] {
        var result: [String: (mtime: Double, size: Int64)] = [:]
        let (lower, upper) = Self.descendantRange(rootPath)
        query("SELECT path, mtime, size FROM files WHERE path > ? AND path < ?", [.text(lower), .text(upper)]) { stmt in
            if let path = Self.columnText(stmt, 0) {
                result[path] = (sqlite3_column_double(stmt, 1), sqlite3_column_int64(stmt, 2))
            }
        }
        return result
    }

    private func upsert(_ record: LibraryIndexRecord) {
        func opt(_ s: String?) -> SQLValue { s.map { .text($0) } ?? .null }
        func opt(_ i: Int?) -> SQLValue { i.map { .int(Int64($0)) } ?? .null }
        let p = record.parameters
        exec("""
             INSERT INTO files(path, folder, name, mtime, size, model, sampler, seed, steps, cfg, width, height)
             VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
             ON CONFLICT(path) DO UPDATE SET
                folder = excluded.folder, name = excluded.name, mtime = excluded.mtime, size = excluded.size,
                model = excluded.model, sampler = excluded.sampler, seed = excluded.seed, steps = excluded.steps,
                cfg = excluded.cfg, width = excluded.width, height = excluded.height
             """,
             [.text(record.path), .text(record.folder), .text(record.name), .double(record.mtime), .int(record.size),
              opt(p.model), opt(p.sampler), opt(p.seed), opt(p.steps), opt(p.cfg), opt(p.width), opt(p.height)])
        var rowID: Int64?
        query("SELECT id FROM files WHERE path = ?", [.text(record.path)]) { stmt in
            rowID = sqlite3_column_int64(stmt, 0)
        }
        guard let rowID else { return }
        exec("DELETE FROM prompts WHERE rowid = ?", [.int(rowID)])
        exec("INSERT INTO prompts(rowid, path, name, prompt, negative) VALUES(?, ?, ?, ?, ?)",
             [.int(rowID), .text(record.path), .text(Self.searchableName(record.name)),
              .text(record.prompt), .text(record.negative)])
    }

    // MARK: - Static helpers

    private static func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL, let cString = sqlite3_column_text(stmt, index) else {
            return nil
        }
        return String(cString: cString)
    }

    private static func columnInt(_ stmt: OpaquePointer, _ index: Int32) -> Int? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(stmt, index))
    }

    /// Trims trailing slashes only. Deliberately not `standardizingPath`, which can drop a
    /// `/private` prefix and so stop matching the paths the browser uses.
    static func normalizedPath(_ path: String) -> String {
        var result = path
        while result.count > 1 && result.hasSuffix("/") { result.removeLast() }
        return result
    }

    /// Exclusive bounds matching every path strictly beneath `path` ("/" sorts right before "0").
    static func descendantRange(_ path: String) -> (String, String) {
        if path == "/" { return ("/", "0") }
        return (path + "/", path + "0")
    }

    /// Filenames like "portrait_of-a_cat.png" become searchable words.
    private static func searchableName(_ name: String) -> String {
        name.replacingOccurrences(of: "_", with: " ")
    }

    /// The prompt excerpt, unless the match was only in the file name and there is no prompt.
    private static func bestSnippet(prompt: String?, name: String?) -> String {
        let promptSnippet = cleanSnippet(prompt ?? "")
        if promptSnippet.contains("«") || !promptSnippet.isEmpty { return promptSnippet }
        return cleanSnippet(name ?? "")
    }

    private static func cleanSnippet(_ snippet: String) -> String {
        snippet
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Translates the user query syntax into a safe FTS5 MATCH expression.
    /// Words are ANDed, `"quoted phrase"` stays a phrase, `-word` excludes, `word*` is a prefix.
    /// Every term is quoted so FTS5 operators/punctuation in user text are inert.
    /// Returns nil when the query has no positive term.
    static func ftsQuery(from query: String) -> String? {
        var positives: [String] = []
        var negatives: [String] = []

        let chars = Array(query)
        var i = 0
        while i < chars.count {
            if chars[i].isWhitespace { i += 1; continue }
            var negate = false
            if chars[i] == "-" {
                negate = true
                i += 1
                if i >= chars.count { break }
                if chars[i].isWhitespace { continue }
            }
            var term = ""
            var isPhrase = false
            if chars[i] == "\"" {
                isPhrase = true
                i += 1
                while i < chars.count, chars[i] != "\"" { term.append(chars[i]); i += 1 }
                i += 1 // closing quote (or end)
            } else {
                while i < chars.count, !chars[i].isWhitespace { term.append(chars[i]); i += 1 }
            }
            var prefix = false
            if !isPhrase, term.hasSuffix("*") {
                prefix = true
                while term.hasSuffix("*") { term.removeLast() }
            } else if isPhrase, i < chars.count, chars[i] == "*" {
                prefix = true
                i += 1
            }
            guard term.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else { continue }
            let quoted = "\"" + term.replacingOccurrences(of: "\"", with: "\"\"") + "\"" + (prefix ? "*" : "")
            if negate { negatives.append(quoted) } else { positives.append(quoted) }
        }

        guard !positives.isEmpty else { return nil }
        var expression = "(" + positives.joined(separator: " AND ") + ")"
        for negative in negatives {
            expression = "(" + expression + " NOT " + negative + ")"
        }
        return "{name prompt} : " + expression
    }

    /// Recursive walk of supported files (hidden files and package contents skipped). Paths are
    /// built from `rootPath` + child names so every row keeps the caller's root prefix
    /// (FileManager can resolve e.g. /var → /private/var). Returns nil when cancelled.
    private static func walk(rootPath: String) -> [LibraryIndexCandidate]? {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey,
                                      .contentModificationDateKey, .fileSizeKey]
        var result: [LibraryIndexCandidate] = []
        var stack = [rootPath]
        var visitedDirectories = 0
        while let directoryPath = stack.popLast() {
            let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
            visitedDirectories += 1
            if visitedDirectories % 64 == 0, Task.isCancelled { return nil }
            guard let children = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants, .skipsSubdirectoryDescendants]
            ) else { continue }
            for url in children {
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                if values.isDirectory == true {
                    if values.isPackage != true, values.isSymbolicLink != true {
                        stack.append(childPath(directoryPath, url.lastPathComponent))
                    }
                    continue
                }
                let name = url.lastPathComponent
                guard values.isRegularFile == true, isIndexable(name) else { continue }
                let path = childPath(directoryPath, name)
                result.append(LibraryIndexCandidate(
                    path: path,
                    name: name,
                    folder: directoryPath,
                    mtime: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
                    size: Int64(values.fileSize ?? 0)
                ))
            }
        }
        return result
    }

    private static func childPath(_ directory: String, _ name: String) -> String {
        directory == "/" ? "/" + name : directory + "/" + name
    }

    static func isIndexable(_ name: String) -> Bool {
        FileHelpers.isPlibFile(name)
            || FileHelpers.isAoeFile(name)
            || FileHelpers.isImageFile(name)
            || FileHelpers.isVideoFile(name)
            || FileHelpers.isAudioFile(name)
    }

    private static func extractRecords(_ batch: [LibraryIndexCandidate]) async -> [LibraryIndexRecord] {
        await withTaskGroup(of: (Int, LibraryIndexRecord).self) { group in
            let width = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount))
            var next = 0
            var results = [LibraryIndexRecord?](repeating: nil, count: batch.count)
            func enqueue() {
                guard next < batch.count else { return }
                let index = next
                let candidate = batch[index]
                next += 1
                group.addTask { (index, await LibraryIndexExtractor.record(for: candidate)) }
            }
            for _ in 0..<width { enqueue() }
            while let (index, record) = await group.next() {
                results[index] = record
                if Task.isCancelled { group.cancelAll(); break }
                enqueue()
            }
            return results.compactMap { $0 }
        }
    }
}

// MARK: - Extraction

struct LibraryIndexCandidate: Sendable {
    let path: String
    let name: String
    let folder: String
    let mtime: Double
    let size: Int64
}

struct LibraryIndexRecord: Sendable {
    let path: String
    let name: String
    let folder: String
    let mtime: Double
    let size: Int64
    var prompt: String = ""
    var negative: String = ""
    var parameters = GenerationParameters()
}

/// Reads the same metadata the app shows for a file, without decoding images or touching the
/// parsers' in-memory caches (which are sized for browsing, not whole-library scans).
enum LibraryIndexExtractor {
    static func record(for candidate: LibraryIndexCandidate) async -> LibraryIndexRecord {
        var record = LibraryIndexRecord(
            path: candidate.path,
            name: candidate.name,
            folder: candidate.folder,
            mtime: candidate.mtime,
            size: candidate.size
        )
        let url = URL(fileURLWithPath: candidate.path)
        let name = candidate.name

        if FileHelpers.isPlibFile(name) {
            if let data = try? Data(contentsOf: url),
               let file = try? JSONDecoder().decode(PlibFile.self, from: data)
            {
                let prompt = file.prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let blind = file.blindPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let hint = file.hint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                record.prompt = [prompt.isEmpty ? blind : prompt, prompt.isEmpty ? "" : blind, hint]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                if let model = file.generationInfo?.model, model != "N/A", !model.isEmpty {
                    record.parameters.model = model
                }
            }
        } else if FileHelpers.isAoeFile(name) {
            if let data = try? Data(contentsOf: url),
               let file = try? JSONDecoder().decode(AoeFile.self, from: data)
            {
                let full = file.analysis?.fullPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let hint = file.hint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let short = file.analysis?.shortDescription?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                record.prompt = [full, hint, short].filter { !$0.isEmpty }.joined(separator: "\n")
                if let model = file.model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
                    record.parameters.model = model
                }
            }
        } else if FileHelpers.isImageFile(name) {
            let meta = ImageMetadataParser.readMetadataUncached(at: url)
            record.prompt = meta.prompt
            record.negative = meta.negativePrompt ?? ""
            var params = GenerationParameters(fields: meta.fields)
            if let model = meta.model, !model.isEmpty { params.model = model }
            if params.width == nil || params.height == nil,
               let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
               let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            {
                params.width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
                params.height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
            }
            record.parameters = params
        } else if FileHelpers.isAudioFile(name) {
            let meta = await AudioMetadataParser.shared.parse(at: url)
            record.prompt = meta.searchText
        }
        return record
    }
}
