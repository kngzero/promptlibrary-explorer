import Foundation
import Observation

/// Text in images (OCR) and suggested tags: glue between the listing, the details panel
/// and `ImageTextController` / `TagSuggestionController`.
///
/// Search: recognised text has its own search mode, "Text in Image", and is part of
/// "All". The Prompt mode stays prompt-only, so watermarks, signatures and garbled
/// pseudo-text that image models paint don't pollute prompt searches. Library search
/// (Find in Library…) also matches it: the library index appends the text to each
/// image's searchable text.
extension ExplorerViewModel {
    var imageTextController: ImageTextController { .shared }

    // MARK: Hooks

    func installImageTextHooks() {
        imageTextController.onListingTextChange = { [weak self] in
            self?.externalListingInputsDidChange()
        }
        imageTextController.attach()
        observeImageTextListing()
    }

    private func observeImageTextListing() {
        withObservationTracking {
            _ = listingSourceContents
            _ = selectedFolderPath
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.imageTextListingDidChange()
                self?.observeImageTextListing()
            }
        }
    }

    private func imageTextListingDidChange() {
        let folder = isFolderListing ? selectedFolderPath?.path : nil
        let paths = folder == nil ? listingSourceContents.filter { !$0.isDirectory }.map(\.path) : []
        imageTextController.listingDidChange(scope: promptIndexScope, folder: folder, paths: paths)
    }

    // MARK: Search / smart folders

    /// Recognised text of the listing's files (for the smart-folder rule).
    var imageTextByPathForListing: [String: String] {
        imageTextController.listingText
    }

    /// Listed files whose recognised text contains every word of `query`.
    func imageTextMatchingPaths(for query: String) -> Set<String> {
        let texts = imageTextController.listingText
        guard !texts.isEmpty else { return [] }
        return Set(texts.compactMap { ImageTextSearch.matches($0.value, query: query) ? $0.key : nil })
    }

    // MARK: Suggested tags

    /// Model name for suggestions: parsed parameters, else the loaded prompt entry.
    func suggestionModel(for path: String) -> String? {
        if let model = parametersByPath[path]?.model, !model.isEmpty { return model }
        if selectedPromptEntry?.sourcePath == path, let model = selectedPromptEntry?.generationInfo.model, model != "N/A" {
            return model
        }
        return nil
    }

    /// Adds suggested tags to `paths` (an explicit click on a chip or Add All).
    func addSuggestedTags(_ names: [String], to paths: [String]) {
        let choices = names.map { TagSuggestionPlan.Choice(suggestion: TagSuggestion(name: $0, source: .content, confidence: 1), isChecked: true) }
        applySuggestionPlan(TagSuggestionPlan(rows: paths.map { TagSuggestionPlan.Row(path: $0, choices: choices) }), confirmed: true)
    }

    func addSuggestedTag(_ name: String, to paths: [String]) {
        addSuggestedTags([name], to: paths)
    }

    /// Applies a reviewed plan. `confirmed: false` changes nothing.
    @discardableResult
    func applySuggestionPlan(_ plan: TagSuggestionPlan, confirmed: Bool) -> TagSuggestionApplyOutcome {
        let outcome = TagSuggestionApplier.apply(plan, confirmed: confirmed, tags: .shared)
        if case let .applied(files, tags, _) = outcome {
            reloadCurationStateFromStores()
            if tags > 0 {
                showToast(tags == 1 ? "Added 1 tag" : "Added \(tags) tags to \(files == 1 ? "1 file" : "\(files) files")", type: .success)
            }
        }
        return outcome
    }

    var canApplySuggestedTags: Bool {
        selectedItems.contains { !$0.isDirectory && FileHelpers.isImageFile($0.name) }
    }

    /// Library ▸ Apply Suggested Tags… / context menu: a review sheet for the selection.
    func openApplySuggestedTags() {
        let paths = selectedItems.filter { !$0.isDirectory && FileHelpers.isImageFile($0.name) }.map(\.path)
        guard !paths.isEmpty else {
            showToast("Select one or more images first", type: .info)
            return
        }
        TagSuggestionController.shared.openReview(
            paths: paths,
            model: { [weak self] path in self?.suggestionModel(for: path) },
            existingTagNames: { [weak self] path in self?.tagsForFile(at: path).map(\.name) ?? [] }
        )
    }
}
