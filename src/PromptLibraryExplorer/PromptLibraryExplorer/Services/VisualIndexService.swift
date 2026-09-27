import CryptoKit
import Foundation
import SQLite3

// MARK: - Public value types (binding API — see the visual search contract)

struct DominantColor: Sendable, Hashable, Codable {
    let hex: String       // "#RRGGBB"
    let weight: Double    // share of the image, 0…1
}

struct VisualSignature: Sendable {
    let path: String
    let sha256: String            // exact content hash
    let dHash: UInt64             // 64-bit difference hash (perceptual)
    let featurePrint: Data?       // Vision feature print as raw Float32 (see VisualSignatureExtractor.vector(from:))
    let dominantColors: [DominantColor]  // up to 5, sorted by weight desc
    let pixelWidth: Int?
    let pixelHeight: Int?
    let isVideo: Bool
}

/// `.folder` = direct children only; `.library` = recursive under the root.
enum VisualScope: Sendable, Hashable {
    case folder(URL)
    case library(URL)
}

struct SimilarSet: Sendable, Identifiable, Hashable {
    let id: String                // stable: hash of kind + sorted member paths
    let paths: [String]           // display order: by folder then name — never "keeper first"
    let kind: Kind
    enum Kind: String, Sendable { case exact, visual }
}

struct SimilarityHit: Sendable, Hashable, Identifiable {
    var id: String { path }
    let path: String
    let distance: Float           // smaller = more similar
}

struct VisualIndexProgress: Sendable, Equatable {
    let done: Int
    let total: Int
    let currentName: String?
}

// MARK: - Service

