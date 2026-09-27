import Foundation
import Observation

/// Version stacks: glue between the listing and `StackController`.
///
/// A collapsed stack is ONE listed item (its cover, or the first visible member when
/// filters hide the cover), so selection, ratings, flags, tags, drags and the context
/// menu act on that item only. Expanding the stack lists every member inline, right
/// after the cover, and each can then be selected on its own.
extension ExplorerViewModel {
    var stackController: StackController { .shared }

    /// The key Stack Variants is remembered under: the folder, or `collection:<id>`.
    /// Virtual listings (ranked results) are never stacked.
    var stackScope: String? {
        guard activeVirtualListing == nil else { return nil }
        return promptIndexScope
    }

    var isStackingEnabled: Bool {
        stackController.isEnabled(forScope: stackScope)
    }

    // MARK: Hooks

    func installStackHooks() {
        stackController.onPresentationChange = { [weak self] in
            self?.externalListingInputsDidChange()
        }
        observeStackInputs()
    }

    /// Re-detects when the listing, its prompt data or the stack book change.
    private func observeStackInputs() {
        withObservationTracking {
            _ = listingSourceContents
            _ = parametersByPath
            _ = promptTextByPath
            _ = selectedFolderPath
            _ = stackController.book
            _ = stackController.enabledScopes
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleStackDetection()
                self?.observeStackInputs()
            }
        }
    }

    func scheduleStackDetection() {
        guard let scope = stackScope, stackController.isEnabled(forScope: scope) else {
            if !stackController.stacks.isEmpty { stackController.clearStacks() }
            // Coming back to a stacked listing loads its prompt data again.
            if stackController.promptDataRequestedScope != stackScope { stackController.promptDataRequestedScope = nil }
            return
        }
        // Seeds and prompts come from the per-listing prompt index (parsed once per scope).
        if stackController.promptDataRequestedScope != scope {
            stackController.promptDataRequestedScope = scope
            loadListingPromptDataIfNeeded(force: true)
            Task { await ensurePromptIndexForCurrentListing() }
        }
        stackController.detect(candidates: stackCandidates(), scope: scope) { [weak self] in
            self?.stackScope
        }
    }

    /// The listing's images and videos with what detection can use.
    func stackCandidates() -> [StackCandidate] {
        listingSourceContents.compactMap { entry -> StackCandidate? in
            guard !entry.isDirectory, FileHelpers.isImageFile(entry.name) || FileHelpers.isVideoFile(entry.name) else { return nil }
            let parameters = parametersByPath[entry.path]
            return StackCandidate(
                path: entry.path,
                modified: entry.modifiedDate,
                seed: parameters?.seed,
                prompt: promptTextByPath[entry.path],
                width: parameters?.width,
                height: parameters?.height
            )
        }
    }

    /// The listing pipeline's stack step (called from `processedFolderContents`).
    func applyingStacks(to items: [FileEntry]) -> [FileEntry] {
        let controller = stackController
        guard controller.isEnabled(forScope: stackScope), !controller.stacks.isEmpty else {
            controller.presentation = StackPresentation()
            return items
        }
        let result = StackPresentation.apply(to: items, path: \.path, stacks: controller.stacks, expanded: controller.expanded)
        controller.presentation = result.presentation
        return result.items
    }

    // MARK: Tile info

    /// The stack this listed item stands for (collapsed or expanded), when it's a head.
    func stackHead(for path: String) -> StackPresentation.Head? {
        _ = stackController.revision
        return stackController.presentation.heads[path]
    }

    /// Visible variants behind collapsed stack covers (not counted as filtered out).
    var collapsedStackMemberCount: Int {
        _ = stackController.revision
        return stackController.presentation.heads.values.reduce(0) { $0 + ($1.isExpanded ? 0 : $1.visibleCount - 1) }
    }

    /// True for members shown inline because their stack is expanded.
    func isExpandedStackMember(_ path: String) -> Bool {
        _ = stackController.revision
        return stackController.presentation.expandedMembers[path] != nil
    }

    // MARK: Commands

    func toggleStackingForCurrentListing() {
        guard let scope = stackScope else {
            showToast("Stacks aren't available in this listing", type: .info)
            return
        }
        let enable = !stackController.isEnabled(forScope: scope)
        stackController.setEnabled(enable, forScope: scope)
        if enable { scheduleStackDetection() }
    }

    /// Selected paths with collapsed stacks expanded to their visible members.
    private var stackActionPaths: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in selectedItems where !item.isDirectory {
            var paths = [item.path]
            if let head = stackController.presentation.heads[item.path], !head.isExpanded,
               let stack = stackController.stack(withID: head.stackID)
            {
                paths = [item.path] + stack.members.filter { $0 != item.path }
            }
            for path in paths where seen.insert(path).inserted { result.append(path) }
        }
        return result
    }

    var canStackSelection: Bool {
        stackScope != nil && stackActionPaths.count >= 2
    }

    /// The stack the selection is in (all selected items in the same one).
    var selectedStack: FileStack? {
        let paths = selectedItems.filter { !$0.isDirectory }.map(\.path)
        guard let first = paths.first, let stack = stackController.stack(containing: first) else { return nil }
        guard paths.allSatisfy({ stackController.stack(containing: $0)?.id == stack.id }) else { return nil }
        guard isStackingEnabled else { return nil }
        return stack
    }

    func stackSelection() {
        guard let scope = stackScope else { return }
        let paths = stackActionPaths
        guard paths.count >= 2 else {
            showToast("Select two or more files to stack", type: .info)
            return
        }
        if !stackController.isEnabled(forScope: scope) {
            stackController.setEnabled(true, forScope: scope)
        }
        stackController.updateBook { $0.createStack(paths: paths) }
        showToast("Stacked \(paths.count) files", type: .success)
        scheduleStackDetection()
    }

    func unstackSelection() {
        guard let stack = selectedStack else { return }
        stackController.updateBook { book in
            if let id = stack.manualID { book.dissolve(id: id) } else { book.exclude(stack.members) }
        }
        stackController.setExpanded(false, stackID: stack.id)
        showToast("Unstacked \(stack.count) files", type: .success)
        scheduleStackDetection()
    }

    /// Display-only: the cover implies nothing about which file to keep.
    var canSetSelectionAsStackCover: Bool {
        guard let stack = selectedStack, selectedItems.count == 1, let path = selectedItemPath else { return false }
        return stack.coverPath != path
    }

    func setSelectionAsStackCover() {
        guard let stack = selectedStack, let path = selectedItemPath, stack.members.contains(path) else { return }
        stackController.updateBook { book in
            if let id = stack.manualID {
                book.setCover(path, stackID: id)
            } else {
                // Pinning an automatic stack's cover makes it a manual stack.
                book.createStack(paths: stack.members, coverPath: path)
            }
        }
        showToast("Set as stack cover", type: .success)
        scheduleStackDetection()
    }

    var canRemoveSelectionFromStack: Bool {
        selectedStack != nil
    }

    func removeSelectionFromStack() {
        guard let stack = selectedStack else { return }
        let paths = selectedItems.map(\.path).filter { stack.members.contains($0) }
        guard !paths.isEmpty else { return }
        stackController.updateBook { book in
            for path in paths { book.remove(path) }
        }
        showToast(paths.count == 1 ? "Removed from stack" : "Removed \(paths.count) files from the stack", type: .success)
        scheduleStackDetection()
    }

    func toggleStackExpansion(_ stackID: String) {
        stackController.toggleExpanded(stackID)
    }

    /// View ▸ Expand / Collapse Stack for the selection.
    func toggleSelectedStackExpansion() {
        guard let stack = selectedStack else { return }
        stackController.toggleExpanded(stack.id)
    }

    // MARK: Lightbox

    /// Opening the lightbox on a collapsed stack expands it, so ← / → walk its members;
    /// closing collapses it again unless the lightbox ended on another member.
    func stacksLightboxDidChange(isOpen: Bool) {
        let items = processedFolderContents
        let path = lightboxIndex >= 0 && lightboxIndex < items.count ? items[lightboxIndex].path : nil
        if isOpen {
            guard let path, let head = stackController.presentation.heads[path], !head.isExpanded else { return }
            stackController.lightboxExpandedStackID = head.stackID
            stackController.setExpanded(true, stackID: head.stackID)
        } else if let id = stackController.lightboxExpandedStackID {
            stackController.lightboxExpandedStackID = nil
            let endedOnMember = path.map { stackController.presentation.expandedMembers[$0] == id } ?? false
            if !endedOnMember { stackController.setExpanded(false, stackID: id) }
        }
    }

    // MARK: Moves

    func stacksItemDidMove(from oldPath: String, to newPath: String) {
        stackController.itemDidMove(from: oldPath, to: newPath)
    }
}
