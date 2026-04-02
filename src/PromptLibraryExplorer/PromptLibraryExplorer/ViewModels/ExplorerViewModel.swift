import AppKit
import Foundation
import Observation

struct DeleteConfirmationRequest: Identifiable {
    let id = UUID()
    let urls: [URL]
    let names: [String]

    var title: String {
        urls.count == 1 ? "Delete Permanently?" : "Delete \(urls.count) Items Permanently?"
    }

    var message: String {
        if names.count == 1, let name = names.first {
            return "\"\(name)\" will be deleted immediately. This action cannot be undone."
        }
        return "These \(urls.count) items will be deleted immediately. This action cannot be undone."
    }
}

private struct PathMoveRecord {
    let from: URL
    let to: URL
}

private struct TrashRestoreRecord {
    let trashedURL: URL
    let originalURL: URL
}

private struct FolderHistoryEntry {
    let title: String
    let apply: @MainActor () async throws -> FolderHistoryEntry
}

private enum FolderHistoryError: LocalizedError {
    case viewModelReleased

    var errorDescription: String? {
        switch self {
        case .viewModelReleased:
            return "The file history is no longer available."
        }
    }
}

/// Root view model managing folder navigation, selection, and file operations.
@Observable
@MainActor
final class ExplorerViewModel {
    // MARK: - State

    var explorerRootPath: URL?
    var folderTree: [FileEntry] = []
    var selectedFolderPath: URL?
    var folderContents: [FileEntry] = []
    var isLoadingFolder = false

    // Sort & Filter
    var sortConfig = SortConfig()
    var filterConfig = FilterConfig()
    var searchQuery = ""
    private var customOrderByFolder: [String: [String]] = [:]
    private var ratingsByPath: [String: Int] = [:]
    private var lastStandardSortConfigByFolder: [String: SortConfig] = [:]
    private var collapsedSidebarFolderPaths: Set<String> = []
    private var previousSidebarCollapsedFolderPaths: Set<String>?

    // Selection
    var selectedItemIndex: Int = -1
    var selectedIndices: Set<Int> = []
    var selectionAnchorIndex: Int?
    var selectedPromptEntry: PromptEntry?
    var activePane: ExplorerPane = .content
    var gridColumnCount: Int = 1
    var sidebarContentRowHint: Int = 0
    var showStatusBar = true
    var appearanceMode: AppAppearanceMode = .dark

    // UI State
    var thumbnailSize: Double = 5
    var thumbnailsOnly = false
    var lightboxOpen = false
    var lightboxIndex: Int = 0
    var toastMessage: (message: String, type: ToastType)?
    var settingsOpen = false
    var helpOpen = false
    var statisticsOpen = false
    var isLoadingComparison = false
    var comparisonSession: AoeComparisonSession?
    var deleteConfirmationRequest: DeleteConfirmationRequest?

    // Recent History
    var recentFolders: [RecentItem] = []

    // Smart Folders
    var smartFolders: [SmartFolder] = []
    var activeSmartFolder: SmartFolder?
    var showSmartFolderEditor = false
    var editingSmartFolder: SmartFolder?
    var canUndoFolderAction: Bool { !undoHistory.isEmpty }
    var canRedoFolderAction: Bool { !redoHistory.isEmpty }

    var undoMenuTitle: String {
        undoHistory.last.map { "Undo \($0.title)" } ?? "Undo Folder Action"
    }

    var redoMenuTitle: String {
        redoHistory.last.map { "Redo \($0.title)" } ?? "Redo Folder Action"
    }

    private let settings = SettingsStore.shared
    private var undoHistory: [FolderHistoryEntry] = []
    private var redoHistory: [FolderHistoryEntry] = []

    init() {
        customOrderByFolder = settings.loadCustomOrders()
        ratingsByPath = settings.loadRatings()
        thumbnailSize = settings.thumbnailSize
        sortConfig = SortConfig(
            field: SortField(rawValue: settings.sortField) ?? .type,
            direction: SortDirection(rawValue: settings.sortDirection) ?? .asc
        )
        filterConfig = FilterConfig(
            hideOther: settings.hideOther,
            hideJpg: settings.hideJpg,
            hidePng: settings.hidePng,
            filterMinRating: settings.filterMinRating
        )
        showStatusBar = settings.showStatusBar
        appearanceMode = AppAppearanceMode(rawValue: settings.appearanceMode) ?? .dark

        // Load recent history & smart folders
        recentFolders = RecentHistoryService.shared.loadRecentFolders()
        smartFolders = SmartFolderService.shared.loadSmartFolders()

        // Restore last folder
        if !settings.lastOpenedFolder.isEmpty {
            let url = URL(fileURLWithPath: settings.lastOpenedFolder)
            if FileManager.default.fileExists(atPath: url.path) {
                Task { await selectFolder(url, setAsRoot: true) }
            }
        }
    }

    // MARK: - Processed Contents (sorted/filtered)

    var processedFolderContents: [FileEntry] {
        var items = folderContents

        // Filter
        items = items.filter { item in
            let name = item.name.lowercased()

            // Search
            if !searchQuery.isEmpty {
                let query = searchQuery.lowercased()
                if !name.contains(query) { return false }
            }

            // Extension filters
            if filterConfig.hideJpg && (name.hasSuffix(".jpg") || name.hasSuffix(".jpeg")) { return false }
            if filterConfig.hidePng && name.hasSuffix(".png") { return false }

            // Hide unsupported types
            if filterConfig.hideOther {
                let isDir = item.isDirectory
                let isAllowed = isDir || FileHelpers.isPromptSnapshotFile(name) || FileHelpers.isImageFile(name)
                if !isAllowed { return false }
            }

            return true
        }

        if filterConfig.filterMinRating > 0 {
            items = items.filter { rating(for: $0.path) >= filterConfig.filterMinRating }
        }

        // Smart folder filter
        if let smartFolder = activeSmartFolder {
            items = SmartFolderService.shared.filterEntries(
                items,
                criteria: smartFolder.criteria,
                ratingLookup: { self.rating(for: $0) }
            )
        }

        return sortItems(items, using: sortConfig)
    }

