import AppKit
import Foundation

// MARK: - Timeline and Map pages (View ▸ Timeline, View ▸ Map) — glue
//
// Full-page modes of the main window, like the Similar Images page: the
// sidebar stays, the browser and details panel are covered, and leaving shows
// the browser exactly as it was. State lives in `GeoTimelineController.shared`.
//
// This Folder = the browser's listing (folder, collection or listing) with its
// filters and search applied. Whole Library = every indexed file under the
// root, with the filter settings (file types, rating, flags, labels, colour).
//
// Nothing here marks, suggests or performs deletion.

extension ExplorerViewModel {
    var mapTimeline: GeoTimelineController { .shared }

    // MARK: Page state

    /// The Similar Images and Compare pages win: opening either closes this one.
    var isMapTimelinePageActive: Bool {
        mapTimeline.page != nil && !isSimilarImagesPageActive && viewing.comparePage == nil
    }

    var isTimelinePageActive: Bool { isMapTimelinePageActive && mapTimeline.page == .timeline }
    var isMapPageActive: Bool { isMapTimelinePageActive && mapTimeline.page == .map }

    func showTimelinePage() { showMapTimelinePage(.timeline) }
    func showMapPage() { showMapTimelinePage(.map) }

    func toggleTimelinePage() {
        isTimelinePageActive ? leaveMapTimelinePage() : showTimelinePage()
    }

    func toggleMapPage() {
        isMapPageActive ? leaveMapTimelinePage() : showMapPage()
    }

    func showMapTimelinePage(_ page: MapTimelinePage) {
        guard explorerRootPath != nil, !lightboxOpen else { return }
        if commandPaletteOpen { commandPaletteOpen = false }
        if QuickLookController.isPanelVisible { QuickLookController.shared.close() }
        if isSimilarImagesPageActive { leaveSimilarImagesPage() }
        if viewing.comparePage != nil { closeComparePage() }
        let wasShowing = mapTimeline.page != nil
        mapTimeline.show(page)
        if !wasShowing || mapTimeline.items.isEmpty { reloadMapTimeline() }
        mapTimeline.startBackfillIfNeeded(root: explorerRootPath)
    }

    /// Back to the browser, exactly as it was.
    func leaveMapTimelinePage() {
        mapTimeline.leave()
        if !lightboxOpen { mapTimelineLightboxSession = nil }
    }

    /// What the page's This Folder scope follows: the listing, its filters and search.
    var mapTimelineListingSignature: MapTimelineListingSignature {
        MapTimelineListingSignature(
            folderPath: selectedFolderPath?.path,
            rootPath: explorerRootPath?.path,
            collectionID: activeCollectionID,
            smartFolderID: activeSmartFolder?.id,
            virtualListingID: activeVirtualListing?.id,
            filter: filterConfig,
            searchQuery: searchQuery,
            tagID: filterByTagID,
            fileCount: processedFolderContents.count
        )
    }

    /// The listing / filters changed under the page.
    func mapTimelineListingDidChange(from old: MapTimelineListingSignature, to new: MapTimelineListingSignature) {
        // A lightbox the page opened borrows the browser's listing; that isn't the user navigating.
        guard mapTimelineLightboxSession == nil, similarPagePendingRestore == nil, !isRestoringBrowserForSimilarPage else { return }
        switch mapTimeline.scope {
        case .folder:
            reloadMapTimeline()
        case .library:
            if old.rootPath != new.rootPath || old.filter != new.filter {
                mapTimeline.resetBackfillIfFinished()
                mapTimeline.startBackfillIfNeeded(root: explorerRootPath)
                reloadMapTimeline()
            }
        }
    }

    // MARK: Loading

    /// Loads the page's items for its scope (cancels any load in flight).
    func reloadMapTimeline() {
        guard mapTimeline.page != nil else { return }
        let generation = mapTimeline.beginLoad()
        switch mapTimeline.scope {
        case .folder:
            let entries = processedFolderContents.filter { !$0.isDirectory }
            loadFolderTimeline(entries: entries, generation: generation)
        case .library:
            guard let root = explorerRootPath else {
                mapTimeline.setItems([], unfilteredCount: 0, generation: generation)
                return
            }
            loadLibraryTimeline(root: root, generation: generation)
        }
    }

