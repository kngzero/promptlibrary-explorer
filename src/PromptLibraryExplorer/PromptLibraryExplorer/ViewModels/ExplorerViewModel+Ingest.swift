import AppKit
import Foundation

// MARK: - Live folder updates and the ingest inbox
//
// State lives in FolderWatcherController (FSEvents on the open library) and
// IngestController (watched sources, rules, Inbox, log). This is the glue: it
// turns their batches into incremental listing refreshes, undoable moves,
// curation reloads and the Inbox virtual listing. Nothing here deletes a file.

extension ExplorerViewModel: IngestHost {
    func installIngestHooks() {
        FolderWatcherController.shared.onChanges = { [weak self] set in
            await self?.applyLiveFolderChanges(set)
        }
        IngestController.shared.host = self
        IngestController.shared.start()
    }

    /// A library root opened: watch it for outside changes.
    func liveUpdatesRootDidOpen(_ root: URL) {
        FolderWatcherController.shared.watch(root: root)
    }

    // MARK: Live updates

    /// Folds one batch of outside changes into the current listing: only paths the
    /// listing shows (or that belong in the open folder) are refreshed, and files
    /// whose size and date already match what's listed (the app's own writes) are
    /// skipped.
    func applyLiveFolderChanges(_ set: FolderLiveChangeSet) async {
        if set.needsFullRefresh {
            await refreshFolder()
            return
        }
        let plan = LiveListingChangePlan.make(
            set: set,
            listed: listingSourceContents,
            folderPath: isFolderListing ? selectedFolderPath?.standardizedFileURL.path : nil,
            sidebarFolderPaths: sidebarFolderPathSet
        )
        if plan.isEmpty {
            if plan.folderTreeChanged { await refreshFolderTreeForExternalChanges() }
            return
        }
        await refreshListingForExternalChanges(removed: plan.removed, added: plan.added, modified: plan.modified)
    }

    /// Every folder in the sidebar tree (to notice folders removed from outside).
    var sidebarFolderPathSet: Set<String> {
        var result = Set<String>()
        func walk(_ nodes: [FileEntry]) {
            for node in nodes where node.isDirectory {
                result.insert(node.url.standardizedFileURL.path)
                if let children = node.children { walk(children) }
            }
        }
        walk(folderTree)
        return result
    }

    // MARK: IngestHost

    var ingestLibraryRoot: URL? { explorerRootPath }

    func ingestDidPerform(moves: [(from: URL, to: URL)], copies: [URL]) async {
        await recordIngestFileOperations(moves: moves, copies: copies, title: "Ingest")
    }

    func ingestDidChangeCuration() {
        reloadCurationStateFromStores()
    }

    func ingestInboxDidChange() {
        guard let listing = activeVirtualListing, case let .inbox(sourceID) = listing.kind else { return }
        let paths = IngestController.shared.inboxPaths(sourceID: sourceID)
        guard paths != listing.paths else { return }
        var next = listing
        next.paths = paths
        activeVirtualListing = next
        Task { await reloadVirtualListingContents() }
    }

    func ingestShowToast(_ message: String, type: ToastType) {
        showToast(message, type: type)
    }

    // MARK: Inbox listing

    var isInboxListingActive: Bool {
        if case .inbox = activeVirtualListing?.kind { return true }
        return false
    }

    /// Shows the Inbox (all sources, or one) as a virtual listing, newest first.
    func openInbox(sourceID: UUID? = nil) {
        let controller = IngestController.shared
        let paths = controller.inboxPaths(sourceID: sourceID)
        let title = sourceID.flatMap { controller.source(id: $0)?.name }.map { "Inbox — \($0)" } ?? "Inbox"
        if paths.isEmpty {
            showToast("Nothing new in the last 7 days", type: .info)
        }
        openVirtualListing(VirtualListing(kind: .inbox(sourceID: sourceID), title: title, paths: paths))
    }

    func markInboxSeen() {
        IngestController.shared.markAllSeen()
    }

    func showIngestLog() {
        IngestController.shared.logSheetOpen = true
    }

    /// Settings ▸ Ingest.
    func openIngestSettings() {
        UserDefaults.standard.set(SettingsPage.ingest.rawValue, forKey: SettingsView.selectedPageKey)
        openSettings()
    }
}

/// Which outside changes touch the current listing (pure, so it can be tested).
struct LiveListingChangePlan: Equatable {
    var removed: [String] = []
    var added: [String] = []
    var modified: [String] = []
    var folderTreeChanged = false

    var isEmpty: Bool { removed.isEmpty && added.isEmpty && modified.isEmpty }

    /// - Parameters:
    ///   - listed: the listing's entries (folder contents, a collection or a virtual listing).
    ///   - folderPath: the open folder when the listing is a folder (new files there are
    ///     added); nil for collections and virtual listings (only listed files refresh).
    static func make(
        set: FolderLiveChangeSet,
        listed: [FileEntry],
        folderPath: String?,
        sidebarFolderPaths: Set<String>
    ) -> LiveListingChangePlan {
        var plan = LiveListingChangePlan()
        let byPath = Dictionary(listed.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        func isDirectChild(_ path: String) -> Bool {
            guard let folderPath else { return false }
            return (path as NSString).deletingLastPathComponent == folderPath
        }

        for path in set.removed {
            if byPath[path] != nil { plan.removed.append(path) }
            if sidebarFolderPaths.contains(path) { plan.folderTreeChanged = true }
        }
        for path in set.changedDirectories {
            plan.folderTreeChanged = true
            if byPath[path] == nil, isDirectChild(path) { plan.added.append(path) }
        }
        for (path, snapshot) in set.changedFiles.sorted(by: { $0.key < $1.key }) {
            if let entry = byPath[path] {
                let sameSize = entry.fileSize == snapshot.size
                let sameDate = entry.modifiedDate.map { abs($0.timeIntervalSince1970 - snapshot.mtime) < 0.001 } ?? false
                if !(sameSize && sameDate) { plan.modified.append(path) }
            } else if isDirectChild(path) {
                plan.added.append(path)
            }
        }
        return plan
    }
}