    var currentCustomOrder: [String] {
        guard let path = selectedFolderPath?.path else { return [] }
        return customOrderByFolder[path] ?? []
    }

    var selectedItems: [FileEntry] {
        selectedIndices
            .sorted()
            .compactMap { index in
                guard index >= 0 && index < processedFolderContents.count else { return nil }
                return processedFolderContents[index]
            }
    }

    var selectedPaths: [String] {
        selectedItems.map(\.path)
    }

    var selectedAoeItems: [FileEntry] {
        selectedItems.filter { item in
            !item.isDirectory && FileHelpers.isAoeFile(item.name)
        }
    }

    var visibleItemCount: Int {
        processedFolderContents.count
    }

    var hiddenItemCount: Int {
        max(0, folderContents.count - processedFolderContents.count)
    }

    var sidebarFolders: [SidebarFolderItem] {
        guard let root = explorerRootPath else { return [] }

        let rootName = root.lastPathComponent.isEmpty ? root.path : root.lastPathComponent
        let rootItem = SidebarFolderItem(
            url: root,
            name: rootName,
            depth: 0,
            hasChildren: !folderTree.isEmpty,
            isExpanded: isSidebarFolderExpanded(root)
        )

        return [rootItem] +
            (rootItem.isExpanded ? flattenedSidebarFolders(from: folderTree, depth: 1) : [])
    }

    // MARK: - Folder Navigation

    func openFolder() async {
        guard let url = FileSystemService.openFolderDialog() else { return }
        await selectFolder(url, setAsRoot: true)
        recordRecentFolder(url)
    }

    func selectFolder(_ url: URL, setAsRoot: Bool = false) async {
        if setAsRoot {
            explorerRootPath = url
            settings.lastOpenedFolder = url.path
            collapsedSidebarFolderPaths = []
            previousSidebarCollapsedFolderPaths = nil
            undoHistory = []
            redoHistory = []
            await clearParserCaches()
        }

        selectedFolderPath = url
        activeSmartFolder = nil
        rememberStandardSortConfig(sortConfig, for: url)
        revealSidebarSelection(url)
        clearSelection()
        await refreshFolderContents()
        await refreshFolderTree()

    }

    func selectFavorite(_ favorite: FavoriteFolder) async {
        let url: URL?
        switch favorite {
        case .desktop: url = FileSystemService.desktopURL
        case .documents: url = FileSystemService.documentsURL
        case .pictures: url = FileSystemService.picturesURL
        }
        guard let folderURL = url else { return }
        await selectFolder(folderURL, setAsRoot: true)
    }

    func refreshFolder() async {
        await clearParserCaches()
        await refreshFolderContents()
        await refreshFolderTree()
    }

    // MARK: - File Operations

    func moveItem(from source: URL, to destinationDir: URL) async {
        await moveItems([source], to: destinationDir)
    }

    func moveDraggedItems(_ urls: [URL], to destinationDir: URL) async {
        let sources = resolvedDragSourceURLs(from: urls, to: destinationDir)
        await moveItems(sources, to: destinationDir)
    }

    func moveItemsUsingFolderPicker(_ urls: [URL]) async {
        let deduped = deduplicatedURLs(urls)
        guard !deduped.isEmpty else { return }
        guard let destinationDir = FileSystemService.openFolderDialog(
            title: "Choose Destination Folder",
            prompt: "Move",
            directoryURL: selectedFolderPath ?? explorerRootPath
        ) else { return }

        await moveItems(deduped, to: destinationDir)
    }

    func navigateUpToParentFolder() async {
        guard let selectedFolderPath else { return }
        let current = selectedFolderPath.standardizedFileURL
        let root = (explorerRootPath ?? selectedFolderPath).standardizedFileURL
        guard current.path != root.path else { return }

        let parent = current.deletingLastPathComponent().standardizedFileURL
        guard isSameOrDescendant(parent, of: root) else { return }
        await selectFolder(parent)
    }

    func requestPermanentDelete(for items: [FileEntry]) {
        let uniqueItems = deduplicatedItems(items)
        let urls = uniqueItems.map(\.url)
        let names = uniqueItems.map(\.name)
        guard !urls.isEmpty else {
            return
        }

        deleteConfirmationRequest = DeleteConfirmationRequest(urls: urls, names: names)
    }

    func clearDeleteConfirmation() {
        deleteConfirmationRequest = nil
    }

    func deleteItemsPermanently(at urls: [URL]) async {
        let targets = deduplicatedURLs(urls)
        guard !targets.isEmpty else { return }

        do {
            for target in targets {
                try FileSystemService.deleteEntry(at: target)
            }

            clearSelection()
            await refreshFolder()
            showToast(targets.count == 1 ? "Item deleted permanently" : "Deleted \(targets.count) items permanently", type: .success)
        } catch {
            let noun = targets.count == 1 ? "item" : "items"
            showToast("Failed to delete \(noun): \(error.localizedDescription)", type: .error)
        }
    }