    /// This Folder: the listing's files, dated by their file dates at once,
    /// then by capture dates as they're read (index first, then the files).
    private func loadFolderTimeline(entries: [FileEntry], generation: Int) {
        let controller = mapTimeline
        controller.setLibraryIsUnindexed(false)
        // Already-read dates at once, so returning to a folder doesn't flicker.
        var captures = controller.cachedCaptures(for: entries)
        func publish() {
            let items = entries.compactMap { entry -> TimelineItem? in
                let capture = captures[entry.path]
                guard let resolved = CaptureDateResolver.resolve(capture: capture, created: entry.creationDate, modified: entry.modifiedDate)
                else { return nil }
                return TimelineItem(path: entry.path, resolved: resolved, coordinate: capture?.coordinate)
            }
            controller.setItems(items, unfilteredCount: entries.count, generation: generation)
        }
        publish()
        controller.runLoad(generation) {
            controller.setReadingDates(true, generation: generation)
            var lastPublish = Date.distantPast
            await controller.readCaptures(for: entries) { batch in
                guard controller.isCurrent(generation) else { return }
                captures.merge(batch) { _, new in new }
                // Throttled: a big folder reads in many batches.
                if Date().timeIntervalSince(lastPublish) > 0.4 {
                    lastPublish = Date()
                    publish()
                }
            }
            guard controller.isCurrent(generation) else { return }
            publish()
            controller.setReadingDates(false, generation: generation)
        }
    }

    /// Whole Library: every index row under the root in one query, then the filters.
    private func loadLibraryTimeline(root: URL, generation: Int) {
        let controller = mapTimeline
        let config = filterConfig
        controller.runLoad(generation) { [weak self] in
            let rows = await LibraryIndexService.shared.captureRows(under: root)
            guard let self, controller.isCurrent(generation) else { return }
            controller.setLibraryIsUnindexed(rows.isEmpty)
            let prepared: [TimelineItem] = await Task.detached(priority: .userInitiated) {
                rows.compactMap { row -> TimelineItem? in
                    let name = (row.path as NSString).lastPathComponent
                    guard !config.hides(FileHelpers.filterType(forName: name)), let resolved = row.resolved else { return nil }
                    return TimelineItem(path: row.path, resolved: resolved, coordinate: row.capture.coordinate)
                }
            }.value
            guard controller.isCurrent(generation) else { return }
            let filtered = await self.applyingTimelineFilters(prepared, config: config)
            guard controller.isCurrent(generation) else { return }
            controller.setItems(filtered, unfilteredCount: rows.count, generation: generation)
        }
    }

