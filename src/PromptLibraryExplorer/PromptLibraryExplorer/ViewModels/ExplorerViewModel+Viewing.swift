import AppKit
import Foundation

// MARK: - Viewing tools: Compare Images, slideshow (glue)
//
// State lives in `ViewingController.shared`; this is the view model's side:
// what the targets are, when the commands are available, and the actions.
// Inspection only — nothing here marks, suggests or performs deletion.

extension ExplorerViewModel {
    var viewing: ViewingController { .shared }

    // MARK: Compare page

    /// The Similar Images page always wins (it closes the Compare page).
    var isComparePageActive: Bool { viewing.comparePage != nil && !isSimilarImagesPageActive }

    var comparePageModel: CompareCanvasModel? { viewing.comparePage }

    /// Folder / collection / smart folder / virtual listing: a change means
    /// the user navigated, and the Compare page makes way for the browser.
    var comparePageNavigationKey: String {
        [
            selectedFolderPath?.path ?? "",
            activeCollectionID?.uuidString ?? "",
            activeSmartFolder?.id.uuidString ?? "",
            activeVirtualListing?.id.uuidString ?? "",
        ].joined(separator: "|")
    }

    /// 2–4 selected images / videos (a video compares as a frame).
    var compareSelectionPaths: [String]? {
        CompareEligibility.paths(for: selectedItems)
    }

    /// View ▸ Compare Images is available: a 2–4 file selection in the
    /// browser, or a group on the Similar Images page (inline compare).
    var canCompareImages: Bool {
        if isSimilarImagesPageActive { return (similarImages.selectedSet?.paths.count ?? 0) >= CompareEligibility.minimumCount }
        guard explorerRootPath != nil, !lightboxOpen else { return false }
        return compareSelectionPaths != nil
    }

    /// View ▸ Compare Images: the Compare page for the selection, or on the
    /// Similar Images page the group's inline compare (toggles).
    func compareImagesCommand() {
        if isSimilarImagesPageActive {
            viewing.similarPageCompare.toggle()
            return
        }
        guard let paths = compareSelectionPaths else {
            showToast("Select 2 to 4 images or videos to compare", type: .info)
            return
        }
        openComparePage(paths: paths)
    }

    func openComparePage(paths: [String]) {
        guard !lightboxOpen, !isSimilarImagesPageActive else { return }
        if commandPaletteOpen { commandPaletteOpen = false }
        if QuickLookController.isPanelVisible { QuickLookController.shared.close() }
        viewing.showComparePage(paths: paths)
    }

    func closeComparePage() {
        viewing.closeComparePage()
    }

    /// Keys while the Compare page is up (from `handleGlobalKey`). Esc closes
    /// it; the browser's own bare keys (arrows, Return, Space, Delete,
    /// ⇧Delete, culling keys, M) are swallowed so nothing reaches the hidden
    /// grid. Anything with ⌘ / ⌃ / ⌥ passes through to the menus.
    func handleComparePageKey(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard isComparePageActive else { return false }
        if modifiers.contains(.command) || modifiers.contains(.control) || modifiers.contains(.option) { return false }
        switch keyCode {
        case KeyCode.escape.rawValue:
            closeComparePage()
            return true
        case KeyCode.leftArrow.rawValue, KeyCode.rightArrow.rawValue, KeyCode.upArrow.rawValue, KeyCode.downArrow.rawValue,
             KeyCode.returnKey.rawValue, KeyCode.space.rawValue, KeyCode.delete.rawValue, KeyCode.forwardDelete.rawValue:
            return true
        default:
            break
        }
        if let characters, CullAction(keyCharacters: characters) != nil { return true }
        if VisualSearchKeys.isMoreLikeThis(characters: characters, modifiers: modifiers) { return true }
        return false
    }

    /// A pane's menu (Reveal in Finder, Copy Path, Copy Prompt).
    func performCompareAction(_ action: CompareImageAction, path: String) {
        switch action {
        case .revealInFinder:
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        case .copyPath:
            ClipboardService.copyString(path)
            showToast("Path copied", type: .success)
        case .copyPrompt:
            let name = URL(fileURLWithPath: path).lastPathComponent
            Task {
                let prompt = await SimilarImagesModel.readPrompt(atPath: path)
                guard !prompt.isEmpty else {
                    showToast("\"\(name)\" has no prompt", type: .info)
                    return
                }
                ClipboardService.copyString(prompt)
                showToast("Prompt copied", type: .success)
            }
        }
    }

    // MARK: Slideshow

    /// What View ▸ Start Slideshow plays: the Similar Images page's group, a
    /// 2+ file selection, or the current listing (folder, collection or
    /// virtual listing, filters applied, in listing order).
    var slideshowPlan: (slides: [FileEntry], start: Int) {
        let includeVideos = viewing.slideshowOptions.includeVideos
        if isSimilarImagesPageActive {
            guard let set = similarImages.selectedSet else { return ([], 0) }
            let entries = set.paths.map { similarImages.entry(for: $0) }
            let focused = similarImages.focusedPath.map { [$0] } ?? []
            return SlideshowEligibility.slides(listing: entries, selectedPaths: focused, includeVideos: includeVideos)
        }
        return SlideshowEligibility.slides(
            listing: processedFolderContents,
            selectedPaths: selectedPaths,
            includeVideos: includeVideos
        )
    }

    /// Cheap check for menus (no plan is built).
    var canStartSlideshow: Bool {
        guard explorerRootPath != nil, !viewing.isSlideshowRunning else { return false }
        if isSimilarImagesPageActive { return similarImages.selectedSet != nil }
        let includeVideos = viewing.slideshowOptions.includeVideos
        return processedFolderContents.contains { SlideshowEligibility.isEligible($0, includeVideos: includeVideos) }
    }

    func startSlideshow() {
        let plan = slideshowPlan
        guard !plan.slides.isEmpty else {
            showToast("Nothing to show: no images in this listing", type: .info)
            return
        }
        if QuickLookController.isPanelVisible { QuickLookController.shared.close() }
        let screen = ModalKeyGuard.mainBrowserWindow?.screen ?? NSScreen.main
        viewing.startSlideshow(slides: plan.slides, start: plan.start, on: screen) { [weak self] path in
            self?.rating(for: path) ?? 0
        }
    }
}
