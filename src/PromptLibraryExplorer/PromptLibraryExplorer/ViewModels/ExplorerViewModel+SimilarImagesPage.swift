import AppKit
import Foundation

// MARK: - Similar Images page (Library ▸ Similar Images)
//
// A full-page mode of the main window: the sidebar stays, the content browser
// and details panel are covered by the page. Entering and leaving never touch
// the browser's folder, listing or selection; the one flow that borrows the
// hidden browser (the lightbox walks its listing) puts it back on close.
//
// HARD RULE (user decision): inspection only. Nothing here marks, pre-selects,
// ranks for removal or deletes a file; the page has no trash affordance.

extension ExplorerViewModel {
    var isSimilarImagesPageActive: Bool { similarPage.isActive }

    /// The focused card while the page is up and no lightbox covers it: what
    /// menu commands (Cull, Copy Prompt, Reveal, More Like This…) act on.
    var similarPageTargetPath: String? {
        guard similarPage.isActive, !lightboxOpen else { return nil }
        return similarImages.focusedPath
    }

    /// Folder / root / scope the page's search depends on.
    var similarPageContext: SimilarPageContext {
        SimilarPageContext(
            folderPath: selectedFolderPath?.path,
            rootPath: explorerRootPath?.path,
            scope: visualSearchScope
        )
    }

    // MARK: Enter / leave

    func showSimilarImagesPage() {
        guard explorerRootPath != nil else { return }
        if commandPaletteOpen { commandPaletteOpen = false }
        if QuickLookController.isPanelVisible { QuickLookController.shared.close() }
        guard !similarPage.isActive else { return }
        similarPage.enter()
        similarImages.pruneMissingFiles()
        runSimilarImagesSearch()
    }

    /// Back to the browser, exactly as it was.
    func leaveSimilarImagesPage() {
        similarPage.leave()
        // A lightbox the page asked for that never opened (superseded) is forgotten.
        if !lightboxOpen { similarPageLightboxSession = nil }
    }

    func toggleSimilarImagesPage() {
        if similarPage.isActive {
            leaveSimilarImagesPage()
        } else {
            showSimilarImagesPage()
        }
    }

    /// Results for the current scope and controls: cached ones at once,
    /// otherwise a new search. `force` (Find) always searches again.
    func runSimilarImagesSearch(force: Bool = false) {
        similarImages.show(scope: currentVisualScope, root: explorerRootPath, force: force)
    }

    /// The page saw the folder, root or scope change (sidebar click, back /
    /// forward, the scope control).
    func similarPageContextChanged(from old: SimilarPageContext, to new: SimilarPageContext) {
        guard similarPage.effect(from: old, to: new) == .rerunSearch else { return }
        if !lightboxOpen { similarPageLightboxSession = nil }
        runSimilarImagesSearch()
        if old.rootPath != new.rootPath {
            let root = explorerRootPath
            Task { await similarImages.refreshIndexStats(root: root) }
        }
    }

    // MARK: Keys (owned by `handleGlobalKey` while the page is up)

    func performSimilarPageKey(_ action: SimilarPageKeyAction, isRepeat: Bool) {
        if isRepeat, !action.allowsRepeat { return }
        switch action {
        case .previousGroup: similarImages.moveGroup(by: -1)
        case .nextGroup: similarImages.moveGroup(by: 1)
        case .previousCard: similarImages.moveCard(by: -1)
        case .nextCard: similarImages.moveCard(by: 1)
        case .openLightbox:
            if let path = similarImages.focusedPath { openSimilarPageLightbox(at: path) }
        case .moreLikeThis:
            if let path = similarImages.focusedPath { similarPageMoreLikeThis(path: path) }
        case let .cull(cull):
            guard let path = similarImages.focusedPath else { return }
            applySimilarCardCull(cull, path: path)
            // Culling mode's auto-advance walks the page's cards, never the hidden grid.
            if isCullAutoAdvanceActive { similarImages.moveCard(by: 1) }
        case .leave:
            leaveSimilarImagesPage()
        }
    }

    // MARK: Card and group actions

    func performSimilarCardAction(_ action: SimilarCardAction, path: String) {
        similarImages.focus(path: path)
        switch action {
        case .openInLightbox:
            openSimilarPageLightbox(at: path)
        case .showInFolder:
            // Closes the page (`.fileRevealed`) and opens the file's folder with it selected.
            Task { await revealFile(at: URL(fileURLWithPath: path)) }
        case .revealInFinder:
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        case .moreLikeThis:
            similarPageMoreLikeThis(path: path)
        case .copyPrompt:
            copySimilarCardPrompt(path)
        }
    }

    /// Group header actions. Add to Collection… needs a choice: the page's
    /// menu calls `addPaths(_:toCollection:)` / `createCollection(...)`.
    func performSimilarGroupAction(_ action: SimilarGroupPageAction, on set: SimilarSet) {
        switch action {
        case .selectInBrowser:
            leaveSimilarImagesPage()
            openSimilarGroup(set, selectAll: true)
        case .openAsListing:
            let focused = similarImages.focus.groupID == set.id ? similarImages.focusedPath : nil
            leaveSimilarImagesPage()
            openSimilarGroup(set, selecting: focused ?? set.paths.first)
        case .addToCollection:
            break
        }
    }

