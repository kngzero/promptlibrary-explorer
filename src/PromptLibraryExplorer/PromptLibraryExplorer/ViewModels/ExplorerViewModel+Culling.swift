import AppKit
import Foundation

// MARK: - Culling: flags, ratings and Finder labels

extension ExplorerViewModel {
    /// Culling mode is on and so is auto-advance.
    var isCullAutoAdvanceActive: Bool { cullingModeEnabled && cullAutoAdvance }

    /// The item the lightbox shows, when open.
    var lightboxItem: FileEntry? {
        guard lightboxOpen else { return nil }
        let items = processedFolderContents
        guard lightboxIndex >= 0, lightboxIndex < items.count else { return nil }
        return items[lightboxIndex]
    }

    /// What a culling action applies to: the lightbox's item while it's open,
    /// otherwise the whole selection. Flags and ratings skip folders.
    func cullTargets(for action: CullAction) -> [FileEntry] {
        let items = lightboxOpen ? (lightboxItem.map { [$0] } ?? []) : selectedItems
        return action.appliesToFolders ? items : items.filter { !$0.isDirectory }
    }

    /// Applies `action` to `cullTargets(for:)` (one undo step) and flashes
    /// feedback. Returns how many items it targeted.
    ///
    /// When a flag / label filter hides the lightbox's item as a result, the
    /// lightbox moves to its neighbour on its own (`remapSelectionToProcessedContents`);
    /// the selection, which drives the details, is re-pointed at it here.
    @discardableResult
    func performCullAction(_ action: CullAction) -> Int {
        let targets = cullTargets(for: action)
        guard !targets.isEmpty else { return 0 }
        let lightboxPathBefore = lightboxItem?.path
        apply(action, to: targets)
        if let lightboxPathBefore, let item = lightboxItem, item.path != lightboxPathBefore {
            selectItem(at: lightboxIndex)
        }
        return targets.count
    }

    /// Applies `action` to `items` as one undoable step.
    func apply(_ action: CullAction, to items: [FileEntry]) {
        guard !items.isEmpty else { return }
        switch action {
        case let .flag(flag):
            applyFlag(flag, toPaths: items.map(\.path))
        case let .rating(stars):
            applyRating(stars, toPaths: items.map(\.path))
        case let .label(label):
            applyLabel(label, to: items.map(\.url))
        }
        cullFeedback = CullFeedback(id: (cullFeedback?.id ?? 0) &+ 1, action: action, count: items.count)
        if !lightboxOpen, items.count > 1 {
            showToast("\(action.feedbackTitle) · \(items.count) items", type: .success)
        }
    }

    // MARK: Flags & ratings (undoable)

    func applyFlag(_ flag: FileFlag, toPaths paths: [String]) {
        let values = Dictionary(paths.map { ($0, flag) }, uniquingKeysWith: { first, _ in first })
        let previous = writeFlags(values)
        guard !previous.isEmpty else { return }
        recordFolderHistoryEntry(makeFlagHistoryEntry(previous, title: flag.actionTitle))
    }

    func applyRating(_ rating: Int, toPaths paths: [String]) {
        let clamped = max(0, min(5, rating))
        let values = Dictionary(paths.map { ($0, clamped) }, uniquingKeysWith: { first, _ in first })
        let previous = writeRatings(values)
        guard !previous.isEmpty else { return }
        recordFolderHistoryEntry(makeRatingHistoryEntry(previous, title: "Rating"))
    }

    /// History entry that writes `values`; its inverse writes back what they replaced.
    private func makeFlagHistoryEntry(_ values: [String: FileFlag], title: String) -> FolderHistoryEntry {
        FolderHistoryEntry(title: title) { [weak self] in
            guard let self else { return ExplorerViewModel.releasedHistoryResult(count: values.count) }
            let replaced = self.writeFlags(values)
            return FolderHistoryApplyResult(
                inverse: replaced.isEmpty ? nil : self.makeFlagHistoryEntry(replaced, title: title),
                remaining: nil,
                appliedCount: values.count,
                failedCount: 0,
                firstError: nil
            )
        }
    }

    private func makeRatingHistoryEntry(_ values: [String: Int], title: String) -> FolderHistoryEntry {
        FolderHistoryEntry(title: title) { [weak self] in
            guard let self else { return ExplorerViewModel.releasedHistoryResult(count: values.count) }
            let replaced = self.writeRatings(values)
            return FolderHistoryApplyResult(
                inverse: replaced.isEmpty ? nil : self.makeRatingHistoryEntry(replaced, title: title),
                remaining: nil,
                appliedCount: values.count,
                failedCount: 0,
                firstError: nil
            )
        }
    }

    // MARK: Finder labels (on the file; undoable)

