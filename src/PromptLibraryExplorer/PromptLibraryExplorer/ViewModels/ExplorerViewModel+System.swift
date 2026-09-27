import AppKit
import CoreSpotlight
import Foundation

// MARK: - System integration glue

/// Spotlight results, `promptlibrary://` links, Shortcuts and cloud placeholders.
/// State lives in `SpotlightController`, `CloudFileController` and
/// `PromptLibraryAutomation`; this only connects them to the browser.
extension ExplorerViewModel {
    /// Once, when the main window's view model is ready (App file).
    func configureSystemIntegration() {
        PromptLibraryAutomation.viewModel = self
        let cloud = CloudFileController.shared
        cloud.onDownloaded = { [weak self] paths in
            guard let self else { return }
            // Same path as an outside edit: per-path cache drop, and the primary
            // item's details (lightbox image) reload.
            Task { await self.refreshListingForExternalChanges(removed: [], added: [], modified: paths) }
        }
        cloud.onMessage = { [weak self] message, type in
            self?.showToast(message, type: type)
        }
        SpotlightController.shared.start()
    }

    // MARK: promptlibrary:// links

    func handleAutomationURL(_ url: URL) async {
        switch AutomationURL.parse(url) {
        case .failure(let error):
            showToast(error.localizedDescription, type: .error)
        case .success(let action):
            await perform(action)
        }
    }

    func perform(_ action: AutomationURLAction) async {
        guard !isModalBlockingCommands else {
            showToast("Close the open dialog, then try the link again", type: .info)
            return
        }
        switch action {
        case .open(let path):
            guard FileManager.default.fileExists(atPath: path) else {
                showToast("\u{201C}\((path as NSString).lastPathComponent)\u{201D} doesn't exist", type: .error)
                return
            }
            lightboxOpen = false
            await openExternalURLs([URL(fileURLWithPath: path)])
        case .search(let query):
            lightboxOpen = false
            librarySearchQuery = query
            librarySearchOpen = true
            runLibrarySearch()
        case .collection(let name):
            let all = CollectionService.shared.all()
            collections = all
            guard let id = AutomationCollectionMatcher.match(name, in: all.map { (id: $0.id, name: $0.name) }) else {
                showToast("There's no collection named \u{201C}\(name)\u{201D}", type: .error)
                return
            }
            lightboxOpen = false
            if isSimilarImagesPageActive { leaveSimilarImagesPage() }
            openCollection(id)
        }
    }

    // MARK: Spotlight results

    /// A Spotlight result was opened: its identifier is the file's path.
    func handleSpotlightActivity(_ activity: NSUserActivity) {
        guard activity.activityType == CSSearchableItemActionType,
              let path = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String
        else { return }
        guard SpotlightActivationDeduper.shouldHandle(path) else { return }
        lightboxOpen = false
        Task { await revealFile(at: URL(fileURLWithPath: path)) }
    }

    // MARK: Cloud placeholders

    /// Online-only files among `items` (live: downloads in this session count as local).
    func cloudOnlyItems(in items: [FileEntry]) -> [FileEntry] {
        items.filter { CloudFileController.shared.isCloudOnly($0) }
    }

    func downloadCloudFiles(_ items: [FileEntry]) {
        CloudFileController.shared.download(cloudOnlyItems(in: items).map(\.url))
    }

    func makeCloudFilesAvailableOffline(_ items: [FileEntry]) {
        let files = items.filter { !$0.isDirectory }
        CloudFileController.shared.makeAvailableOffline(files.map(\.url))
    }
}

/// The App delegate and SwiftUI's `onContinueUserActivity` can both see one Spotlight
/// activation; the second within two seconds is dropped.
@MainActor
enum SpotlightActivationDeduper {
    private static var last: (path: String, date: Date)?

    static func shouldHandle(_ path: String, now: Date = Date()) -> Bool {
        if let last, last.path == path, now.timeIntervalSince(last.date) < 2 { return false }
        last = (path, now)
        return true
    }
}
