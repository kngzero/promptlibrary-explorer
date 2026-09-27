import AppKit
import Foundation

// MARK: - Non-destructive image editor (glue)
//
// State lives in `EditController.shared` (recipes + the open session); this is the view
// model's side: targets, availability, the page's keys, undoable saves / reverts and
// Save Edited Copy…. Originals are never modified.

extension ExplorerViewModel {
    var editController: EditController {
        let controller = EditController.shared
        if controller.onRecipesChanged == nil {
            controller.onRecipesChanged = { [weak self] paths in self?.editRecipesDidChange(paths) }
        }
        return controller
    }

    var editorSession: EditorSession? { editController.session }

    /// The editor page covers the browser and details columns.
    var isEditorPageActive: Bool { editController.session != nil }

    // MARK: Targets

    /// What Edit ▸ Edit Image… acts on: the lightbox's file, else the one selected file.
    var editTargetItem: FileEntry? {
        if lightboxOpen {
            guard lightboxIndex >= 0, lightboxIndex < processedFolderContents.count else { return nil }
            return processedFolderContents[lightboxIndex]
        }
        guard !isSimilarImagesPageActive, !isComparePageActive else { return nil }
        let files = selectedFileItems
        return files.count == 1 ? files.first : nil
    }

    var canEditImage: Bool {
        guard !isEditorPageActive, let item = editTargetItem else { return false }
        return EditEligibility.isEditable(item.name)
    }

    /// Why Edit Image… is unavailable for the target (menu title suffix), or nil.
    var editImageUnavailableReason: String? {
        guard !isEditorPageActive, let item = editTargetItem else { return nil }
        return EditEligibility.reason(forName: item.name)
    }

    /// Edited files among the selection (or the lightbox's file).
    var editedTargetPaths: [String] {
        if lightboxOpen || isEditorPageActive {
            guard let path = editTargetItem?.path, editController.isEdited(path) else { return [] }
            return [path]
        }
        return selectedFileItems.map(\.path).filter { editController.isEdited($0) }
    }

    // MARK: Open / close

    func openEditImageForTarget() {
        guard let item = editTargetItem else {
            showToast("Select one image to edit", type: .info)
            return
        }
        openEditor(for: item)
    }

    func openEditor(for item: FileEntry) {
        guard !item.isDirectory, EditEligibility.isEditable(item.name) else {
            showToast(EditEligibility.reason(forName: item.name) ?? "This file can't be edited", type: .info)
            return
        }
        guard CloudFileStatus.isLocallyAvailable(item.url) else {
            showToast("Download “\(item.name)” first: it's online only", type: .info)
            return
        }
        if let current = editController.session {
            guard current.path != item.path else { return }
            guard confirmDiscard(current) else { return }
            editController.session = nil
        }
        let fromLightbox = lightboxOpen
        if commandPaletteOpen { commandPaletteOpen = false }
        if QuickLookController.isPanelVisible { QuickLookController.shared.close() }
        if isComparePageActive { closeComparePage() }
        if fromLightbox { lightboxOpen = false }

        let session = EditorSession(path: item.path, savedRecipe: editController.recipe(for: item.path))
        session.returnToLightbox = fromLightbox
        editController.session = session
        // Nothing in the covered browser keeps keyboard focus.
        ModalKeyGuard.mainBrowserWindow?.makeFirstResponder(nil)
        // The page (EditorPageView) loads the working copy.
    }

    /// Done (`save`) or a confirmed Cancel. Saving records one undoable history step.
    func closeEditor(save: Bool) {
        guard let session = editController.session else { return }
        session.cancelRender()
        if save, session.isDirty {
            let recipe = session.recipe.normalized()
            let reverted = recipe.isIdentity
            writeEditRecipes([session.path: reverted ? nil : recipe], title: reverted ? "Revert to Original" : "Edit Image")
            showToast(reverted ? "Reverted “\(session.name)” to the original" : "Saved the edit to “\(session.name)” (the file is unchanged)", type: .success)
        }
        editController.session = nil
        editController.clearShowOriginal(session.path)
        ModalKeyGuard.mainBrowserWindow?.makeFirstResponder(nil)
        if session.returnToLightbox, let index = processedFolderContents.firstIndex(where: { $0.path == session.path }) {
            lightboxIndex = index
            selectItem(at: index)
            lightboxOpen = true
        }
    }

    /// Esc / Cancel: closes, asking first when there are unsaved changes.
    func requestCancelEditor() {
        guard let session = editController.session else { return }
        guard confirmDiscard(session) else { return }
        closeEditor(save: false)
    }