    /// Rating, flag, label and colour filters for Whole Library items (file
    /// types are applied while reading the rows).
    private func applyingTimelineFilters(_ items: [TimelineItem], config: FilterConfig) async -> [TimelineItem] {
        var result = items
        if config.filterMinRating > 0 {
            result = result.filter { rating(for: $0.path) >= config.filterMinRating }
        }
        if config.flagFilter != .all {
            result = result.filter { config.flagFilter.includes(flag(for: $0.path)) }
        }
        if !config.labelFilter.isEmpty {
            let paths = result.map(\.path)
            let labels: [String: Int] = await Task.detached(priority: .userInitiated) {
                var labels: [String: Int] = [:]
                for path in paths {
                    if let number = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.labelNumberKey]))?.labelNumber {
                        labels[path] = number
                    }
                }
                return labels
            }.value
            result = result.filter { config.labelFilter.contains(FinderLabel(labelNumber: labels[$0.path]).rawValue) }
        }
        if let colorFilter = config.colorFilter {
            let colors = await VisualIndexService.shared.dominantColors(forPaths: result.map(\.path))
            result = result.filter { PaletteMatcher.matches(colors[$0.path] ?? [], filter: colorFilter) }
        }
        return result
    }

    // MARK: Selection & actions

    /// Click: selects the file on the page (and in the hidden browser when it's listed there).
    func selectMapTimelineItem(_ path: String) {
        mapTimeline.selectedPath = path
        if mapTimeline.scope == .folder { selectPath(path) }
    }

    /// The browser entry for `path` and its index when it's in the listing.
    func listedEntry(for path: String) -> (entry: FileEntry, index: Int)? {
        let items = processedFolderContents
        guard let index = items.firstIndex(where: { $0.path == path }) else { return nil }
        return (items[index], index)
    }

    /// A FileEntry for any file (listed, else read from disk).
    func mapTimelineEntry(for path: String) -> FileEntry {
        listedEntry(for: path)?.entry
            ?? FileEntry.load(from: URL(fileURLWithPath: path))
            ?? FileEntry(url: URL(fileURLWithPath: path), isDirectory: false)
    }

    /// "Show in Browser": the files as a virtual listing (newest first).
    func showMapTimelineItemsInBrowser(_ paths: [String], title: String, kind: VirtualListing.Kind, selecting: String? = nil) {
        guard !paths.isEmpty else { return }
        leaveMapTimelinePage()
        openVirtualListing(VirtualListing(kind: kind, title: title, paths: paths), selecting: selecting ?? paths.first)
    }

    /// Reveal the file in its folder in the browser.
    func revealMapTimelineItem(_ path: String) {
        leaveMapTimelinePage()
        Task { await revealFile(at: URL(fileURLWithPath: path)) }
    }

    /// Rename from the page's item menu: the browser does inline rename, so the page makes way.
    func renameFromMapTimeline(_ path: String) {
        leaveMapTimelinePage()
        guard selectPath(path) else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .beginRenameSelection, object: nil)
        }
    }

    // MARK: Context menu entry points (grid / list)

    /// "Show in Timeline": opens the Timeline (This Folder) scrolled to the file's day.
    func showInTimeline(_ item: FileEntry) {
        guard !item.isDirectory else { return }
        mapTimeline.scope = .folder
        showTimelinePage()
        let path = item.path
        Task {
            let capture = await mapTimeline.capture(for: item)
            guard let resolved = CaptureDateResolver.resolve(capture: capture, created: item.creationDate, modified: item.modifiedDate)
            else { return }
            let timelineItem = TimelineItem(path: path, resolved: resolved, coordinate: capture.coordinate)
            mapTimeline.selectedPath = path
            mapTimeline.scrollTargetSectionID = mapTimeline.sectionID(containing: timelineItem)
        }
    }

    /// "Show on Map": the Map (This Folder) centred on the file, or a note when it has no location.
    func showOnMap(_ item: FileEntry) {
        guard !item.isDirectory else { return }
        let path = item.path
        let name = item.name
        Task {
            let capture = await mapTimeline.capture(for: item)
            guard capture.coordinate != nil else {
                showToast("\"\(name)\" has no location", type: .info)
                return
            }
            mapTimeline.scope = .folder
            showMapPage()
            mapTimeline.selectedPath = path
            mapTimeline.mapFocusPath = path
        }
    }

    // MARK: Lightbox (borrows the hidden browser, like the Similar Images page)

    /// Opens `path` in the lightbox walking `paths` (a day, a map cluster). The
    /// lightbox steps through the browser's listing, so `paths` become the
    /// hidden browser's listing until it closes; then the browser's listing
    /// and selection are put back.
    func openMapTimelineLightbox(paths: [String], at path: String, title: String, kind: VirtualListing.Kind) {
        guard isMapTimelinePageActive, !lightboxOpen, paths.contains(path) else { return }
        mapTimeline.selectedPath = path
        let snapshot = similarPagePendingRestore ?? SimilarPageBrowserSnapshot(
            listing: listingModeState,
            smartFolderID: activeSmartFolder?.id,
            selectedPaths: selectedPaths,
            primaryPath: selectedItemPath
        )
        similarPagePendingRestore = snapshot
        let listing = VirtualListing(kind: kind, title: title, paths: paths)
        mapTimelineLightboxSession = SimilarPageLightboxSession(snapshot: snapshot, groupListingID: listing.id)
        openVirtualListing(listing, openLightboxAt: path) { [weak self] in
            guard let self, !self.lightboxOpen, self.mapTimelineLightboxSession?.groupListingID == listing.id else { return }
            // A filter in the browser hides the file: put everything back.
            self.mapTimelineLightboxSession = nil
            self.showToast("A filter in the browser hides \"\(URL(fileURLWithPath: path).lastPathComponent)\"", type: .info)
            self.restoreBrowser(from: snapshot)
        }
    }

    /// Called when the lightbox closes (`lightboxOpen` didSet).
    func mapTimelineLightboxDidClose() {
        guard let session = mapTimelineLightboxSession else { return }
        mapTimelineLightboxSession = nil
        let items = processedFolderContents
        let lastPath = lightboxIndex >= 0 && lightboxIndex < items.count ? items[lightboxIndex].path : nil
        guard activeVirtualListing?.id == session.groupListingID else {
            // Moved on inside the lightbox (More Like This): the browser keeps it.
            similarPagePendingRestore = nil
            leaveMapTimelinePage()
            return
        }
        if let lastPath { mapTimeline.selectedPath = lastPath }
        restoreBrowser(from: session.snapshot)
    }

    /// Stored on the controller (the view model's stored properties live in its main file).
    var mapTimelineLightboxSession: SimilarPageLightboxSession? {
        get { mapTimeline.lightboxSession }
        set { mapTimeline.lightboxSession = newValue }
    }

    // MARK: Keys (from `handleGlobalKey` while the page is up)

    /// Esc leaves; ←/→ previous / next file; ↑/↓ previous / next day (Timeline);
    /// Space / Return lightbox; M More Like This; P X U 0–9 cull the selected
    /// file. Every other bare key is swallowed so nothing reaches the hidden
    /// browser. Keys with ⌘ / ⌃ / ⌥ go to the menus.
    func handleMapTimelinePageKey(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags, isRepeat: Bool) -> Bool {
        guard isMapTimelinePageActive else { return false }
        if modifiers.contains(.command) || modifiers.contains(.control) || modifiers.contains(.option) { return false }
        guard let action = SimilarPageKeyAction.action(keyCode: keyCode, characters: characters, modifiers: modifiers) else {
            // Delete / ⇧Delete never act on the hidden browser's selection.
            return keyCode == KeyCode.delete.rawValue || keyCode == KeyCode.forwardDelete.rawValue
        }
        if isRepeat, !action.allowsRepeat { return true }
        let order = mapTimelineKeyOrder
        switch action {
        case .leave:
            leaveMapTimelinePage()
        case .previousCard, .nextCard:
            moveMapTimelineSelection(in: order, by: action == .nextCard ? 1 : -1)
        case .previousGroup, .nextGroup:
            if mapTimeline.page == .timeline { moveTimelineSection(by: action == .nextGroup ? 1 : -1) }
        case .openLightbox:
            openSelectedMapTimelineItem()
        case .moreLikeThis:
            if let path = mapTimeline.selectedPath { showMoreLikeThis(for: mapTimelineEntry(for: path)) }
        case let .cull(cull):
            guard let path = mapTimeline.selectedPath else { return true }
            apply(cull, to: [mapTimelineEntry(for: path)])
            if isCullAutoAdvanceActive { moveMapTimelineSelection(in: order, by: 1) }
        }
        return true
    }

    /// Paths the arrow keys walk: the Timeline's order, or the map cluster's files.
    private var mapTimelineKeyOrder: [String] {
        if mapTimeline.page == .map { return mapTimeline.selectedCluster?.memberIDs ?? [] }
        return mapTimeline.sections.flatMap { $0.items.map(\.path) }
    }

    private func moveMapTimelineSelection(in order: [String], by step: Int) {
        guard !order.isEmpty else { return }
        let current = mapTimeline.selectedPath.flatMap { order.firstIndex(of: $0) }
        let next = current.map { min(max($0 + step, 0), order.count - 1) } ?? 0
        selectMapTimelineItem(order[next])
        if mapTimeline.page == .timeline, let item = mapTimeline.item(for: order[next]) {
            mapTimeline.scrollTargetSectionID = mapTimeline.sectionID(containing: item)
        }
    }

    private func moveTimelineSection(by step: Int) {
        let sections = mapTimeline.sections
        guard !sections.isEmpty else { return }
        let current = mapTimeline.selectedPath
            .flatMap { path in sections.firstIndex { section in section.items.contains { $0.path == path } } }
        let next = current.map { min(max($0 + step, 0), sections.count - 1) } ?? 0
        if let first = sections[next].items.first { selectMapTimelineItem(first.path) }
        mapTimeline.scrollTargetSectionID = sections[next].id
    }

    /// Space / Return / double-click: the lightbox, walking the file's day (Timeline) or cluster (Map).
    func openSelectedMapTimelineItem() {
        guard let path = mapTimeline.selectedPath else { return }
        openMapTimelineItem(path)
    }

    func openMapTimelineItem(_ path: String) {
        if mapTimeline.page == .map, let cluster = mapTimeline.selectedCluster, cluster.memberIDs.contains(path) {
            openMapTimelineLightbox(paths: cluster.memberIDs, at: path, title: "Map · \(cluster.count) files", kind: .geo)
            return
        }
        guard let item = mapTimeline.item(for: path) else { return }
        let dayItems = mapTimeline.dayItems(containing: item)
        let day = TimelineBucketer.day(of: item, calendar: mapTimeline.calendar)
        let title = TimelineBucketer.title(for: TimelineSection(
            id: "", zoom: .day, year: day.year, month: day.month, day: day.day, items: []
        ))
        openMapTimelineLightbox(paths: dayItems.map(\.path), at: path, title: title, kind: .timeline)
    }

    // MARK: Browser: Sort by Capture Date, Group By Month / Year

    /// The sort or the grouping needs the listing's capture dates.
    var needsListingCaptureDates: Bool {
        sortConfig.field == .captureDate || groupBy.usesCaptureDates
    }

    /// Reads the listing's capture dates when the sort / grouping needs them
    /// (index first, then the files, in the background). Also call on navigation.
    func loadListingCaptureDatesIfNeeded() {
        guard needsListingCaptureDates else { return }
        mapTimeline.loadListingDates(for: listingSourceContents) { [weak self] in
            self?.listingCaptureDatesDidChange()
        }
    }

    /// Sort by Capture Date's value: capture, else creation, else modification date.
    func captureSortDate(for entry: FileEntry) -> Date? {
        guard !entry.isDirectory else { return entry.modifiedDate }
        return mapTimeline.listingDate(for: entry)?.date
    }

    /// Month / Year grouping input.
    var groupingCaptureDates: [String: ResolvedCaptureDate] {
        groupBy.usesCaptureDates ? mapTimeline.listingDates : [:]
    }

    /// Group key + title for Month / Year: the capture's own wall-clock month.
    nonisolated static func captureGroupKey(for resolved: ResolvedCaptureDate, byYear: Bool) -> (key: String, title: String) {
        CaptureDateGrouping.key(for: resolved, byYear: byYear)
    }
}

