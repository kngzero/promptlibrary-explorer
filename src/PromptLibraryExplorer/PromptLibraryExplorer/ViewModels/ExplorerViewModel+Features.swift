import AppKit
import Foundation

// MARK: - Modal state, filters, selection actions

extension ExplorerViewModel {
    /// True while any sheet, alert or modal owned by the main window is up.
    /// Menu commands no-op (and are disabled) while this is true. Settings is a
    /// separate, non-modal window, so it doesn't count.
    var isAnyModalOpen: Bool {
        helpOpen || statisticsOpen || showSmartFolderEditor
            || promptDiffSession != nil || comparisonSession != nil
            || batchMetadataEditorOpen || metadataEditorPath != nil
            || deleteConfirmationRequest != nil || isShowingNewFolderPrompt
            || batchRenameOpen || librarySearchOpen || duplicatesOpen || snippetsOpen
    }

    /// `isAnyModalOpen`, plus AppKit modal sessions / sheets the model doesn't
    /// track (save panels etc.). Use at action time; not observable.
    var isModalBlockingCommands: Bool {
        if isAnyModalOpen { return true }
        if NSApp.modalWindow != nil { return true }
        guard let keyWindow = NSApp.keyWindow else { return false }
        return keyWindow.isSheet || keyWindow.attachedSheet != nil
    }

    /// True when any search, filter, tag, smart folder or collection narrows the listing.
    var hasActiveFilters: Bool {
        !searchQuery.isEmpty || filterConfig != FilterConfig() || filterByTagID != nil
            || activeSmartFolder != nil || activeCollectionID != nil || activeVirtualListing != nil
    }

    func clearAllFilters() {
        if !searchQuery.isEmpty { searchQuery = "" }
        updateContentSearch()
        if filterConfig != FilterConfig() {
            filterConfig = FilterConfig()
            persistFilterConfig()
        }
        if filterByTagID != nil { filterByTagID = nil }
        if activeSmartFolder != nil { activeSmartFolder = nil }
        if activeCollectionID != nil { openCollection(nil) }
        if activeVirtualListing != nil { closeVirtualListing() }
    }

    /// Selected files (not folders) in listing order.
    var selectedFileItems: [FileEntry] {
        selectedItems.filter { !$0.isDirectory }
    }

    /// Copies the prompts of every selected file, blank-line separated.
    func copyPromptOfSelection() {
        if let path = similarPageTargetPath {
            copySimilarCardPrompt(path)
            return
        }
        let items = selectedFileItems
        guard !items.isEmpty else {
            showToast("Select files to copy their prompts", type: .info)
            return
        }
        Task {
            var prompts: [String] = []
            for item in items {
                let parsed = await Self.parsePromptData(for: item)
                if let prompt = parsed.prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
                    prompts.append(prompt)
                }
            }
            guard !prompts.isEmpty else {
                showToast(items.count == 1 ? "No prompt in this file" : "No prompts in the selected files", type: .info)
                return
            }
            ClipboardService.copyString(prompts.joined(separator: "\n\n"))
            showToast(prompts.count == 1 ? "Prompt copied" : "Copied \(prompts.count) prompts", type: .success)
        }
    }

    func copySelection(as format: PromptCopyFormat) {
        let items = selectedFileItems
        guard !items.isEmpty else {
            showToast("Select files to copy their prompts", type: .info)
            return
        }
        let primaryPath = selectedItemPath
        let loadedPrimary = selectedPromptEntry
        Task {
            var outputs: [String] = []
            for item in items {
                let entry: PromptEntry?
                if item.path == primaryPath, let loadedPrimary {
                    entry = loadedPrimary
                } else {
                    entry = await promptEntry(for: item)
                }
                guard let entry, !entry.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                outputs.append(PromptFormatService.format(entry, as: format))
            }
            guard !outputs.isEmpty else {
                showToast("No prompts to copy", type: .info)
                return
            }
            ClipboardService.copyString(outputs.joined(separator: "\n\n"))
            showToast(
                outputs.count == 1 ? "Copied as \(format.title)" : "Copied \(outputs.count) prompts as \(format.title)",
                type: .success
            )
        }
    }

    func copyPathsOfSelection() {
        let paths = similarPageTargetPath.map { [$0] } ?? selectedPaths
        guard !paths.isEmpty else { return }
        ClipboardService.copyString(paths.joined(separator: "\n"))
        showToast(paths.count == 1 ? "Path copied" : "Copied \(paths.count) paths", type: .success)
    }

    func revealSelectionInFinder() {
        if let path = similarPageTargetPath {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            return
        }
        let urls = selectedItems.map(\.url)
        if urls.isEmpty, let folder = selectedFolderPath, isFolderListing {
            NSWorkspace.shared.activateFileViewerSelecting([folder])
            return
        }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// Moves the selection to the Trash (confirmation per preference; undoable).
    func trashSelection() {
        // The Similar Images page never trashes anything (not even the hidden grid's selection).
        guard !similarPage.isActive else { return }
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        requestTrash(at: urls)
    }

    /// Toggles Quick Look for the selection (the primary item shows first).
    func quickLookSelection() {
        guard !similarPage.isActive else { return }
        let items = selectedItems
        guard !items.isEmpty || QuickLookController.isPanelVisible else { return }
        let startIndex = items.firstIndex(where: { $0.path == selectedItemPath }) ?? 0
        QuickLookController.shared.toggle(urls: items.map(\.url), startingAt: startIndex)
    }

    /// Keeps an open Quick Look panel in step with the selection.
    func syncQuickLookWithSelection() {
        guard QuickLookController.isPanelVisible else { return }
        let urls = selectedItems.map(\.url)
        QuickLookController.shared.update(urls: urls)
    }
}

