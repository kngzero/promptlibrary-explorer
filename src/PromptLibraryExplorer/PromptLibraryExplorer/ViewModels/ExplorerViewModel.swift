import AppKit
import Foundation
import Observation

struct DeleteConfirmationRequest: Identifiable {
    enum Kind {
        case trash
        case permanent
    }

    let id = UUID()
    let kind: Kind
    let urls: [URL]
    let names: [String]
    /// Cull ▸ Move Rejects to Trash…: always confirmed, worded for rejects.
    var isRejects = false

    var title: String {
        switch kind {
        case .trash where isRejects:
            return urls.count == 1 ? "Move 1 Reject to Trash?" : "Move \(urls.count) Rejects to Trash?"
        case .trash:
            return urls.count == 1 ? "Move to Trash?" : "Move \(urls.count) Items to Trash?"
        case .permanent:
            return urls.count == 1 ? "Delete Permanently?" : "Delete \(urls.count) Items Permanently?"
        }
    }

    var message: String {
        let subject = names.count == 1 ? names.first.map { "\"\($0)\"" } : nil

        switch kind {
        case .trash where isRejects:
            if let subject {
                return "The rejected item \(subject) will be moved to the Trash. You can put it back from there or undo this action."
            }
            return "The \(urls.count) rejected items in this listing, including any hidden by filters, will be moved to the Trash. You can put them back from there or undo this action."
        case .trash:
            if let subject {
                return "\(subject) will be moved to the Trash. You can put it back from there or undo this action."
            }
            return "These \(urls.count) items will be moved to the Trash. You can put them back from there or undo this action."
        case .permanent:
            if let subject {
                return "\(subject) will be deleted immediately. This action cannot be undone."
            }
            return "These \(urls.count) items will be deleted immediately. This action cannot be undone."
        }
    }

    var confirmButtonTitle: String {
        switch kind {
        case .trash: return "Move to Trash"
        case .permanent: return "Delete"
        }
    }
}

private struct PathMoveRecord {
    let from: URL
    let to: URL
}

/// Result of a batch move: what to undo, plus how many files moved, were
/// skipped because the name was already taken, or failed.
private struct MoveOutcome {
    let historyEntry: FolderHistoryEntry?
    let movedCount: Int
    let skippedCount: Int
    let failedCount: Int
    let firstError: Error?
}

/// Path-keyed metadata (ratings, flags, tags, favorites, custom order) lifted
/// off a file or folder and its descendants, so it can be put back later.
private struct PathMetadataSnapshot {
    var ratings: [String: Int] = [:]
    var flags: [String: FileFlag] = [:]
    var tags: [String: [UUID]] = [:]
    var favorites: Set<String> = []
    var customOrders: [String: [String]] = [:]
    /// Collection id -> (index in that collection, path) of every removed member.
    var collectionMemberships: [UUID: [(index: Int, path: String)]] = [:]
    /// XMP sidecars trashed with the item (put back on undo).
    var sidecars: [SidecarTrashRecord] = []

    var isEmpty: Bool {
        ratings.isEmpty && flags.isEmpty && tags.isEmpty && favorites.isEmpty && customOrders.isEmpty
            && collectionMemberships.isEmpty && sidecars.isEmpty
    }
}

private struct TrashRestoreRecord {
    let trashedURL: URL
    let originalURL: URL
    /// Metadata removed from the stores when the item was trashed; restored
    /// together with the file on undo.
    let metadata: PathMetadataSnapshot
}

/// One undoable move step: items to trash first (redo of a Replace), then the
/// moves, then items to put back from the Trash (undo of a Replace).
private struct MoveBatch {
    var trashFirst: [URL] = []
    var moves: [PathMoveRecord] = []
    var restoreAfter: [TrashRestoreRecord] = []
    /// Apply the moves through unique temporary names so chained and swapped
    /// names (a→b while b→c, or a↔b) work in any order.
    var twoPhase = false

    var isEmpty: Bool { trashFirst.isEmpty && moves.isEmpty && restoreAfter.isEmpty }
    var itemCount: Int { trashFirst.count + moves.count + restoreAfter.count }
}

/// Paths a mutation touched, so a refresh can invalidate just those instead of
/// every parser cache and the prompt index. Applied in order: removed, moved, added.
private struct ListingPathChanges {
    var removed: [String] = []
    var moves: [(from: String, to: String)] = []
    /// Paths that appeared from outside the listing (e.g. restored from Trash).
    var added: [String] = []
    /// Folders are involved; per-path invalidation would miss their descendants.
    var involvesDirectories = false

    var allPaths: [String] { removed + moves.flatMap { [$0.from, $0.to] } + added }

    mutating func noteDirectory(at path: String) {
        guard !involvesDirectories else { return }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            involvesDirectories = true
        }
    }
}

/// Outcome of applying one history entry. A partially failed apply yields both
/// an inverse (for what did happen) and a remainder (for what didn't), so a
/// half-applied entry is never retried as a whole.
struct FolderHistoryApplyResult {
    let inverse: FolderHistoryEntry?
    let remaining: FolderHistoryEntry?
    let appliedCount: Int
    let failedCount: Int
    let firstError: Error?
}

struct FolderHistoryEntry {
    let title: String
    let apply: @MainActor () async -> FolderHistoryApplyResult
}

/// A visited location in the folder navigation history: the selected folder plus
/// the root it was browsed under, so going back can restore a previous root too.
private struct FolderNavigationLocation: Equatable {
    let folder: URL
    let root: URL
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
    var selectedFolderPath: URL? {
        didSet { invalidateSortedFolderContents() }
    }
    var folderContents: [FileEntry] = [] {
        didSet { invalidateSortedFolderContents() }
    }
    var isLoadingFolder = false

    // Sort & Filter
    var sortConfig = SortConfig() {
        didSet {
            // Picking a sort in a virtual listing replaces its similarity ranking
            // (Sort ▸ Similarity brings it back).
            if activeVirtualListing != nil, virtualListingRanked { virtualListingRanked = false }
            invalidateSortedFolderContents()
        }
    }
    var filterConfig = FilterConfig() {
        didSet {
            invalidateProcessedFolderContents()
            if filterConfig.colorFilter != oldValue.colorFilter { loadListingDominantColorsIfNeeded() }
        }
    }
    var searchQuery = "" {
        didSet { invalidateProcessedFolderContents() }
    }
    var searchMode: SearchMode = .filename {
        didSet { invalidateProcessedFolderContents() }
    }
    var contentSearchMatches: Set<String> = [] {
        didSet { invalidateProcessedFolderContents() }
    }
    private var customOrderByFolder: [String: [String]] = [:] {
        didSet { invalidateSortedFolderContents() }
    }
    private var ratingsByPath: [String: Int] = [:] {
        didSet {
            // Ratings only affect ordering when sorting by rating; otherwise
            // just the min-rating / smart folder filters need re-running.
            if sortConfig.field == .rating {
                invalidateSortedFolderContents()
            } else {
                invalidateProcessedFolderContents()
            }
        }
    }
    /// Pick / reject flags, path-keyed like ratings.
    private var flagBook = FlagBook() {
        didSet {
            if sortConfig.field == .flag {
                invalidateSortedFolderContents()
            } else {
                invalidateProcessedFolderContents()
            }
        }
    }
    private var lastStandardSortConfigByFolder: [String: SortConfig] = [:]
    private var collapsedSidebarFolderPaths: Set<String> = []
    private var previousSidebarCollapsedFolderPaths: Set<String>?

    // Culling
    /// Shows the culling HUD in the lightbox and enables auto-advance.
    var cullingModeEnabled = false {
        didSet {
            guard cullingModeEnabled != oldValue else { return }
            settings.cullingMode = cullingModeEnabled
        }
    }
    /// After a flag / rating / label key, move on to the next item (culling mode only).
    var cullAutoAdvance = true {
        didSet {
            guard cullAutoAdvance != oldValue else { return }
            settings.cullAutoAdvance = cullAutoAdvance
        }
    }
    /// Last culling action, for the HUD's flash.
    var cullFeedback: CullFeedback?

    // Tags
    var allTags: [FileTag] = []
    private var tagAssignments: [String: [UUID]] = [:] {
        didSet { invalidateProcessedFolderContents() }
    }
    var filterByTagID: UUID? {
        didSet { invalidateProcessedFolderContents() }
    }

    // Favorites / Pinned
    var favoritePaths: Set<String> = []

    // Command Palette
    var commandPaletteOpen = false

    // Preview Panel Toggle
    var previewPaneCollapsed = false

    // Prompt Diff
    var promptDiffSession: PromptDiffSession?

    // Batch Metadata
    var batchMetadataEditorOpen = false

    // Selection
    //
    // Indices are positions in `processedFolderContents`. They are mirrored by
    // paths so that whenever the processed list changes (search, filters, sort,
    // refresh...) the indices can be recomputed to point at the same files.
    var selectedItemIndex: Int = -1 {
        didSet {
            guard !isRemappingSelection else { return }
            primarySelectionPath = processedPath(at: selectedItemIndex)
        }
    }
    var selectedIndices: Set<Int> = [] {
        didSet {
            guard !isRemappingSelection else { return }
            guard !selectedIndices.isEmpty else {
                selectionPathSet = []
                return
            }
            let items = processedFolderContents
            selectionPathSet = Set(selectedIndices.compactMap { index in
                index >= 0 && index < items.count ? items[index].path : nil
            })
        }
    }
    var selectionAnchorIndex: Int? {
        didSet {
            guard !isRemappingSelection else { return }
            selectionAnchorPath = selectionAnchorIndex.flatMap { processedPath(at: $0) }
        }
    }
    @ObservationIgnored private var selectionPathSet: Set<String> = []
    @ObservationIgnored private var primarySelectionPath: String?
    @ObservationIgnored private var selectionAnchorPath: String?
    @ObservationIgnored private var lightboxPath: String?
    @ObservationIgnored private var isRemappingSelection = false
    var selectedPromptEntry: PromptEntry?
    var activePane: ExplorerPane = .content
    var gridColumnCount: Int = 1
    var sidebarContentRowHint: Int = 0
    var showStatusBar = true
    var appearanceMode: AppAppearanceMode = .dark {
        didSet {
            guard appearanceMode != oldValue else { return }
            appearanceMode.applyToApp()
        }
    }

    // File operation preferences
    var confirmBeforeTrash = false
    var duplicateNamePolicy: DuplicateNamePolicy = .keepBoth
    var externalDragOperation: ExternalDragOperation = .copy

    // UI State
    var thumbnailSize: Double = 5
    var thumbnailsOnly = false
    var lightboxOpen = false {
        didSet {
            if lightboxOpen, !oldValue {
                lightboxPath = processedPath(at: lightboxIndex)
            }
            // A lightbox the Similar Images page opened hands the browser back.
            if !lightboxOpen, oldValue { similarPageLightboxDidClose() }
            // Version stacks: a lightbox opened on a stack walks its members.
            if lightboxOpen != oldValue { stacksLightboxDidChange(isOpen: lightboxOpen) }
        }
    }
    var lightboxIndex: Int = 0 {
        didSet {
            guard !isRemappingSelection else { return }
            lightboxPath = processedPath(at: lightboxIndex)
        }
    }
    var toastMessage: (message: String, type: ToastType)?
    var toastID: Int = 0
    @ObservationIgnored private var toastDismissWorkItem: DispatchWorkItem?
    var helpOpen = false
    var statisticsOpen = false
    var isLoadingComparison = false
    var comparisonSession: AoeComparisonSession?
    var deleteConfirmationRequest: DeleteConfirmationRequest?
    var metadataEditorPath: String?

    // View mode & grouping
    var viewMode: BrowserViewMode = .grid {
        didSet {
            guard viewMode != oldValue else { return }
            settings.viewMode = viewMode.rawValue
        }
    }
    var groupBy: GroupByField = .none {
        didSet {
            guard groupBy != oldValue else { return }
            settings.groupBy = groupBy.rawValue
            contentGroupsRevision &+= 1
            // Grouping reorders the processed list so each group is contiguous.
            invalidateProcessedFolderContents()
            if groupBy.needsGenerationParameters {
                loadListingPromptDataIfNeeded(force: true)
            }
            if groupBy == .colorFamily { loadListingDominantColorsIfNeeded() }
        }
    }
    /// Generation parameters for files in the current listing, filled from the
    /// library index and from the per-folder prompt index build.
    var parametersByPath: [String: GenerationParameters] = [:] {
        didSet {
            if groupBy.needsGenerationParameters {
                contentGroupsRevision &+= 1
                invalidateProcessedFolderContents()
            } else if activeSmartFolder != nil {
                invalidateProcessedFolderContents()
            }
        }
    }
    /// Original-case positive / negative prompt text per path for the current
    /// listing (the prompt index stores lowercased text only).
    var promptTextByPath: [String: String] = [:] {
        didSet { if activeSmartFolder != nil { invalidateProcessedFolderContents() } }
    }
    var negativePromptByPath: [String: String] = [:] {
        didSet { if activeSmartFolder != nil { invalidateProcessedFolderContents() } }
    }
    /// Bumped when grouping inputs other than the processed list change.
    private var contentGroupsRevision = 0
    @ObservationIgnored private var contentGroupsCacheKey: (processed: Int, groups: Int) = (-1, -1)
    @ObservationIgnored private var contentGroupsCache: [ContentGroup] = []

    /// Send to Mood / Send to Story in progress (drives the progress capsule).
    var artOfficialSendProgress: ArtOfficialSendProgress?

    // Feature sheets (UI lives in the views; these just drive presentation)
    var batchRenameOpen = false
    var librarySearchOpen = false
    var duplicatesOpen = false
    var snippetsOpen = false

    // Collections
    var collections: [FileCollection] = []
    var collectionSets: [CollectionSet] = []
    /// When set, the listing is that collection's files (cross-folder) instead
    /// of `selectedFolderPath`'s contents.
    var activeCollectionID: UUID? {
        didSet {
            guard activeCollectionID != oldValue else { return }
            invalidateSortedFolderContents()
        }
    }
    /// Existing files of the active collection, in collection order.
    var collectionContents: [FileEntry] = [] {
        didSet { invalidateSortedFolderContents() }
    }

    // Virtual listings (More Like This, palette matches, a Similar Images group)
    /// When set, the listing is these ranked files instead of the folder's.
    /// Mutually exclusive with `activeCollectionID` (see `ListingModeState`).
    var activeVirtualListing: VirtualListing? {
        didSet {
            guard activeVirtualListing != oldValue else { return }
            invalidateSortedFolderContents()
        }
    }
    /// Existing files of the virtual listing, in rank order.
    var virtualListingContents: [FileEntry] = [] {
        didSet { invalidateSortedFolderContents() }
    }
    /// Rank order (true) or the regular sort (false) for a virtual listing.
    var virtualListingRanked = true {
        didSet {
            guard virtualListingRanked != oldValue else { return }
            invalidateSortedFolderContents()
        }
    }

    // Visual search
    /// Browser or the Similar Images page (never persisted: launch shows the browser).
    var similarPage = SimilarPageModeState()
    /// Similar Images page state and results; kept while the page is closed.
    let similarImages = SimilarImagesModel()
    /// Set while a lightbox opened from the Similar Images page borrows the
    /// hidden browser's listing (see `SimilarPageLightboxSession`).
    @ObservationIgnored var similarPageLightboxSession: SimilarPageLightboxSession?
    /// True while the page puts the browser's listing back, so the listing
    /// switches involved don't count as the user leaving the page.
    @ObservationIgnored var isRestoringBrowserForSimilarPage = false
    /// Browser state a restore (after a page lightbox) is still putting back.
    @ObservationIgnored var similarPagePendingRestore: SimilarPageBrowserSnapshot?
    /// This Folder / Whole Library for every visual search (persisted).
    var visualSearchScope: VisualSearchScopeChoice = .folder {
        didSet {
            guard visualSearchScope != oldValue else { return }
            settings.visualSearchScope = visualSearchScope.rawValue
        }
    }
    /// Filter ▸ Colour… popover (anchored to the toolbar's Filter menu).
    var colorFilterPopoverOpen = false
    /// Appearance: thin dominant-colour strip on grid tiles.
    var showTileColorStrip = false {
        didSet {
            guard showTileColorStrip != oldValue else { return }
            settings.showTileColorStrip = showTileColorStrip
            loadListingDominantColorsIfNeeded()
        }
    }
    /// Dominant colours of the listing's files (loaded only while something
    /// needs them: colour filter / rule, Colour Family grouping, tile strip).
    var dominantColorsByPath: [String: [DominantColor]] = [:] {
        didSet {
            if groupBy == .colorFamily { contentGroupsRevision &+= 1 }
            if filterConfig.colorFilter != nil || groupBy == .colorFamily
                || activeSmartFolder?.criteria.dominantColor != nil
            {
                invalidateProcessedFolderContents()
            }
        }
    }
    @ObservationIgnored var dominantColorsTask: Task<Void, Never>?

    // Library search
    var librarySearchQuery = ""
    var librarySearchResults: [LibrarySearchHit] = []
    var isLibrarySearching = false
    var isLibraryIndexing = false
    var libraryIndexProgress: (done: Int, total: Int)?
    @ObservationIgnored var librarySearchTask: Task<Void, Never>?
    @ObservationIgnored var libraryIndexTask: Task<Void, Never>?
    @ObservationIgnored var libraryIndexRoot: String?
    /// Serialises fire-and-forget library index mutations (moves / removals).
    @ObservationIgnored var libraryIndexMutationTask: Task<Void, Never>?
    @ObservationIgnored var libraryParametersTask: Task<Void, Never>?