extension GroupByField {
    /// Grouping by the capture date (Month, Year).
    var usesCaptureDates: Bool { self == .month || self == .year }
}

/// Month / Year group keys and titles (not actor-isolated: the grouping runs in a plain struct).
enum CaptureDateGrouping {
    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMMy")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private static let lock = NSLock()

    static func key(for resolved: ResolvedCaptureDate, byYear: Bool, calendar: Calendar = .current) -> (key: String, title: String) {
        let item = TimelineItem(path: "", resolved: resolved, coordinate: nil)
        let day = TimelineBucketer.day(of: item, calendar: calendar)
        if byYear { return (String(format: "%04d", day.year), String(day.year)) }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = utc.date(from: DateComponents(year: day.year, month: day.month, day: 1, hour: 12)) ?? resolved.date
        lock.lock()
        let title = monthFormatter.string(from: date)
        lock.unlock()
        return (String(format: "%04d-%02d", day.year, day.month), title)
    }
}

/// What the page's This Folder scope depends on.
struct MapTimelineListingSignature: Equatable {
    var folderPath: String?
    var rootPath: String?
    var collectionID: UUID?
    var smartFolderID: UUID?
    var virtualListingID: UUID?
    var filter: FilterConfig
    var searchQuery: String
    var tagID: UUID?
    var fileCount: Int
}