// MARK: - Library search & indexing

extension ExplorerViewModel {
    /// Runs `librarySearchQuery` against the library index after a 250 ms
    /// debounce; a newer call cancels the pending one.
    func runLibrarySearch() {
        librarySearchTask?.cancel()
        let query = librarySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            librarySearchResults = []
            isLibrarySearching = false
            return
        }

        let root = explorerRootPath
        isLibrarySearching = true
        librarySearchTask = Task(priority: .userInitiated) { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let hits = await LibraryIndexService.shared.search(query, under: root, limit: 200)
            guard !Task.isCancelled, let self else { return }
            guard self.librarySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
            self.librarySearchResults = hits
            self.isLibrarySearching = false
        }
    }

    /// Re-indexes the current root with progress.
    func reindexLibrary() {
        guard let root = explorerRootPath else {
            showToast("Open a folder to index it", type: .info)
            return
        }
        startLibraryIndex(root: root, priority: .userInitiated, announce: true)
    }

    /// Indexes `root` in the background when it hasn't been indexed in 24 h.
    func autoIndexLibraryIfNeeded(root: URL) {
        let rootPath = root.standardizedFileURL.path
        if libraryIndexRoot == rootPath, libraryIndexTask != nil { return }
        // A different root's pass is no longer wanted.
        if libraryIndexRoot != rootPath { cancelLibraryIndex() }

        Task(priority: .background) { [weak self] in
            let stats = await LibraryIndexService.shared.stats(under: root)
            if let last = stats.lastIndexed, Date().timeIntervalSince(last) < 24 * 60 * 60 { return }
            guard let self, self.explorerRootPath?.standardizedFileURL.path == rootPath else { return }
            self.startLibraryIndex(root: root, priority: .background, announce: false)
        }
    }

    func cancelLibraryIndex() {
        libraryIndexTask?.cancel()
        libraryIndexTask = nil
        libraryIndexRoot = nil
        isLibraryIndexing = false
        libraryIndexProgress = nil
    }

    private func startLibraryIndex(root: URL, priority: TaskPriority, announce: Bool) {
        let rootPath = root.standardizedFileURL.path
        if libraryIndexRoot == rootPath, libraryIndexTask != nil, !announce { return }
        libraryIndexTask?.cancel()

        isLibraryIndexing = true
        libraryIndexProgress = (0, 0)
        libraryIndexRoot = rootPath

        let reportProgress: @Sendable (Int, Int) -> Void = { [weak self] done, total in
            Task { @MainActor in
                guard let self, self.libraryIndexRoot == rootPath, self.isLibraryIndexing else { return }
                self.libraryIndexProgress = (done, total)
            }
        }

        libraryIndexTask = Task(priority: priority) { [weak self] in
            await LibraryIndexService.shared.indexLibrary(root: root, progress: reportProgress)
            guard let self else { return }
            guard !Task.isCancelled, self.libraryIndexRoot == rootPath else { return }
            self.isLibraryIndexing = false
            self.libraryIndexProgress = nil
            self.libraryIndexTask = nil
            self.libraryIndexRoot = nil
            if announce {
                let stats = await LibraryIndexService.shared.stats(under: root)
                self.showToast("Indexed \(stats.fileCount) files", type: .success)
            }
            // Fresh parameters for grouping, and fresh results for an open search.
            self.loadListingPromptDataIfNeeded(force: false)
            if !self.librarySearchQuery.isEmpty { self.runLibrarySearch() }
        }
    }

    /// Navigates to the hit's folder and selects the file.
    func revealLibraryHit(_ hit: LibrarySearchHit) {
        librarySearchOpen = false
        Task { await revealFile(at: URL(fileURLWithPath: hit.path)) }
    }

    /// Opens the file's parent folder (inside the current root when possible,
    /// otherwise as a new root) and selects the file, clearing filters that
    /// would hide it.
    func revealFile(at url: URL) async {
        // The file is shown in the browser, so the Similar Images page closes.
        similarPage.handle(.fileRevealed)
        let fileURL = url.standardizedFileURL
        let parent = fileURL.deletingLastPathComponent().standardizedFileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            showToast("\"\(fileURL.lastPathComponent)\" no longer exists", type: .error)
            return
        }

        let root = explorerRootPath?.standardizedFileURL
        let insideRoot = root.map { parent.path == $0.path || parent.path.hasPrefix($0.path + "/") } ?? false
        if !isFolderListing || selectedFolderPath?.standardizedFileURL.path != parent.path {
            await selectFolder(parent, setAsRoot: !insideRoot)
            if !insideRoot { recordRecentFolderIfNeeded(parent) }
        }
        guard selectedFolderPath?.standardizedFileURL.path == parent.path else { return }

        if !selectPath(fileURL.path) {
            clearAllFilters()
            selectPath(fileURL.path)
        }
        // The grid only scrolls on selection *changes*; after a folder switch the
        // revealed file can be selected yet off screen, so ask for it explicitly
        // once the new listing has laid out.
        let revealed = fileURL.path
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NotificationCenter.default.post(name: .scrollToRevealedFile, object: revealed)
        }
    }

    /// Breadcrumb-bar drop: a folder opens (staying under the current root when it
    /// lives inside it); a file (or package) opens its folder with the file selected.
    func navigate(toDropped url: URL) async {
        let target = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) else {
            showToast("\"\(target.lastPathComponent)\" no longer exists", type: .error)
            return
        }
        let isPackage = (try? target.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
        guard isDirectory.boolValue, !isPackage else {
            await revealFile(at: target)
            return
        }

        let root = explorerRootPath?.standardizedFileURL
        let insideRoot = root.map { target.path == $0.path || target.path.hasPrefix($0.path + "/") } ?? false
        guard !isFolderListing || selectedFolderPath?.standardizedFileURL.path != target.path else { return }
        await selectFolder(target, setAsRoot: !insideRoot)
        if !insideRoot { recordRecentFolderIfNeeded(target) }
    }

    /// Opens files / folders handed to the app by Finder or the Dock.
    func openExternalURLs(_ urls: [URL]) async {
        guard let first = urls.first?.standardizedFileURL else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: first.path, isDirectory: &isDirectory) else { return }

        if isDirectory.boolValue {
            await selectFolder(first, setAsRoot: true)
            recordRecentFolderIfNeeded(first)
        } else {
            await revealFile(at: first)
        }
    }

    func recordRecentFolderIfNeeded(_ url: URL) {
        RecentHistoryService.shared.addRecentFolder(url)
        recentFolders = RecentHistoryService.shared.loadRecentFolders()
    }
}