    /// The listed entry's Finder label (0 = none).
    func labelNumber(for path: String) -> Int {
        listingSourceContents.first(where: { $0.path == path })?.labelNumber ?? 0
    }

    /// Writes `label` to every URL's Finder label and records one undo step
    /// holding the old values.
    func applyLabel(_ label: FinderLabel, to urls: [URL]) {
        let outcome = writeLabels(urls.map { (url: $0, label: label.rawValue) })
        if !outcome.previous.isEmpty {
            recordFolderHistoryEntry(makeLabelHistoryEntry(outcome.previous, title: "Label"))
        }
        if !outcome.failed.isEmpty {
            let noun = outcome.failed.count == 1 ? "item" : "\(outcome.failed.count) items"
            showToast(
                "Couldn't label \(noun): \(outcome.firstError?.localizedDescription ?? "Unknown error")",
                type: .error
            )
        }
    }

    /// Sets Finder labels on disk and patches the listing in place (no reload).
    /// `previous` holds the old label of every item that changed.
    private func writeLabels(
        _ targets: [(url: URL, label: Int)]
    ) -> (previous: [(url: URL, label: Int)], failed: [(url: URL, label: Int)], firstError: Error?) {
        var previous: [(url: URL, label: Int)] = []
        var failed: [(url: URL, label: Int)] = []
        var firstError: Error?
        var listed: [String: Int] = [:]

        for target in targets {
            // Read fresh: Finder may have changed it since the listing was read.
            let old = FileSystemService.labelNumber(at: target.url)
            guard old != target.label else {
                listed[target.url.path] = old
                continue
            }
            do {
                try FileSystemService.setLabelNumber(target.label, at: target.url)
                previous.append((target.url, old))
                listed[target.url.path] = target.label
            } catch {
                failed.append(target)
                if firstError == nil { firstError = error }
            }
        }
        updateListedLabelNumbers(listed)
        return (previous, failed, firstError)
    }

    private func makeLabelHistoryEntry(_ targets: [(url: URL, label: Int)], title: String) -> FolderHistoryEntry {
        FolderHistoryEntry(title: title) { [weak self] in
            guard let self else { return ExplorerViewModel.releasedHistoryResult(count: targets.count) }
            let outcome = self.writeLabels(targets)
            return FolderHistoryApplyResult(
                inverse: outcome.previous.isEmpty ? nil : self.makeLabelHistoryEntry(outcome.previous, title: title),
                remaining: outcome.failed.isEmpty ? nil : self.makeLabelHistoryEntry(outcome.failed, title: title),
                appliedCount: targets.count - outcome.failed.count,
                failedCount: outcome.failed.count,
                firstError: outcome.firstError
            )
        }
    }

    /// Updates `labelNumber` of listed entries (folder and collection listings).
    private func updateListedLabelNumbers(_ numbers: [String: Int]) {
        guard !numbers.isEmpty else { return }
        func patched(_ entries: [FileEntry]) -> [FileEntry]? {
            var changed = false
            let next = entries.map { entry -> FileEntry in
                guard let number = numbers[entry.path], entry.labelNumber != number else { return entry }
                var copy = entry
                copy.labelNumber = number
                changed = true
                return copy
            }
            return changed ? next : nil
        }
        if let next = patched(folderContents) { folderContents = next }
        if let next = patched(collectionContents) { collectionContents = next }
        if let next = patched(virtualListingContents) { virtualListingContents = next }
    }

    // MARK: Rejects

    /// Rejected files of the listing, including ones hidden by filters.
    var rejectedListingItems: [FileEntry] {
        listingSourceContents.filter { !$0.isDirectory && flag(for: $0.path) == .reject }
    }

    /// Cull ▸ Select Rejects: selects every listed rejected file.
    func selectRejects() {
        let items = processedFolderContents
        let indices = items.indices.filter { !items[$0].isDirectory && flag(for: items[$0].path) == .reject }
        guard let first = indices.first else {
            let message = rejectedListingItems.isEmpty
                ? "No rejects in this listing"
                : "The rejects here are hidden by a filter"
            showToast(message, type: .info)
            return
        }
        selectItem(at: first)
        selectedIndices = Set(indices)
        syncQuickLookWithSelection()
    }

    /// Cull ▸ Move Rejects to Trash…: always asks first (the trash itself is undoable).
    func requestTrashRejects() {
        let rejects = rejectedListingItems
        guard !rejects.isEmpty else {
            showToast("No rejects in this listing", type: .info)
            return
        }
        deleteConfirmationRequest = DeleteConfirmationRequest(
            kind: .trash,
            urls: rejects.map(\.url),
            names: rejects.map(\.name),
            isRejects: true
        )
    }
}