    // Duplicates
    var duplicateClusters: [[String]] = []
    var isFindingDuplicates = false
    @ObservationIgnored var duplicatesTask: Task<Void, Never>?

    // Recent History
    var recentFolders: [RecentItem] = []

    // Smart Folders
    var smartFolders: [SmartFolder] = []
    var activeSmartFolder: SmartFolder? {
        didSet {
            invalidateProcessedFolderContents()
            if activeSmartFolderNeedsPromptData { loadListingPromptDataIfNeeded(force: false) }
            if activeSmartFolder?.criteria.dominantColor != nil { loadListingDominantColorsIfNeeded() }
        }
    }
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
    private let flagStore = FlagStore()
    private var undoHistory: [FolderHistoryEntry] = []
    private var redoHistory: [FolderHistoryEntry] = []
    private var backNavigationStack: [FolderNavigationLocation] = []
    private var forwardNavigationStack: [FolderNavigationLocation] = []
    private let maxNavigationHistoryEntries = 50
    @ObservationIgnored private var promptEntryLoadTask: Task<Void, Never>?
    @ObservationIgnored private var contentSearchTask: Task<Void, Never>?
    /// Folder-owned prompt index build; searches await it instead of cancelling it.
    @ObservationIgnored private var promptIndexBuildTask: Task<Void, Never>?
    @ObservationIgnored private var promptIndexBuildFolderPath: String?
    @ObservationIgnored private var promptIndexBuildID = 0
    /// Scope whose full build also filled `promptTextByPath` / `parametersByPath`.
    /// The prompt index can outlive those maps (they reset on navigation), so a
    /// complete index alone doesn't mean the maps are filled.
    @ObservationIgnored var promptDataCompleteScope: String?
    /// Bumped by every navigation so stale async results can be discarded.
    @ObservationIgnored private var navigationGeneration = 0
    private var processedFolderContentsRevision = 0
    @ObservationIgnored private var processedFolderContentsCacheRevision = -1
    @ObservationIgnored private var processedFolderContentsCache: [FileEntry] = []
    /// Sorted (but unfiltered) folder contents. Only contents, sort config,
    /// ratings and custom order invalidate it, so typing a search just filters.
    @ObservationIgnored private var sortedFolderContentsRevision = 0
    @ObservationIgnored private var sortedFolderContentsCacheRevision = -1
    @ObservationIgnored private var sortedFolderContentsCache: [FileEntry] = []

    init() {
        // Curation safety first: backs up every store on the first launch with it.
        CurationController.shared.bootstrap()
        customOrderByFolder = settings.loadCustomOrders()
        ratingsByPath = settings.loadRatings()
        flagBook = flagStore.load()
        cullingModeEnabled = settings.cullingMode
        cullAutoAdvance = settings.cullAutoAdvance
        thumbnailSize = settings.thumbnailSize
        sortConfig = SortConfig(
            field: SortField(rawValue: settings.sortField) ?? .type,
            direction: SortDirection(rawValue: settings.sortDirection) ?? .asc
        )
        filterConfig = settings.loadFilterConfig()
        showStatusBar = settings.showStatusBar
        thumbnailsOnly = settings.thumbnailsOnly
        appearanceMode = AppAppearanceMode(rawValue: settings.appearanceMode) ?? .dark

        confirmBeforeTrash = settings.confirmBeforeTrash
        duplicateNamePolicy = DuplicateNamePolicy(rawValue: settings.duplicateNamePolicy) ?? .keepBoth
        externalDragOperation = ExternalDragOperation(rawValue: settings.externalDragOperation) ?? .copy

        searchMode = SearchMode(rawValue: settings.searchMode) ?? .filename
        previewPaneCollapsed = settings.previewPaneCollapsed
        viewMode = BrowserViewMode(rawValue: settings.viewMode) ?? .grid
        groupBy = GroupByField(rawValue: settings.groupBy) ?? .none
        visualSearchScope = VisualSearchScopeChoice(rawValue: settings.visualSearchScope) ?? .folder
        showTileColorStrip = settings.showTileColorStrip
        collections = CollectionService.shared.all()
        collectionSets = CollectionService.shared.allSets()

        // Load recent history & smart folders
        recentFolders = RecentHistoryService.shared.loadRecentFolders()
        smartFolders = SmartFolderService.shared.loadSmartFolders()

        // Load tags & favorites
        allTags = TagService.shared.loadTags()
        tagAssignments = TagService.shared.loadAssignments()
        favoritePaths = FavoritesService.shared.loadFavorites()

        // Restore last root, folder and selected file
        if !settings.lastOpenedFolder.isEmpty {
            let url = URL(fileURLWithPath: settings.lastOpenedFolder)
            if FileManager.default.fileExists(atPath: url.path) {
                let lastFolder = settings.lastSelectedFolder
                let lastFile = settings.lastSelectedFilePath
                Task { await restoreLastSession(root: url, folderPath: lastFolder, filePath: lastFile) }
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.persistWindowState() }
        }

        installCurationHooks()
        installIngestHooks()
        installStackHooks()
        installImageTextHooks()

        let mode = appearanceMode
        DispatchQueue.main.async { mode.applyToApp() }
    }

    /// Re-opens the last root, the folder below it that was showing, and the
    /// file that was selected there, without adding navigation history.
    private func restoreLastSession(root: URL, folderPath: String, filePath: String) async {
        var folder = root
        if !folderPath.isEmpty {
            let candidate = URL(fileURLWithPath: folderPath)
            if isSameOrDescendant(candidate, of: root), isExistingDirectory(candidate) {
                folder = candidate
            }
        }

        let generationBefore = navigationGeneration
        await applyFolderSelection(folder, rootToEstablish: root)
        // Any other navigation since then wins over the restored selection.
        guard !filePath.isEmpty,
              navigationGeneration == generationBefore &+ 1,
              selectedFolderPath?.standardizedFileURL.path == folder.standardizedFileURL.path,
              primarySelectionPath == nil
        else { return }
        selectPath(filePath)
    }

    /// Saves what window restoration needs (called at quit).
    func persistWindowState() {
        settings.previewPaneCollapsed = previewPaneCollapsed
        settings.viewMode = viewMode.rawValue
        settings.groupBy = groupBy.rawValue
        if isFolderListing {
            settings.lastSelectedFolder = selectedFolderPath?.path ?? ""
            settings.lastSelectedFilePath = primarySelectionPath ?? ""
        }
    }

    /// Selects the listed item at `path`; returns false when it isn't listed.
    @discardableResult
    func selectPath(_ path: String) -> Bool {
        let items = processedFolderContents
        guard let index = items.firstIndex(where: { $0.path == path }) else { return false }
        selectItem(at: index)
        return true
    }

    // MARK: - Processed Contents (sorted/filtered)

    var processedFolderContents: [FileEntry] {
        let revision = processedFolderContentsRevision
        if processedFolderContentsCacheRevision == revision {
            return processedFolderContentsCache
        }

        // Filtering preserves order, so filters run on top of the cached sort.
        var items = sortedFolderContents
        let query = searchQuery.lowercased()
        // Text recognised in images (ExplorerViewModel+Suggestions).
        let imageTextHits: Set<String> = (searchMode == .imageText || searchMode == .all) && !query.isEmpty
            ? imageTextMatchingPaths(for: query) : []

        // Filter
        items = items.filter { item in
            // Search
            if !query.isEmpty {
                let name = item.name.lowercased()
                switch searchMode {
                case .filename:
                    if !name.contains(query) { return false }
                case .prompt:
                    if !contentSearchMatches.contains(item.path) { return false }
                case .all:
                    if !name.contains(query) && !contentSearchMatches.contains(item.path)
                        && !imageTextHits.contains(item.path) { return false }
                case .imageText:
                    if !imageTextHits.contains(item.path) { return false }
                }
            }

            if let fileType = FileHelpers.filterType(for: item),
               filterConfig.hides(fileType)
            {
                return false
            }

            return true
        }

        if filterConfig.filterMinRating > 0 {
            items = items.filter { rating(for: $0.path) >= filterConfig.filterMinRating }
        }

        if filterConfig.flagFilter != .all || !filterConfig.labelFilter.isEmpty {
            let config = filterConfig
            items = items.filter { config.passesCullFilters(flag: flag(for: $0.path), labelNumber: $0.labelNumber) }
        }

        // Colour filter: files whose dominant colours are near the palette.
        if let colorFilter = filterConfig.colorFilter {
            let colors = dominantColorsByPath
            items = items.filter { PaletteMatcher.matches(colors[$0.path] ?? [], filter: colorFilter) }
        }

        // Tag filter
        if let tagID = filterByTagID {
            let taggedPaths = taggedPaths(for: tagID)
            items = items.filter { taggedPaths.contains($0.path) }
        }

        // Smart folder filter
        if let smartFolder = activeSmartFolder {
            items = SmartFolderService.filter(
                items,
                criteria: smartFolder.criteria,
                context: smartFolderContext()
            )
        }

        // Version stacks (ExplorerViewModel+Stacks): collapsed stacks list only their cover.
        items = applyingStacks(to: items)

        if groupBy != .none {
            items = groupedContiguously(items)
        }

        processedFolderContentsCache = items
        processedFolderContentsCacheRevision = revision
        return items
    }

    /// `folderContents` sorted by the current sort config, cached until the
    /// contents, sort config, ratings or custom order change.
    private var sortedFolderContents: [FileEntry] {
        let revision = sortedFolderContentsRevision
        if sortedFolderContentsCacheRevision == revision {
            return sortedFolderContentsCache
        }

        let sorted: [FileEntry]
        if activeVirtualListing != nil, virtualListingRanked {
            // Similarity rank, most similar first.
            sorted = virtualListingContents
        } else if activeCollectionID != nil, sortConfig.field == .custom {
            // Collection order is the custom order in collection mode.
            sorted = collectionContents
        } else {
            sorted = sortItems(listingSourceContents, using: sortConfig)
        }
        sortedFolderContentsCache = sorted
        sortedFolderContentsCacheRevision = revision
        return sorted
    }

    var currentCustomOrder: [String] {
        guard let path = selectedFolderPath?.path else { return [] }
        return customOrderByFolder[path] ?? []
    }