    @discardableResult
    func renameItem(at url: URL, to newName: String) async -> Bool {
        let sourceURL = url.standardizedFileURL
        let destinationURL = sourceURL
            .deletingLastPathComponent()
            .appendingPathComponent(newName)
            .standardizedFileURL

        guard sourceURL.path != destinationURL.path else {
            return true
        }

        do {
            let renamedURL = try FileSystemService.rename(at: sourceURL, to: newName).standardizedFileURL
            await refreshAfterMutation(preferredPaths: [renamedURL.path])
            recordFolderHistoryEntry(
                makeMoveHistoryEntry(
                    recordsToApplyNext: [PathMoveRecord(from: renamedURL, to: sourceURL)],
                    title: "Rename"
                )
            )
            showToast("Item renamed", type: .success)
            return true
        } catch {
            showToast("Failed to rename: \(error.localizedDescription)", type: .error)
            return false
        }
    }

    func trashItems(at urls: [URL]) async {
        let targets = deduplicatedURLs(urls)
        guard !targets.isEmpty else { return }

        do {
            let undoEntry = try await performTrashOperation(targets, title: "Move to Trash")
            recordFolderHistoryEntry(undoEntry)
            showToast(targets.count == 1 ? "Moved to Trash" : "Moved \(targets.count) items to Trash", type: .success)
        } catch {
            let noun = targets.count == 1 ? "item" : "items"
            showToast("Failed to trash \(noun): \(error.localizedDescription)", type: .error)
        }
    }

    func trashItem(at url: URL) async {
        await trashItems(at: [url])
    }

    func deleteItemPermanently(at url: URL) async {
        await deleteItemsPermanently(at: [url])
    }

    func importExternalFiles(_ urls: [URL]) async {
        guard let dest = selectedFolderPath else { return }
        await importExternalFiles(urls, to: dest)
    }

    func importExternalFiles(_ urls: [URL], to destinationDir: URL) async {
        let allowed = urls.filter { FileHelpers.isDroppable($0.path) }
        guard !allowed.isEmpty else {
            showToast("No valid files to import", type: .error)
            return
        }

        do {
            let undoEntry = try await performMoveOperation(allowed, to: destinationDir, title: "Import")
            recordFolderHistoryEntry(undoEntry)
            showToast("Imported \(allowed.count) file(s)", type: .success)
        } catch {
            showToast("Failed to import file(s): \(error.localizedDescription)", type: .error)
        }
    }

    func undoLastFolderAction() async {
        guard let entry = undoHistory.popLast() else { return }

        do {
            let redoEntry = try await entry.apply()
            redoHistory.append(redoEntry)
            showToast("Undid \(entry.title.lowercased())", type: .success)
        } catch {
            undoHistory.append(entry)
            showToast("Failed to undo \(entry.title.lowercased()): \(error.localizedDescription)", type: .error)
        }
    }

    func redoLastFolderAction() async {
        guard let entry = redoHistory.popLast() else { return }

        do {
            let undoEntry = try await entry.apply()
            undoHistory.append(undoEntry)
            showToast("Redid \(entry.title.lowercased())", type: .success)
        } catch {
            redoHistory.append(entry)
            showToast("Failed to redo \(entry.title.lowercased()): \(error.localizedDescription)", type: .error)
        }
    }

