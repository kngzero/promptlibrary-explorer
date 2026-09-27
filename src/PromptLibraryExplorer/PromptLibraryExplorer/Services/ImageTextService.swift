import Foundation
import SQLite3

/// Stored analysis of one image.
struct ImageTextRecord: Sendable, Equatable {
    let path: String
    /// Recognised text ("" = none found); nil when text recognition hasn't run.
    let text: String?
    /// Classification labels; nil when classification hasn't run.
    let labels: [ImageLabel]?
    let analyzedAt: Date?

    var hasText: Bool { !(text ?? "").isEmpty }
}

struct ImageTextProgress: Sendable, Equatable {
    let done: Int
    let total: Int
    let currentName: String?
    /// Paths whose records were just written (the listing may want to reload).
    let flushed: [String]
}

/// What an analysis pass computes.
struct ImageTextOptions: Sendable, Equatable {
    var recognizeText = true
    var classify = true

    var isEmpty: Bool { !recognizeText && !classify }
}

/// Text recognised in images and Vision classification labels, per file (path + mtime +
/// size), in its own SQLite database (`image-text.sqlite`) so the visual index schema is
/// untouched. The work shares the visual index's schedule (see `ImageTextController`).
actor ImageTextService {
    static let shared = ImageTextService()
    /// Bump when the analysis changes enough that old rows should be redone.
    static let analysisRevision = 1
    static let workerCount = 2

    typealias Analyzer = @Sendable (URL, ImageTextOptions) async -> ImageAnalysisResult?

    private var db: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]
    private var didAttemptOpen = false
    private let databaseURL: URL
    private let analyzer: Analyzer
    /// Called with paths whose recognised text was stored (the library index re-reads them).
    private var onTextStored: (@Sendable ([String]) async -> Void)?
    private var activeBuildCount = 0
    private var pathsMutatedDuringBuilds: [String] = []
    private(set) var analyzedCount = 0

    init(databaseURL: URL? = nil, analyzer: Analyzer? = nil) {
        if let databaseURL {
            self.databaseURL = databaseURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            self.databaseURL = base
                .appendingPathComponent("PromptLibraryExplorer", isDirectory: true)
                .appendingPathComponent("image-text.sqlite")
        }
        self.analyzer = analyzer ?? { url, options in
            ImageTextRecognizer.analyze(url: url, recognizeText: options.recognizeText, classify: options.classify)
        }
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        if let db { sqlite3_close_v2(db) }
    }

    func setOnTextStored(_ handler: (@Sendable ([String]) async -> Void)?) {
        onTextStored = handler
    }

    // MARK: Analysis

    /// Walks `root` and analyses images that are new, changed (mtime + size), from an older
    /// revision, or missing a part `options` now asks for; rows of files that disappeared are
    /// removed. Cancellation stops scheduling; finished files are kept. False when cancelled.
    @discardableResult
    func analyzeLibrary(
        root: URL,
        options: ImageTextOptions,
        progress: (@Sendable (ImageTextProgress) -> Void)? = nil
    ) async -> Bool {
        guard !options.isEmpty, openIfNeeded() else { return false }
        let rootPath = VisualIndexService.normalizedPath(root.path)
        activeBuildCount += 1
        let logStart = pathsMutatedDuringBuilds.count
        defer {
            activeBuildCount -= 1
            if activeBuildCount == 0 { pathsMutatedDuringBuilds.removeAll() }
        }
        let walked = await withTaskGroup(of: [VisualIndexCandidate]?.self) { group in
            group.addTask(priority: .utility) { VisualIndexService.walk(rootPath: rootPath) }
            return await group.next() ?? nil
        }
        guard !Task.isCancelled, let walked else { return false }
        let candidates = walked.filter { FileHelpers.isImageFile(($0.path as NSString).lastPathComponent) }

        let existing = existingRows(under: rootPath)
        var todo: [VisualIndexCandidate] = []
        var seen = Set<String>()
        for candidate in candidates {
            seen.insert(candidate.path)
            if let row = existing[candidate.path], Self.isCurrent(row, mtime: candidate.mtime, size: candidate.size, options: options) {
                continue
            }
            todo.append(candidate)
        }
        let mutated = pathsMutatedDuringBuilds[logStart...]
        let stale = existing.keys.filter { path in !seen.contains(path) && !mutated.contains { VisualIndexService.isSameOrDescendant(path, of: $0) } }
        if !stale.isEmpty {
            transaction { for path in stale { exec("DELETE FROM analysis WHERE path = ?", [.text(path)]) } }
        }
        exec("INSERT INTO roots(root, last_analyzed, total) VALUES(?, NULL, ?) ON CONFLICT(root) DO UPDATE SET total = excluded.total",
             [.text(rootPath), .int(Int64(candidates.count))])

        let finished = await compute(todo, options: options, logStart: logStart, progress: progress)
        guard finished, !Task.isCancelled else { return false }
        exec("UPDATE roots SET last_analyzed = ? WHERE root = ?", [.double(Date().timeIntervalSince1970), .text(rootPath)])
        return true
    }

    /// Analyses specific image files (new or changed only, unless `force`). Missing paths
    /// lose their rows. Returns the stored records.
    @discardableResult
    func analyze(paths: [String], options: ImageTextOptions, force: Bool = false) async -> [String: ImageTextRecord] {
        guard !options.isEmpty, openIfNeeded() else { return [:] }
        activeBuildCount += 1
        let logStart = pathsMutatedDuringBuilds.count
        defer {
            activeBuildCount -= 1
            if activeBuildCount == 0 { pathsMutatedDuringBuilds.removeAll() }
        }
        var todo: [VisualIndexCandidate] = []
        for raw in paths {
            let path = VisualIndexService.normalizedPath(raw)
            guard FileManager.default.fileExists(atPath: path) else {
                await removeEntries(under: path)
                continue
            }
            guard FileHelpers.isImageFile((path as NSString).lastPathComponent),
                  let candidate = VisualIndexService.candidate(forFile: path)
            else { continue }
            if !force, let row = row(forPath: path), Self.isCurrent(row, mtime: candidate.mtime, size: candidate.size, options: options) {
                continue
            }
            todo.append(candidate)
        }
        _ = await compute(todo, options: options, logStart: logStart, progress: nil)
        var result: [String: ImageTextRecord] = [:]
        for raw in paths {
            if let record = record(forPath: raw) { result[raw] = record }
        }
        return result
    }

    private struct PendingRow: Sendable {
        let candidate: VisualIndexCandidate
        let result: ImageAnalysisResult
    }

    private func compute(
        _ candidates: [VisualIndexCandidate],
        options: ImageTextOptions,
        logStart: Int,
        progress: (@Sendable (ImageTextProgress) -> Void)?
    ) async -> Bool {
        let total = candidates.count
        progress?(ImageTextProgress(done: 0, total: total, currentName: nil, flushed: []))
        guard total > 0 else { return true }
        let analyzer = analyzer
        var buffer: [PendingRow] = []
        var done = 0
        var lastFlush = Date()

        await withTaskGroup(of: PendingRow?.self) { group in
            var next = 0
            func enqueue() {
                guard next < total, !Task.isCancelled else { return }
                let candidate = candidates[next]
                next += 1
                group.addTask(priority: .utility) {
                    let url = URL(fileURLWithPath: candidate.path)
                    // A file that can't be decoded still gets a row, so it isn't retried forever.
                    let result = await analyzer(url, options)
                        ?? ImageAnalysisResult(text: options.recognizeText ? "" : nil, labels: options.classify ? [] : nil)
                    return PendingRow(candidate: candidate, result: result)
                }
            }
            for _ in 0..<Self.workerCount { enqueue() }
            while let row = await group.next() {
                if let row {
                    buffer.append(row)
                    done += 1
                    analyzedCount += 1
                    let now = Date()
                    if buffer.count >= 16 || now.timeIntervalSince(lastFlush) > 2 || done == total {
                        let flushed = await flush(&buffer, options: options, logStart: logStart)
                        lastFlush = now
                        progress?(ImageTextProgress(done: done, total: total, currentName: (row.candidate.path as NSString).lastPathComponent, flushed: flushed))
                    } else {
                        progress?(ImageTextProgress(done: done, total: total, currentName: (row.candidate.path as NSString).lastPathComponent, flushed: []))
                    }
                }
                enqueue()
            }
        }
        _ = await flush(&buffer, options: options, logStart: logStart)
        return done == total
    }

    /// Writes buffered rows; returns their paths.
    private func flush(_ buffer: inout [PendingRow], options: ImageTextOptions, logStart: Int) async -> [String] {
        guard !buffer.isEmpty else { return [] }
        let mutated = pathsMutatedDuringBuilds[logStart...]
        let rows = buffer.filter { row in !mutated.contains { VisualIndexService.isSameOrDescendant(row.candidate.path, of: $0) } }
        buffer.removeAll(keepingCapacity: true)
        guard !rows.isEmpty else { return [] }
        let now = Date().timeIntervalSince1970
        transaction {
            for row in rows { upsert(row, options: options, now: now) }
        }
        let withText = rows.filter { !($0.result.text ?? "").isEmpty }.map(\.candidate.path)
        if !withText.isEmpty, let onTextStored { await onTextStored(withText) }
        return rows.map(\.candidate.path)
    }

    // MARK: Queries

    func record(forPath raw: String) -> ImageTextRecord? {
        guard openIfNeeded() else { return nil }
        return row(forPath: VisualIndexService.normalizedPath(raw)).map { Self.record(from: $0, path: raw) }
    }

    /// Non-empty recognised text for the direct children of `folder`.
    func texts(inFolder folder: String) -> [String: String] {
        guard openIfNeeded() else { return [:] }
        var result: [String: String] = [:]
        query("SELECT path, text FROM analysis WHERE folder = ? AND text IS NOT NULL AND text != ''",
              [.text(VisualIndexService.normalizedPath(folder))]) { stmt in
            if let path = Self.columnText(stmt, 0), let text = Self.columnText(stmt, 1) { result[path] = text }
        }
        return result
    }

    func texts(forPaths paths: [String]) -> [String: String] {
        guard openIfNeeded() else { return [:] }
        var result: [String: String] = [:]
        for raw in paths {
            query("SELECT text FROM analysis WHERE path = ? AND text IS NOT NULL AND text != ''",
                  [.text(VisualIndexService.normalizedPath(raw))]) { stmt in
                if let text = Self.columnText(stmt, 0) { result[raw] = text }
            }
        }
        return result
    }

    func text(forPath raw: String) -> String? {
        texts(forPaths: [raw])[raw]
    }

    func stats(under root: URL?) -> (analyzed: Int, withText: Int, total: Int?) {
        guard openIfNeeded() else { return (0, 0, nil) }
        var analyzed = 0, withText = 0
        var total: Int?
        if let root {
            let rootPath = VisualIndexService.normalizedPath(root.path)
            let (lower, upper) = VisualIndexService.descendantRange(rootPath)
            query("SELECT COUNT(*), SUM(CASE WHEN text IS NOT NULL AND text != '' THEN 1 ELSE 0 END) FROM analysis WHERE path > ? AND path < ?",
                  [.text(lower), .text(upper)]) { stmt in
                analyzed = Int(sqlite3_column_int64(stmt, 0))
                withText = Int(sqlite3_column_int64(stmt, 1))
            }
            query("SELECT total FROM roots WHERE root = ?", [.text(rootPath)]) { stmt in total = Self.columnInt(stmt, 0) }
        } else {
            query("SELECT COUNT(*), SUM(CASE WHEN text IS NOT NULL AND text != '' THEN 1 ELSE 0 END) FROM analysis", []) { stmt in
                analyzed = Int(sqlite3_column_int64(stmt, 0))
                withText = Int(sqlite3_column_int64(stmt, 1))
            }
        }
        return (analyzed, withText, total)
    }

    // MARK: Mutations

    func movePath(from oldPath: String, to newPath: String) async {
        guard openIfNeeded() else { return }
        let old = VisualIndexService.normalizedPath(oldPath)
        let new = VisualIndexService.normalizedPath(newPath)
        guard old != new else { return }
        noteMutation(old)
        noteMutation(new)
        let offset = Int64(old.unicodeScalars.count + 1)
        let (lower, upper) = VisualIndexService.descendantRange(old)
        let (newLower, newUpper) = VisualIndexService.descendantRange(new)
        transaction {
            exec("DELETE FROM analysis WHERE path = ?", [.text(new)])
            exec("DELETE FROM analysis WHERE path > ? AND path < ?", [.text(newLower), .text(newUpper)])
            exec("UPDATE analysis SET path = ?, folder = ? WHERE path = ?", [.text(new), .text(VisualIndexService.parentPath(new)), .text(old)])
            exec("""
                 UPDATE analysis SET path = ? || substr(path, ?), folder = ? || substr(folder, ?)
                 WHERE path > ? AND path < ?
                 """,
                 [.text(new), .int(offset), .text(new), .int(offset), .text(lower), .text(upper)])
        }
    }

    func removeEntries(under path: String) async {
        guard openIfNeeded() else { return }
        let normalized = VisualIndexService.normalizedPath(path)
        noteMutation(normalized)
        let (lower, upper) = VisualIndexService.descendantRange(normalized)
        transaction {
            exec("DELETE FROM analysis WHERE path = ?", [.text(normalized)])
            exec("DELETE FROM analysis WHERE path > ? AND path < ?", [.text(lower), .text(upper)])
        }
    }

    /// Marks rows under `root` out of date so the next pass redoes them.
    func markStale(under root: URL) async {
        guard openIfNeeded() else { return }
        let (lower, upper) = VisualIndexService.descendantRange(VisualIndexService.normalizedPath(root.path))
        exec("UPDATE analysis SET mtime = -1 WHERE path > ? AND path < ?", [.text(lower), .text(upper)])
    }

    func reset() async {
        guard openIfNeeded() else { return }
        noteMutation("/")
        transaction {
            exec("DELETE FROM analysis", [])
            exec("DELETE FROM roots", [])
        }
        exec("VACUUM", [])
    }

    private func noteMutation(_ path: String) {
        guard activeBuildCount > 0 else { return }
        pathsMutatedDuringBuilds.append(path)
    }

    // MARK: Rows

    private struct Row {
        let mtime: Double
        let size: Int64
        let revision: Int
        let text: String?
        let labels: String?
        let didText: Bool
        let didLabels: Bool
        let analyzedAt: Double?
    }

    private static func isCurrent(_ row: Row, mtime: Double, size: Int64, options: ImageTextOptions) -> Bool {
        abs(row.mtime - mtime) < 0.0005 && row.size == size && row.revision == analysisRevision
            && (!options.recognizeText || row.didText) && (!options.classify || row.didLabels)
    }

    private static let rowColumns = "mtime, size, revision, text, labels, did_text, did_labels, analyzed_at"

    private func row(forPath path: String) -> Row? {
        var found: Row?
        query("SELECT \(Self.rowColumns) FROM analysis WHERE path = ?", [.text(path)]) { stmt in
            found = Self.row(from: stmt, offset: 0)
        }
        return found
    }

    private func existingRows(under rootPath: String) -> [String: Row] {
        var result: [String: Row] = [:]
        let (lower, upper) = VisualIndexService.descendantRange(rootPath)
        query("SELECT path, \(Self.rowColumns) FROM analysis WHERE path > ? AND path < ?", [.text(lower), .text(upper)]) { stmt in
            if let path = Self.columnText(stmt, 0) { result[path] = Self.row(from: stmt, offset: 1) }
        }
        return result
    }

    private static func row(from stmt: OpaquePointer, offset: Int32) -> Row {
        Row(
            mtime: sqlite3_column_double(stmt, offset),
            size: sqlite3_column_int64(stmt, offset + 1),
            revision: Int(sqlite3_column_int64(stmt, offset + 2)),
            text: columnText(stmt, offset + 3),
            labels: columnText(stmt, offset + 4),
            didText: sqlite3_column_int64(stmt, offset + 5) != 0,
            didLabels: sqlite3_column_int64(stmt, offset + 6) != 0,
            analyzedAt: sqlite3_column_type(stmt, offset + 7) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, offset + 7)
        )
    }

    private static func record(from row: Row, path: String) -> ImageTextRecord {
        let labels: [ImageLabel]? = row.didLabels
            ? (row.labels.flatMap { try? JSONDecoder().decode([ImageLabel].self, from: Data($0.utf8)) } ?? [])
            : nil
        return ImageTextRecord(
            path: path,
            text: row.didText ? (row.text ?? "") : nil,
            labels: labels,
            analyzedAt: row.analyzedAt.map { Date(timeIntervalSince1970: $0) }
        )
    }

    private func upsert(_ pending: PendingRow, options: ImageTextOptions, now: Double) {
        let path = pending.candidate.path
        // A pass that skipped a part keeps what an earlier pass stored for it.
        let previous = row(forPath: path)
        let sameFile = previous.map { abs($0.mtime - pending.candidate.mtime) < 0.0005 && $0.size == pending.candidate.size } ?? false
        let text: String? = pending.result.text ?? (sameFile ? previous?.text : nil)
        let didText = pending.result.text != nil || (sameFile && previous?.didText == true)
        var labelsJSON: String?
        if let labels = pending.result.labels {
            labelsJSON = (try? JSONEncoder().encode(labels)).map { String(decoding: $0, as: UTF8.self) }
        } else if sameFile {
            labelsJSON = previous?.labels
        }
        let didLabels = pending.result.labels != nil || (sameFile && previous?.didLabels == true)
        exec("""
             INSERT OR REPLACE INTO analysis(path, folder, mtime, size, revision, text, labels, did_text, did_labels, analyzed_at)
             VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
             """,
             [.text(path), .text(pending.candidate.folder), .double(pending.candidate.mtime), .int(pending.candidate.size),
              .int(Int64(Self.analysisRevision)), text.map { .text($0) } ?? .null, labelsJSON.map { .text($0) } ?? .null,
              .int(didText ? 1 : 0), .int(didLabels ? 1 : 0), .double(now)])
    }

    // MARK: Database plumbing

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
        try? FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
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
        CREATE TABLE IF NOT EXISTS analysis(
            path TEXT PRIMARY KEY,
            folder TEXT NOT NULL,
            mtime REAL,
            size INTEGER,
            revision INTEGER NOT NULL DEFAULT 0,
            text TEXT,
            labels TEXT,
            did_text INTEGER NOT NULL DEFAULT 0,
            did_labels INTEGER NOT NULL DEFAULT 0,
            analyzed_at REAL
        );
        CREATE INDEX IF NOT EXISTS analysis_folder ON analysis(folder);
        CREATE TABLE IF NOT EXISTS roots(root TEXT PRIMARY KEY, last_analyzed REAL, total INTEGER);
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

    private func transaction(_ body: () -> Void) {
        sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
        body()
        if sqlite3_exec(db, "COMMIT", nil, nil, nil) != SQLITE_OK {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
        }
    }

    private static func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL, let cString = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cString)
    }

    private static func columnInt(_ stmt: OpaquePointer, _ index: Int32) -> Int? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(stmt, index))
    }
}