    /// P X U 0–9 (or the card's Flag / Rating / Label menus) on one card.
    func applySimilarCardCull(_ action: CullAction, path: String) {
        similarImages.focus(path: path)
        apply(action, to: [similarImages.entry(for: path)])
    }

    /// More Like This for a card: the ranked listing opens in the browser.
    func similarPageMoreLikeThis(path: String) {
        showMoreLikeThis(for: similarImages.entry(for: path))
    }

    func copySimilarCardPrompt(_ path: String) {
        let name = URL(fileURLWithPath: path).lastPathComponent
        Task {
            let prompt = await similarImages.prompt(for: path)
            guard !prompt.isEmpty else {
                showToast("\"\(name)\" has no prompt", type: .info)
                return
            }
            ClipboardService.copyString(prompt)
            showToast("Prompt copied", type: .success)
        }
    }

    // MARK: Lightbox (borrows the hidden browser)

    /// Opens `path` in the lightbox, walking its group. The lightbox steps
    /// through the browser's listing, so the group becomes the (hidden)
    /// browser's listing until the lightbox closes; then the browser's
    /// listing and selection are put back and focus returns to the page.
    func openSimilarPageLightbox(at path: String) {
        guard similarPage.isActive, !lightboxOpen,
              let set = similarImages.sets.first(where: { $0.paths.contains(path) })
        else { return }
        similarImages.focus(path: path)
        // A restore still in flight holds the real browser state.
        let snapshot = similarPagePendingRestore ?? SimilarPageBrowserSnapshot(
            listing: listingModeState,
            smartFolderID: activeSmartFolder?.id,
            selectedPaths: selectedPaths,
            primaryPath: selectedItemPath
        )
        similarPagePendingRestore = snapshot
        let listing = similarGroupListing(set)
        similarPageLightboxSession = SimilarPageLightboxSession(snapshot: snapshot, groupListingID: listing.id)
        openVirtualListing(listing, openLightboxAt: path) { [weak self] in
            guard let self, !self.lightboxOpen,
                  self.similarPageLightboxSession?.groupListingID == listing.id
            else { return }
            // The file didn't open (a browser filter hides it): put everything back.
            self.similarPageLightboxSession = nil
            self.showToast("A filter in the browser hides \"\(URL(fileURLWithPath: path).lastPathComponent)\"", type: .info)
            self.restoreBrowser(from: snapshot)
        }
    }

    /// Called when the lightbox closes (`lightboxOpen` didSet).
    func similarPageLightboxDidClose() {
        guard let session = similarPageLightboxSession else { return }
        similarPageLightboxSession = nil
        let items = processedFolderContents
        let lastPath = lightboxIndex >= 0 && lightboxIndex < items.count ? items[lightboxIndex].path : nil

        guard activeVirtualListing?.id == session.groupListingID else {
            // Moved on inside the lightbox (More Like This): the browser keeps
            // the new listing, and the page makes way for it.
            similarPagePendingRestore = nil
            leaveSimilarImagesPage()
            return
        }
        if let lastPath { similarImages.focus(path: lastPath) }
        restoreBrowser(from: session.snapshot)
    }

    /// Puts the browser's listing, smart folder and selection back.
    func restoreBrowser(from snapshot: SimilarPageBrowserSnapshot) {
        similarPagePendingRestore = snapshot
        let finish: () -> Void = { [weak self] in
            guard let self else { return }
            if self.similarPagePendingRestore == snapshot { self.similarPagePendingRestore = nil }
            if self.activeSmartFolder?.id != snapshot.smartFolderID {
                self.activeSmartFolder = snapshot.smartFolderID.flatMap { id in
                    self.smartFolders.first { $0.id == id }
                }
            }
            self.applySelection(paths: snapshot.selectedPaths, primary: snapshot.primaryPath)
        }
        let wasRestoring = isRestoringBrowserForSimilarPage
        isRestoringBrowserForSimilarPage = true
        defer { isRestoringBrowserForSimilarPage = wasRestoring }
        switch snapshot.restoreStep(from: listingModeState) {
        case .none:
            finish()
        case .closeVirtualListing:
            closeVirtualListing(then: finish)
        case let .openVirtual(listing):
            openVirtualListing(listing, then: finish)
        case let .openCollection(id):
            openCollection(id, then: finish)
        }
    }

    /// Selects `paths` (those still listed), `primary` as the primary item.
    func applySelection(paths: [String], primary: String?) {
        let items = processedFolderContents
        var indexByPath: [String: Int] = [:]
        for (index, item) in items.enumerated() { indexByPath[item.path] = index }
        let indices = paths.compactMap { indexByPath[$0] }
        guard let first = primary.flatMap({ indexByPath[$0] }) ?? indices.first else {
            clearSelection()
            return
        }
        selectItem(at: first)
        if indices.count > 1 {
            selectedIndices = Set(indices).union([first])
            syncQuickLookWithSelection()
        }
    }
}