    var selectedItems: [FileEntry] {
        let items = processedFolderContents
        return selectedIndices
            .sorted()
            .compactMap { index -> FileEntry? in
                guard index >= 0 && index < items.count else { return nil }
                return items[index]
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
        // Variants tucked behind a collapsed stack's cover aren't "hidden" by a filter.
        max(0, listingSourceContents.count - processedFolderContents.count - collapsedStackMemberCount)
    }

    /// Unsorted, unfiltered entries behind the listing: the active collection's
    /// files, or the selected folder's contents.
    var listingSourceContents: [FileEntry] {
        if activeVirtualListing != nil { return virtualListingContents }
        return activeCollectionID != nil ? collectionContents : folderContents
    }

    /// True while the listing shows a collection instead of a folder.
    var isCollectionMode: Bool { activeCollectionID != nil }

    /// True while the listing shows a virtual listing (Similar to …, palette matches…).
    var isVirtualListingMode: Bool { activeVirtualListing != nil }

    /// True when the listing is the selected folder's own contents (not a
    /// collection or a virtual listing): folder-only actions need this.
    var isFolderListing: Bool { activeCollectionID == nil && activeVirtualListing == nil }

    /// Folder / collection / virtual listing, as the pure state machine sees it.
    var listingModeState: ListingModeState {
        ListingModeState(collectionID: activeCollectionID, virtualListing: activeVirtualListing)
    }

    var activeCollection: FileCollection? {
        guard let activeCollectionID else { return nil }
        return collections.first(where: { $0.id == activeCollectionID })
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
        recordNavigationHistory(destination: url, root: setAsRoot ? url : explorerRootPath)
        await applyFolderSelection(url, rootToEstablish: setAsRoot ? url : nil)
    }

    private func applyFolderSelection(_ url: URL, rootToEstablish: URL?) async {
        // Every navigation gets a token; after each await we bail if a newer
        // navigation has started, so root/folder/history changes can't interleave.
        navigationGeneration &+= 1
        let generation = navigationGeneration
        let folderChanged = selectedFolderPath?.standardizedFileURL.path != url.standardizedFileURL.path

        // All synchronous state first, so the model is never half-switched.
        if let rootToEstablish {
            explorerRootPath = rootToEstablish
            settings.lastOpenedFolder = rootToEstablish.path
            collapsedSidebarFolderPaths = []
            previousSidebarCollapsedFolderPaths = nil
            undoHistory = []
            redoHistory = []
            folderTree = []
        }

        clearSelection()
        let leavingCollection = !isFolderListing
        if folderChanged || rootToEstablish != nil || leavingCollection {
            // Stale entries from the previous folder must not stay actionable
            // while the new one is scanned off the main thread.
            folderContents = []
            resetListingPromptData()
        }
        activeCollectionID = nil
        collectionContents = []
        activeVirtualListing = nil
        virtualListingContents = []
        selectedFolderPath = url
        settings.lastSelectedFolder = url.path
        activeSmartFolder = nil
        rememberStandardSortConfig(sortConfig, for: url)
        revealSidebarSelection(url)

        // The prompt index belongs to the folder it was built for.
        cancelPromptIndexBuild()

        if rootToEstablish != nil {
            await clearParserCaches()
            guard generation == navigationGeneration else { return }
        }

        guard await refreshFolderContents(showLoading: true) else { return }
        guard generation == navigationGeneration else { return }
        loadListingPromptDataIfNeeded(force: false)
        if let rootToEstablish {
            autoIndexLibraryIfNeeded(root: rootToEstablish)
            curationRootDidOpen(rootToEstablish)
            liveUpdatesRootDidOpen(rootToEstablish)
            // Visual index: automatic, low priority, incremental — unless the
            // user stopped it in Settings ▸ Search Index.
            if VisualIndexController.shared.isEnabled {
                VisualIndexController.shared.start(root: rootToEstablish)
            }
        }
        guard await refreshFolderTree() else { return }
        guard generation == navigationGeneration else { return }
        refreshPromptSearchIfNeeded()
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
        await refreshFolder(changes: nil)
    }

    /// With `changes` (a mutation the app made itself), only the touched paths
    /// are invalidated and the prompt index is patched per path; without, every
    /// parser cache and the prompt index are dropped to pick up outside edits.
    private func refreshFolder(changes: ListingPathChanges?) async {
        let generation = navigationGeneration
        // Parser caches are keyed by path with no modification check, so a
        // refresh must drop (at least the touched) entries to pick up changes.
        var pathsToReparse: [String] = []
        if let changes, !changes.involvesDirectories {
            pathsToReparse = await invalidateCaches(for: changes)
        } else {
            await clearParserCaches()
        }
        guard generation == navigationGeneration else { return }
        if activeVirtualListing != nil {
            guard await reloadVirtualListingContents() else { return }
        } else if activeCollectionID != nil {
            guard await reloadCollectionContents() else { return }
        } else {
            guard await refreshFolderContents(showLoading: false) else { return }
        }
        if !pathsToReparse.isEmpty {
            await reindexPromptData(for: pathsToReparse)
            guard generation == navigationGeneration else { return }
        }
        loadListingPromptDataIfNeeded(force: true)
        guard await refreshFolderTree() else { return }
        refreshPromptSearchIfNeeded()
    }

    // MARK: - Back / Forward Navigation

    var canNavigateBack: Bool { !backNavigationStack.isEmpty }
    var canNavigateForward: Bool { !forwardNavigationStack.isEmpty }

    var backNavigationTitle: String {
        backNavigationStack.last.map { "Back to \"\(navigationDisplayName(for: $0.folder))\"" } ?? "Back"
    }

    var forwardNavigationTitle: String {
        forwardNavigationStack.last.map { "Forward to \"\(navigationDisplayName(for: $0.folder))\"" } ?? "Forward"
    }

    func navigateBack() async {
        guard let next = nextReachableLocation(in: backNavigationStack) else {
            backNavigationStack = []
            showToast("No previous folder is still available", type: .info)
            return
        }

        let origin = currentNavigationLocation
        backNavigationStack = next.remaining
        await applyHistoryLocation(next.location)

        if let origin, origin != next.location {
            forwardNavigationStack = trimmedNavigationStack(forwardNavigationStack + [origin])
        }
    }

    func navigateForward() async {
        guard let next = nextReachableLocation(in: forwardNavigationStack) else {
            forwardNavigationStack = []
            showToast("No forward folder is still available", type: .info)
            return
        }

        let origin = currentNavigationLocation
        forwardNavigationStack = next.remaining
        await applyHistoryLocation(next.location)

        if let origin, origin != next.location {
            backNavigationStack = trimmedNavigationStack(backNavigationStack + [origin])
        }
    }

    private var currentNavigationLocation: FolderNavigationLocation? {
        guard let selectedFolderPath, let explorerRootPath else { return nil }
        return FolderNavigationLocation(
            folder: selectedFolderPath.standardizedFileURL,
            root: explorerRootPath.standardizedFileURL
        )
    }

    private func recordNavigationHistory(destination url: URL, root: URL?) {
        guard let current = currentNavigationLocation, let root else { return }

        let destination = FolderNavigationLocation(
            folder: url.standardizedFileURL,
            root: root.standardizedFileURL
        )
        guard destination != current else { return }

        backNavigationStack = trimmedNavigationStack(backNavigationStack + [current])
        forwardNavigationStack.removeAll()
    }

    private func applyHistoryLocation(_ location: FolderNavigationLocation) async {
        let rootChanged = explorerRootPath?.standardizedFileURL.path != location.root.path
        await applyFolderSelection(location.folder, rootToEstablish: rootChanged ? location.root : nil)
    }

    /// Pops the most recent entry that still exists on disk, discarding stale ones along the way.
    private func nextReachableLocation(
        in stack: [FolderNavigationLocation]
    ) -> (location: FolderNavigationLocation, remaining: [FolderNavigationLocation])? {
        var remaining = stack

        while let candidate = remaining.popLast() {
            if isReachable(candidate) {
                return (candidate, remaining)
            }
        }

        return nil
    }

    private func isReachable(_ location: FolderNavigationLocation) -> Bool {
        isExistingDirectory(location.folder) && isExistingDirectory(location.root)
    }

    private func isExistingDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    private func trimmedNavigationStack(_ stack: [FolderNavigationLocation]) -> [FolderNavigationLocation] {
        guard stack.count > maxNavigationHistoryEntries else { return stack }
        return Array(stack.suffix(maxNavigationHistoryEntries))
    }

    private func navigationDisplayName(for url: URL) -> String {
        let name = url.lastPathComponent
        return name.isEmpty ? url.path : name
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

        deleteConfirmationRequest = DeleteConfirmationRequest(kind: .permanent, urls: urls, names: names)
    }

    /// Entry point for every "move to Trash" action, so the confirmation
    /// preference is honoured in one place rather than at each call site.
    func requestTrash(at urls: [URL]) {
        let targets = deduplicatedURLs(urls)
        guard !targets.isEmpty else { return }

        guard confirmBeforeTrash else {
            Task { await trashItems(at: targets) }
            return
        }

        deleteConfirmationRequest = DeleteConfirmationRequest(
            kind: .trash,
            urls: targets,
            names: targets.map(\.lastPathComponent)
        )
    }

    func clearDeleteConfirmation() {
        deleteConfirmationRequest = nil
    }

    func deleteItemsPermanently(at urls: [URL]) async {
        let targets = deduplicatedURLs(urls)
        guard !targets.isEmpty else { return }

        var deletedCount = 0
        var failedCount = 0
        var firstError: Error?

        for target in targets {
            do {
                try FileSystemService.deleteEntry(at: target)
                deletedCount += 1
                // A new file at this path must not inherit the old one's metadata.
                _ = removeMetadata(under: target.path)
            } catch {
                failedCount += 1
                if firstError == nil { firstError = error }
            }
        }

        // Always refresh: some items may be gone even when others failed.
        clearSelection()
        await refreshFolder()

        if failedCount == 0 {
            showToast(deletedCount == 1 ? "Item deleted permanently" : "Deleted \(deletedCount) items permanently", type: .success)
        } else if deletedCount == 0 {
            let noun = targets.count == 1 ? "item" : "items"
            showToast("Failed to delete \(noun): \(firstError?.localizedDescription ?? "Unknown error")", type: .error)
        } else {
            showToast(
                "Deleted \(deletedCount) of \(targets.count) items; \(failedCount) failed: \(firstError?.localizedDescription ?? "Unknown error")",
                type: .error
            )
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
            migrateMetadataKeys(from: sourceURL.path, to: renamedURL.path)
            var changes = ListingPathChanges(moves: [(sourceURL.path, renamedURL.path)])
            changes.noteDirectory(at: renamedURL.path)
            await refreshAfterMutation(preferredPaths: [renamedURL.path], changes: changes)
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

    // MARK: - Create Folder

    var isShowingNewFolderPrompt = false {
        didSet {
            // Collections are not folders: nothing to create a folder in.
            if isShowingNewFolderPrompt, !canCreateFolder {
                isShowingNewFolderPrompt = false
            }
        }
    }

    /// False in collection mode or without a folder.
    var canCreateFolder: Bool {
        isFolderListing && selectedFolderPath != nil
    }
    var newFolderName = "untitled folder"

    func createNewFolder() async {
        guard isFolderListing, let parent = selectedFolderPath else {
            showToast("No folder selected", type: .error)
            return
        }

        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            showToast("Folder name cannot be empty", type: .error)
            return
        }

        do {
            let newURL = try FileSystemService.createFolder(in: parent, named: name)
            await refreshFolder()
            showToast("Created \"\(newURL.lastPathComponent)\"", type: .success)
        } catch {
            showToast("Failed to create folder: \(error.localizedDescription)", type: .error)
        }

        newFolderName = "untitled folder"
    }

    func trashItems(at urls: [URL]) async {
        let targets = deduplicatedURLs(urls)
        guard !targets.isEmpty else { return }

        let outcome = await trashURLs(targets)
        if !outcome.records.isEmpty {
            recordFolderHistoryEntry(
                makeRestoreTrashHistoryEntry(recordsToApplyNext: outcome.records, title: "Move to Trash")
            )
        }

        let trashedCount = outcome.records.count
        let failedCount = outcome.failed.count
        let errorText = outcome.firstError?.localizedDescription ?? "Unknown error"
        if failedCount == 0 {
            showToast(trashedCount == 1 ? "Moved to Trash" : "Moved \(trashedCount) items to Trash", type: .success)
        } else if trashedCount == 0 {
            let noun = targets.count == 1 ? "item" : "items"
            showToast("Failed to trash \(noun): \(errorText)", type: .error)
        } else {
            showToast("Moved \(trashedCount) of \(targets.count) items to Trash; \(failedCount) failed: \(errorText)", type: .error)
        }
    }

    func trashItem(at url: URL) async {
        await trashItems(at: [url])
    }

    func deleteItemPermanently(at url: URL) async {
        await deleteItemsPermanently(at: [url])
    }

    func importExternalFiles(_ urls: [URL]) async {
        guard isFolderListing else {
            showToast("Open a folder to import files into it", type: .info)
            return
        }
        guard let dest = selectedFolderPath else { return }
        await importExternalFiles(urls, to: dest)
    }

    func importExternalFiles(_ urls: [URL], to destinationDir: URL) async {
        let allowed = urls.filter { FileHelpers.isDroppable($0.path) }
        guard !allowed.isEmpty else {
            showToast("No valid files to import", type: .error)
            return
        }

        let outcome = await performMoveOperation(allowed, to: destinationDir, title: "Import")
        if let historyEntry = outcome.historyEntry {
            recordFolderHistoryEntry(historyEntry)
        }
        showToast(
            moveOutcomeMessage(verb: "Imported", outcome: outcome),
            type: moveOutcomeToastType(outcome)
        )
    }

    func undoLastFolderAction() async {
        guard let entry = undoHistory.popLast() else { return }

        let result = await entry.apply()
        // Only what did not apply goes back on the undo stack; what did apply
        // becomes redoable.
        if let remaining = result.remaining {
            undoHistory.append(remaining)
        }
        if let inverse = result.inverse {
            redoHistory.append(inverse)
        }
        showHistoryToast(verb: "undo", pastVerb: "Undid", title: entry.title, result: result)
    }

    func redoLastFolderAction() async {
        guard let entry = redoHistory.popLast() else { return }

        let result = await entry.apply()
        if let remaining = result.remaining {
            redoHistory.append(remaining)
        }
        if let inverse = result.inverse {
            undoHistory.append(inverse)
        }
        showHistoryToast(verb: "redo", pastVerb: "Redid", title: entry.title, result: result)
    }

    private func showHistoryToast(verb: String, pastVerb: String, title: String, result: FolderHistoryApplyResult) {
        let action = title.lowercased()
        let errorText = result.firstError?.localizedDescription ?? "Unknown error"

        if result.failedCount == 0 {
            showToast("\(pastVerb) \(action)", type: .success)
        } else if result.appliedCount == 0 {
            showToast("Failed to \(verb) \(action): \(errorText)", type: .error)
        } else {
            let noun = result.failedCount == 1 ? "item" : "items"
            showToast(
                "\(pastVerb) \(action) for \(result.appliedCount) items; \(result.failedCount) \(noun) failed: \(errorText)",
                type: .error
            )
        }
    }

    func openDeveloperWebsite() {
        guard let url = URL(string: HelpContent.developerResource.urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Opens the Settings window (the app's `Settings` scene, ⌘,). Only a view
    /// can call `openSettings`, so this posts for MainContentView to act on.
    func openSettings() {
        NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
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
        syncQuickLookWithSelection()
    }

    /// ⌘A: selects everything in the current listing (files and folders, like Finder).
    /// Keeps the current primary item when there is one, so the preview doesn't jump.
    func selectAllItems() {
        let items = processedFolderContents
        guard !items.isEmpty else { return }
        activePane = .content

        let primary = (selectedItemIndex >= 0 && selectedItemIndex < items.count) ? selectedItemIndex : 0
        selectedIndices = Set(items.indices)
        selectionAnchorIndex = 0
        if selectedItemIndex != primary {
            selectedItemIndex = primary
            loadPromptEntry(for: items[primary])
        }
        syncQuickLookWithSelection()
    }

    func clearSelection() {
        promptEntryLoadTask?.cancel()
        promptEntryLoadTask = nil
        selectedIndices = []
        selectedItemIndex = -1
        selectionAnchorIndex = nil
        selectionPathSet = []
        primarySelectionPath = nil
        selectionAnchorPath = nil
        selectedPromptEntry = nil
    }

    /// Path of the primary selected item, independent of list position.
    var selectedItemPath: String? {
        primarySelectionPath
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

        activePane = .sidebar

        guard let selectedFolderPath else {
            await selectFolder(folders[0].url)
            return
        }

        // The sidebar only lists a few levels; when the current folder is deeper
        // (or hidden) there is no sensible neighbour, so do nothing rather than
        // jumping to the root's first child.
        let currentPath = selectedFolderPath.standardizedFileURL.path
        guard let currentIndex = folders.firstIndex(where: { $0.url.standardizedFileURL.path == currentPath })
        else { return }

        let nextIndex = max(0, min(folders.count - 1, currentIndex + offset))
        guard nextIndex != currentIndex else { return }
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
        // A virtual listing has no custom order of its own.
        if activeVirtualListing != nil { return }
        if let collectionID = activeCollectionID {
            // In collection mode the collection's own order is the custom order;
            // adopt the order currently on screen before switching to it.
            if sortConfig.field != .custom {
                let order = sortedFolderContents.map(\.path)
                CollectionService.shared.reorder(id: collectionID, paths: order)
                collections = CollectionService.shared.all()
                let byPath = Dictionary(collectionContents.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
                collectionContents = order.compactMap { byPath[$0] }
                sortConfig = SortConfig(field: .custom, direction: .asc)
                persistSortConfig()
            }
            return
        }
        guard let folderPath = selectedFolderPath?.path else { return }

        let nextOrder: [String]
        if sortConfig.field == .custom {
            nextOrder = completedCustomOrderForCurrentFolder()
        } else {
            rememberStandardSortConfig(sortConfig, for: selectedFolderPath)
            nextOrder = sortedFolderContents.map(\.path)
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
        if activeVirtualListing != nil { return }
        if activeCollectionID != nil {
            reorderCollectionItems(sourcePaths: sourcePaths, targetPath: targetPath, position: position)
            return
        }
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
        settings.saveFilterConfig(filterConfig)
    }

    func persistThumbnailSize() {
        settings.thumbnailSize = thumbnailSize
    }

    func persistStatusBarVisibility() {
        settings.showStatusBar = showStatusBar
    }

    func persistThumbnailsOnly() {
        settings.thumbnailsOnly = thumbnailsOnly
    }

    func persistConfirmBeforeTrash() {
        settings.confirmBeforeTrash = confirmBeforeTrash
    }

    func persistDuplicateNamePolicy() {
        settings.duplicateNamePolicy = duplicateNamePolicy.rawValue
    }

    func persistExternalDragOperation() {
        settings.externalDragOperation = externalDragOperation.rawValue
    }

    func persistAppearanceMode() {
        settings.appearanceMode = appearanceMode.rawValue
    }

    // MARK: - Ratings

    func rating(for path: String) -> Int {
        ratingsByPath[path] ?? 0
    }

    /// Rates one file (undoable; see `applyRating(_:toPaths:)`).
    func setRating(_ rating: Int, for path: String) {
        applyRating(rating, toPaths: [path])
    }

    /// Writes ratings (0 clears) without recording history. Returns the
    /// previous rating of every path whose rating changed.
    @discardableResult
    func writeRatings(_ values: [String: Int]) -> [String: Int] {
        var next = ratingsByPath
        var previous: [String: Int] = [:]
        for (path, rating) in values {
            let clamped = max(0, min(5, rating))
            let old = next[path] ?? 0
            guard old != clamped else { continue }
            previous[path] = old
            if clamped == 0 {
                next.removeValue(forKey: path)
            } else {
                next[path] = clamped
            }
        }
        guard !previous.isEmpty else { return [:] }
        ratingsByPath = next
        settings.saveRatings(next)
        return previous
    }

    // MARK: - Flags

    func flag(for path: String) -> FileFlag {
        flagBook.flag(for: path)
    }

    /// Writes flags without recording history. Returns the previous flag of
    /// every path whose flag changed.
    @discardableResult
    func writeFlags(_ values: [String: FileFlag]) -> [String: FileFlag] {
        var next = flagBook
        var previous: [String: FileFlag] = [:]
        for (path, flag) in values {
            let old = next.flag(for: path)
            guard old != flag else { continue }
            previous[path] = old
            next.set(flag, for: path)
        }
        guard !previous.isEmpty else { return [:] }
        flagBook = next
        flagStore.save(next)
        return previous
    }

    // MARK: - Recent History

    func openRecentFolder(_ item: RecentItem) async {
        await selectFolder(item.url, setAsRoot: true)
    }

    func removeRecentFolder(_ item: RecentItem) {
        RecentHistoryService.shared.removeRecentFolder(path: item.path)
        recentFolders = RecentHistoryService.shared.loadRecentFolders()
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
        // From the Similar Images page, a click shows the smart folder in the
        // browser (it doesn't toggle an already active one off).
        if similarPage.handle(.smartFolderActivated) == .leftPage, activeSmartFolder?.id == folder.id { return }
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

        // Editing the active smart folder must apply its new criteria now.
        if activeSmartFolder?.id == folder.id {
            activeSmartFolder = folder  // didSet invalidates processed contents
        }
    }

    // MARK: - Tags

    func addTag(name: String, colorHex: String) {
        let tag = FileTag(name: name, colorHex: colorHex)
        TagService.shared.addTag(tag)
        allTags = TagService.shared.loadTags()
    }

    func removeTag(id: UUID) {
        TagService.shared.removeTag(id: id)
        allTags = TagService.shared.loadTags()
        tagAssignments = TagService.shared.loadAssignments()
        if filterByTagID == id { filterByTagID = nil }
    }

    func updateTag(_ tag: FileTag) {
        TagService.shared.updateTag(tag)
        allTags = TagService.shared.loadTags()
    }

    func toggleTagForFile(_ tagID: UUID, path: String) {
        TagService.shared.toggleTag(tagID, forPath: path)
        tagAssignments = TagService.shared.loadAssignments()
    }

    /// Applies one target state to the whole selection: if every selected file
    /// already has the tag it is removed from all, otherwise added to all.
    func toggleTagForSelectedFiles(_ tagID: UUID) {
        let paths = selectedPaths
        guard !paths.isEmpty else { return }

        let shouldRemove = paths.allSatisfy { fileHasTag(tagID, path: $0) }
        for path in paths {
            if shouldRemove {
                TagService.shared.removeTag(tagID, fromPath: path)
            } else {
                TagService.shared.assignTag(tagID, toPath: path)
            }
        }
        tagAssignments = TagService.shared.loadAssignments()
    }

    func tagsForFile(at path: String) -> [FileTag] {
        let tagIDs = tagAssignments[path] ?? []
        let idSet = Set(tagIDs)
        return allTags.filter { idSet.contains($0.id) }
    }

    func fileHasTag(_ tagID: UUID, path: String) -> Bool {
        tagAssignments[path]?.contains(tagID) ?? false
    }

    // MARK: - Favorites / Pinned Items

    func isFavorite(path: String) -> Bool {
        favoritePaths.contains(path)
    }

    func toggleFavorite(path: String) {
        if favoritePaths.contains(path) {
            favoritePaths.remove(path)
        } else {
            favoritePaths.insert(path)
        }
        FavoritesService.shared.saveFavorites(favoritePaths)
    }

    /// Applies one target state to the whole selection: if every selected file
    /// is already a favorite all are unfavorited, otherwise all are favorited.
    func toggleFavoriteForSelectedFiles() {
        let paths = selectedPaths
        guard !paths.isEmpty else { return }

        if paths.allSatisfy(favoritePaths.contains) {
            favoritePaths.subtract(paths)
        } else {
            favoritePaths.formUnion(paths)
        }
        FavoritesService.shared.saveFavorites(favoritePaths)
    }

    // MARK: - Prompt Content Search

    func updateContentSearch() {
        contentSearchTask?.cancel()

        guard !searchQuery.isEmpty, searchMode != .filename, searchMode != .imageText else {
            if !contentSearchMatches.isEmpty {
                contentSearchMatches = []
            }
            return
        }

        let query = searchQuery
        let mode = searchMode
        let selectedFolderPath = promptIndexScope

        // Debounce prompt search so rapid typing or mode changes do not pile up parse work.
        // Cancelling this task never cancels the index build it waits on.
        contentSearchTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }

            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let selectedFolderPath else { return }

            await self.ensurePromptIndex(for: selectedFolderPath)

            guard !Task.isCancelled else { return }
            let matches = await PromptIndexService.shared.search(query: query)
            guard !Task.isCancelled else { return }

            guard self.searchQuery == query,
                  self.searchMode == mode,
                  self.promptIndexScope == selectedFolderPath
            else {
                return
            }

            if matches != self.contentSearchMatches {
                self.contentSearchMatches = matches
            }
        }
    }

    /// Makes sure the prompt index holds a complete build for `folderPath`,
    /// starting a build if needed or waiting on the one already running.
    /// Key the prompt index is built for: the active collection, else the folder.
    var promptIndexScope: String? {
        if let activeVirtualListing { return "virtual:\(activeVirtualListing.id.uuidString)" }
        if let activeCollectionID { return "collection:\(activeCollectionID.uuidString)" }
        return selectedFolderPath?.path
    }

    /// Makes sure the prompt index (and the prompt text / parameter maps
    /// captured with it) is complete for the current listing.
    func ensurePromptIndexForCurrentListing() async {
        guard let scope = promptIndexScope else { return }
        await ensurePromptIndex(for: scope)
    }

    private func ensurePromptIndex(for folderPath: String) async {
        if promptDataCompleteScope == folderPath,
           await PromptIndexService.shared.isIndexComplete(for: folderPath) { return }
        guard promptIndexScope == folderPath else { return }

        if let task = promptIndexBuildTask, promptIndexBuildFolderPath == folderPath {
            await task.value
            return
        }

        promptIndexBuildTask?.cancel()
        promptIndexBuildID &+= 1
        let buildID = promptIndexBuildID
        let items = listingSourceContents.filter { !$0.isDirectory }

        let task = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.buildPromptIndex(items: items, folderPath: folderPath)
            if self.promptIndexBuildID == buildID {
                self.promptIndexBuildTask = nil
                self.promptIndexBuildFolderPath = nil
            }
        }
        promptIndexBuildTask = task
        promptIndexBuildFolderPath = folderPath
        await task.value
    }

    private func cancelPromptIndexBuild() {
        promptIndexBuildTask?.cancel()
        promptIndexBuildTask = nil
        promptIndexBuildFolderPath = nil
        promptIndexBuildID &+= 1
    }

    /// Build the prompt index for all parseable files in `folderPath`.
    /// Parsing happens on the parser actors, off the main actor. Only a build
    /// that reaches the end is marked complete.
    private func buildPromptIndex(items: [FileEntry], folderPath: String) async {
        let generation = await PromptIndexService.shared.beginBuild(folderPath: folderPath)

        var pendingPrompts: [String: String] = [:]
        var pendingNegatives: [String: String] = [:]
        var pendingParameters: [String: GenerationParameters] = [:]

        func flush() {
            guard promptIndexScope == folderPath else { return }
            if !pendingPrompts.isEmpty { promptTextByPath.merge(pendingPrompts) { _, new in new } }
            if !pendingNegatives.isEmpty { negativePromptByPath.merge(pendingNegatives) { _, new in new } }
            if !pendingParameters.isEmpty {
                // Parsed values fill gaps left by the library index.
                var next = parametersByPath
                for (path, parsed) in pendingParameters {
                    next[path] = (next[path] ?? GenerationParameters()).filling(from: parsed)
                }
                parametersByPath = next
            }
            pendingPrompts = [:]
            pendingNegatives = [:]
            pendingParameters = [:]
        }

        for (offset, item) in items.enumerated() {
            guard !Task.isCancelled else { return }

            let parsed = await Self.parsePromptData(for: item)

            guard !Task.isCancelled else { return }
            if let prompt = parsed.searchText, !prompt.isEmpty {
                await PromptIndexService.shared.index(path: item.path, prompt: prompt, generation: generation)
            }
            if let prompt = parsed.prompt, !prompt.isEmpty { pendingPrompts[item.path] = prompt }
            if let negative = parsed.negative, !negative.isEmpty { pendingNegatives[item.path] = negative }
            if !parsed.parameters.isEmpty { pendingParameters[item.path] = parsed.parameters }

            if offset % 40 == 39 { flush() }
        }

        guard !Task.isCancelled else { return }
        flush()
        await PromptIndexService.shared.finishBuild(generation: generation)
        if promptIndexScope == folderPath {
            promptDataCompleteScope = folderPath
        }
    }

    /// Prompt text, negative prompt and generation parameters parsed from one
    /// file. `searchText` is what the content search indexes.
    struct ParsedPromptData: Sendable {
        var searchText: String?
        var prompt: String?
        var negative: String?
        var parameters = GenerationParameters()
    }

    nonisolated static func parsePromptData(for item: FileEntry) async -> ParsedPromptData {
        var result = ParsedPromptData()
        if FileHelpers.isPlibFile(item.name) || FileHelpers.isAoeFile(item.name) {
            let entry = FileHelpers.isPlibFile(item.name)
                ? await PlibParser.shared.parse(at: item.url)
                : await AoeParser.shared.parse(at: item.url)
            guard let entry else { return result }
            result.prompt = entry.prompt
            result.searchText = entry.prompt
            result.negative = entry.blindPrompt
            result.parameters = GenerationParameters.parsed(
                from: entry.embeddedMetadata,
                model: entry.generationInfo.model
            )
        } else if FileHelpers.isArtOfficialDocumentFile(item.name) {
            // Mood / Story: title + body (names, notes, shot descriptions, palette hex)
            // go into the content search; they have no positive prompt of their own.
            if let document = await ArtOfficialDocumentParser.shared.parse(at: item.url) {
                let text = document.indexText
                result.searchText = text.isEmpty ? nil : text
            }
        } else if FileHelpers.isImageFile(item.name) {
            let meta = await ImageMetadataParser.shared.parse(at: item.url)
            if !meta.prompt.isEmpty {
                result.prompt = meta.prompt
                result.searchText = meta.prompt
            }
            result.negative = meta.negativePrompt
            result.parameters = GenerationParameters.parsed(from: meta.fields, model: meta.model)
        } else if FileHelpers.isAudioFile(item.name) {
            let meta = await AudioMetadataParser.shared.parse(at: item.url)
            result.searchText = meta.searchText.isEmpty ? nil : meta.searchText
        }
        return result
    }

    func persistSearchMode() {
        settings.searchMode = searchMode.rawValue
    }

    // MARK: - Preview Panel Toggle

    func togglePreviewPane() {
        previewPaneCollapsed.toggle()
        settings.previewPaneCollapsed = previewPaneCollapsed
    }

    // MARK: - Prompt Diff

    func openPromptDiff() {
        openPromptDiff(for: Array(selectedItems.prefix(2)))
    }

    /// Opens the prompt diff for the first two of `paths` (e.g. a duplicate cluster).
    func compareCluster(_ paths: [String]) {
        let listed = Dictionary(listingSourceContents.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let items = paths.prefix(2).compactMap { listed[$0] ?? FileEntry.load(from: URL(fileURLWithPath: $0)) }
        openPromptDiff(for: items)
    }

    private func openPromptDiff(for items: [FileEntry]) {
        guard items.count == 2 else {
            showToast("Select two files to compare prompts", type: .info)
            return
        }

        Task {
            async let entryA = promptEntry(for: items[0])
            async let entryB = promptEntry(for: items[1])

            guard let a = await entryA, let b = await entryB else {
                showToast("Unable to load both files for comparison", type: .error)
                return
            }

            guard !a.prompt.isEmpty || !b.prompt.isEmpty else {
                showToast("Neither file contains prompt text", type: .info)
                return
            }

            promptDiffSession = PromptDiffSession(
                sourceA: a, nameA: items[0].name,
                sourceB: b, nameB: items[1].name
            )
        }
    }

    // MARK: - Batch Metadata Editing

    func openBatchMetadataEditor() {
        let imageItems = selectedItems.filter { item in
            !item.isDirectory && isEmbeddableImageFile(item.name)
        }
        guard !imageItems.isEmpty else {
            showToast("Select PNG or JPEG files to batch edit metadata", type: .info)
            return
        }
        batchMetadataEditorOpen = true
    }

    func isEmbeddableImageFile(_ name: String) -> Bool {
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        return ext == "png" || ext == "jpg" || ext == "jpeg"
    }

    func isEmbeddableAudioFile(_ name: String) -> Bool {
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        return ext == "mp3" || ext == "wav"
    }

    func isEmbeddableMetadataFile(_ name: String) -> Bool {
        isEmbeddableImageFile(name) || isEmbeddableAudioFile(name)
    }

    var selectedEmbeddableImages: [FileEntry] {
        selectedItems.filter { !$0.isDirectory && isEmbeddableImageFile($0.name) }
    }

    // MARK: - Metadata Editing

    func openMetadataEditor(for path: String) {
        metadataEditorPath = path
    }

    /// Called after metadata is successfully embedded into a supported media file.
    /// Clears caches and reloads the entry so the UI reflects the new metadata.
    func didEmbedMetadata(at path: String) {
        ThumbnailService.shared.clearCache()

        showToast("Metadata embedded", type: .success)
        metadataEditorPath = nil

        Task {
            // The parsers only support clear-all; the caches must be dropped
            // *before* reloading or the old metadata is served again.
            await ImageMetadataParser.shared.clearCache()
            await AudioMetadataParser.shared.clearCache()
            // The index holds this file's old text; rebuild it on the next search.
            self.cancelPromptIndexBuild()
            await PromptIndexService.shared.clearIndex()

            // Reload the selected entry to pick up new metadata
            if self.primarySelectionPath == path,
               let item = self.processedFolderContents.first(where: { $0.path == path })
            {
                self.loadPromptEntry(for: item)
            }
            self.refreshPromptSearchIfNeeded()
        }
    }

    // MARK: - Toast

    func showToast(_ message: String, type: ToastType) {
        toastDismissWorkItem?.cancel()
        toastMessage = (message, type)
        toastID += 1

        let currentID = toastID
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.toastID == currentID else { return }
            self.toastMessage = nil
        }
        toastDismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    // MARK: - Breadcrumbs

    var breadcrumbs: [(name: String, url: URL)] {
        if let listing = activeVirtualListing {
            // A single crumb, like a collection's.
            let back = selectedFolderPath ?? explorerRootPath ?? URL(fileURLWithPath: NSHomeDirectory())
            return [(listing.title, back)]
        }
        if let collection = activeCollection {
            // A single crumb; clicking it returns to the folder the collection
            // was opened from.
            let back = selectedFolderPath ?? explorerRootPath ?? URL(fileURLWithPath: NSHomeDirectory())
            return [(collection.name, back)]
        }
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

    /// Reads the selected folder off the main actor. Returns false (and applies
    /// nothing) when a newer navigation made the result stale.
    @discardableResult
    private func refreshFolderContents(showLoading: Bool) async -> Bool {
        guard let path = selectedFolderPath else {
            folderContents = []
            isLoadingFolder = false
            return true
        }

        let generation = navigationGeneration
        if showLoading {
            isLoadingFolder = true
        }

        let entries = await Task.detached(priority: .userInitiated) {
            (try? FileSystemService.readDirectory(at: path)) ?? []
        }.value

        // A newer navigation owns `isLoadingFolder` from here on.
        guard generation == navigationGeneration, selectedFolderPath == path else { return false }

        folderContents = entries
        isLoadingFolder = false
        CurationController.shared.listingDidLoad(entries)
        return true
    }

    /// Builds the sidebar tree off the main actor. Returns false when stale.
    @discardableResult
    private func refreshFolderTree() async -> Bool {
        guard let root = explorerRootPath else {
            folderTree = []
            return true
        }

        let generation = navigationGeneration
        let tree = await Task.detached(priority: .userInitiated) {
            (try? FileSystemService.buildFolderTree(root: root, depth: 3)) ?? []
        }.value

        guard generation == navigationGeneration, explorerRootPath == root else { return false }
        folderTree = tree
        return true
    }

    private func loadPromptEntry(for item: FileEntry) {
        promptEntryLoadTask?.cancel()

        guard !item.isDirectory else {
            selectedPromptEntry = nil
            return
        }

        let expectedPath = item.path
        selectedPromptEntry = nil

        promptEntryLoadTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            let entry = await self.promptEntry(for: item)
            guard !Task.isCancelled else { return }

            guard self.primarySelectionPath == expectedPath else { return }

            self.selectedPromptEntry = entry

            // Index prompt content in background for content search.
            if let entry, !Task.isCancelled {
                let searchText = self.searchIndexText(for: entry)
                if !searchText.isEmpty {
                    await PromptIndexService.shared.index(path: expectedPath, prompt: searchText)
                }
            }
        }
    }

    func promptEntry(for item: FileEntry) async -> PromptEntry? {
        guard !item.isDirectory else { return nil }

        if FileHelpers.isPlibFile(item.name) {
            async let metadata = FileSystemService.getMetadataAsync(for: item.url)
            guard var entry = await PlibParser.shared.parse(at: item.url) else { return nil }
            guard !Task.isCancelled else { return nil }
            entry.fileMetadata = await metadata
            return entry
        }

        if FileHelpers.isAoeFile(item.name) {
            async let metadata = FileSystemService.getMetadataAsync(for: item.url)
            guard var entry = await AoeParser.shared.parse(at: item.url) else { return nil }
            guard !Task.isCancelled else { return nil }
            entry.fileMetadata = await metadata
            return entry
        }

        if FileHelpers.isArtOfficialDocumentFile(item.name) {
            async let metadata = FileSystemService.getMetadataAsync(for: item.url)
            guard let document = await ArtOfficialDocumentParser.shared.parse(at: item.url) else { return nil }
            guard !Task.isCancelled else { return nil }
            // Rendered board / contact sheet, disk-cached by ThumbnailService.
            let overview = await ThumbnailService.shared.previewImage(for: item.url, maxPixelSize: 2048)
            guard !Task.isCancelled else { return nil }
            var entry = PromptEntry(
                prompt: "",
                blindPrompt: nil,
                hint: nil,
                generationInfo: GenerationInfo(aspectRatio: .notAvailable, model: "N/A", timestamp: "", numberOfImages: 0),
                images: overview.map { [$0] } ?? [],
                referenceImages: [],
                rawImages: [],
                rawReferenceImages: [],
                sourcePath: item.path,
                analysis: nil,
                embeddedMetadata: [],
                fileMetadata: await metadata
            )
            entry.artOfficialDocument = document
            return entry
        }

        if FileHelpers.isImageFile(item.name) {
            async let metadata = FileSystemService.getMetadataAsync(for: item.url)
            async let image = ThumbnailService.shared.previewImage(for: item.url)
            async let imageMetadata = ImageMetadataParser.shared.parse(at: item.url)

            guard let image = await image else { return nil }
            guard !Task.isCancelled else { return nil }

            let fileMetadata = await metadata
            let parsedMetadata = await imageMetadata

            var entry = PromptEntry(
                prompt: parsedMetadata.prompt,
                blindPrompt: parsedMetadata.negativePrompt,
                generationInfo: GenerationInfo(
                    aspectRatio: aspectRatio(for: fileMetadata),
                    model: parsedMetadata.model ?? "N/A",
                    timestamp: parsedMetadata.timestamp ?? "",
                    numberOfImages: 1
                ),
                images: [image],
                referenceImages: [],
                rawImages: [item.path],
                rawReferenceImages: [],
                sourcePath: item.path,
                embeddedMetadata: parsedMetadata.fields,
                fileMetadata: fileMetadata
            )
            entry.comfyPromptJSON = parsedMetadata.comfyPromptJSON
            entry.comfyWorkflowJSON = parsedMetadata.comfyWorkflowJSON
            return entry
        }

        if FileHelpers.isVideoFile(item.name) {
            let fileMetadata = await FileSystemService.getMetadataAsync(for: item.url)

            return PromptEntry(
                prompt: "",
                blindPrompt: nil,
                hint: nil,
                generationInfo: GenerationInfo(
                    aspectRatio: aspectRatio(for: fileMetadata),
                    model: "N/A",
                    timestamp: "",
                    numberOfImages: 0
                ),
                images: [],
                referenceImages: [],
                rawImages: [],
                rawReferenceImages: [],
                sourcePath: item.path,
                videoURL: item.url,
                analysis: nil,
                embeddedMetadata: [],
                fileMetadata: fileMetadata
            )
        }

        if FileHelpers.isAudioFile(item.name) {
            async let metadata = FileSystemService.getMetadataAsync(for: item.url)
            async let audioMetadata = AudioMetadataParser.shared.parse(at: item.url)

            let fileMetadata = await metadata
            let parsedMetadata = await audioMetadata

            return PromptEntry(
                prompt: "",
                blindPrompt: nil,
                hint: nil,
                generationInfo: GenerationInfo(
                    aspectRatio: .notAvailable,
                    model: "N/A",
                    timestamp: "",
                    numberOfImages: 0
                ),
                images: [],
                referenceImages: [],
                rawImages: [],
                rawReferenceImages: [],
                sourcePath: item.path,
                audioURL: item.url,
                analysis: nil,
                embeddedMetadata: parsedMetadata.fields,
                fileMetadata: fileMetadata
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

    private func searchIndexText(for entry: PromptEntry) -> String {
        if let document = entry.artOfficialDocument {
            return document.indexText
        }
        let prompt = entry.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty {
            return prompt
        }

        var seen = Set<String>()
        var values: [String] = []

        for field in entry.embeddedMetadata {
            let key = canonicalMetadataKey(field.label)
            guard key != "software" else { continue }

            let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }

            let identity = value.lowercased()
            guard seen.insert(identity).inserted else { continue }
            values.append(value)
        }

        return values.joined(separator: "\n")
    }

    private func canonicalMetadataKey(_ value: String) -> String {
        value
            .lowercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    /// Drops the parser-cache entries and patches the prompt index for the
    /// paths in `changes`. Returns the paths that entered the listing and must
    /// be parsed into the index to keep it complete for the current scope.
    private func invalidateCaches(for changes: ListingPathChanges) async -> [String] {
        for path in Set(changes.allPaths) {
            await PlibParser.shared.invalidate(path: path)
            await AoeParser.shared.invalidate(path: path)
            await ArtOfficialDocumentParser.shared.invalidate(path: path)
        }
        // These two only support clear-all.
        await ImageMetadataParser.shared.clearCache()
        await AudioMetadataParser.shared.clearCache()

        // A build in flight may already have read old paths; restart it.
        if promptIndexBuildTask != nil {
            cancelPromptIndexBuild()
            await PromptIndexService.shared.clearIndex()
            return []
        }

        let scope = promptIndexScope
        let folderScope = isFolderListing ? selectedFolderPath?.standardizedFileURL.path : nil
        func inScope(_ path: String) -> Bool {
            guard let folderScope else { return true }  // collections / virtual listings: membership follows the file
            return (path as NSString).deletingLastPathComponent == folderScope
        }

        var entering: [String] = []
        // Moved out of the listed folder. (Removed paths' prompt data was already
        // dropped by `removeMetadata`.)
        var leaving: [String] = []
        for move in changes.moves {
            if !inScope(move.to) {
                leaving.append(move.to)
            } else if !inScope(move.from) {
                entering.append(move.to)
            }
        }
        entering += changes.added.filter(inScope)

        let indexComplete: Bool
        if let scope {
            indexComplete = await PromptIndexService.shared.isIndexComplete(for: scope)
        } else {
            indexComplete = false
        }
        // Parsing a large import eagerly would cost more than a lazy rebuild.
        if indexComplete, entering.count > 50 {
            await PromptIndexService.shared.clearIndex()
            return []
        }

        await PromptIndexService.shared.apply(
            removing: changes.removed,
            moves: changes.moves.map { PromptIndexService.PathMove(from: $0.from, to: $0.to) },
            thenRemoving: leaving
        )
        for path in leaving {
            promptTextByPath.removeValue(forKey: path)
            negativePromptByPath.removeValue(forKey: path)
            parametersByPath.removeValue(forKey: path)
        }
        return indexComplete ? entering : []
    }

    /// Parses `paths` (those still in the listing) into the prompt index and the
    /// prompt text / parameter maps, as a full build would.
    private func reindexPromptData(for paths: [String]) async {
        let scope = promptIndexScope
        let listed = Dictionary(listingSourceContents.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        for path in paths {
            guard let item = listed[path], !item.isDirectory else { continue }
            let parsed = await Self.parsePromptData(for: item)
            guard promptIndexScope == scope else { return }
            if let text = parsed.searchText, !text.isEmpty {
                await PromptIndexService.shared.index(path: path, prompt: text)
            }
            if let prompt = parsed.prompt, !prompt.isEmpty { promptTextByPath[path] = prompt }
            if let negative = parsed.negative, !negative.isEmpty { negativePromptByPath[path] = negative }
            if !parsed.parameters.isEmpty {
                parametersByPath[path] = (parametersByPath[path] ?? GenerationParameters()).filling(from: parsed.parameters)
            }
        }
    }

    private func clearParserCaches() async {
        cancelPromptIndexBuild()
        await PlibParser.shared.clearCache()
        await AoeParser.shared.clearCache()
        await ArtOfficialDocumentParser.shared.clearCache()
        await ImageMetadataParser.shared.clearCache()
        await AudioMetadataParser.shared.clearCache()
        await PromptIndexService.shared.clearIndex()
    }

    private func refreshPromptSearchIfNeeded() {
        contentSearchTask?.cancel()

        guard !searchQuery.isEmpty, searchMode != .filename, searchMode != .imageText else {
            if !contentSearchMatches.isEmpty {
                contentSearchMatches = []
            }
            return
        }

        updateContentSearch()
    }

    private func invalidateSortedFolderContents() {
        sortedFolderContentsRevision &+= 1
        invalidateProcessedFolderContents()
    }

    /// Listing inputs owned by other controllers (version stacks, text in images)
    /// changed: re-run the filters.
    func externalListingInputsDidChange() {
        invalidateProcessedFolderContents()
    }

    private func invalidateProcessedFolderContents() {
        processedFolderContentsRevision &+= 1

        // Selection and lightbox are stored as indices into the processed list;
        // re-point them at the same files in the new list.
        if !selectionPathSet.isEmpty || primarySelectionPath != nil || lightboxOpen {
            remapSelectionToProcessedContents()
        }
    }

    private func processedPath(at index: Int) -> String? {
        guard index >= 0 else { return nil }
        let items = processedFolderContents
        guard index >= 0 && index < items.count else { return nil }
        return items[index].path
    }

    /// Recomputes `selectedIndices`, `selectedItemIndex`, `selectionAnchorIndex`
    /// and `lightboxIndex` from the stored paths against the current processed
    /// list. Paths that are no longer listed are dropped.
    private func remapSelectionToProcessedContents() {
        guard !isRemappingSelection else { return }
        isRemappingSelection = true
        defer { isRemappingSelection = false }

        let items = processedFolderContents
        var indexByPath: [String: Int] = [:]
        indexByPath.reserveCapacity(items.count)
        for (index, item) in items.enumerated() where indexByPath[item.path] == nil {
            indexByPath[item.path] = index
        }

        // Multi-selection
        let survivingPaths = selectionPathSet.filter { indexByPath[$0] != nil }
        selectionPathSet = survivingPaths
        let nextIndices = Set(survivingPaths.compactMap { indexByPath[$0] })
        if nextIndices != selectedIndices {
            selectedIndices = nextIndices
        }

        // Primary item: keep it when still listed, else fall back to the first
        // remaining selected item.
        let previousPrimaryPath = primarySelectionPath
        var nextPrimaryIndex = primarySelectionPath.flatMap { indexByPath[$0] }
        if nextPrimaryIndex == nil {
            nextPrimaryIndex = nextIndices.min()
        }
        let nextPrimaryPath = nextPrimaryIndex.map { items[$0].path }
        primarySelectionPath = nextPrimaryPath
        let nextSelectedItemIndex = nextPrimaryIndex ?? -1
        if nextSelectedItemIndex != selectedItemIndex {
            selectedItemIndex = nextSelectedItemIndex
        }

        if nextPrimaryPath != previousPrimaryPath {
            if let nextPrimaryIndex {
                loadPromptEntry(for: items[nextPrimaryIndex])
            } else {
                promptEntryLoadTask?.cancel()
                promptEntryLoadTask = nil
                selectedPromptEntry = nil
            }
        }

        // Anchor
        var nextAnchorIndex = selectionAnchorPath.flatMap { indexByPath[$0] }
        if nextAnchorIndex == nil, !nextIndices.isEmpty {
            nextAnchorIndex = nextPrimaryIndex
        }
        selectionAnchorPath = nextAnchorIndex.map { items[$0].path }
        if nextAnchorIndex != selectionAnchorIndex {
            selectionAnchorIndex = nextAnchorIndex
        }

        // Lightbox: follow its item; if it vanished, move to the nearest
        // previewable item, or close when there is none.
        if lightboxOpen {
            if let lightboxPath, let index = indexByPath[lightboxPath] {
                if lightboxIndex != index { lightboxIndex = index }
            } else if let index = nearestPreviewableIndex(in: items, around: lightboxIndex) {
                lightboxIndex = index
                lightboxPath = items[index].path
            } else {
                lightboxOpen = false
                lightboxIndex = 0
                lightboxPath = nil
            }
        } else if lightboxIndex < 0 || lightboxIndex >= max(1, items.count) {
            lightboxIndex = 0
            lightboxPath = nil
        }
    }

    private func nearestPreviewableIndex(in items: [FileEntry], around index: Int) -> Int? {
        guard !items.isEmpty else { return nil }
        let start = max(0, min(items.count - 1, index))
        for distance in 0..<items.count {
            let after = start + distance
            if after < items.count, FileHelpers.isPreviewable(items[after]) { return after }
            let before = start - distance
            if distance > 0, before >= 0, FileHelpers.isPreviewable(items[before]) { return before }
            if after >= items.count && before < 0 { break }
        }
        return nil
    }

    private func taggedPaths(for tagID: UUID) -> Set<String> {
        Set(tagAssignments.compactMap { path, assignedTagIDs in
            assignedTagIDs.contains(tagID) ? path : nil
        })
    }

    private func moveItems(_ urls: [URL], to destinationDir: URL) async {
        let sources = validatedMoveSources(urls, to: destinationDir)
        guard !sources.isEmpty else {
            showToast("Invalid move destination", type: .error)
            return
        }

        let outcome = await performMoveOperation(sources, to: destinationDir, title: "Move")
        if let historyEntry = outcome.historyEntry {
            recordFolderHistoryEntry(historyEntry)
        }
        showToast(
            moveOutcomeMessage(verb: "Moved", outcome: outcome),
            type: moveOutcomeToastType(outcome)
        )
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

        if config.field == .flag {
            // `.asc` is picks first, like rating's high-to-low `.asc`.
            let book = flagBook
            sortedItems.sort { a, b in
                let fA = book.flag(for: a.path).rawValue
                let fB = book.flag(for: b.path).rawValue
                if fA != fB {
                    return config.direction == .asc ? fA > fB : fA < fB
                }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
            return sortedItems
        }

        if config.field == .label {
            // Finder's menu order (Red … Gray); unlabeled items last either way.
            sortedItems.sort { a, b in
                let rA = FinderLabel(labelNumber: a.labelNumber).sortRank
                let rB = FinderLabel(labelNumber: b.labelNumber).sortRank
                switch (rA, rB) {
                case let (x?, y?) where x != y:
                    return config.direction == .asc ? x < y : x > y
                case (.some, nil):
                    return true
                case (nil, .some):
                    return false
                default:
                    return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                }
            }
            return sortedItems
        }

        if config.field == .dateModified || config.field == .dateCreated || config.field == .size {
            // Folders first (like Finder), then by value; missing values sort
            // last in either direction; ties fall back to name.
            let field = config.field
            func value(_ entry: FileEntry) -> Double? {
                switch field {
                case .dateModified: return entry.modifiedDate?.timeIntervalSinceReferenceDate
                case .dateCreated: return entry.creationDate?.timeIntervalSinceReferenceDate
                default: return entry.fileSize.map(Double.init)
                }
            }
            let decorated = sortedItems.map { (entry: $0, value: value($0)) }
            return decorated.sorted { lhs, rhs in
                if lhs.entry.isDirectory != rhs.entry.isDirectory { return lhs.entry.isDirectory }
                switch (lhs.value, rhs.value) {
                case let (a?, b?) where a != b:
                    return config.direction == .asc ? a < b : a > b
                case (.some, nil):
                    return true
                case (nil, .some):
                    return false
                default:
                    let nameComparison = lhs.entry.name.localizedCaseInsensitiveCompare(rhs.entry.name)
                    if nameComparison != .orderedSame { return nameComparison == .orderedAscending }
                    return lhs.entry.path < rhs.entry.path
                }
            }.map(\.entry)
        }

        func compareStrings(_ lhs: String, _ rhs: String) -> ComparisonResult {
            lhs.localizedCaseInsensitiveCompare(rhs)
        }

        func comesBefore(_ comparison: ComparisonResult, direction: SortDirection) -> Bool {
            switch comparison {
            case .orderedAscending:
                return direction == .asc
            case .orderedDescending:
                return direction == .desc
            case .orderedSame:
                return false
            }
        }

        // Decorate-sort-undecorate: compute each entry's type descriptor once
        // instead of twice per comparison.
        let sortsByType = config.field == .type
        let decorated = sortedItems.map { entry in
            (entry: entry, descriptor: sortsByType ? FileHelpers.typeSortDescriptor(for: entry) : nil)
        }

        let sortedDecorated = decorated.sorted { lhs, rhs in
            let a = lhs.entry
            let b = rhs.entry

            if sortsByType, let descriptorA = lhs.descriptor, let descriptorB = rhs.descriptor {
                if a.isDirectory != b.isDirectory {
                    return a.isDirectory
                }

                if descriptorA.rank != descriptorB.rank {
                    let comparison = descriptorA.rank < descriptorB.rank ? ComparisonResult.orderedAscending : .orderedDescending
                    return comesBefore(comparison, direction: config.direction)
                }

                let typeComparison = compareStrings(descriptorA.typeLabel, descriptorB.typeLabel)
                if typeComparison != .orderedSame {
                    return comesBefore(typeComparison, direction: config.direction)
                }

                let extensionComparison = compareStrings(descriptorA.canonicalExtension, descriptorB.canonicalExtension)
                if extensionComparison != .orderedSame {
                    return comesBefore(extensionComparison, direction: config.direction)
                }
            }

            let nameComparison = compareStrings(a.name, b.name)
            if nameComparison != .orderedSame {
                return comesBefore(nameComparison, direction: config.direction)
            }

            return compareStrings(a.path, b.path) == .orderedAscending
        }

        return sortedDecorated.map(\.entry)
    }

    func recordFolderHistoryEntry(_ entry: FolderHistoryEntry) {
        undoHistory.append(entry)
        redoHistory.removeAll()

        if undoHistory.count > 50 {
            undoHistory.removeFirst(undoHistory.count - 50)
        }
    }

    /// Moves each source into `destinationDir`, continuing past failures.
    /// Always refreshes, and the history entry covers exactly what moved.
    private func performMoveOperation(_ sources: [URL], to destinationDir: URL, title: String) async -> MoveOutcome {
        var appliedRecords: [PathMoveRecord] = []
        var replacedRecords: [TrashRestoreRecord] = []
        var changes = ListingPathChanges()
        var skippedCount = 0
        var failedCount = 0
        var firstError: Error?

        for source in sources {
            let sourceURL = source.standardizedFileURL
            do {
                let report = try FileSystemService.moveFileReportingReplacement(
                    from: sourceURL,
                    to: destinationDir,
                    onDuplicate: duplicateNamePolicy
                )

                switch report.resolution {
                case let .moved(movedURL):
                    let record = PathMoveRecord(from: sourceURL, to: movedURL.standardizedFileURL)
                    if let trashedURL = report.replacedTrashURL {
                        // The replaced file's ratings, tags, favorite and collection
                        // membership go with it into the Trash (and come back on undo);
                        // the incoming file must not inherit them.
                        let metadata = removeMetadata(under: record.to.path)
                        replacedRecords.append(TrashRestoreRecord(
                            trashedURL: trashedURL.standardizedFileURL,
                            originalURL: record.to,
                            metadata: metadata
                        ))
                        changes.removed.append(record.to.path)
                    }
                    appliedRecords.append(record)
                    migrateMetadataKeys(from: record.from.path, to: record.to.path)
                    changes.moves.append((record.from.path, record.to.path))
                    changes.noteDirectory(at: record.to.path)
                case .skipped:
                    skippedCount += 1
                }
            } catch {
                failedCount += 1
                if firstError == nil { firstError = error }
            }
        }

        await refreshAfterMutation(preferredPaths: appliedRecords.map { $0.to.path }, changes: changes)

        // Nothing moved means nothing to undo, so no history entry is recorded.
        // Undo moves the files back, then restores what they replaced.
        let historyEntry = appliedRecords.isEmpty
            ? nil
            : makeMoveBatchHistoryEntry(
                MoveBatch(moves: invertedMoveRecords(appliedRecords), restoreAfter: replacedRecords),
                title: title
            )

        return MoveOutcome(
            historyEntry: historyEntry,
            movedCount: appliedRecords.count,
            skippedCount: skippedCount,
            failedCount: failedCount,
            firstError: firstError
        )
    }

    /// Builds the toast for a move that may have skipped same-named files or
    /// failed for some of them.
    private func moveOutcomeMessage(verb: String, outcome: MoveOutcome) -> String {
        var parts: [String] = []

        if outcome.movedCount > 0 {
            let noun = outcome.movedCount == 1 ? "file" : "files"
            parts.append("\(verb) \(outcome.movedCount) \(noun)")
        }

        if outcome.skippedCount > 0 {
            if outcome.movedCount > 0 {
                parts.append("skipped \(outcome.skippedCount) already here")
            } else {
                parts.append(outcome.skippedCount == 1
                    ? "Skipped 1 file already named that here"
                    : "Skipped \(outcome.skippedCount) files already named that here")
            }
        }

        if outcome.failedCount > 0 {
            let errorText = outcome.firstError?.localizedDescription ?? "Unknown error"
            if parts.isEmpty {
                let noun = outcome.failedCount == 1 ? "item" : "items"
                parts.append("\(outcome.failedCount) \(noun) could not be \(verb.lowercased()): \(errorText)")
            } else {
                parts.append("\(outcome.failedCount) failed: \(errorText)")
            }
        }

        return parts.isEmpty ? "Nothing to \(verb.lowercased())" : parts.joined(separator: ", ")
    }

    private func moveOutcomeToastType(_ outcome: MoveOutcome) -> ToastType {
        if outcome.failedCount > 0 { return .error }
        return outcome.movedCount > 0 ? .success : .info
    }

    /// Applies exact path moves in order, continuing past failures. Does not refresh.
    private func performExactMoveRecordsNow(
        _ records: [PathMoveRecord]
    ) -> (applied: [PathMoveRecord], failed: [PathMoveRecord], firstError: Error?) {
        var appliedRecords: [PathMoveRecord] = []
        var failedRecords: [PathMoveRecord] = []
        var firstError: Error?

        for record in records {
            do {
                let movedURL = try FileSystemService.moveEntry(from: record.from, to: record.to).standardizedFileURL
                let applied = PathMoveRecord(from: record.from.standardizedFileURL, to: movedURL)
                appliedRecords.append(applied)
                migrateMetadataKeys(from: applied.from.path, to: applied.to.path)
            } catch {
                failedRecords.append(record)
                if firstError == nil { firstError = error }
            }
        }
        return (appliedRecords, failedRecords, firstError)
    }

    /// Applies path moves in two phases — every source first goes to a unique
    /// hidden name in its own folder, then each goes to its destination — so a
    /// destination another item is vacating (chains, swaps) is always free.
    /// An item whose second phase fails is put back under its original name
    /// (or, if that got taken, a free name beside it). Does not refresh.
    ///
    /// `applied` lists every item that ended up somewhere new (including those
    /// that fell back to a free name, counted in `misplacedCount`); `failed`
    /// lists the ones left exactly where they started.
    private func performTwoPhaseMovesNow(
        _ records: [PathMoveRecord]
    ) -> (applied: [PathMoveRecord], failed: [PathMoveRecord], misplacedCount: Int, firstError: Error?) {
        let fm = FileManager.default
        var staged: [(record: PathMoveRecord, temp: URL)] = []
        var applied: [PathMoveRecord] = []
        var failed: [PathMoveRecord] = []
        var misplacedCount = 0
        var firstError: Error?

        for record in records {
            let from = record.from.standardizedFileURL
            let to = record.to.standardizedFileURL
            guard from.path != to.path else { continue }
            let temp = from.deletingLastPathComponent()
                .appendingPathComponent(".plx-rename-\(UUID().uuidString)")
                .standardizedFileURL
            do {
                try fm.moveItem(at: from, to: temp)
                migrateMetadataKeys(from: from.path, to: temp.path)
                staged.append((PathMoveRecord(from: from, to: to), temp))
            } catch {
                failed.append(record)
                if firstError == nil { firstError = error }
            }
        }

        for (record, temp) in staged {
            do {
                // moveEntry never overwrites: an occupied destination throws.
                let final = try FileSystemService.moveEntry(from: temp, to: record.to).standardizedFileURL
                migrateMetadataKeys(from: temp.path, to: final.path)
                applied.append(PathMoveRecord(from: record.from, to: final))
            } catch {
                if firstError == nil { firstError = error }
                if (try? fm.moveItem(at: temp, to: record.from)) != nil {
                    migrateMetadataKeys(from: temp.path, to: record.from.path)
                    failed.append(record)
                    continue
                }
                misplacedCount += 1
                let fallback = FileSystemService.nonConflictingURL(for: record.from).standardizedFileURL
                if (try? fm.moveItem(at: temp, to: fallback)) != nil {
                    migrateMetadataKeys(from: temp.path, to: fallback.path)
                    applied.append(PathMoveRecord(from: record.from, to: fallback))
                } else {
                    // Still under its temporary name; undo can move it back.
                    applied.append(PathMoveRecord(from: record.from, to: temp))
                }
            }
        }
        return (applied, failed, misplacedCount, firstError)
    }

    /// Trashes each URL, continuing past failures. Metadata is lifted off each
    /// trashed item (so a new file at the same path starts clean) and kept in
    /// its restore record for undo.
    private func trashURLs(
        _ urls: [URL]
    ) async -> (records: [TrashRestoreRecord], failed: [URL], firstError: Error?) {
        let outcome = trashURLsNow(urls)
        var changes = ListingPathChanges()
        for record in outcome.records {
            changes.removed.append(record.originalURL.path)
            changes.noteDirectory(at: record.trashedURL.path)
        }
        await refreshAfterMutation(changes: changes)
        return outcome
    }

    private func trashURLsNow(
        _ urls: [URL]
    ) -> (records: [TrashRestoreRecord], failed: [URL], firstError: Error?) {
        var restoreRecords: [TrashRestoreRecord] = []
        var failedURLs: [URL] = []
        var firstError: Error?

        for url in deduplicatedURLs(urls) {
            let sourceURL = url.standardizedFileURL
            do {
                let trashedURL = try FileSystemService.moveToTrash(at: sourceURL).standardizedFileURL
                let metadata = removeMetadata(under: sourceURL.path)
                restoreRecords.append(
                    TrashRestoreRecord(trashedURL: trashedURL, originalURL: sourceURL, metadata: metadata)
                )
            } catch {
                failedURLs.append(sourceURL)
                if firstError == nil { firstError = error }
            }
        }
        return (restoreRecords, failedURLs, firstError)
    }

    private func restoreTrashedRecords(
        _ records: [TrashRestoreRecord]
    ) async -> (restored: [URL], failed: [TrashRestoreRecord], firstError: Error?) {
        let outcome = restoreTrashedRecordsNow(records)
        var changes = ListingPathChanges()
        for url in outcome.restored {
            changes.added.append(url.path)
            changes.noteDirectory(at: url.path)
        }
        await refreshAfterMutation(preferredPaths: outcome.restored.map(\.path), changes: changes)
        return outcome
    }

    private func restoreTrashedRecordsNow(
        _ records: [TrashRestoreRecord]
    ) -> (restored: [URL], failed: [TrashRestoreRecord], firstError: Error?) {
        var restoredURLs: [URL] = []
        var failedRecords: [TrashRestoreRecord] = []
        var firstError: Error?

        for record in records {
            do {
                let restoredURL = try FileSystemService.moveEntry(from: record.trashedURL, to: record.originalURL).standardizedFileURL
                restoredURLs.append(restoredURL)
                restoreMetadata(record.metadata, from: record.originalURL.path, to: restoredURL.path)
                // Back from the Trash: the visual index picks the file up again.
                VisualIndexController.shared.invalidate(paths: [restoredURL.path])
            } catch {
                failedRecords.append(record)
                if firstError == nil { firstError = error }
            }
        }
        return (restoredURLs, failedRecords, firstError)
    }

    private func makeMoveHistoryEntry(recordsToApplyNext: [PathMoveRecord], title: String) -> FolderHistoryEntry {
        makeMoveBatchHistoryEntry(MoveBatch(moves: recordsToApplyNext), title: title)
    }

    /// History entry that applies `batch`; its inverse is the batch that undoes
    /// exactly what applied (moves reversed, trash and restore swapped).
    private func makeMoveBatchHistoryEntry(_ batch: MoveBatch, title: String) -> FolderHistoryEntry {
        FolderHistoryEntry(title: title) { [weak self] in
            guard let self else { return ExplorerViewModel.releasedHistoryResult(count: batch.itemCount) }

            let trashed = self.trashURLsNow(batch.trashFirst)

            var moveApplied: [PathMoveRecord]
            var moveFailed: [PathMoveRecord]
            var moveError: Error?
            var misplacedCount = 0
            if batch.twoPhase {
                let outcome = self.performTwoPhaseMovesNow(batch.moves)
                (moveApplied, moveFailed, misplacedCount, moveError) =
                    (outcome.applied, outcome.failed, outcome.misplacedCount, outcome.firstError)
            } else {
                let outcome = self.performExactMoveRecordsNow(batch.moves)
                (moveApplied, moveFailed, moveError) = (outcome.applied, outcome.failed, outcome.firstError)
            }

            let restored = self.restoreTrashedRecordsNow(batch.restoreAfter)

            var changes = ListingPathChanges()
            for record in trashed.records {
                changes.removed.append(record.originalURL.path)
                changes.noteDirectory(at: record.trashedURL.path)
            }
            for record in moveApplied {
                changes.moves.append((record.from.path, record.to.path))
                changes.noteDirectory(at: record.to.path)
            }
            for url in restored.restored {
                changes.added.append(url.path)
                changes.noteDirectory(at: url.path)
            }
            await self.refreshAfterMutation(
                preferredPaths: moveApplied.map(\.to.path) + restored.restored.map(\.path),
                changes: changes
            )

            let inverse = MoveBatch(
                trashFirst: restored.restored,
                moves: self.invertedMoveRecords(moveApplied),
                restoreAfter: trashed.records,
                twoPhase: batch.twoPhase
            )
            let remaining = MoveBatch(
                trashFirst: trashed.failed,
                moves: moveFailed,
                restoreAfter: restored.failed,
                twoPhase: batch.twoPhase
            )
            let failedCount = trashed.failed.count + moveFailed.count + restored.failed.count + misplacedCount
            return FolderHistoryApplyResult(
                inverse: inverse.isEmpty ? nil : self.makeMoveBatchHistoryEntry(inverse, title: title),
                remaining: remaining.isEmpty ? nil : self.makeMoveBatchHistoryEntry(remaining, title: title),
                appliedCount: batch.moves.isEmpty
                    ? trashed.records.count + restored.restored.count
                    : moveApplied.count - misplacedCount,
                failedCount: failedCount,
                firstError: trashed.firstError ?? moveError ?? restored.firstError
            )
        }
    }

    private func makeRestoreTrashHistoryEntry(recordsToApplyNext: [TrashRestoreRecord], title: String) -> FolderHistoryEntry {
        FolderHistoryEntry(title: title) { [weak self] in
            guard let self else { return ExplorerViewModel.releasedHistoryResult(count: recordsToApplyNext.count) }
            let outcome = await self.restoreTrashedRecords(recordsToApplyNext)
            return FolderHistoryApplyResult(
                inverse: outcome.restored.isEmpty
                    ? nil
                    : self.makeTrashHistoryEntry(urlsToApplyNext: outcome.restored, title: title),
                remaining: outcome.failed.isEmpty
                    ? nil
                    : self.makeRestoreTrashHistoryEntry(recordsToApplyNext: outcome.failed, title: title),
                appliedCount: outcome.restored.count,
                failedCount: outcome.failed.count,
                firstError: outcome.firstError
            )
        }
    }

    private func makeTrashHistoryEntry(urlsToApplyNext: [URL], title: String) -> FolderHistoryEntry {
        FolderHistoryEntry(title: title) { [weak self] in
            guard let self else { return ExplorerViewModel.releasedHistoryResult(count: urlsToApplyNext.count) }
            let outcome = await self.trashURLs(urlsToApplyNext)
            return FolderHistoryApplyResult(
                inverse: outcome.records.isEmpty
                    ? nil
                    : self.makeRestoreTrashHistoryEntry(recordsToApplyNext: outcome.records, title: title),
                remaining: outcome.failed.isEmpty
                    ? nil
                    : self.makeTrashHistoryEntry(urlsToApplyNext: outcome.failed, title: title),
                appliedCount: outcome.records.count,
                failedCount: outcome.failed.count,
                firstError: outcome.firstError
            )
        }
    }

    static func releasedHistoryResult(count: Int) -> FolderHistoryApplyResult {
        FolderHistoryApplyResult(
            inverse: nil,
            remaining: nil,
            appliedCount: 0,
            failedCount: max(1, count),
            firstError: FolderHistoryError.viewModelReleased
        )
    }

    // MARK: - Path-keyed metadata

    /// Moves ratings, flags, tags, favorites and custom sort order from `oldPath` (and,
    /// for folders, everything under it) to `newPath`, in memory and on disk.
    func migrateMetadataKeys(from oldPath: String, to newPath: String) {
        guard oldPath != newPath else { return }
        // Sidecars and the Finder tag mirror follow the item.
        CurationController.shared.itemDidMove(from: oldPath, to: newPath)
        stacksItemDidMove(from: oldPath, to: newPath)
        IngestController.shared.itemDidMove(from: oldPath, to: newPath)

        CollectionService.shared.migratePaths(from: oldPath, to: newPath)
        collections = CollectionService.shared.all()
        enqueueLibraryIndexMutation { await LibraryIndexService.shared.movePath(from: oldPath, to: newPath) }
        VisualIndexController.shared.invalidate(paths: [oldPath, newPath])
        if var listing = activeVirtualListing, listing.migratePaths(from: oldPath, to: newPath) {
            activeVirtualListing = listing
        }
        if let migrated = MetadataPathKeys.migratingKeys(of: parametersByPath, from: oldPath, to: newPath) {
            parametersByPath = migrated
        }
        if let migrated = MetadataPathKeys.migratingKeys(of: promptTextByPath, from: oldPath, to: newPath) {
            promptTextByPath = migrated
        }
        if let migrated = MetadataPathKeys.migratingKeys(of: negativePromptByPath, from: oldPath, to: newPath) {
            negativePromptByPath = migrated
        }

        if let migrated = MetadataPathKeys.migratingKeys(of: ratingsByPath, from: oldPath, to: newPath) {
            ratingsByPath = migrated
            settings.saveRatings(ratingsByPath)
        }

        var nextFlags = flagBook
        if nextFlags.migrate(from: oldPath, to: newPath) {
            flagBook = nextFlags
            flagStore.save(nextFlags)
        }

        if let migrated = MetadataPathKeys.migratingKeys(of: tagAssignments, from: oldPath, to: newPath) {
            TagService.shared.saveAssignments(migrated)
            tagAssignments = migrated
        }

        var nextFavorites: Set<String> = []
        var favoritesChanged = false
        for path in favoritePaths {
            if let rewritten = MetadataPathKeys.rewrite(path, from: oldPath, to: newPath), rewritten != path {
                nextFavorites.insert(rewritten)
                favoritesChanged = true
            } else {
                nextFavorites.insert(path)
            }
        }
        if favoritesChanged {
            favoritePaths = nextFavorites
            FavoritesService.shared.saveFavorites(nextFavorites)
        }

        // Custom orders are keyed by folder path and list item paths.
        let migratedOrderKeys = MetadataPathKeys.migratingKeys(of: customOrderByFolder, from: oldPath, to: newPath)
        var nextOrders = migratedOrderKeys ?? customOrderByFolder
        var ordersChanged = migratedOrderKeys != nil
        for (folder, order) in nextOrders {
            var orderChanged = false
            let rewrittenOrder = order.map { path -> String in
                if let rewritten = MetadataPathKeys.rewrite(path, from: oldPath, to: newPath), rewritten != path {
                    orderChanged = true
                    return rewritten
                }
                return path
            }
            if orderChanged {
                nextOrders[folder] = rewrittenOrder
                ordersChanged = true
            }
        }
        if ordersChanged {
            customOrderByFolder = nextOrders
            settings.saveCustomOrders(nextOrders)
        }

        if let migrated = MetadataPathKeys.migratingKeys(
            of: lastStandardSortConfigByFolder, from: oldPath, to: newPath
        ) {
            lastStandardSortConfigByFolder = migrated
        }
    }

    /// Removes and returns every metadata entry keyed by `path` or a descendant.
    @discardableResult
    private func removeMetadata(under path: String) -> PathMetadataSnapshot {
        var snapshot = PathMetadataSnapshot()
        snapshot.sidecars = CurationController.shared.itemWillBeRemoved(at: path)

        let ratingKeys = ratingsByPath.keys.filter { MetadataPathKeys.isSameOrDescendant($0, of: path) }
        if !ratingKeys.isEmpty {
            var next = ratingsByPath
            for key in ratingKeys {
                snapshot.ratings[key] = next.removeValue(forKey: key)
            }
            ratingsByPath = next
            settings.saveRatings(next)
        }

        var nextFlags = flagBook
        let removedFlags = nextFlags.removeAll(under: path)
        if !removedFlags.isEmpty {
            snapshot.flags = removedFlags
            flagBook = nextFlags
            flagStore.save(nextFlags)
        }

        let tagKeys = tagAssignments.keys.filter { MetadataPathKeys.isSameOrDescendant($0, of: path) }
        if !tagKeys.isEmpty {
            var next = tagAssignments
            for key in tagKeys {
                snapshot.tags[key] = next.removeValue(forKey: key)
            }
            TagService.shared.saveAssignments(next)
            tagAssignments = next
        }

        let favoriteKeys = favoritePaths.filter { MetadataPathKeys.isSameOrDescendant($0, of: path) }
        if !favoriteKeys.isEmpty {
            snapshot.favorites = favoriteKeys
            favoritePaths.subtract(favoriteKeys)
            FavoritesService.shared.saveFavorites(favoritePaths)
        }

        let orderKeys = customOrderByFolder.keys.filter { MetadataPathKeys.isSameOrDescendant($0, of: path) }
        if !orderKeys.isEmpty {
            var next = customOrderByFolder
            for key in orderKeys {
                snapshot.customOrders[key] = next.removeValue(forKey: key)
            }
            customOrderByFolder = next
            settings.saveCustomOrders(next)
        }

        var removedCollectionPaths: [String] = []
        for collection in CollectionService.shared.all() {
            let members = collection.paths.enumerated()
                .filter { MetadataPathKeys.isSameOrDescendant($0.element, of: path) }
                .map { (index: $0.offset, path: $0.element) }
            guard !members.isEmpty else { continue }
            snapshot.collectionMemberships[collection.id] = members
            removedCollectionPaths.append(contentsOf: members.map(\.path))
        }
        if !removedCollectionPaths.isEmpty {
            CollectionService.shared.removePaths(Array(Set(removedCollectionPaths)))
            collections = CollectionService.shared.all()
        }

        enqueueLibraryIndexMutation { await LibraryIndexService.shared.removeEntries(under: path) }
        VisualIndexController.shared.invalidate(paths: [path])

        // Parsed prompt data belongs to the file that left, not to whatever
        // takes its path next.
        if promptTextByPath.keys.contains(where: { MetadataPathKeys.isSameOrDescendant($0, of: path) }) {
            promptTextByPath = promptTextByPath.filter { !MetadataPathKeys.isSameOrDescendant($0.key, of: path) }
        }
        if negativePromptByPath.keys.contains(where: { MetadataPathKeys.isSameOrDescendant($0, of: path) }) {
            negativePromptByPath = negativePromptByPath.filter { !MetadataPathKeys.isSameOrDescendant($0.key, of: path) }
        }
        let parameterKeys = parametersByPath.keys.filter { MetadataPathKeys.isSameOrDescendant($0, of: path) }
        if !parameterKeys.isEmpty {
            var next = parametersByPath
            for key in parameterKeys { next.removeValue(forKey: key) }
            parametersByPath = next
        }

        return snapshot
    }

    /// Puts a snapshot taken at `oldPath` back, rewritten to `newPath`.
    private func restoreMetadata(_ snapshot: PathMetadataSnapshot, from oldPath: String, to newPath: String) {
        guard !snapshot.isEmpty else { return }
        CurationController.shared.itemWasRestored(snapshot.sidecars, from: oldPath, to: newPath)

        func target(_ key: String) -> String {
            MetadataPathKeys.rewrite(key, from: oldPath, to: newPath) ?? key
        }

        if !snapshot.ratings.isEmpty {
            var next = ratingsByPath
            for (key, value) in snapshot.ratings { next[target(key)] = value }
            ratingsByPath = next
            settings.saveRatings(next)
        }

        if !snapshot.flags.isEmpty {
            var next = flagBook
            next.restore(snapshot.flags, from: oldPath, to: newPath)
            flagBook = next
            flagStore.save(next)
        }

        if !snapshot.tags.isEmpty {
            var next = tagAssignments
            for (key, value) in snapshot.tags { next[target(key)] = value }
            TagService.shared.saveAssignments(next)
            tagAssignments = next
        }

        if !snapshot.favorites.isEmpty {
            favoritePaths.formUnion(snapshot.favorites.map(target))
            FavoritesService.shared.saveFavorites(favoritePaths)
        }

        if !snapshot.customOrders.isEmpty {
            var next = customOrderByFolder
            for (key, order) in snapshot.customOrders {
                next[target(key)] = order.map(target)
            }
            customOrderByFolder = next
            settings.saveCustomOrders(next)
        }

        if !snapshot.collectionMemberships.isEmpty {
            for collection in CollectionService.shared.all() {
                guard let members = snapshot.collectionMemberships[collection.id] else { continue }
                var paths = collection.paths
                var added: [String] = []
                for member in members.sorted(by: { $0.index < $1.index }) {
                    let restored = target(member.path)
                    guard !paths.contains(restored) else { continue }
                    paths.insert(restored, at: min(member.index, paths.count))
                    added.append(restored)
                }
                guard !added.isEmpty else { continue }
                // `reorder` ignores unknown paths, so add first, then place them.
                CollectionService.shared.add(paths: added, to: collection.id)
                CollectionService.shared.reorder(id: collection.id, paths: paths)
            }
            collections = CollectionService.shared.all()
        }
    }

    /// Re-reads every curation store after the curation controller changed them
    /// (library sync, import / restore, Finder tags, sidecars). Only changed values
    /// are reassigned, so unchanged listings don't re-sort.
    func reloadCurationStateFromStores() {
        let orders = settings.loadCustomOrders()
        if orders != customOrderByFolder { customOrderByFolder = orders }
        let ratings = settings.loadRatings()
        if ratings != ratingsByPath { ratingsByPath = ratings }
        let flags = flagStore.load()
        if flags != flagBook { flagBook = flags }
        let tags = TagService.shared.loadTags()
        if tags != allTags { allTags = tags }
        let assignments = TagService.shared.loadAssignments()
        if assignments != tagAssignments { tagAssignments = assignments }
        let favorites = FavoritesService.shared.loadFavorites()
        if favorites != favoritePaths { favoritePaths = favorites }
        let loadedCollections = CollectionService.shared.all()
        if loadedCollections != collections { collections = loadedCollections }
        let sets = CollectionService.shared.allSets()
        if sets != collectionSets { collectionSets = sets }
        let folders = SmartFolderService.shared.loadSmartFolders()
        if folders != smartFolders { smartFolders = folders }
        let recents = RecentHistoryService.shared.loadRecentFolders()
        if recents != recentFolders { recentFolders = recents }
        if let id = filterByTagID, !allTags.contains(where: { $0.id == id }) { filterByTagID = nil }
    }

    /// Runs library-index mutations one after another, in call order. They are
    /// only ordered among themselves: a library index build may be suspended
    /// mid-batch while one runs, and `LibraryIndexService` itself drops the
    /// build's records for paths a mutation touched, so no ordering with
    /// `indexLibrary` is assumed here.
    func enqueueLibraryIndexMutation(_ operation: @escaping @Sendable () async -> Void) {
        let previous = libraryIndexMutationTask
        libraryIndexMutationTask = Task(priority: .utility) {
            await previous?.value
            await operation()
        }
    }

    /// The moves that undo `records`, in reverse order so chained moves
    /// (a→b then b→c) unwind correctly.
    private func invertedMoveRecords(_ records: [PathMoveRecord]) -> [PathMoveRecord] {
        records.reversed().map { record in
            PathMoveRecord(from: record.to, to: record.from)
        }
    }

    /// Refreshes after a file mutation. With `changes`, only the touched paths'
    /// caches and prompt-index entries are updated; without, everything is dropped.
    private func refreshAfterMutation(preferredPaths: [String] = [], changes: ListingPathChanges? = nil) async {
        await refreshFolder(changes: changes)
        restoreSelection(afterRefreshing: preferredPaths)
    }

    /// Selects `preferredPaths` (the first listed one becomes primary) against
    /// the current processed list; paths that aren't listed are dropped.
    private func restoreSelection(afterRefreshing preferredPaths: [String]) {
        let uniquePaths = Array(NSOrderedSet(array: preferredPaths).compactMap { $0 as? String })
        guard !uniquePaths.isEmpty else {
            clearSelection()
            return
        }

        selectionPathSet = Set(uniquePaths)
        primarySelectionPath = uniquePaths.first
        selectionAnchorPath = uniquePaths.first
        remapSelectionToProcessedContents()

        guard !selectedIndices.isEmpty else {
            clearSelection()
            return
        }

        // Always reload: the file behind the primary path may have changed.
        let items = processedFolderContents
        if selectedItemIndex >= 0, selectedItemIndex < items.count {
            loadPromptEntry(for: items[selectedItemIndex])
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

enum SearchMode: String, CaseIterable {
    case filename
    case prompt
    case all
    /// Text recognised in images (OCR, see ImageTextService). "All" includes it too.
    case imageText

    var displayName: String {
        switch self {
        case .filename: return "Filename"
        case .prompt: return "Prompt"
        case .all: return "All"
        case .imageText: return "Text in Image"
        }
    }

    var icon: String {
        switch self {
        case .filename: return "doc.text"
        case .prompt: return "text.quote"
        case .all: return "magnifyingglass"
        case .imageText: return "text.viewfinder"
        }
    }
}

struct PromptDiffSession: Identifiable {
    let id = UUID()
    let sourceA: PromptEntry
    let nameA: String
    let sourceB: PromptEntry
    let nameB: String
}

// MARK: - Grouping, collections, batch rename (need file-private state)

extension ExplorerViewModel {
    /// Sections of `processedFolderContents` for `groupBy`; `[]` when not grouping.
    /// Order within each group follows the active sort; groups appear in the
    /// order of their first item, except "Unknown", which is always last. Each
    /// group's `indices` is a contiguous ascending range of the processed list.
    var contentGroups: [ContentGroup] {
        guard groupBy != .none else { return [] }
        let key = (processed: processedFolderContentsRevision, groups: contentGroupsRevision)
        if contentGroupsCacheKey == key { return contentGroupsCache }

        // `processedFolderContents` is already ordered group by group (see
        // `groupedContiguously`), so every group's indices form one ascending run.
        let items = processedFolderContents
        let field = groupBy
        let keyer = GroupKeyer(field: field, flags: flagBook, colors: dominantColorsByPath)
        var order: [String] = []
        var titles: [String: String] = [:]
        var indicesByKey: [String: [Int]] = [:]

        for (index, item) in items.enumerated() {
            let (resolvedKey, title) = keyer.key(for: item, parameters: parametersByPath[item.path])
            if indicesByKey[resolvedKey] == nil {
                order.append(resolvedKey)
                titles[resolvedKey] = title
            }
            indicesByKey[resolvedKey, default: []].append(index)
        }

        // Normally already last; kept for safety if the list was not regrouped.
        if let unknownIndex = order.firstIndex(of: GroupKeyer.unknownKey) {
            order.remove(at: unknownIndex)
            order.append(GroupKeyer.unknownKey)
        }

        let groups = order.map { key in
            ContentGroup(id: "\(field.rawValue):\(key)", title: titles[key] ?? "Unknown", indices: indicesByKey[key] ?? [])
        }
        contentGroupsCache = groups
        contentGroupsCacheKey = key
        return groups
    }

    /// Stable regrouping of `items` for `groupBy`: groups in order of their first
    /// item ("Unknown" last), each group's items together in their sorted order.
    fileprivate func groupedContiguously(_ items: [FileEntry]) -> [FileEntry] {
        let keyer = GroupKeyer(field: groupBy, flags: flagBook, colors: dominantColorsByPath)
        var order: [String] = []
        var buckets: [String: [FileEntry]] = [:]
        for item in items {
            let key = keyer.key(for: item, parameters: parametersByPath[item.path]).key
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(item)
        }
        if let unknownIndex = order.firstIndex(of: GroupKeyer.unknownKey) {
            order.remove(at: unknownIndex)
            order.append(GroupKeyer.unknownKey)
        }
        guard order.count > 1 else { return items }
        return order.flatMap { buckets[$0] ?? [] }
    }

    /// Group key and title of one item for a `GroupByField`.
    private struct GroupKeyer {
        static let unknownKey = "__unknown__"
        let field: GroupByField
        let flags: FlagBook
        let colors: [String: [DominantColor]]
        let dayFormatter: DateFormatter
        let keyFormatter: DateFormatter

        init(field: GroupByField, flags: FlagBook, colors: [String: [DominantColor]] = [:]) {
            self.field = field
            self.flags = flags
            self.colors = colors
            dayFormatter = DateFormatter()
            dayFormatter.dateStyle = .medium
            dayFormatter.timeStyle = .none
            keyFormatter = DateFormatter()
            keyFormatter.dateFormat = "yyyy-MM-dd"
            keyFormatter.locale = Locale(identifier: "en_US_POSIX")
        }

        func key(for item: FileEntry, parameters: GenerationParameters?) -> (key: String, title: String) {
            var groupKey: String?
            var title: String?

            switch field {
            case .none:
                break
            case .model:
                groupKey = parameters?.model.flatMap(ExplorerViewModel.nonEmpty)
                title = groupKey
            case .sampler:
                groupKey = parameters?.sampler.flatMap(ExplorerViewModel.nonEmpty)
                title = groupKey
            case .seed:
                groupKey = parameters?.seed.flatMap(ExplorerViewModel.nonEmpty)
                title = groupKey.map { "Seed \($0)" }
            case .day:
                if let date = item.modifiedDate {
                    groupKey = keyFormatter.string(from: date)
                    title = dayFormatter.string(from: date)
                }
            case .type:
                let descriptor = FileHelpers.typeSortDescriptor(for: item)
                groupKey = "\(descriptor.rank)|\(descriptor.typeLabel)"
                title = descriptor.typeLabel
            case .flag:
                let flag = flags.flag(for: item.path)
                groupKey = "flag\(flag.rawValue)"
                title = flag.groupTitle
            case .label:
                let label = FinderLabel(labelNumber: item.labelNumber)
                // Unlabeled items form the last group.
                guard label != .none else { return (Self.unknownKey, "No Label") }
                groupKey = "label\(label.rawValue)"
                title = label.title
            case .colorFamily:
                // Not yet indexed (or no colours: folders, audio…) forms the last group.
                guard let family = ColorFamily.of(colors[item.path] ?? []) else {
                    return (Self.unknownKey, "No Colour Data")
                }
                groupKey = "colour\(family.rawValue)"
                title = family.title
            }

            guard let groupKey else { return (Self.unknownKey, "Unknown") }
            return (groupKey.lowercased(), title ?? "Unknown")
        }
    }

    nonisolated fileprivate static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "N/A" else { return nil }
        return trimmed
    }

    // MARK: Listing prompt data

    func resetListingPromptData() {
        libraryParametersTask?.cancel()
        libraryParametersTask = nil
        dominantColorsTask?.cancel()
        dominantColorsTask = nil
        if !dominantColorsByPath.isEmpty { dominantColorsByPath = [:] }
        promptDataCompleteScope = nil
        if !parametersByPath.isEmpty { parametersByPath = [:] }
        if !promptTextByPath.isEmpty { promptTextByPath = [:] }
        if !negativePromptByPath.isEmpty { negativePromptByPath = [:] }
    }

    /// Fills `parametersByPath` from the library index for the current listing,
    /// and — when grouping or the active smart folder needs prompt data — builds
    /// the per-listing prompt index, which captures prompts and parameters too.
    func loadListingPromptDataIfNeeded(force: Bool) {
        loadListingDominantColorsIfNeeded()
        let paths = listingSourceContents.filter { !$0.isDirectory }.map(\.path)
        guard !paths.isEmpty, let scope = promptIndexScope else { return }

        libraryParametersTask?.cancel()
        let needsParse = groupBy.needsGenerationParameters || activeSmartFolderNeedsPromptData
        libraryParametersTask = Task(priority: .utility) { [weak self] in
            let fromLibrary = await LibraryIndexService.shared.parameters(forPaths: paths)
            guard !Task.isCancelled, let self, self.promptIndexScope == scope else { return }
            if !fromLibrary.isEmpty {
                var next = self.parametersByPath
                for (path, value) in fromLibrary {
                    // Values parsed from the file itself are fresher.
                    next[path] = next[path].map { $0.filling(from: value) } ?? value
                }
                if next != self.parametersByPath { self.parametersByPath = next }
            }
            if needsParse {
                await self.ensurePromptIndexForCurrentListing()
            }
        }
    }

    var activeSmartFolderNeedsPromptData: Bool {
        guard let criteria = activeSmartFolder?.criteria else { return false }
        return !criteria.modelContains.isEmpty || criteria.requiresPrompt || criteria.requiresNegativePrompt
    }

    func smartFolderContext() -> SmartFolderService.SmartFolderContext {
        var tagsByPath: [String: Set<UUID>] = [:]
        tagsByPath.reserveCapacity(tagAssignments.count)
        for (path, ids) in tagAssignments { tagsByPath[path] = Set(ids) }
        var modelByPath: [String: String] = [:]
        for (path, parameters) in parametersByPath {
            if let model = parameters.model, !model.isEmpty { modelByPath[path] = model }
        }
        return SmartFolderService.SmartFolderContext(
            tagsByPath: tagsByPath,
            favorites: favoritePaths,
            ratings: ratingsByPath,
            promptByPath: promptTextByPath,
            negativeByPath: negativePromptByPath,
            modelByPath: modelByPath,
            flags: flagBook.flags,
            dominantColorsByPath: dominantColorsByPath,
            imageTextByPath: imageTextByPathForListing
        )
    }

    // MARK: Collections

    /// Shows `id`'s files as the listing (nil returns to the folder).
    func openCollection(_ id: UUID?, then completion: (() -> Void)? = nil) {
        if id != nil, !isRestoringBrowserForSimilarPage { similarPage.handle(.collectionOpened) }
        guard id != activeCollectionID else {
            completion?()
            return
        }
        navigationGeneration &+= 1
        cancelPromptIndexBuild()
        clearSelection()
        resetListingPromptData()
        activeSmartFolder = nil
        // A collection replaces any virtual listing (ListingModeState.openCollection).
        activeVirtualListing = nil
        virtualListingContents = []

        guard let id, collections.contains(where: { $0.id == id }) else {
            activeCollectionID = nil
            collectionContents = []
            // The folder listing may have been dropped by the generation bump.
            Task {
                guard await self.refreshFolderContents(showLoading: true) else { return }
                self.loadListingPromptDataIfNeeded(force: false)
                self.refreshPromptSearchIfNeeded()
                completion?()
            }
            return
        }

        collectionContents = []
        activeCollectionID = id
        Task {
            guard await self.reloadCollectionContents() else { return }
            self.loadListingPromptDataIfNeeded(force: false)
            self.refreshPromptSearchIfNeeded()
            completion?()
        }
    }

    /// Re-reads the active collection's files from disk (missing files are
    /// skipped). Returns false when the result went stale.
    @discardableResult
    func reloadCollectionContents() async -> Bool {
        collections = CollectionService.shared.all()
        guard let id = activeCollectionID, let collection = collections.first(where: { $0.id == id }) else {
            if activeCollectionID != nil {
                activeCollectionID = nil
                collectionContents = []
            }
            return false
        }

        let generation = navigationGeneration
        let paths = collection.paths
        isLoadingFolder = true
        let entries = await Task.detached(priority: .userInitiated) {
            paths.compactMap { FileEntry.load(from: URL(fileURLWithPath: $0)) }
        }.value
        guard generation == navigationGeneration, activeCollectionID == id else { return false }
        collectionContents = entries
        isLoadingFolder = false
        return true
    }

    // MARK: Virtual listings

    /// Shows `listing` (ranked paths) in place of the folder or collection.
    /// The files are read first and swapped in at once, so an open lightbox
    /// stays on its file when that file is part of the new listing (More Like
    /// This from the lightbox lists the reference image first).
    ///
    /// - Parameters:
    ///   - selecting: path to select (and show in an open lightbox) afterwards.
    ///   - selectAll: select every listed file afterwards.
    ///   - openLightboxAt: path to open in the lightbox afterwards.
    ///   - completion: runs once the listing shows (not when superseded).
    func openVirtualListing(
        _ listing: VirtualListing,
        selecting: String? = nil,
        selectAll: Bool = false,
        openLightboxAt: String? = nil,
        then completion: (() -> Void)? = nil
    ) {
        var state = listingModeState
        state.openVirtual(listing)
        guard let resolved = state.virtualListing else { return }

        navigationGeneration &+= 1
        let generation = navigationGeneration
        let paths = resolved.paths
        Task {
            let entries = await Self.loadVirtualListingEntries(paths)
            guard generation == self.navigationGeneration else { return }
            self.applyVirtualListing(resolved, entries: entries)

            if let target = openLightboxAt ?? selecting, self.selectPath(target) {
                if openLightboxAt != nil || self.lightboxOpen,
                   let index = self.processedFolderContents.firstIndex(where: { $0.path == target }),
                   FileHelpers.isPreviewable(self.processedFolderContents[index])
                {
                    self.lightboxIndex = index
                    self.lightboxOpen = true
                }
            } else if selectAll {
                self.selectAllItems()
            }
            self.loadListingPromptDataIfNeeded(force: false)
            self.refreshPromptSearchIfNeeded()
            completion?()
        }
    }

    /// Swaps the listing over in one step (no intermediate remaps).
    private func applyVirtualListing(_ listing: VirtualListing, entries: [FileEntry]) {
        cancelPromptIndexBuild()
        clearSelection()
        resetListingPromptData()
        activeSmartFolder = nil

        isRemappingSelection = true
        activeCollectionID = nil
        collectionContents = []
        virtualListingRanked = true
        virtualListingContents = entries
        activeVirtualListing = listing
        isRemappingSelection = false
        invalidateSortedFolderContents()
        isLoadingFolder = false
    }

    /// Closes the virtual listing and returns to where it was opened from
    /// (the folder, or the collection that was open), reselecting the
    /// reference file of a More Like This listing.
    func closeVirtualListing(then completion: (() -> Void)? = nil) {
        guard let listing = activeVirtualListing else {
            completion?()
            return
        }
        var state = listingModeState
        state.closeVirtual()

        if let id = state.collectionID, collections.contains(where: { $0.id == id }) {
            virtualListingContents = []
            activeVirtualListing = nil
            let wasRestoring = isRestoringBrowserForSimilarPage
            isRestoringBrowserForSimilarPage = true
            openCollection(id, then: completion)
            isRestoringBrowserForSimilarPage = wasRestoring
            return
        }

        navigationGeneration &+= 1
        let generation = navigationGeneration
        cancelPromptIndexBuild()
        clearSelection()
        resetListingPromptData()
        virtualListingContents = []
        activeVirtualListing = nil
        let source = listing.sourcePath
        Task {
            guard await self.refreshFolderContents(showLoading: self.folderContents.isEmpty) else { return }
            guard generation == self.navigationGeneration else { return }
            self.loadListingPromptDataIfNeeded(force: false)
            self.refreshPromptSearchIfNeeded()
            if let source { self.selectPath(source) }
            completion?()
        }
    }

    /// Re-reads the virtual listing's files (missing ones are skipped, so files
    /// put back from the Trash reappear). Returns false when stale.
    @discardableResult
    func reloadVirtualListingContents() async -> Bool {
        guard let listing = activeVirtualListing else { return false }
        let generation = navigationGeneration
        let entries = await Self.loadVirtualListingEntries(listing.paths)
        guard generation == navigationGeneration, activeVirtualListing?.id == listing.id else { return false }
        virtualListingContents = entries
        return true
    }

    nonisolated static func loadVirtualListingEntries(_ paths: [String]) async -> [FileEntry] {
        await Task.detached(priority: .userInitiated) {
            var seen = Set<String>()
            return paths.compactMap { path -> FileEntry? in
                guard seen.insert(path).inserted else { return nil }
                return FileEntry.load(from: URL(fileURLWithPath: path))
            }
        }.value
    }

    func createCollection(named name: String, withSelection: Bool, inSet setID: UUID? = nil) {
        let paths = withSelection ? selectedPaths : []
        let collection = CollectionService.shared.create(name: name, paths: paths, parentID: setID)
        collections = CollectionService.shared.all()
        showToast(
            paths.isEmpty
                ? "Created collection \"\(collection.name)\""
                : "Created \"\(collection.name)\" with \(paths.count) item\(paths.count == 1 ? "" : "s")",
            type: .success
        )
    }

    func addSelection(toCollection id: UUID) {
        let paths = selectedItems.filter { !$0.isDirectory }.map(\.path)
        guard !paths.isEmpty else {
            showToast("Select files to add to the collection", type: .info)
            return
        }
        CollectionService.shared.add(paths: paths, to: id)
        collections = CollectionService.shared.all()
        let name = collections.first(where: { $0.id == id })?.name ?? "collection"
        showToast("Added \(paths.count) item\(paths.count == 1 ? "" : "s") to \"\(name)\"", type: .success)
        if activeCollectionID == id {
            Task { await self.reloadCollectionContents() }
        }
    }

    func removeSelectionFromActiveCollection() {
        guard let id = activeCollectionID else { return }
        let paths = selectedPaths
        guard !paths.isEmpty else { return }
        CollectionService.shared.remove(paths: paths, from: id)
        collections = CollectionService.shared.all()
        let removing = Set(paths)
        collectionContents.removeAll { removing.contains($0.path) }
        showToast("Removed \(paths.count) item\(paths.count == 1 ? "" : "s") from the collection", type: .success)
    }

    func renameCollection(_ id: UUID, to name: String) {
        CollectionService.shared.rename(id: id, to: name)
        collections = CollectionService.shared.all()
    }

    func deleteCollection(_ id: UUID) {
        CollectionService.shared.delete(id: id)
        collections = CollectionService.shared.all()
        if activeCollectionID == id {
            openCollection(nil)
        }
    }

    // MARK: Collection sets

    func createCollectionSet(named name: String, inSet parentID: UUID? = nil) {
        let set = CollectionService.shared.createSet(name: name, parentID: parentID)
        collectionSets = CollectionService.shared.allSets()
        showToast("Created collection set \"\(set.name)\"", type: .success)
    }

    func renameCollectionSet(_ id: UUID, to name: String) {
        CollectionService.shared.renameSet(id: id, to: name)
        collectionSets = CollectionService.shared.allSets()
    }

    /// Deletes the set; its contents move up one level.
    func deleteCollectionSet(_ id: UUID) {
        CollectionService.shared.deleteSet(id: id)
        collectionSets = CollectionService.shared.allSets()
        collections = CollectionService.shared.all()
    }

    func moveCollection(_ id: UUID, toSet setID: UUID?) {
        CollectionService.shared.move(collection: id, toSet: setID)
        collections = CollectionService.shared.all()
    }

    /// Returns false when the move was refused (a set can't go inside itself).
    @discardableResult
    func moveCollectionSet(_ id: UUID, toParent parentID: UUID?) -> Bool {
        let before = CollectionService.shared.allSets()
        CollectionService.shared.moveSet(id: id, toParent: parentID)
        collectionSets = CollectionService.shared.allSets()
        let moved = collectionSets.first(where: { $0.id == id })?.parentID == parentID
        if !moved, before.first(where: { $0.id == id })?.parentID != parentID {
            showToast("A set can't be moved inside itself", type: .info)
        }
        return moved
    }

    /// Direct children of `parentID` (nil = top level), each list sorted by name.
    func collectionChildren(of parentID: UUID?) -> (sets: [CollectionSet], collections: [FileCollection]) {
        let order: (String, String) -> Bool = { $0.localizedStandardCompare($1) == .orderedAscending }
        return (
            collectionSets.filter { $0.parentID == parentID }.sorted { order($0.name, $1.name) },
            collections.filter { $0.parentID == parentID }.sorted { order($0.name, $1.name) }
        )
    }

    /// Ancestor sets of a collection or set, outermost first.
    func collectionSetAncestors(ofParent parentID: UUID?) -> [CollectionSet] {
        var chain: [CollectionSet] = []
        var seen = Set<UUID>()
        var current = parentID
        while let id = current, seen.insert(id).inserted,
              let set = collectionSets.first(where: { $0.id == id }) {
            chain.insert(set, at: 0)
            current = set.parentID
        }
        return chain
    }

    /// Unique files across every collection inside `setID`, at any depth.
    func collectionSetItemCount(_ setID: UUID) -> Int {
        let setIDs = CollectionService.shared.descendantSetIDs(of: setID, including: true)
        var paths = Set<String>()
        for collection in collections {
            if let parent = collection.parentID, setIDs.contains(parent) {
                paths.formUnion(collection.paths)
            }
        }
        return paths.count
    }

    func reorderCollectionItems(sourcePaths: [String], targetPath: String, position: ReorderPosition) {
        guard let id = activeCollectionID else { return }
        ensureCustomSortForCurrentFolder()

        let currentOrder = collectionContents.map(\.path)
        let available = Set(currentOrder)
        let sources = sourcePaths.filter { available.contains($0) }
        guard !sources.isEmpty, !sources.contains(targetPath) else { return }

        let withoutSources = currentOrder.filter { !sources.contains($0) }
        guard let targetIndex = withoutSources.firstIndex(of: targetPath) else { return }
        let insertIndex = position == .after ? targetIndex + 1 : targetIndex
        let nextOrder = Array(withoutSources[..<insertIndex]) + sources + Array(withoutSources[insertIndex...])

        CollectionService.shared.reorder(id: id, paths: nextOrder)
        collections = CollectionService.shared.all()

        let previousSelection = selectedPaths
        let byPath = Dictionary(collectionContents.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        collectionContents = nextOrder.compactMap { byPath[$0] }

        let nextSelection = previousSelection.contains(where: sources.contains) ? previousSelection : sources
        restoreSelection(afterRefreshing: nextSelection)
    }

    // MARK: Batch rename

    /// Plans a template rename of the selection (or the whole listing when
    /// nothing is selected). Folders are skipped.
    func batchRenamePlan(template: String) async -> [RenamePlanItem] {
        let targets = batchRenameTargets
        guard !targets.isEmpty else { return [] }

        let needsParsedData = RenameTemplateService.usesAnyToken(RenameTemplateService.parsedDataTokens, in: template)
        if needsParsedData {
            await ensurePromptIndexForCurrentListing()
        }

        let contexts = targets.enumerated().map { offset, item in
            let parameters = parametersByPath[item.path]
            return RenameTemplateContext(
                url: item.url,
                index: offset,
                modifiedDate: item.modifiedDate,
                prompt: promptTextByPath[item.path],
                model: parameters?.model,
                seed: parameters?.seed,
                sampler: parameters?.sampler,
                steps: parameters?.steps,
                cfg: parameters?.cfg,
                width: parameters?.width,
                height: parameters?.height
            )
        }
        return await Task.detached(priority: .userInitiated) {
            RenameTemplateService.plan(template: template, items: contexts)
        }.value
    }

    var batchRenameTargets: [FileEntry] {
        let source = selectedItems.isEmpty ? processedFolderContents : selectedItems
        return source.filter { !$0.isDirectory }
    }

    /// Applies a rename plan as a single undoable step. Conflicting and
    /// unchanged items are skipped; failures are reported in one toast.
    func applyBatchRename(_ plan: [RenamePlanItem]) async {
        let actionable = plan.filter { !$0.conflict && !$0.unchanged }
        guard !actionable.isEmpty else {
            showToast("Nothing to rename", type: .info)
            return
        }

        // Two phases (every file to a temporary name, then to its final name) so
        // renumbering chains and swaps work regardless of plan order.
        let records = actionable.map {
            PathMoveRecord(from: $0.source.standardizedFileURL, to: $0.destination.standardizedFileURL)
        }
        let outcome = performTwoPhaseMovesNow(records)
        let applied = outcome.applied
        let renamedCount = applied.count - outcome.misplacedCount
        let failedCount = outcome.failed.count + outcome.misplacedCount
        let firstError = outcome.firstError

        var changes = ListingPathChanges()
        changes.moves = applied.map { ($0.from.path, $0.to.path) }
        // Refreshing also reloads the active collection's files.
        await refreshAfterMutation(preferredPaths: applied.map(\.to.path), changes: changes)

        if !applied.isEmpty {
            // One entry for the whole batch; undo and redo are two-phase too.
            recordFolderHistoryEntry(
                makeMoveBatchHistoryEntry(
                    MoveBatch(moves: invertedMoveRecords(applied), twoPhase: true),
                    title: "Batch Rename"
                )
            )
        }

        let skipped = plan.count - actionable.count
        if failedCount == 0 {
            var message = "Renamed \(renamedCount) file\(renamedCount == 1 ? "" : "s")"
            if skipped > 0 { message += ", skipped \(skipped)" }
            showToast(message, type: .success)
        } else {
            showToast(
                "Renamed \(renamedCount) of \(actionable.count); \(failedCount) failed: \(firstError?.localizedDescription ?? "Unknown error")",
                type: .error
            )
        }
    }
}

extension GroupByField {
    /// Grouping that needs parsed generation parameters.
    var needsGenerationParameters: Bool {
        switch self {
        case .model, .sampler, .seed: return true
        case .none, .day, .type, .flag, .label, .colorFamily: return false
        }
    }
}

// MARK: - Live folder updates & ingest hooks (need file-private state)
//
// Glue and state live in ExplorerViewModel+Ingest.swift, FolderWatcherController
// and IngestController; these two only reach the private refresh / undo machinery.

extension ExplorerViewModel {
    /// Applies changes made outside the app through the incremental change-set
    /// refresh (per-path cache invalidation and prompt-index patching, no full
    /// reload). Selection and scroll are kept; a rewritten primary file reloads
    /// its details.
    func refreshListingForExternalChanges(removed: [String], added: [String], modified: [String]) async {
        guard !(removed.isEmpty && added.isEmpty && modified.isEmpty) else { return }
        var changes = ListingPathChanges()
        // A rewritten file is dropped from the prompt index and parsed again.
        changes.removed = removed + modified
        changes.added = added + modified
        await refreshFolder(changes: changes)
        if let primary = primarySelectionPath, modified.contains(primary) {
            let items = processedFolderContents
            if selectedItemIndex >= 0, selectedItemIndex < items.count, items[selectedItemIndex].path == primary {
                loadPromptEntry(for: items[selectedItemIndex])
            }
        }
    }

    /// Only the sidebar folder tree changed (a folder appeared or went away elsewhere).
    func refreshFolderTreeForExternalChanges() async {
        await refreshFolderTree()
    }

    /// Moves and renames the ingest inbox performed: metadata keys follow the
    /// files, the listing refreshes without touching the selection, and the moves
    /// become one undoable step (Undo moves the files back). Copies only refresh;
    /// undoing them would mean trashing files, which ingest never does.
    func recordIngestFileOperations(moves: [(from: URL, to: URL)], copies: [URL], title: String) async {
        let records = moves.map { PathMoveRecord(from: $0.from.standardizedFileURL, to: $0.to.standardizedFileURL) }
        var changes = ListingPathChanges()
        for record in records {
            migrateMetadataKeys(from: record.from.path, to: record.to.path)
            changes.moves.append((record.from.path, record.to.path))
        }
        changes.added = copies.map { $0.standardizedFileURL.path }
        await refreshFolder(changes: changes)
        guard !records.isEmpty else { return }
        recordFolderHistoryEntry(makeMoveBatchHistoryEntry(MoveBatch(moves: invertedMoveRecords(records)), title: title))
    }
}
