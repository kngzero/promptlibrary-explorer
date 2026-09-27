import Foundation
import Observation

/// Neutral facts shown beside each file in a similar group. Nothing here is
/// used to rank, highlight or pick a "best" copy (see the HARD RULE in
/// Models/VisualSearch.swift).
struct SimilarImageInfo: Equatable, Sendable {
    var pixelWidth: Int?
    var pixelHeight: Int?
    var fileSize: Int64?
    var folderPath: String
    var isVideo: Bool

    var resolutionText: String? {
        guard let pixelWidth, let pixelHeight, pixelWidth > 0, pixelHeight > 0 else { return nil }
        return "\(pixelWidth) × \(pixelHeight)"
    }

    var sizeText: String? {
        fileSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    }
}

/// Find Similar Images: runs the engine's `similarSets` for a scope and keeps
/// the groups (in the engine's display order) plus neutral per-file info.
/// Exposes no selection state and no removal action of any kind.
@Observable
@MainActor
final class SimilarImagesModel {
    private(set) var sets: [SimilarSet] = []
    private(set) var info: [String: SimilarImageInfo] = [:]
    private(set) var isComputing = false
    private(set) var hasSearched = false
    /// Files the visual index holds under the root (nil until checked).
    private(set) var indexedCount: Int?
    /// Scope the current results were computed for.
    private(set) var resultsScope: VisualScope?

    @ObservationIgnored private var task: Task<Void, Never>?

    /// Actions each group offers, in display order — no deletion affordance.
    var groupActions: [SimilarGroupAction] { SimilarGroupAction.groupActions }
    /// Actions each file in a group offers.
    var fileActions: [SimilarGroupAction] { SimilarGroupAction.fileActions }

    var fileCount: Int { sets.reduce(0) { $0 + $1.paths.count } }

    /// Rows for a group: exactly the set's own order, never re-sorted by size
    /// or resolution.
    nonisolated static func rows(for set: SimilarSet, info: [String: SimilarImageInfo]) -> [(path: String, info: SimilarImageInfo?)] {
        set.paths.map { ($0, info[$0]) }
    }

    func rows(for set: SimilarSet) -> [(path: String, info: SimilarImageInfo?)] {
        Self.rows(for: set, info: info)
    }

    func refreshIndexStats(root: URL?) async {
        indexedCount = await VisualIndexService.shared.stats(under: root).indexed
    }

    func run(scope: VisualScope, root: URL?, strictness: Double, includeVideos: Bool) {
        task?.cancel()
        isComputing = true
        hasSearched = true
        task = Task { [weak self] in
            let found = await VisualIndexService.shared.similarSets(
                in: scope,
                strictness: strictness,
                includeVideos: includeVideos
            )
            guard !Task.isCancelled else { return }
            let paths = found.flatMap(\.paths)
            let signatures = await VisualIndexService.shared.signatures(forPaths: paths)
            let details = await Task.detached(priority: .userInitiated) {
                Self.fileDetails(for: paths, signatures: signatures)
            }.value
            let stats = await VisualIndexService.shared.stats(under: root)
            guard !Task.isCancelled, let self else { return }
            self.sets = found
            self.info = details
            self.resultsScope = scope
            self.indexedCount = stats.indexed
            self.isComputing = false
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isComputing = false
    }

    /// Drops paths that no longer exist from the groups (after a rename, move
    /// or trash elsewhere); a group left with fewer than two files disappears.
    func pruneMissingFiles() {
        let fm = FileManager.default
        sets = sets.compactMap { set in
            let existing = set.paths.filter { fm.fileExists(atPath: $0) }
            guard existing.count >= 2 else { return nil }
            return existing.count == set.paths.count
                ? set
                : SimilarSet(id: set.id, paths: existing, kind: set.kind)
        }
    }

    nonisolated private static func fileDetails(
        for paths: [String],
        signatures: [String: VisualSignature]
    ) -> [String: SimilarImageInfo] {
        var result: [String: SimilarImageInfo] = [:]
        let fm = FileManager.default
        for path in paths {
            let signature = signatures[path]
            let size = (try? fm.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
            result[path] = SimilarImageInfo(
                pixelWidth: signature?.pixelWidth,
                pixelHeight: signature?.pixelHeight,
                fileSize: size,
                folderPath: (path as NSString).deletingLastPathComponent,
                isVideo: signature?.isVideo ?? FileHelpers.isVideoFile(path)
            )
        }
        return result
    }
}