/// Persistent visual signatures (content hash, dHash, Vision feature print, dominant
/// colours) for images, video middle frames and Mood / Story renders, in its own
/// SQLite database. Signature work runs in background child tasks with bounded
/// concurrency; the actor only owns the database.
///
/// Similar-set strictness mapping (`strictness` 0…1):
/// - `≥ 0.999` → exact (identical bytes) sets only.
/// - dHash Hamming radius = round(14 − 12·s), clamped 2…14 (0 → 14 bits, 0.5 → 8, 0.9 → 3).
/// - feature-print distance ≤ 0.45 − 0.30·s (0 → 0.45, 0.5 → 0.30, 0.9 → 0.18). Measured
///   (revision 2, 224² input): resize/upscale 0.02–0.14, JPEG re-encode ~0.2, unrelated ≥ 0.5.
/// - palette distance (OKLab) ≤ 0.20 − 0.14·s (guards flat images whose dHash is degenerate).
/// - a pair with no feature print on either side needs Hamming ≤ radius / 2.
actor VisualIndexService {
    static let shared = VisualIndexService()

    private var db: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]
    private var didAttemptOpen = false
    private let databaseURL: URL

    /// Signatures fully computed by this instance (tests: pause/resume must not redo work).
    private(set) var computedSignatureCount = 0

    /// Paths moved / removed while a build is in flight; builds drop records at or under
    /// them instead of resurrecting ghost rows (same fix as LibraryIndexService).
    private var activeBuildCount = 0
    private var pathsMutatedDuringBuilds: [String] = []

    /// Parallel signature workers: half the active cores, at least 2.
    static let workerCount = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)

    init(databaseURL: URL? = nil) {
        if let databaseURL {
            self.databaseURL = databaseURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            self.databaseURL = base
                .appendingPathComponent("PromptLibraryExplorer", isDirectory: true)
                .appendingPathComponent("visual-index.sqlite")
        }
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        if let db { sqlite3_close_v2(db) }
    }

    // MARK: Indexing

    /// Walks `root` recursively and (re)computes signatures for new or changed files
    /// (mtime + size), deleting rows for files that disappeared under it. `force`
    /// recomputes everything. Cancellation stops scheduling new files; files already
    /// finished are written, so a later run resumes where this one stopped.
    /// Returns false when cancelled.
    @discardableResult
    func indexLibrary(
        root: URL,
        force: Bool = false,
        progress: (@Sendable (VisualIndexProgress) -> Void)? = nil
    ) async -> Bool {
        guard openIfNeeded() else { return false }
        let rootPath = Self.normalizedPath(root.path)
        activeBuildCount += 1
        let logStart = pathsMutatedDuringBuilds.count
        defer {
            activeBuildCount -= 1
            if activeBuildCount == 0 { pathsMutatedDuringBuilds.removeAll() }
        }

        let candidates = await Self.walkInBackground(rootPath: rootPath)
        guard !Task.isCancelled, let candidates else { return false }

        let existing = existingSignatures(under: rootPath)
        var toIndex: [VisualIndexCandidate] = []
        var seen = Set<String>()
        seen.reserveCapacity(candidates.count)
        for candidate in candidates {
            seen.insert(candidate.path)
            if !force, let signature = existing[candidate.path],
               abs(signature.mtime - candidate.mtime) < 0.0005, signature.size == candidate.size
            {
                continue
            }
            toIndex.append(candidate)
        }

        let mutatedSinceStart = pathsMutatedDuringBuilds[logStart...]
        let stale = existing.keys.filter { path in
            !seen.contains(path) && !mutatedSinceStart.contains { Self.isSameOrDescendant(path, of: $0) }
        }
        transaction {
            for path in stale { exec("DELETE FROM signatures WHERE path = ?", [.text(path)]) }
            exec("INSERT INTO roots(root, last_indexed, total) VALUES(?, NULL, ?) ON CONFLICT(root) DO UPDATE SET total = excluded.total",
                 [.text(rootPath), .int(Int64(candidates.count))])
        }

        let finished = await compute(toIndex, logStart: logStart, progress: progress)
        guard finished, !Task.isCancelled else { return false }
        exec("UPDATE roots SET last_indexed = ? WHERE root = ?", [.double(Date().timeIntervalSince1970), .text(rootPath)])
        return true
    }

    /// Indexes specific files, or every eligible file under a directory (a file that was
    /// just edited, moved in, or restored) — only those new or changed by mtime + size
    /// unless `force`. Paths that no longer exist are removed.
    func index(paths: [String], force: Bool = false) async {
        guard openIfNeeded() else { return }
        activeBuildCount += 1
        let logStart = pathsMutatedDuringBuilds.count
        defer {
            activeBuildCount -= 1
            if activeBuildCount == 0 { pathsMutatedDuringBuilds.removeAll() }
        }
        var candidates: [VisualIndexCandidate] = []
        for raw in paths {
            let path = Self.normalizedPath(raw)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
                await removeEntries(under: path)
                continue
            }
            if isDirectory.boolValue {
                candidates += await Self.walkInBackground(rootPath: path) ?? []
            } else if let candidate = Self.candidate(forFile: path) {
                candidates.append(candidate)
            }
        }
        if !force {
            candidates.removeAll { candidate in
                var unchanged = false
                query("SELECT mtime, size FROM signatures WHERE path = ?", [.text(candidate.path)]) { stmt in
                    unchanged = abs(sqlite3_column_double(stmt, 0) - candidate.mtime) < 0.0005
                        && sqlite3_column_int64(stmt, 1) == candidate.size
                }
                return unchanged
            }
        }
        _ = await compute(candidates, logStart: logStart, progress: nil)
    }

    private func compute(
        _ candidates: [VisualIndexCandidate],
        logStart: Int,
        progress: (@Sendable (VisualIndexProgress) -> Void)?
    ) async -> Bool {
        // Online-only cloud files are skipped (reading them would download them); they
        // have no row yet, so a later pass picks them up once downloaded.
        let candidates = candidates.filter { CloudFileStatus.isLocallyAvailable(path: $0.path) }
        let total = candidates.count
        progress?(VisualIndexProgress(done: 0, total: total, currentName: nil))
        guard total > 0 else { return true }

        var buffer: [VisualIndexRecord] = []
        var done = 0
        var lastReport = Date.distantPast
        var lastFlush = Date()

        await withTaskGroup(of: VisualIndexRecord?.self) { group in
            var next = 0
            func enqueue() {
                guard next < total, !Task.isCancelled else { return }
                let candidate = candidates[next]
                next += 1
                group.addTask(priority: .utility) {
                    await VisualSignatureExtractor.record(for: candidate)
                }
            }
            for _ in 0..<Self.workerCount { enqueue() }
            // Drain every in-flight task (even after cancellation) so finished work is kept.
            while let result = await group.next() {
                if let result {
                    buffer.append(result)
                    done += 1
                    computedSignatureCount += 1
                    let now = Date()
                    if buffer.count >= 32 || now.timeIntervalSince(lastFlush) > 1 {
                        flush(&buffer, logStart: logStart)
                        lastFlush = now
                    }
                    if now.timeIntervalSince(lastReport) > 0.1 || done == total {
                        lastReport = now
                        progress?(VisualIndexProgress(
                            done: done, total: total,
                            currentName: (result.path as NSString).lastPathComponent
                        ))
                    }
                }
                enqueue()
            }
        }
        flush(&buffer, logStart: logStart)
        return done == total
    }

    private func flush(_ buffer: inout [VisualIndexRecord], logStart: Int) {
        guard !buffer.isEmpty else { return }
        let mutated = pathsMutatedDuringBuilds[logStart...]
        if !mutated.isEmpty {
            buffer.removeAll { record in mutated.contains { Self.isSameOrDescendant(record.path, of: $0) } }
        }
        let records = buffer
        buffer.removeAll(keepingCapacity: true)
        guard !records.isEmpty else { return }
        transaction {
            for record in records { upsert(record) }
        }
    }

    /// Writes precomputed records directly (tests and benchmarks).
    func store(_ records: [VisualIndexRecord]) async {
        guard openIfNeeded() else { return }
        transaction {
            for record in records { upsert(record) }
        }
    }

    // MARK: Queries

    func signatures(forPaths paths: [String]) async -> [String: VisualSignature] {
        guard openIfNeeded() else { return [:] }
        var result: [String: VisualSignature] = [:]
        for raw in paths {
            let path = Self.normalizedPath(raw)
            query("SELECT \(Self.rowColumns) FROM signatures WHERE path = ?", [.text(path)]) { stmt in
                if let row = Self.row(from: stmt, withFeature: true), let signature = row.signature {
                    result[raw] = signature
                }
            }
        }
        return result
    }

    /// dHash and pixel size only (no feature prints): what version-stack detection needs
    /// for upscale lineage. Unindexed paths are missing from the result.
    func stackSignatures(forPaths paths: [String]) async -> [String: (dHash: UInt64, width: Int?, height: Int?)] {
        guard openIfNeeded() else { return [:] }
        var result: [String: (dHash: UInt64, width: Int?, height: Int?)] = [:]
        for raw in paths {
            query("SELECT dhash, width, height FROM signatures WHERE path = ?", [.text(Self.normalizedPath(raw))]) { stmt in
                guard sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return }
                result[raw] = (UInt64(bitPattern: sqlite3_column_int64(stmt, 0)), Self.columnInt(stmt, 1), Self.columnInt(stmt, 2))
            }
        }
        return result
    }

    func dominantColors(forPaths paths: [String]) async -> [String: [DominantColor]] {
        guard openIfNeeded() else { return [:] }
        var result: [String: [DominantColor]] = [:]
        for raw in paths {
            query("SELECT colors FROM signatures WHERE path = ?", [.text(Self.normalizedPath(raw))]) { stmt in
                let colors = Self.decodeColors(Self.columnText(stmt, 0))
                if !colors.isEmpty { result[raw] = colors }
            }
        }
        return result
    }

    func similarSets(in scope: VisualScope, strictness: Double, includeVideos: Bool) async -> [SimilarSet] {
        guard openIfNeeded() else { return [] }
        let rows = rows(in: scope, withFeatures: true).filter { $0.sha256 != nil && (includeVideos || !$0.isVideo) }
        let s = min(1, max(0, strictness))
        return Self.similarSets(rows: rows, strictness: s)
    }

    func moreLikeThis(path: String, in scope: VisualScope, limit: Int) async -> [SimilarityHit] {
        guard openIfNeeded() else { return [] }
        let queryPath = Self.normalizedPath(path)
        guard let target = await signatureRow(forPath: queryPath) else { return [] }
        let targetVector = target.feature.flatMap(VisualSignatureExtractor.vector(from:))
        var hits: [SimilarityHit] = []
        for row in rows(in: scope, withFeatures: targetVector != nil) where row.path != queryPath {
            if let targetVector, let data = row.feature, let vector = VisualSignatureExtractor.vector(from: data),
               vector.count == targetVector.count
            {
                hits.append(SimilarityHit(path: row.path, distance: VisualVectorMath.distance(targetVector, vector)))
            } else if let a = target.dHash, let b = row.dHash {
                hits.append(SimilarityHit(path: row.path, distance: Float((a ^ b).nonzeroBitCount) / 32))
            }
        }
        hits.sort { $0.distance != $1.distance ? $0.distance < $1.distance : $0.path < $1.path }
        return Array(hits.prefix(max(0, limit)))
    }

    func colorMatches(palette: [String], tolerance: Double, in scope: VisualScope, limit: Int) async -> [SimilarityHit] {
        guard openIfNeeded() else { return [] }
        let query = palette.compactMap(OKLab.init(hex:))
        guard !query.isEmpty else { return [] }
        let maxDistance = Self.colorMaxDistance(tolerance: tolerance)
        var hits: [SimilarityHit] = []
        for row in rows(in: scope, withFeatures: false) where !row.colors.isEmpty {
            let distance = VisualPalette.matchDistance(query: query, palette: VisualPalette.lab(row.colors))
            if distance <= maxDistance { hits.append(SimilarityHit(path: row.path, distance: Float(distance))) }
        }
        hits.sort { $0.distance != $1.distance ? $0.distance < $1.distance : $0.path < $1.path }
        return Array(hits.prefix(max(0, limit)))
    }

    /// Tolerance 0…1 → maximum mean OKLab cost: 0.05 (near-exact) … 0.30 (same family).
    static func colorMaxDistance(tolerance: Double) -> Double {
        0.05 + 0.25 * min(1, max(0, tolerance))
    }

    func stats(under root: URL?) async -> (indexed: Int, total: Int?) {
        guard openIfNeeded() else { return (0, nil) }
        var indexed = 0
        var total: Int?
        if let root {
            let rootPath = Self.normalizedPath(root.path)
            let (lower, upper) = Self.descendantRange(rootPath)
            query("SELECT COUNT(*) FROM signatures WHERE path > ? AND path < ?", [.text(lower), .text(upper)]) { stmt in
                indexed = Int(sqlite3_column_int64(stmt, 0))
            }
            query("SELECT total FROM roots WHERE root = ?", [.text(rootPath)]) { stmt in
                total = Self.columnInt(stmt, 0)
            }
        } else {
            query("SELECT COUNT(*) FROM signatures", []) { stmt in indexed = Int(sqlite3_column_int64(stmt, 0)) }
        }
        return (indexed, total)
    }

    /// When `root` (exactly) was last fully indexed.
    func lastIndexed(root: URL) async -> Date? {
        guard openIfNeeded() else { return nil }
        var result: Date?
        query("SELECT last_indexed FROM roots WHERE root = ?", [.text(Self.normalizedPath(root.path))]) { stmt in
            if sqlite3_column_type(stmt, 0) != SQLITE_NULL {
                result = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
            }
        }
        return result
    }

    // MARK: Mutations

    /// Marks every row under `root` out of date (mtime −1) without dropping it, so the
    /// next incremental run recomputes each file once — and a paused rebuild resumes
    /// with only the files it hasn't redone yet.
    func markStale(under root: URL) async {
        guard openIfNeeded() else { return }
        let (lower, upper) = Self.descendantRange(Self.normalizedPath(root.path))
        exec("UPDATE signatures SET mtime = -1 WHERE path > ? AND path < ?", [.text(lower), .text(upper)])
    }

    /// Renames rows for `from` and everything under it.
    func movePath(from oldPath: String, to newPath: String) async {
        guard openIfNeeded() else { return }
        let old = Self.normalizedPath(oldPath)
        let new = Self.normalizedPath(newPath)
        guard old != new else { return }
        noteMutation(old)
        noteMutation(new)
        let offset = Int64(old.unicodeScalars.count + 1)
        let (lower, upper) = Self.descendantRange(old)
        let (newLower, newUpper) = Self.descendantRange(new)
        let newFolder = Self.parentPath(new)
        transaction {
            exec("DELETE FROM signatures WHERE path = ?", [.text(new)])
            exec("DELETE FROM signatures WHERE path > ? AND path < ?", [.text(newLower), .text(newUpper)])
            exec("UPDATE signatures SET path = ?, folder = ? WHERE path = ?", [.text(new), .text(newFolder), .text(old)])
            exec("""
                 UPDATE signatures SET path = ? || substr(path, ?), folder = ? || substr(folder, ?)
                 WHERE path > ? AND path < ?
                 """,
                 [.text(new), .int(offset), .text(new), .int(offset), .text(lower), .text(upper)])
            exec("DELETE FROM roots WHERE root = ?", [.text(new)])
            exec("UPDATE roots SET root = ? WHERE root = ?", [.text(new), .text(old)])
        }
    }

    func removeEntries(under path: String) async {
        guard openIfNeeded() else { return }
        let normalized = Self.normalizedPath(path)
        noteMutation(normalized)
        let (lower, upper) = Self.descendantRange(normalized)
        transaction {
            exec("DELETE FROM signatures WHERE path = ?", [.text(normalized)])
            exec("DELETE FROM signatures WHERE path > ? AND path < ?", [.text(lower), .text(upper)])
        }
    }

    func reset() async {
        guard openIfNeeded() else { return }
        // Anything a running build extracted before the reset must not reappear.
        noteMutation("/")
        transaction {
            exec("DELETE FROM signatures", [])
            exec("DELETE FROM roots", [])
        }
        exec("VACUUM", [])
    }

    private func noteMutation(_ path: String) {
        guard activeBuildCount > 0 else { return }
        pathsMutatedDuringBuilds.append(path)
    }

    // MARK: - Similar-set algorithm

    struct Thresholds: Sendable, Equatable {
        let exactOnly: Bool
        let hammingRadius: Int
        let featureDistance: Float
        let paletteDistance: Double

        init(strictness s: Double) {
            exactOnly = s >= 0.999
            hammingRadius = min(14, max(2, Int((14 - 12 * s).rounded())))
            featureDistance = Float(0.45 - 0.30 * s)
            paletteDistance = 0.20 - 0.14 * s
        }
    }

    static func similarSets(rows: [Row], strictness: Double) -> [SimilarSet] {
        let thresholds = Thresholds(strictness: strictness)

        // Exact groups by content hash.
        var bySHA: [String: [Int]] = [:]
        for (index, row) in rows.enumerated() {
            if let sha = row.sha256 { bySHA[sha, default: []].append(index) }
        }
        var sets: [SimilarSet] = []
        for members in bySHA.values where members.count > 1 {
            sets.append(makeSet(members.map { rows[$0].path }, kind: .exact))
        }

        if !thresholds.exactOnly {
            // One representative per content hash; visual sets are built over them and
            // expanded back to every copy.
            var representatives: [Int] = []
            var copies: [Int: [Int]] = [:]
            for members in bySHA.values {
                let sorted = members.sorted { rows[$0].path < rows[$1].path }
                guard let rep = sorted.first, rows[rep].dHash != nil else { continue }
                representatives.append(rep)
                copies[rep] = sorted
            }
            representatives.sort { rows[$0].path < rows[$1].path }

            let hashes = representatives.map { rows[$0].dHash ?? 0 }
            let index = HammingIndex(hashes: hashes)
            var vectors = [[Float]?](repeating: nil, count: representatives.count)
            var decoded = [Bool](repeating: false, count: representatives.count)
            func vector(_ i: Int) -> [Float]? {
                if !decoded[i] {
                    decoded[i] = true
                    vectors[i] = rows[representatives[i]].feature.flatMap(VisualSignatureExtractor.vector(from:))
                }
                return vectors[i]
            }
            let palettes = representatives.map { VisualPalette.lab(rows[$0].colors) }

            var unions = UnionFind(count: representatives.count)
            var scratch = HammingIndex.Scratch(count: representatives.count)
            var linked = [Bool](repeating: false, count: representatives.count)
            for i in representatives.indices {
                index.neighbours(of: i, radius: thresholds.hammingRadius, scratch: &scratch) { j, hamming in
                    guard j > i else { return }
                    let a = vector(i), b = vector(j)
                    if let a, let b, a.count == b.count {
                        guard VisualVectorMath.distance(a, b) <= thresholds.featureDistance else { return }
                    } else if hamming > thresholds.hammingRadius / 2 {
                        return
                    }
                    guard VisualPalette.paletteDistance(palettes[i], palettes[j]) <= thresholds.paletteDistance else { return }
                    unions.union(i, j)
                    linked[i] = true
                    linked[j] = true
                }
            }
            var components: [Int: [Int]] = [:]
            for i in representatives.indices where linked[i] {
                components[unions.find(i), default: []].append(i)
            }
            for component in components.values where component.count > 1 {
                let paths = component.flatMap { copies[representatives[$0]] ?? [] }.map { rows[$0].path }
                sets.append(makeSet(paths, kind: .visual))
            }
        }

        return sets.sorted { lhs, rhs in
            guard let a = lhs.paths.first, let b = rhs.paths.first else { return lhs.id < rhs.id }
            if a != b { return displayOrder(a, b) }
            return lhs.kind == .exact && rhs.kind == .visual
        }
    }

    private static func makeSet(_ paths: [String], kind: SimilarSet.Kind) -> SimilarSet {
        let key = kind.rawValue + "\n" + paths.sorted().joined(separator: "\n")
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return SimilarSet(id: "\(kind.rawValue)-\(digest)", paths: paths.sorted(by: displayOrder), kind: kind)
    }

    /// Folder, then file name (Finder order). Never size, resolution or date.
    static func displayOrder(_ lhs: String, _ rhs: String) -> Bool {
        let lf = parentPath(lhs), rf = parentPath(rhs)
        if lf != rf {
            let order = lf.localizedStandardCompare(rf)
            if order != .orderedSame { return order == .orderedAscending }
            return lf < rf
        }
        let ln = (lhs as NSString).lastPathComponent, rn = (rhs as NSString).lastPathComponent
        let order = ln.localizedStandardCompare(rn)
        if order != .orderedSame { return order == .orderedAscending }
        return lhs < rhs
    }

    // MARK: - Rows

    struct Row: Sendable {
        let path: String
        let folder: String
        let sha256: String?
        let dHash: UInt64?
        let feature: Data?
        let colors: [DominantColor]
        let width: Int?
        let height: Int?
        let isVideo: Bool

        var signature: VisualSignature? {
            guard let sha256, let dHash else { return nil }
            return VisualSignature(
                path: path, sha256: sha256, dHash: dHash, featurePrint: feature, dominantColors: colors,
                pixelWidth: width, pixelHeight: height, isVideo: isVideo
            )
        }
    }

    private static let rowColumns = "path, folder, sha256, dhash, colors, width, height, is_video, feature"
    private static let rowColumnsNoFeature = "path, folder, sha256, dhash, colors, width, height, is_video, NULL"

    private func rows(in scope: VisualScope, withFeatures: Bool) -> [Row] {
        let columns = withFeatures ? Self.rowColumns : Self.rowColumnsNoFeature
        var result: [Row] = []
        switch scope {
        case .folder(let url):
            query("SELECT \(columns) FROM signatures WHERE folder = ?", [.text(Self.normalizedPath(url.path))]) { stmt in
                if let row = Self.row(from: stmt, withFeature: withFeatures) { result.append(row) }
            }
        case .library(let url):
            let (lower, upper) = Self.descendantRange(Self.normalizedPath(url.path))
            query("SELECT \(columns) FROM signatures WHERE path > ? AND path < ?", [.text(lower), .text(upper)]) { stmt in
                if let row = Self.row(from: stmt, withFeature: withFeatures) { result.append(row) }
            }
        }
        return result
    }

    /// The stored row, or one computed (and stored) now for a file not indexed yet.
    private func signatureRow(forPath path: String) async -> Row? {
        var found: Row?
        query("SELECT \(Self.rowColumns) FROM signatures WHERE path = ?", [.text(path)]) { stmt in
            found = Self.row(from: stmt, withFeature: true)
        }
        if let found { return found }
        guard let candidate = Self.candidate(forFile: path) else { return nil }
        let record = await Task.detached(priority: .userInitiated) {
            await VisualSignatureExtractor.record(for: candidate)
        }.value
        guard let record else { return nil }
        upsert(record)
        return Row(
            path: record.path, folder: record.folder, sha256: record.sha256, dHash: record.dHash,
            feature: record.featurePrint, colors: record.colors, width: record.width, height: record.height,
            isVideo: record.isVideo
        )
    }

    private static func row(from stmt: OpaquePointer, withFeature: Bool) -> Row? {
        guard let path = columnText(stmt, 0) else { return nil }
        var feature: Data?
        if withFeature, sqlite3_column_type(stmt, 8) == SQLITE_BLOB, let bytes = sqlite3_column_blob(stmt, 8) {
            feature = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 8)))
        }
        return Row(
            path: path,
            folder: columnText(stmt, 1) ?? parentPath(path),
            sha256: columnText(stmt, 2),
            dHash: sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : UInt64(bitPattern: sqlite3_column_int64(stmt, 3)),
            feature: feature,
            colors: decodeColors(columnText(stmt, 4)),
            width: columnInt(stmt, 5),
            height: columnInt(stmt, 6),
            isVideo: sqlite3_column_int64(stmt, 7) != 0
        )
    }

    /// `[{"hex":"#RRGGBB","weight":0.412},…]` — written by hand so `decodeColors` can
    /// take a fast path (JSONSerialization is ~10× slower per row).
    static func encodeColors(_ colors: [DominantColor]) -> String {
        "[" + colors.map { "{\"hex\":\"\($0.hex)\",\"weight\":\(String(format: "%.3f", $0.weight))}" }.joined(separator: ",") + "]"
    }

    static func decodeColors(_ text: String?) -> [DominantColor] {
        guard let text, text.count > 2 else { return [] }
        if let fast = fastDecodeColors(text) { return fast }
        guard let data = text.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return array.compactMap { item in
            guard let hex = item["hex"] as? String, let weight = (item["weight"] as? NSNumber)?.doubleValue else { return nil }
            return DominantColor(hex: hex, weight: weight)
        }
    }

    private static func fastDecodeColors(_ text: String) -> [DominantColor]? {
        var text = text
        return text.withUTF8 { bytes -> [DominantColor]? in
            let n = bytes.count
            guard n >= 2, bytes[0] == UInt8(ascii: "["), bytes[n - 1] == UInt8(ascii: "]") else { return nil }
            func matches(_ key: [UInt8], at index: Int) -> Bool {
                guard index + key.count <= n else { return false }
                for offset in 0..<key.count where bytes[index + offset] != key[offset] { return false }
                return true
            }
            func string(_ range: Range<Int>) -> String {
                String(decoding: UnsafeBufferPointer(rebasing: bytes[range]), as: UTF8.self)
            }
            var result: [DominantColor] = []
            var i = 1
            while i < n - 1 {
                guard bytes[i] == UInt8(ascii: "{"), matches(hexKey, at: i + 1) else { return nil }
                i += 1 + hexKey.count
                guard i + 7 <= n else { return nil }
                let hex = string(i..<(i + 7))
                i += 7
                guard matches(weightKey, at: i) else { return nil }
                i += weightKey.count
                let start = i
                while i < n, bytes[i] != UInt8(ascii: "}") { i += 1 }
                guard i < n, let weight = Double(string(start..<i)) else { return nil }
                result.append(DominantColor(hex: hex, weight: weight))
                i += 1
                if i < n - 1 {
                    guard bytes[i] == UInt8(ascii: ",") else { return nil }
                    i += 1
                }
            }
            return result
        }
    }

    private static let hexKey = Array(#""hex":""#.utf8)
    private static let weightKey = Array(#"","weight":"#.utf8)

    // MARK: - Walking

    private static func walkInBackground(rootPath: String) async -> [VisualIndexCandidate]? {
        // A child task (not detached) so cancellation reaches the walk.
        await withTaskGroup(of: [VisualIndexCandidate]?.self) { group in
            group.addTask(priority: .utility) { walk(rootPath: rootPath) }
            return await group.next() ?? nil
        }
    }

    /// Recursive walk of images, videos and Mood / Story documents (hidden files and
    /// package contents skipped). Paths keep the caller's root prefix. Nil when cancelled.
    static func walk(rootPath: String) -> [VisualIndexCandidate]? {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey,
                                      .contentModificationDateKey, .fileSizeKey]
        var result: [VisualIndexCandidate] = []
        var stack = [rootPath]
        var visited = 0
        while let directoryPath = stack.popLast() {
            visited += 1
            if visited % 32 == 0, Task.isCancelled { return nil }
            guard let children = try? fm.contentsOfDirectory(
                at: URL(fileURLWithPath: directoryPath, isDirectory: true),
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants, .skipsSubdirectoryDescendants]
            ) else { continue }
            for url in children {
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                let name = url.lastPathComponent
                if values.isDirectory == true {
                    if values.isPackage != true, values.isSymbolicLink != true {
                        stack.append(childPath(directoryPath, name))
                    }
                    continue
                }
                guard values.isRegularFile == true, VisualSignatureExtractor.kind(ofName: name) != nil else { continue }
                result.append(VisualIndexCandidate(
                    path: childPath(directoryPath, name),
                    folder: directoryPath,
                    mtime: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
                    size: Int64(values.fileSize ?? 0)
                ))
            }
        }
        return result
    }

    static func candidate(forFile path: String) -> VisualIndexCandidate? {
        let url = URL(fileURLWithPath: path)
        guard VisualSignatureExtractor.kind(ofName: url.lastPathComponent) != nil,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
              values.isRegularFile == true
        else { return nil }
        return VisualIndexCandidate(
            path: path,
            folder: parentPath(path),
            mtime: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
            size: Int64(values.fileSize ?? 0)
        )
    }

    // MARK: - Database plumbing

    enum SQLValue {
        case text(String)
        case int(Int64)
        case double(Double)
        case blob(Data)
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
        PRAGMA temp_store = MEMORY;
        CREATE TABLE IF NOT EXISTS signatures(
            path TEXT PRIMARY KEY,
            folder TEXT NOT NULL,
            mtime REAL,
            size INTEGER,
            sha256 TEXT,
            dhash INTEGER,
            feature BLOB,
            colors TEXT,
            width INTEGER,
            height INTEGER,
            is_video INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS signatures_folder ON signatures(folder);
        CREATE INDEX IF NOT EXISTS signatures_sha ON signatures(sha256);
        CREATE TABLE IF NOT EXISTS roots(root TEXT PRIMARY KEY, last_indexed REAL, total INTEGER);
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
        """
        if sqlite3_exec(handle, schema, nil, nil, nil) != SQLITE_OK {
            sqlite3_close_v2(handle)
            db = nil
            return false
        }
        // Feature prints from another Vision revision can't be compared: mark every row
        // out of date so the next run recomputes it.
        let revision = String(VisualSignatureExtractor.featurePrintRevision)
        var stored: String?
        query("SELECT value FROM meta WHERE key = 'feature_revision'", []) { stmt in stored = Self.columnText(stmt, 0) }
        if stored != revision {
            if stored != nil {
                exec("UPDATE signatures SET feature = NULL, mtime = -1", [])
            }
            exec("INSERT OR REPLACE INTO meta(key, value) VALUES('feature_revision', ?)", [.text(revision)])
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
            case .blob(let data):
                data.withUnsafeBytes { buffer in
                    _ = sqlite3_bind_blob(stmt, index, buffer.baseAddress, Int32(buffer.count), transient)
                }
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

    private func existingSignatures(under rootPath: String) -> [String: (mtime: Double, size: Int64)] {
        var result: [String: (mtime: Double, size: Int64)] = [:]
        let (lower, upper) = Self.descendantRange(rootPath)
        query("SELECT path, mtime, size FROM signatures WHERE path > ? AND path < ?", [.text(lower), .text(upper)]) { stmt in
            if let path = Self.columnText(stmt, 0) {
                result[path] = (sqlite3_column_double(stmt, 1), sqlite3_column_int64(stmt, 2))
            }
        }
        return result
    }

    private func upsert(_ record: VisualIndexRecord) {
        func opt(_ s: String?) -> SQLValue { s.map { .text($0) } ?? .null }
        func opt(_ i: Int?) -> SQLValue { i.map { .int(Int64($0)) } ?? .null }
        exec("""
             INSERT OR REPLACE INTO signatures(path, folder, mtime, size, sha256, dhash, feature, colors, width, height, is_video)
             VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
             """,
             [.text(record.path), .text(record.folder), .double(record.mtime), .int(record.size),
              opt(record.sha256),
              record.dHash.map { .int(Int64(bitPattern: $0)) } ?? .null,
              record.featurePrint.map { .blob($0) } ?? .null,
              .text(Self.encodeColors(record.colors)),
              opt(record.width), opt(record.height), .int(record.isVideo ? 1 : 0)])
    }

    // MARK: - Static helpers

    private static func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL, let cString = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cString)
    }

    private static func columnInt(_ stmt: OpaquePointer, _ index: Int32) -> Int? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(stmt, index))
    }

    /// Trims trailing slashes only (never `standardizingPath`, which can drop `/private`).
    static func normalizedPath(_ path: String) -> String {
        var result = path
        while result.count > 1 && result.hasSuffix("/") { result.removeLast() }
        return result
    }

    /// Exclusive bounds matching every path strictly beneath `path`.
    static func descendantRange(_ path: String) -> (String, String) {
        if path == "/" { return ("/", "0") }
        return (path + "/", path + "0")
    }

    static func parentPath(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        if slash == path.startIndex { return "/" }
        return String(path[..<slash])
    }

    private static func childPath(_ directory: String, _ name: String) -> String {
        directory == "/" ? "/" + name : directory + "/" + name
    }

    static func isSameOrDescendant(_ path: String, of ancestor: String) -> Bool {
        if path == ancestor { return true }
        if ancestor == "/" { return path.hasPrefix("/") }
        return path.hasPrefix(ancestor + "/")
    }
}