// MARK: - Duplicates

extension ExplorerViewModel {
    /// Clusters near-identical prompts in the current listing (off-main).
    func findDuplicatePrompts(threshold: Double) {
        duplicatesTask?.cancel()
        isFindingDuplicates = true
        let scope = promptIndexScope

        duplicatesTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.ensurePromptIndexForCurrentListing()
            guard !Task.isCancelled, self.promptIndexScope == scope else { return }

            let listed = Set(self.processedFolderContents.lazy.filter { !$0.isDirectory }.map(\.path))
            let prompts = self.promptTextByPath.filter { listed.contains($0.key) }
            let clusters = await Task.detached(priority: .userInitiated) {
                PromptSimilarityService.clusters(prompts: prompts, threshold: threshold, minClusterSize: 2)
            }.value
            guard !Task.isCancelled, self.promptIndexScope == scope else { return }

            self.duplicateClusters = clusters
            self.isFindingDuplicates = false
        }
    }
}

// MARK: - Command palette file matches

extension ExplorerViewModel {
    /// Filename matches in the current listing, then prompt matches from the
    /// current listing's index, then library hits; de-duplicated by path.
    func paletteFileMatches(_ query: String, limit: Int) async -> [LibrarySearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, limit > 0 else { return [] }
        let lower = trimmed.lowercased()

        var results: [LibrarySearchHit] = []
        var seen = Set<String>()

        func append(_ hit: LibrarySearchHit) -> Bool {
            guard seen.insert(hit.path).inserted else { return results.count < limit }
            results.append(hit)
            return results.count < limit
        }

        let items = processedFolderContents.filter { !$0.isDirectory }
        let byPath = Dictionary(items.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })

