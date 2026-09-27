import Foundation

// MARK: - Video & audio tools glue (state lives in MediaController)

extension ExplorerViewModel {
    /// Connects MediaController's toasts and "files written" events to this model.
    /// Idempotent; called by the media sheets host when the window appears.
    func installMediaHooks() {
        let media = MediaController.shared
        media.toast = { [weak self] message, type in self?.showToast(message, type: type) }
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

    func openTrim(for item: FileEntry) {
        guard FileHelpers.isVideoFile(item.name) else { return }
        MediaController.shared.openTrim(for: item.url)
    }
}