    func openDeveloperWebsite() {
        guard let url = URL(string: HelpContent.developerResource.urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Selection

    func selectItem(at index: Int, modifiers: EventModifiers = []) {
        let items = processedFolderContents
        guard index >= 0 && index < items.count else { return }
        activePane = .content

        if modifiers.contains(.shift), let anchor = selectionAnchorIndex {
            let range = min(anchor, index)...max(anchor, index)
            if modifiers.contains(.command) {
                selectedIndices.formUnion(range)
            } else {
                selectedIndices = Set(range)
            }
        } else if modifiers.contains(.command) {
            if selectedIndices.contains(index) {
                selectedIndices.remove(index)
            } else {
                selectedIndices.insert(index)
            }
            selectionAnchorIndex = index
        } else {
            selectedIndices = [index]
            selectionAnchorIndex = index
        }

        selectedItemIndex = index
        loadPromptEntry(for: items[index])
    }

    func clearSelection() {
        selectedIndices = []
        selectedItemIndex = -1
        selectionAnchorIndex = nil
        selectedPromptEntry = nil
    }

    func focusSidebar(preservingContentRow row: Int) {
        sidebarContentRowHint = max(0, row)
        activePane = .sidebar
    }

    func focusContent() {
        activePane = .content
    }

    func navigateSidebar(by offset: Int) async {
        let folders = sidebarFolders
        guard !folders.isEmpty else { return }

        let currentURL = selectedFolderPath ?? folders[0].url
        let currentIndex = folders.firstIndex(where: { $0.url == currentURL }) ?? 0
        let nextIndex = max(0, min(folders.count - 1, currentIndex + offset))

        activePane = .sidebar
        guard nextIndex != currentIndex || selectedFolderPath == nil else { return }
        await selectFolder(folders[nextIndex].url)
    }

    func toggleSidebarFolderExpansion(for url: URL) {
        guard sidebarFolderHasChildren(url) else { return }
        previousSidebarCollapsedFolderPaths = nil

        let path = url.path
        let isCollapsing = !collapsedSidebarFolderPaths.contains(path)

        if isCollapsing {
            collapsedSidebarFolderPaths.insert(path)
        } else {
            collapsedSidebarFolderPaths.remove(path)
        }

        guard isCollapsing,
              let selectedFolderPath,
              selectedFolderPath != url,
              selectedFolderPath.path.hasPrefix(path + "/")
        else { return }

        Task { await selectFolder(url) }
    }

    var isSidebarTreeCollapsed: Bool {
        previousSidebarCollapsedFolderPaths != nil
    }

    func toggleSidebarTreeCollapse() {
        let collapsiblePaths = allSidebarFolderPathsWithChildren()
        guard !collapsiblePaths.isEmpty else { return }

        if let previousSidebarCollapsedFolderPaths {
            collapsedSidebarFolderPaths = previousSidebarCollapsedFolderPaths
            self.previousSidebarCollapsedFolderPaths = nil
            return
        }

        previousSidebarCollapsedFolderPaths = collapsedSidebarFolderPaths
        collapsedSidebarFolderPaths.formUnion(collapsiblePaths)

        guard let selectedFolderPath else { return }
        guard let visibleFolder = nearestVisibleSidebarFolder(for: selectedFolderPath),
              visibleFolder != selectedFolderPath
        else { return }

        Task { await selectFolder(visibleFolder) }
    }

    func toggleSelectedSidebarFolderExpansion() -> Bool {
        guard let selectedFolderPath, activePane == .sidebar else { return false }
        guard sidebarFolderHasChildren(selectedFolderPath) else { return false }

        toggleSidebarFolderExpansion(for: selectedFolderPath)
        return true
    }

    func firstColumnIndexFromSidebarHint() -> Int? {
        let items = processedFolderContents
        guard !items.isEmpty else { return nil }

        let columns = max(1, gridColumnCount)
        let lastRow = (items.count - 1) / columns
        let row = min(sidebarContentRowHint, lastRow)
        return row * columns
    }

    // MARK: - Custom Sort Order

    func setCustomOrder(for folderPath: String, order: [String]) {
        customOrderByFolder[folderPath] = order
        settings.saveCustomOrders(customOrderByFolder)
    }

    func ensureCustomSortForCurrentFolder() {
        guard let folderPath = selectedFolderPath?.path else { return }

        let nextOrder: [String]
        if sortConfig.field == .custom {
            nextOrder = completedCustomOrderForCurrentFolder()
        } else {
            rememberStandardSortConfig(sortConfig, for: selectedFolderPath)
            nextOrder = sortItems(folderContents, using: sortConfig).map(\.path)
        }
        guard !nextOrder.isEmpty else { return }

        let currentOrder = currentCustomOrder

        if nextOrder != currentOrder {
            setCustomOrder(for: folderPath, order: nextOrder)
        }

        if sortConfig != SortConfig(field: .custom, direction: .asc) {
            sortConfig = SortConfig(field: .custom, direction: .asc)
            persistSortConfig()
        }
    }

    func reorderItems(sourcePaths: [String], targetPath: String, position: ReorderPosition) {
        guard let folderPath = selectedFolderPath?.path else { return }
        ensureCustomSortForCurrentFolder()

        let availablePaths = folderContents.map(\.path)
        let availablePathSet = Set(availablePaths)
        let currentSelectedPaths = selectedPaths
        let currentPrimaryPath =
            selectedItemIndex >= 0 && selectedItemIndex < processedFolderContents.count
            ? processedFolderContents[selectedItemIndex].path
            : nil
        let orderedSources = sourcePaths.filter { availablePathSet.contains($0) }

        guard !orderedSources.isEmpty else { return }
        guard !orderedSources.contains(targetPath) else { return }

        let currentOrder = completedCustomOrderForCurrentFolder()

        let withoutSources = currentOrder.filter { !orderedSources.contains($0) }
        guard let targetIndex = withoutSources.firstIndex(of: targetPath) else { return }

        var insertIndex = targetIndex
        if position == .after {
            insertIndex += 1
        }

        let nextOrder =
            Array(withoutSources[..<insertIndex]) +
            orderedSources +
            Array(withoutSources[insertIndex...])

        setCustomOrder(for: folderPath, order: nextOrder)
        sortConfig = SortConfig(field: .custom, direction: .asc)
        persistSortConfig()

        let nextSelectedPaths: [String]
        if currentSelectedPaths.contains(where: orderedSources.contains) {
            nextSelectedPaths = currentSelectedPaths.filter { nextOrder.contains($0) }
        } else {
            nextSelectedPaths = orderedSources
        }

        let visibleItems = processedFolderContents
        let nextSelectedIndices = Set(nextSelectedPaths.compactMap { path in
            visibleItems.firstIndex(where: { $0.path == path })
        })
        selectedIndices = nextSelectedIndices
        selectionAnchorIndex = nextSelectedIndices.min()

        let nextPrimaryPath =
            currentPrimaryPath.flatMap { nextSelectedPaths.contains($0) ? $0 : nil }
            ?? nextSelectedPaths.first

        if let nextPrimaryPath,
           let nextIndex = visibleItems.firstIndex(where: { $0.path == nextPrimaryPath })
        {
            selectedItemIndex = nextIndex
            if let item = visibleItems.first(where: { $0.path == nextPrimaryPath }) {
                loadPromptEntry(for: item)
            }
        } else {
            selectedItemIndex = -1
            selectedPromptEntry = nil
        }
    }

    func openComparison() async {
        let items = Array(selectedAoeItems.prefix(2))
        guard items.count == 2 else {
            showToast("Select two .aoe files to compare", type: .info)
            return
        }

        isLoadingComparison = true
        defer { isLoadingComparison = false }

        async let sourceA = promptEntry(for: items[0])
        async let sourceB = promptEntry(for: items[1])

        guard let resolvedA = await sourceA, let resolvedB = await sourceB else {
            showToast("Unable to load both .aoe files", type: .error)
            return
        }

        comparisonSession = AoeComparisonSession(sourceA: resolvedA, sourceB: resolvedB)
    }

    // MARK: - Settings Persistence

    func persistSortConfig() {
        rememberStandardSortConfig(sortConfig, for: selectedFolderPath)
        settings.sortField = sortConfig.field.rawValue
        settings.sortDirection = sortConfig.direction.rawValue
    }

    func persistFilterConfig() {
        settings.hideOther = filterConfig.hideOther
        settings.hideJpg = filterConfig.hideJpg
        settings.hidePng = filterConfig.hidePng
        settings.filterMinRating = filterConfig.filterMinRating
    }

    func persistThumbnailSize() {
        settings.thumbnailSize = thumbnailSize
    }

    func persistStatusBarVisibility() {
        settings.showStatusBar = showStatusBar
    }

    func persistAppearanceMode() {
        settings.appearanceMode = appearanceMode.rawValue
    }

    // MARK: - Ratings

    func rating(for path: String) -> Int {
        ratingsByPath[path] ?? 0
    }

    func setRating(_ rating: Int, for path: String) {
        let clamped = max(0, min(5, rating))
        if clamped == 0 {
            ratingsByPath.removeValue(forKey: path)
        } else {
            ratingsByPath[path] = clamped
        }
        settings.saveRatings(ratingsByPath)
    }

    // MARK: - Recent History

    func openRecentFolder(_ item: RecentItem) async {
        await selectFolder(item.url, setAsRoot: true)
    }

    func clearRecentFolders() {
        RecentHistoryService.shared.clearRecentFolders()
        recentFolders = []
    }

    private func recordRecentFolder(_ url: URL) {
        RecentHistoryService.shared.addRecentFolder(url)
        recentFolders = RecentHistoryService.shared.loadRecentFolders()
    }

    // MARK: - Smart Folders

    func activateSmartFolder(_ folder: SmartFolder) {
        if activeSmartFolder?.id == folder.id {
            activeSmartFolder = nil
        } else {
            activeSmartFolder = folder
        }
    }

    func editSmartFolder(_ folder: SmartFolder) {
        editingSmartFolder = folder
        showSmartFolderEditor = true
    }

    func deleteSmartFolder(_ folder: SmartFolder) {
        SmartFolderService.shared.removeSmartFolder(id: folder.id)
        smartFolders = SmartFolderService.shared.loadSmartFolders()
        if activeSmartFolder?.id == folder.id {
            activeSmartFolder = nil
        }
    }

    func saveSmartFolder(_ folder: SmartFolder) {
        if smartFolders.contains(where: { $0.id == folder.id }) {
            SmartFolderService.shared.updateSmartFolder(folder)
        } else {
            SmartFolderService.shared.addSmartFolder(folder)
        }
        smartFolders = SmartFolderService.shared.loadSmartFolders()
        editingSmartFolder = nil
    }

    // MARK: - Toast

    func showToast(_ message: String, type: ToastType) {
        toastMessage = (message, type)
    }

    // MARK: - Breadcrumbs

    var breadcrumbs: [(name: String, url: URL)] {
        guard let root = explorerRootPath, let current = selectedFolderPath else { return [] }
        var crumbs: [(String, URL)] = []
        var url = current

        while url.path.hasPrefix(root.path) && url.path != root.deletingLastPathComponent().path {
            crumbs.insert((url.lastPathComponent, url), at: 0)
            let parent = url.deletingLastPathComponent()
            if parent == url { break }
            url = parent
        }

        return crumbs
    }

    // MARK: - Private

    private func refreshFolderContents() async {
        guard let path = selectedFolderPath else {
            folderContents = []
            return
        }

        isLoadingFolder = true
        defer { isLoadingFolder = false }

        do {
            folderContents = try FileSystemService.readDirectory(at: path)
        } catch {
            folderContents = []
        }
    }

    private func refreshFolderTree() async {
        guard let root = explorerRootPath else {
            folderTree = []
            return
        }

        do {
            folderTree = try FileSystemService.buildFolderTree(root: root, depth: 3)
        } catch {
            folderTree = []
        }
    }

    private func loadPromptEntry(for item: FileEntry) {
        guard !item.isDirectory else {
            selectedPromptEntry = nil
            return
        }

        let expectedPath = item.path
        Task {
            let entry = await promptEntry(for: item)

            await MainActor.run {
                let selectedPath =
                    self.selectedItemIndex >= 0 && self.selectedItemIndex < self.processedFolderContents.count
                    ? self.processedFolderContents[self.selectedItemIndex].path
                    : nil
                guard selectedPath == expectedPath else { return }
                self.selectedPromptEntry = entry
            }
        }
    }

    private func promptEntry(for item: FileEntry) async -> PromptEntry? {
        guard !item.isDirectory else { return nil }

        let metadata = FileSystemService.getMetadata(for: item.url)

        if FileHelpers.isPlibFile(item.name) {
            guard var entry = await PlibParser.shared.parse(at: item.url) else { return nil }
            entry.fileMetadata = metadata
            return entry
        }

        if FileHelpers.isAoeFile(item.name) {
            guard var entry = await AoeParser.shared.parse(at: item.url) else { return nil }
            entry.fileMetadata = metadata
            return entry
        }

        if FileHelpers.isImageFile(item.name),
           let image = await ThumbnailService.shared.previewImage(for: item.url)
        {
            let imageMetadata = await ImageMetadataParser.shared.parse(at: item.url)

            return PromptEntry(
                prompt: imageMetadata.prompt,
                blindPrompt: imageMetadata.negativePrompt,
                generationInfo: GenerationInfo(
                    aspectRatio: aspectRatio(for: metadata),
                    model: imageMetadata.model ?? "N/A",
                    timestamp: imageMetadata.timestamp ?? "",
                    numberOfImages: 1
                ),
                images: [image],
                referenceImages: [],
                rawImages: [item.path],
                rawReferenceImages: [],
                sourcePath: item.path,
                embeddedMetadata: imageMetadata.fields,
                fileMetadata: metadata
            )
        }

        return nil
    }

    private func aspectRatio(for metadata: FileMetadata) -> AspectRatio {
        guard let width = metadata.width,
              let height = metadata.height,
              width > 0,
              height > 0
        else {
            return .notAvailable
        }

        let ratio = Double(width) / Double(height)
        let candidates: [(AspectRatio, Double)] = [
            (.oneToOne, 1.0),
            (.sixteenToNine, 16.0 / 9.0),
            (.nineToSixteen, 9.0 / 16.0),
            (.fourToThree, 4.0 / 3.0),
            (.threeToFour, 3.0 / 4.0),
        ]

        if let match = candidates.first(where: { abs($0.1 - ratio) <= 0.03 }) {
            return match.0
        }

        return .notAvailable
    }

    private func clearParserCaches() async {
        await PlibParser.shared.clearCache()
        await AoeParser.shared.clearCache()
        await ImageMetadataParser.shared.clearCache()
    }

    private func moveItems(_ urls: [URL], to destinationDir: URL) async {
        let sources = validatedMoveSources(urls, to: destinationDir)
        guard !sources.isEmpty else {
            showToast("Invalid move destination", type: .error)
            return
        }

        do {
            let undoEntry = try await performMoveOperation(sources, to: destinationDir, title: "Move")
            recordFolderHistoryEntry(undoEntry)
            showToast(sources.count == 1 ? "Item moved" : "Moved \(sources.count) items", type: .success)
        } catch {
            let noun = sources.count == 1 ? "item" : "items"
            showToast("Failed to move \(noun): \(error.localizedDescription)", type: .error)
        }
    }

    private func resolvedDragSourceURLs(from urls: [URL], to destinationDir: URL) -> [URL] {
        guard let firstDraggedURL = urls.first else { return [] }

        let sourceURLs: [URL]
        let draggedPath = firstDraggedURL.standardizedFileURL.path
        let availablePaths = Set(processedFolderContents.map(\.path))

        if selectedPaths.contains(draggedPath), selectedIndices.count > 1 {
            sourceURLs = selectedPaths.compactMap { path in
                guard availablePaths.contains(path) else { return nil }
                return URL(fileURLWithPath: path)
            }
        } else {
            sourceURLs = urls
        }

        return validatedMoveSources(sourceURLs, to: destinationDir)
    }

    private func validatedMoveSources(_ urls: [URL], to destinationDir: URL) -> [URL] {
        let destination = destinationDir.standardizedFileURL

        return deduplicatedURLs(urls).filter { sourceURL in
            let source = sourceURL.standardizedFileURL
            guard source.path != destination.path else { return false }
            guard !isSameOrDescendant(destination, of: source) else { return false }
            return true
        }
    }

    private func deduplicatedURLs(_ urls: [URL]) -> [URL] {
        var seenPaths: Set<String> = []
        return urls.compactMap { url in
            let standardized = url.standardizedFileURL
            guard seenPaths.insert(standardized.path).inserted else { return nil }
            return standardized
        }
    }

    private func deduplicatedItems(_ items: [FileEntry]) -> [FileEntry] {
        var seenPaths: Set<String> = []
        return items.filter { item in
            seenPaths.insert(item.url.standardizedFileURL.path).inserted
        }
    }

    private func rememberStandardSortConfig(_ config: SortConfig, for folderURL: URL?) {
        guard config.field != .custom, let folderPath = folderURL?.path else { return }
        lastStandardSortConfigByFolder[folderPath] = config
    }

    private func completedCustomOrderForCurrentFolder() -> [String] {
        let availablePaths = Set(folderContents.map(\.path))
        guard !availablePaths.isEmpty else { return [] }

        let normalizedCustomOrder = currentCustomOrder.filter { availablePaths.contains($0) }
        let fallbackConfig = standardSortConfigForCurrentFolder()
        let fallbackOrder = sortItems(folderContents, using: fallbackConfig).map(\.path)
        let missingPaths = fallbackOrder.filter { !normalizedCustomOrder.contains($0) }

        return normalizedCustomOrder + missingPaths
    }

    private func standardSortConfigForCurrentFolder() -> SortConfig {
        if sortConfig.field != .custom {
            return sortConfig
        }

        guard let folderPath = selectedFolderPath?.path else {
            return SortConfig(field: .type, direction: .asc)
        }

        return lastStandardSortConfigByFolder[folderPath] ?? SortConfig(field: .type, direction: .asc)
    }

    private func sortItems(_ items: [FileEntry], using config: SortConfig) -> [FileEntry] {
        var sortedItems = items

        if config.field == .custom {
            let order = currentCustomOrder
            let orderIndex = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
            sortedItems.sort { a, b in
                let idxA = orderIndex[a.path]
                let idxB = orderIndex[b.path]
                if let iA = idxA, let iB = idxB { return iA < iB }
                if idxA != nil { return true }
                if idxB != nil { return false }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
            return sortedItems
        }

        if config.field == .rating {
            sortedItems.sort { a, b in
                let rA = ratingsByPath[a.path] ?? 0
                let rB = ratingsByPath[b.path] ?? 0
                if rA != rB {
                    return config.direction == .asc ? rA > rB : rA < rB
                }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
            return sortedItems
        }

        sortedItems.sort { a, b in
            let comparison: ComparisonResult
            if config.field == .type {
                let rankA = FileHelpers.typeRank(for: a)
                let rankB = FileHelpers.typeRank(for: b)
                if rankA != rankB {
                    comparison = rankA < rankB ? .orderedAscending : .orderedDescending
                } else {
                    comparison = a.name.localizedCaseInsensitiveCompare(b.name)
                }
            } else {
                comparison = a.name.localizedCaseInsensitiveCompare(b.name)
            }
            return config.direction == .asc
                ? comparison == .orderedAscending
                : comparison == .orderedDescending
        }

        return sortedItems
    }

    private func recordFolderHistoryEntry(_ entry: FolderHistoryEntry) {
        undoHistory.append(entry)
        redoHistory.removeAll()

        if undoHistory.count > 50 {
            undoHistory.removeFirst(undoHistory.count - 50)
        }
    }

    private func performMoveOperation(_ sources: [URL], to destinationDir: URL, title: String) async throws -> FolderHistoryEntry {
        var appliedRecords: [PathMoveRecord] = []

        for source in sources {
            let sourceURL = source.standardizedFileURL
            let movedURL = try FileSystemService.moveFile(from: sourceURL, to: destinationDir).standardizedFileURL
            appliedRecords.append(PathMoveRecord(from: sourceURL, to: movedURL))
        }

        await refreshAfterMutation(preferredPaths: appliedRecords.map { $0.to.path })
        return makeMoveHistoryEntry(recordsToApplyNext: invertedMoveRecords(appliedRecords), title: title)
    }

    private func performExactMoveRecords(_ records: [PathMoveRecord]) async throws -> [PathMoveRecord] {
        var appliedRecords: [PathMoveRecord] = []

        for record in records {
            let movedURL = try FileSystemService.moveEntry(from: record.from, to: record.to).standardizedFileURL
            appliedRecords.append(PathMoveRecord(from: record.from.standardizedFileURL, to: movedURL))
        }

        await refreshAfterMutation(preferredPaths: appliedRecords.map { $0.to.path })
        return invertedMoveRecords(appliedRecords)
    }

    private func performTrashOperation(_ urls: [URL], title: String) async throws -> FolderHistoryEntry {
        let restoreRecords = try await trashURLs(urls)
        return makeRestoreTrashHistoryEntry(recordsToApplyNext: restoreRecords, title: title)
    }

    private func trashURLs(_ urls: [URL]) async throws -> [TrashRestoreRecord] {
        var restoreRecords: [TrashRestoreRecord] = []

        for url in deduplicatedURLs(urls) {
            let sourceURL = url.standardizedFileURL
            let trashedURL = try FileSystemService.moveToTrash(at: sourceURL).standardizedFileURL
            restoreRecords.append(TrashRestoreRecord(trashedURL: trashedURL, originalURL: sourceURL))
        }

        await refreshAfterMutation()
        return restoreRecords
    }

    private func restoreTrashedRecords(_ records: [TrashRestoreRecord]) async throws -> [URL] {
        var restoredURLs: [URL] = []

        for record in records {
            let restoredURL = try FileSystemService.moveEntry(from: record.trashedURL, to: record.originalURL).standardizedFileURL
            restoredURLs.append(restoredURL)
        }

        await refreshAfterMutation(preferredPaths: restoredURLs.map(\.path))
        return restoredURLs
    }

    private func makeMoveHistoryEntry(recordsToApplyNext: [PathMoveRecord], title: String) -> FolderHistoryEntry {
        FolderHistoryEntry(title: title) { [weak self] in
            guard let self else { throw FolderHistoryError.viewModelReleased }
            let inverseRecords = try await self.performExactMoveRecords(recordsToApplyNext)
            return self.makeMoveHistoryEntry(recordsToApplyNext: inverseRecords, title: title)
        }
    }

    private func makeRestoreTrashHistoryEntry(recordsToApplyNext: [TrashRestoreRecord], title: String) -> FolderHistoryEntry {
        FolderHistoryEntry(title: title) { [weak self] in
            guard let self else { throw FolderHistoryError.viewModelReleased }
            let restoredURLs = try await self.restoreTrashedRecords(recordsToApplyNext)
            return self.makeTrashHistoryEntry(urlsToApplyNext: restoredURLs, title: title)
        }
    }

    private func makeTrashHistoryEntry(urlsToApplyNext: [URL], title: String) -> FolderHistoryEntry {
        FolderHistoryEntry(title: title) { [weak self] in
            guard let self else { throw FolderHistoryError.viewModelReleased }
            let restoreRecords = try await self.trashURLs(urlsToApplyNext)
            return self.makeRestoreTrashHistoryEntry(recordsToApplyNext: restoreRecords, title: title)
        }
    }

    private func invertedMoveRecords(_ records: [PathMoveRecord]) -> [PathMoveRecord] {
        records.map { record in
            PathMoveRecord(from: record.to, to: record.from)
        }
    }

    private func refreshAfterMutation(preferredPaths: [String] = []) async {
        await refreshFolder()
        restoreSelection(afterRefreshing: preferredPaths)
    }

    private func restoreSelection(afterRefreshing preferredPaths: [String]) {
        let uniquePaths = Array(NSOrderedSet(array: preferredPaths).compactMap { $0 as? String })
        guard !uniquePaths.isEmpty else {
            clearSelection()
            return
        }

        let items = processedFolderContents
        let indices = Set(uniquePaths.compactMap { path in
            items.firstIndex(where: { $0.path == path })
        })

        guard !indices.isEmpty else {
            clearSelection()
            return
        }

        let primaryIndex =
            uniquePaths.compactMap { path in
                items.firstIndex(where: { $0.path == path })
            }.first
            ?? indices.min()

        selectedIndices = indices
        selectionAnchorIndex = primaryIndex

        if let primaryIndex {
            selectedItemIndex = primaryIndex
            loadPromptEntry(for: items[primaryIndex])
        } else {
            selectedItemIndex = -1
            selectedPromptEntry = nil
        }
    }

    private func isSameOrDescendant(_ candidate: URL, of ancestor: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let ancestorPath = ancestor.standardizedFileURL.path
        return candidatePath == ancestorPath || candidatePath.hasPrefix(ancestorPath + "/")
    }

    private func flattenedSidebarFolders(from nodes: [FileEntry], depth: Int) -> [SidebarFolderItem] {
        nodes.flatMap { node in
            let children = node.children ?? []
            let item = SidebarFolderItem(
                url: node.url,
                name: node.name,
                depth: depth,
                hasChildren: !children.isEmpty,
                isExpanded: isSidebarFolderExpanded(node.url)
            )

            return [item] +
                ((item.hasChildren && item.isExpanded)
                    ? flattenedSidebarFolders(from: children, depth: depth + 1)
                    : [])
        }
    }

    private func isSidebarFolderExpanded(_ url: URL) -> Bool {
        !collapsedSidebarFolderPaths.contains(url.path)
    }

    private func sidebarFolderHasChildren(_ url: URL) -> Bool {
        guard let children = childrenForSidebarFolder(url) else { return false }
        return !children.isEmpty
    }

    private func childrenForSidebarFolder(_ url: URL) -> [FileEntry]? {
        guard let root = explorerRootPath else { return nil }

        if url == root {
            return folderTree
        }

        return findSidebarChildren(for: url, in: folderTree)
    }

    private func findSidebarChildren(for url: URL, in nodes: [FileEntry]) -> [FileEntry]? {
        for node in nodes {
            if node.url == url {
                return node.children ?? []
            }

            if let children = node.children,
               let found = findSidebarChildren(for: url, in: children)
            {
                return found
            }
        }

        return nil
    }

    private func allSidebarFolderPathsWithChildren() -> Set<String> {
        var paths: Set<String> = []
        collectSidebarFolderPathsWithChildren(from: folderTree, into: &paths)
        return paths
    }

    private func revealSidebarSelection(_ url: URL) {
        guard let root = explorerRootPath?.standardizedFileURL else { return }

        let candidate = url.standardizedFileURL
        guard isSameOrDescendant(candidate, of: root) else { return }

        var current = candidate.deletingLastPathComponent().standardizedFileURL
        var expandedAnyAncestor = false

        while isSameOrDescendant(current, of: root) {
            if collapsedSidebarFolderPaths.remove(current.path) != nil {
                expandedAnyAncestor = true
            }

            if current.path == root.path {
                break
            }

            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent == current { break }
            current = parent
        }

        if expandedAnyAncestor {
            previousSidebarCollapsedFolderPaths = nil
        }
    }

    private func collectSidebarFolderPathsWithChildren(from nodes: [FileEntry], into paths: inout Set<String>) {
        for node in nodes {
            let children = node.children ?? []
            if !children.isEmpty {
                paths.insert(node.path)
                collectSidebarFolderPathsWithChildren(from: children, into: &paths)
            }
        }
    }

    private func nearestVisibleSidebarFolder(for url: URL) -> URL? {
        guard let root = explorerRootPath?.standardizedFileURL else { return nil }

        var candidate = url.standardizedFileURL
        while isSameOrDescendant(candidate, of: root) {
            if isSidebarFolderVisible(candidate) {
                return candidate
            }

            let parent = candidate.deletingLastPathComponent().standardizedFileURL
            if parent == candidate { break }
            candidate = parent
        }

        return root
    }

    private func isSidebarFolderVisible(_ url: URL) -> Bool {
        guard let root = explorerRootPath?.standardizedFileURL else { return false }

        let candidate = url.standardizedFileURL
        if candidate.path == root.path {
            return true
        }

        var current = candidate.deletingLastPathComponent().standardizedFileURL
        while isSameOrDescendant(current, of: root) {
            if collapsedSidebarFolderPaths.contains(current.path) {
                return false
            }

            if current.path == root.path {
                break
            }

            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent == current { break }
            current = parent
        }

        return true
    }
}

// MARK: - Supporting Types

enum FavoriteFolder {
    case desktop, documents, pictures
}

enum ToastType {
    case success, error, info
}

struct AoeComparisonSession: Identifiable {
    let id = UUID()
    let sourceA: PromptEntry
    let sourceB: PromptEntry
}

enum ExplorerPane {
    case sidebar
    case content
}

struct SidebarFolderItem: Identifiable, Hashable {
    let url: URL
    let name: String
    let depth: Int
    let hasChildren: Bool
    let isExpanded: Bool

    var id: String { url.path }
}

enum ReorderPosition {
    case before
    case after
}

struct EventModifiers: OptionSet {
    let rawValue: Int
    static let shift = EventModifiers(rawValue: 1 << 0)
    static let command = EventModifiers(rawValue: 1 << 1)
}
