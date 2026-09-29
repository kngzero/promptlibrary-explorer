import AppKit

// MARK: - Video & audio tools glue (state lives in MediaController)

extension ExplorerViewModel {
    /// Connects MediaController's toasts and "files written" events to this model.
    /// Idempotent; called by the media sheets host when the window appears.
    func installMediaHooks() {
        let media = MediaController.shared
        media.toast = { [weak self] message, type in self?.showToast(message, type: type) }
        media.willOpenTrim = { [weak self] in
            guard let self else { return }
            // The Trim page covers the browser like the image editor: nothing else stays over it.
            if self.commandPaletteOpen { self.commandPaletteOpen = false }
            if QuickLookController.isPanelVisible { QuickLookController.shared.close() }
            if self.isComparePageActive { self.closeComparePage() }
            if self.lightboxOpen { self.lightboxOpen = false }
            ModalKeyGuard.mainBrowserWindow?.makeFirstResponder(nil)
        }
        media.didWriteFiles = { [weak self] urls in
            guard let self else { return }
            let folder = self.selectedFolderPath?.standardizedFileURL.path
            // Only a folder on screen needs to re-list; other folders pick it up when opened.
            if let folder, urls.contains(where: { $0.deletingLastPathComponent().standardizedFileURL.path == folder }) {
                Task { await self.refreshFolder() }
            }
        }
    }

    /// The video the media commands act on: the lightbox item while it's open,
    /// otherwise the single selected file.
    var mediaTargetVideo: FileEntry? {
        if lightboxOpen {
            guard lightboxIndex >= 0, lightboxIndex < processedFolderContents.count else { return nil }
            let item = processedFolderContents[lightboxIndex]
            return FileHelpers.isVideoFile(item.name) ? item : nil
        }
        let files = selectedFileItems
        guard files.count == 1, let item = files.first, FileHelpers.isVideoFile(item.name) else { return nil }
        return item
    }

    /// Selected videos (or the lightbox video) for Save Middle Frame.
    var mediaTargetVideos: [FileEntry] {
        if lightboxOpen { return mediaTargetVideo.map { [$0] } ?? [] }
        return selectedFileItems.filter { FileHelpers.isVideoFile($0.name) }
    }

    var canSaveMiddleFrame: Bool {
        !mediaTargetVideos.isEmpty && !MediaController.shared.isSavingFrame
    }

    var canTrimVideo: Bool {
        mediaTargetVideo != nil && !MediaController.shared.isExporting
    }

    func saveMiddleFramesForTarget() {
        MediaController.shared.saveMiddleFrames(of: mediaTargetVideos.map(\.url))
    }

    /// Save Middle Frame from a context menu: the right-clicked item, or every selected
    /// video when it's part of the selection.
    func saveMiddleFrames(for item: FileEntry) {
        let targets = selectedPaths.contains(item.path)
            ? selectedFileItems.filter { FileHelpers.isVideoFile($0.name) }
            : [item]
        MediaController.shared.saveMiddleFrames(of: targets.map(\.url))
    }

    func openTrimForTarget() {
        guard let item = mediaTargetVideo else {
            showToast("Select one video to trim", type: .info)
            return
        }
        MediaController.shared.openTrim(for: item.url)
    }

    /// Trim & Export Clip… (video) or Trim & Export Audio… (audio files).
    func openTrim(for item: FileEntry) {
        guard FileHelpers.isVideoFile(item.name) || FileHelpers.isAudioFile(item.name) else { return }
        MediaController.shared.openTrim(for: item.url)
    }

    // MARK: Trim page

    var isTrimPageActive: Bool { MediaController.shared.trimSession != nil }

    /// Keys on the Trim page: Esc closes, Space plays the range, ← / → step a
    /// frame (a tenth of a second for audio), I / O set the in and out points.
    /// The browser's bare keys stop here.
    func handleTrimPageKey(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard let session = MediaController.shared.trimSession else { return false }
        if modifiers.contains(.command) || modifiers.contains(.control) || modifiers.contains(.option) { return false }
        switch keyCode {
        case KeyCode.escape.rawValue:
            MediaController.shared.closeTrim()
            return true
        case KeyCode.space.rawValue:
            session.togglePlay()
            return true
        case KeyCode.leftArrow.rawValue:
            session.nudge(by: modifiers.contains(.shift) ? -10 : -1)
            return true
        case KeyCode.rightArrow.rawValue:
            session.nudge(by: modifiers.contains(.shift) ? 10 : 1)
            return true
        case KeyCode.upArrow.rawValue, KeyCode.downArrow.rawValue, KeyCode.returnKey.rawValue,
             KeyCode.delete.rawValue, KeyCode.forwardDelete.rawValue:
            return true
        default:
            break
        }
        switch characters?.lowercased() {
        case "i": session.setIn(); return true
        case "o": session.setOut(); return true
        default: break
        }
        if let characters, CullAction(keyCharacters: characters) != nil { return true }
        if VisualSearchKeys.isMoreLikeThis(characters: characters, modifiers: modifiers) { return true }
        return false
    }
}
