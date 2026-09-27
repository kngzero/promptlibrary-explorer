import Foundation
import Observation

/// The Apply Suggested Tags… review sheet's state: files, their suggestions, checkboxes.
@MainActor @Observable
final class TagSuggestionSession: Identifiable {
    let id = UUID()
    let paths: [String]
    var plan = TagSuggestionPlan()
    private(set) var isLoading = true
    private(set) var loaded = 0
    /// Files with no analysis yet that were analysed for this sheet.
    private(set) var analyzedNow = 0

    init(paths: [String]) {
        self.paths = paths
    }

    func finishLoading(plan: TagSuggestionPlan, analyzedNow: Int) {
        self.plan = plan
        self.analyzedNow = analyzedNow
        isLoading = false
    }

    func noteLoaded(_ count: Int) {
        loaded = count
    }
}

/// Presents the review sheet and computes suggestions for files. Suggestions are cached
/// in the image-text store (labels) and never applied without the user's confirmation.
@MainActor @Observable
final class TagSuggestionController {
    static let shared = TagSuggestionController()

    var session: TagSuggestionSession?

    @ObservationIgnored private var loadTask: Task<Void, Never>?

    /// Suggestions for one file from its stored analysis, dominant colours and model.
    func suggestions(
        for path: String,
        record: ImageTextRecord?,
        model: String?,
        existingTagNames: [String]
    ) async -> [TagSuggestion] {
        let colors = await VisualIndexService.shared.dominantColors(forPaths: [path])[path] ?? []
        return TagSuggestionEngine.suggestions(
            labels: record?.labels,
            colors: colors,
            model: model,
            existingTagNames: existingTagNames
        )
    }

    /// Opens the review sheet for `paths` (images only) and loads their suggestions,
    /// analysing files that haven't been analysed yet (user-initiated, so it runs even
    /// when background analysis is paused).
    func openReview(
        paths: [String],
        model: @escaping @MainActor (String) -> String?,
        existingTagNames: @escaping @MainActor (String) -> [String]
    ) {
        let images = paths.filter { FileHelpers.isImageFile(($0 as NSString).lastPathComponent) }
        let session = TagSuggestionSession(paths: images)
        self.session = session
        loadTask?.cancel()
        loadTask = Task { [weak self, weak session] in
            let controller = ImageTextController.shared
            var records: [String: ImageTextRecord] = [:]
            var missing: [String] = []
            for path in images {
                if let record = await controller.record(for: path), record.labels != nil {
                    records[path] = record
                } else {
                    missing.append(path)
                }
            }
            if !missing.isEmpty {
                let analysed = await controller.analyzeNow(paths: missing)
                records.merge(analysed) { _, new in new }
            }
            guard !Task.isCancelled, let self, let session, self.session?.id == session.id else { return }
            var rows: [(path: String, suggestions: [TagSuggestion])] = []
            for (offset, path) in images.enumerated() {
                let suggestions = await self.suggestions(
                    for: path, record: records[path], model: model(path), existingTagNames: existingTagNames(path)
                )
                rows.append((path, suggestions))
                session.noteLoaded(offset + 1)
            }
            session.finishLoading(plan: TagSuggestionPlan(suggestions: rows), analyzedNow: missing.count)
        }
    }

    func closeReview() {
        loadTask?.cancel()
        loadTask = nil
        session = nil
    }
}