    private func confirmDiscard(_ session: EditorSession) -> Bool {
        guard session.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Discard Your Changes to “\(session.name)”?"
        alert.informativeText = "The edits you made in this session will be lost. The file itself is never changed either way."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Keep Editing")
        alert.addButton(withTitle: "Discard Changes")
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// Keys while the editor page is up (from `handleGlobalKey`). Esc cancels (asking
    /// when dirty); the browser's bare keys are swallowed so nothing reaches the hidden
    /// grid. Anything with ⌘ / ⌃ / ⌥ passes through to the menus (⌘Z undoes in the session).
    func handleEditorPageKey(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard isEditorPageActive else { return false }
        if modifiers.contains(.command) || modifiers.contains(.control) || modifiers.contains(.option) { return false }
        switch keyCode {
        case KeyCode.escape.rawValue:
            // After the key event: the confirmation alert runs a modal loop.
            DispatchQueue.main.async { [weak self] in self?.requestCancelEditor() }
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

    // MARK: Undoable writes

    /// Writes recipes (nil = revert) as one step in the app's undo history.
    func writeEditRecipes(_ values: [String: EditRecipe?], title: String) {
        let replaced = editController.apply(values)
        guard !replaced.isEmpty else { return }
        recordFolderHistoryEntry(makeEditHistoryEntry(replaced, title: title))
    }

    private func makeEditHistoryEntry(_ values: [String: EditRecipe?], title: String) -> FolderHistoryEntry {
        FolderHistoryEntry(title: title) { [weak self] in
            guard let self else { return ExplorerViewModel.releasedHistoryResult(count: values.count) }
            let replaced = self.editController.apply(values)
            return FolderHistoryApplyResult(
                inverse: replaced.isEmpty ? nil : self.makeEditHistoryEntry(replaced, title: title),
                remaining: nil,
                appliedCount: values.count,
                failedCount: 0,
                firstError: nil
            )
        }
    }

    func revertToOriginal(paths: [String]) {
        let edited = paths.filter { editController.isEdited($0) }
        guard !edited.isEmpty else { return }
        writeEditRecipes(Dictionary(edited.map { ($0, EditRecipe?.none) }, uniquingKeysWith: { first, _ in first }), title: "Revert to Original")
        showToast(edited.count == 1 ? "Reverted to the original" : "Reverted \(edited.count) images to the original", type: .success)
    }

    func revertTargetsToOriginal() {
        revertToOriginal(paths: editedTargetPaths)
    }

    // MARK: Save Edited Copy…

    var canSaveEditedCopy: Bool {
        guard let item = editTargetItem, !isEditorPageActive else { return false }
        return editController.isEdited(item.path)
    }

    func saveEditedCopyForTarget() {
        guard let item = editTargetItem else { return }
        saveEditedCopy(of: item)
    }

    /// Writes the edited image as a new file beside the original (never overwriting),
    /// with the original's prompt metadata unless the user picks "Strip AI metadata".
    func saveEditedCopy(of item: FileEntry) {
        guard let recipe = editController.recipe(for: item.path) else {
            showToast("“\(item.name)” has no edits to save", type: .info)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Save an Edited Copy of “\(item.name)”?"
        alert.informativeText = "A new file is written next to the original. The original and its metadata stay exactly as they are."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26), pullsDown: false)
        popup.addItems(withTitles: ["Keep prompt metadata", "Strip AI metadata (for sharing)"])
        alert.accessoryView = popup
        alert.addButton(withTitle: "Save Copy")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let strip = popup.indexOfSelectedItem == 1
        let url = item.url
        Task {
            do {
                let written = try await Task.detached(priority: .userInitiated) {
                    try await EditCopyWriter.write(source: url, recipe: recipe, stripAIMetadata: strip)
                }.value
                refreshAfterExport(folders: [written.deletingLastPathComponent().standardizedFileURL.path])
                showToast("Saved “\(written.lastPathComponent)”", type: .success)
            } catch {
                showToast(error.localizedDescription, type: .error)
            }
        }
    }

    // MARK: Refresh

    /// Recipes changed (save, undo, sync, import): the details / lightbox preview of an
    /// affected file re-renders. Grid and list thumbnails follow `EditController.token`.
    func editRecipesDidChange(_ paths: Set<String>) {
        guard let entry = selectedPromptEntry, let path = entry.sourcePath, paths.contains(path),
              entry.artOfficialDocument == nil, FileHelpers.isImageFile((path as NSString).lastPathComponent)
        else { return }
        Task {
            let image = await ThumbnailService.shared.previewImage(for: URL(fileURLWithPath: path))
            guard let image, self.selectedPromptEntry?.sourcePath == path else { return }
            self.selectedPromptEntry?.images = [image]
        }
    }
}