        // 1. Filenames (prefix matches first)
        let nameMatches = items
            .filter { $0.name.lowercased().contains(lower) }
            .sorted { a, b in
                let aPrefix = a.name.lowercased().hasPrefix(lower)
                let bPrefix = b.name.lowercased().hasPrefix(lower)
                if aPrefix != bPrefix { return aPrefix }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        for item in nameMatches {
            let hit = LibrarySearchHit(
                path: item.path,
                fileName: item.name,
                folderPath: item.url.deletingLastPathComponent().path,
                snippet: promptTextByPath[item.path].map { Self.paletteSnippet($0, matching: nil) } ?? "",
                rank: 0
            )
            if !append(hit) { return results }
        }

        // 2. Prompt text of the current listing
        let promptMatches = await PromptIndexService.shared.search(query: trimmed)
        for path in promptMatches.sorted() {
            guard let item = byPath[path] else { continue }
            var text = promptTextByPath[path] ?? ""
            if text.isEmpty { text = await PromptIndexService.shared.prompt(for: path) ?? "" }
            let hit = LibrarySearchHit(
                path: path,
                fileName: item.name,
                folderPath: item.url.deletingLastPathComponent().path,
                snippet: Self.paletteSnippet(text, matching: trimmed),
                rank: 1
            )
            if !append(hit) { return results }
        }

        // 3. Library
        let libraryHits = await LibraryIndexService.shared.search(trimmed, under: explorerRootPath, limit: limit)
        for hit in libraryHits {
            if !append(hit) { return results }
        }
        return results
    }

    /// Short excerpt around the first match, with the match wrapped in «».
    nonisolated static func paletteSnippet(_ text: String, matching query: String?) -> String {
        let flattened = text.replacingOccurrences(of: "\n", with: " ")
        guard let query, !query.isEmpty,
              let range = flattened.range(of: query, options: .caseInsensitive)
        else {
            return String(flattened.prefix(120))
        }
        let start = flattened.index(range.lowerBound, offsetBy: -40, limitedBy: flattened.startIndex) ?? flattened.startIndex
        let end = flattened.index(range.upperBound, offsetBy: 60, limitedBy: flattened.endIndex) ?? flattened.endIndex
        let prefix = start == flattened.startIndex ? "" : "…"
        let suffix = end == flattened.endIndex ? "" : "…"
        return prefix + flattened[start..<range.lowerBound] + "«" + flattened[range] + "»"
            + flattened[range.upperBound..<end] + suffix
    }
}

extension Notification.Name {
    /// Posted with the revealed file's path; the grid / list scroll it into view.
    static let scrollToRevealedFile = Notification.Name("scrollToRevealedFile")
}
