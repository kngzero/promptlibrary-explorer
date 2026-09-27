import CoreLocation
import Foundation
import Observation

/// The two page modes of the main window this controller drives.
enum MapTimelinePage: String, Sendable {
    case timeline
    case map

    var title: String {
        switch self {
        case .timeline: return "Timeline"
        case .map: return "Map"
        }
    }

    var systemImage: String {
        switch self {
        case .timeline: return "calendar.day.timeline.left"
        case .map: return "map"
        }
    }
}

/// State for View ▸ Timeline and View ▸ Map (full pages over the browser and
/// details panel, like the Similar Images page), the capture-date backfill,
/// place-name lookups, and the capture dates the browser's Sort by Capture Date
/// / Group By Month / Year use. The view model's glue lives in
/// `ExplorerViewModel+MapTimeline.swift`.
///
/// Location privacy: no network use except MapKit's map tiles and, only after
/// the user clicks "Look up place names", CLGeocoder (rate-limited, cached).
@MainActor @Observable
final class GeoTimelineController {
    static let shared = GeoTimelineController()

    // MARK: Page

    /// The page showing; nil = the browser.
    private(set) var page: MapTimelinePage?

    func show(_ page: MapTimelinePage) {
        self.page = page
    }

    func leave() {
        page = nil
        cancelLoad()
    }

    // MARK: Persisted choices

    /// This Folder (the browser's listing, with its filters) or Whole Library.
    var scope: VisualSearchScopeChoice {
        didSet {
            guard scope != oldValue else { return }
            defaults.set(scope.rawValue, forKey: Keys.scope)
        }
    }

    var zoom: TimelineZoom {
        didSet {
            guard zoom != oldValue else { return }
            defaults.set(zoom.rawValue, forKey: Keys.zoom)
            rebucket()
        }
    }

    // MARK: Results

    /// Every file of the scope that passes the filters, newest first.
    private(set) var items: [TimelineItem] = []
    private(set) var sections: [TimelineSection] = []
    private(set) var monthBins: [TimelineMonthBin] = []
    /// Geotagged items, as clustering input.
    private(set) var geoPoints: [GeoPoint] = []
    private(set) var isLoading = false
    /// Capture dates of files the library index hasn't read yet are being read.
    private(set) var isReadingDates = false
    /// Whole Library with an index that has no rows under the root.
    private(set) var libraryIsUnindexed = false
    /// Files in the scope before the filters.
    private(set) var unfilteredCount = 0
    /// Bumped whenever `items` change.
    private(set) var itemsRevision = 0
    /// Bumped whenever `sections` change.
    private(set) var sectionsRevision = 0

    var selectedPath: String?
    /// A section the timeline should scroll to (Show in Timeline, the scrubber).
    var scrollTargetSectionID: String?
    /// A file the map should centre on (Show on Map).
    var mapFocusPath: String?
    /// The map's selected cluster (its members fill the side strip).
    var selectedCluster: GeoCluster?
    /// A lightbox the page opened borrows the browser's listing (see
    /// `ExplorerViewModel.openMapTimelineLightbox`).
    @ObservationIgnored var lightboxSession: SimilarPageLightboxSession?
    /// New Collection… from a page item menu: the files to put in it (the page asks for a name).
    var pendingNewCollectionPaths: [String]?

    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var bucketTask: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let index: LibraryIndexService
    /// Calendar for bucketing (the Mac's time zone); injectable for tests.
    @ObservationIgnored var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }()

    private enum Keys {
        static let scope = "mapTimeline.scope"
        static let zoom = "mapTimeline.zoom"
        static let placeNames = "mapTimeline.placeNames"
    }

    init(defaults: UserDefaults = .standard, index: LibraryIndexService = .shared) {
        self.defaults = defaults
        self.index = index
        scope = VisualSearchScopeChoice(rawValue: defaults.string(forKey: Keys.scope) ?? "") ?? .folder
        zoom = TimelineZoom(rawValue: defaults.string(forKey: Keys.zoom) ?? "") ?? .day
        placeNames = defaults.dictionary(forKey: Keys.placeNames) as? [String: String] ?? [:]
    }

    // MARK: Loading

    /// Starts a load; results from older loads are dropped.
    func beginLoad() -> Int {
        loadTask?.cancel()
        loadGeneration &+= 1
        isLoading = true
        return loadGeneration
    }

    func isCurrent(_ generation: Int) -> Bool { generation == loadGeneration }

    func cancelLoad() {
        loadTask?.cancel()
        loadTask = nil
        loadGeneration &+= 1
        isLoading = false
        isReadingDates = false
    }

    /// Runs `body` as the current load (cancelled by the next one).
    func runLoad(_ generation: Int, _ body: @escaping @MainActor () async -> Void) {
        loadTask = Task { @MainActor in
            await body()
            if self.isCurrent(generation) {
                self.isLoading = false
            }
        }
    }

    func setReadingDates(_ reading: Bool, generation: Int) {
        guard isCurrent(generation) else { return }
        isReadingDates = reading
    }

    func setLibraryIsUnindexed(_ value: Bool) {
        if libraryIsUnindexed != value { libraryIsUnindexed = value }
    }

    /// New results for load `generation` (sorted and bucketed here).
    func setItems(_ newItems: [TimelineItem], unfilteredCount: Int, generation: Int) {
        guard isCurrent(generation) else { return }
        let sorted = newItems.sorted { lhs, rhs in
            lhs.date != rhs.date ? lhs.date > rhs.date : lhs.path < rhs.path
        }
        self.unfilteredCount = unfilteredCount
        guard sorted != items else { return }
        items = sorted
        itemsRevision &+= 1
        geoPoints = sorted.compactMap { item in
            item.coordinate.map { GeoPoint(id: item.path, coordinate: $0, date: item.date) }
        }
        if let selectedPath, !sorted.contains(where: { $0.path == selectedPath }) { self.selectedPath = nil }
        if let cluster = selectedCluster {
            let remaining = Set(sorted.map(\.path))
            if !cluster.memberIDs.contains(where: remaining.contains) { selectedCluster = nil }
        }
        rebucket()
    }

    /// Re-buckets `items` for `zoom` off the main actor.
    private func rebucket() {
        bucketTask?.cancel()
        let items = items
        let zoom = zoom
        let calendar = calendar
        let revision = itemsRevision
        bucketTask = Task { @MainActor in
            let (sections, bins) = await Task.detached(priority: .userInitiated) {
                (TimelineBucketer.sections(for: items, zoom: zoom, calendar: calendar),
                 TimelineBucketer.monthBins(for: items, calendar: calendar))
            }.value
            guard !Task.isCancelled, revision == self.itemsRevision, zoom == self.zoom else { return }
            self.sections = sections
            self.monthBins = bins
            self.sectionsRevision &+= 1
        }
    }

    func item(for path: String) -> TimelineItem? {
        items.first { $0.path == path }
    }

    /// The items of `item`'s wall-clock day (what a double-click walks in the lightbox).
    func dayItems(containing item: TimelineItem) -> [TimelineItem] {
        TimelineBucketer.dayItems(containing: item, in: items, calendar: calendar)
    }

    func sectionID(containing item: TimelineItem) -> String {
        let day = TimelineBucketer.day(of: item, calendar: calendar)
        return TimelineBucketer.sectionID(year: day.year, month: day.month, day: day.day, zoom: zoom)
    }

    // MARK: Capture dates for arbitrary files

    /// Capture data already read this session (validated by mtime).
    @ObservationIgnored private var captureCache: [String: (mtime: Double?, capture: CaptureMetadata)] = [:]

    /// Capture data for `entries`: from the library index where it has been
    /// read, otherwise read from the files (in the background, in batches;
    /// online-only files are skipped) and stored back into the index.
    /// `onBatch` gets each batch's results as they arrive.
    func readCaptures(
        for entries: [FileEntry],
        onBatch: @escaping @MainActor ([String: CaptureMetadata]) -> Void
    ) async {
        let files = entries.filter { !$0.isDirectory }
        guard !files.isEmpty else { return }
        var ready: [String: CaptureMetadata] = [:]
        var missing: [FileEntry] = []
        var unresolved: [FileEntry] = []
        for entry in files {
            let mtime = entry.modifiedDate?.timeIntervalSince1970
            if let cached = captureCache[entry.path], cached.mtime == mtime {
                ready[entry.path] = cached.capture
            } else {
                unresolved.append(entry)
            }
        }
        if !unresolved.isEmpty {
            let rows = await index.captureRows(forPaths: unresolved.map(\.path))
            if Task.isCancelled { return }
            for entry in unresolved {
                let mtime = entry.modifiedDate?.timeIntervalSince1970
                if let row = rows[entry.path], row.isExtracted,
                   let rowMtime = row.mtime?.timeIntervalSince1970, let mtime, abs(rowMtime - mtime) < 0.001
                {
                    ready[entry.path] = row.capture
                    captureCache[entry.path] = (mtime, row.capture)
                } else if FileHelpers.isImageFile(entry.name) || FileHelpers.isVideoFile(entry.name) {
                    missing.append(entry)
                } else {
                    ready[entry.path] = CaptureMetadata()
                    captureCache[entry.path] = (mtime, CaptureMetadata())
                }
            }
        }
        if !ready.isEmpty { onBatch(ready) }

        let batchSize = 48
        var start = 0
        while start < missing.count {
            if Task.isCancelled { return }
            let batch = Array(missing[start..<min(start + batchSize, missing.count)])
            start += batchSize
            let candidates = batch.map { entry in
                LibraryIndexCandidate(
                    path: entry.path, name: entry.name, folder: entry.url.deletingLastPathComponent().path,
                    mtime: entry.modifiedDate?.timeIntervalSince1970 ?? 0, size: entry.fileSize ?? 0,
                    ctime: entry.creationDate?.timeIntervalSince1970
                )
            }
            let updates = await LibraryIndexService.readCaptureUpdates(candidates)
            if Task.isCancelled { return }
            var results: [String: CaptureMetadata] = [:]
            for update in updates {
                results[update.path] = update.capture
                captureCache[update.path] = (update.mtime, update.capture)
            }
            if !results.isEmpty { onBatch(results) }
            await index.storeCapture(updates)
        }
    }

    /// One file's capture data (details panel): cache, index, else the file.
    func capture(for entry: FileEntry) async -> CaptureMetadata {
        var result = CaptureMetadata()
        await readCaptures(for: [entry]) { batch in
            if let value = batch[entry.path] { result = value }
        }
        return result
    }

    /// Capture data already read this session for `entries` (no I/O).
    func cachedCaptures(for entries: [FileEntry]) -> [String: CaptureMetadata] {
        var result: [String: CaptureMetadata] = [:]
        for entry in entries {
            if let cached = captureCache[entry.path], cached.mtime == entry.modifiedDate?.timeIntervalSince1970 {
                result[entry.path] = cached.capture
            }
        }
        return result
    }

    func forgetCachedCapture(paths: [String]) {
        for path in paths { captureCache[path] = nil }
    }

    // MARK: Browser listing dates (Sort by Capture Date, Group By Month / Year)

    /// Resolved dates of the browser's listing, filled while the sort or the
    /// grouping needs them.
    private(set) var listingDates: [String: ResolvedCaptureDate] = [:]
    @ObservationIgnored private var listingTask: Task<Void, Never>?
    @ObservationIgnored private var listingKey: [String] = []

    /// Loads capture dates for the listing; `didChange` runs after each batch
    /// that changed something (the view model re-sorts / regroups then).
    func loadListingDates(for entries: [FileEntry], didChange: @escaping @MainActor () -> Void) {
        let files = entries.filter { !$0.isDirectory }
        let key = files.map(\.path)
        if key == listingKey, listingTask != nil { return }
        listingKey = key
        listingTask?.cancel()
        var next: [String: ResolvedCaptureDate] = [:]
        for entry in files {
            if let resolved = CaptureDateResolver.resolve(capture: nil, created: entry.creationDate, modified: entry.modifiedDate) {
                next[entry.path] = resolved
            }
        }
        listingDates = next
        let byPath = Dictionary(files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        listingTask = Task { @MainActor in
            await self.readCaptures(for: files) { batch in
                var changed = false
                for (path, capture) in batch {
                    guard let entry = byPath[path],
                          let resolved = CaptureDateResolver.resolve(capture: capture, created: entry.creationDate, modified: entry.modifiedDate)
                    else { continue }
                    if self.listingDates[path] != resolved {
                        self.listingDates[path] = resolved
                        changed = true
                    }
                }
                if changed { didChange() }
            }
        }
    }

    /// The listing's resolved date for `entry` (falls back to its file dates).
    func listingDate(for entry: FileEntry) -> ResolvedCaptureDate? {
        listingDates[entry.path]
            ?? CaptureDateResolver.resolve(capture: nil, created: entry.creationDate, modified: entry.modifiedDate)
    }

    // MARK: Backfill (older index rows)

    enum BackfillState: Equatable {
        case idle
        case running(done: Int, total: Int)
        /// Stopped by the user; Resume starts again where it left off.
        case stopped
        case finished
    }

    private(set) var backfill: BackfillState = .idle
    /// Bumped every few hundred rows and at the end, so pages can reload.
    private(set) var backfillRevision = 0
    @ObservationIgnored private var backfillTask: Task<Void, Never>?
    @ObservationIgnored private var backfillRootPath: String?
    @ObservationIgnored private var backfillLastBump = 0

    var isBackfilling: Bool {
        if case .running = backfill { return true }
        return false
    }

    /// Reads capture data for index rows under `root` that predate it. Low
    /// priority and cancellable; a no-op while running for the same root or
    /// after the user stopped it (until `resumeBackfill`).
    func startBackfillIfNeeded(root: URL?) {
        guard let root else { return }
        let rootPath = root.standardizedFileURL.path
        if backfill == .stopped { return }
        if backfillTask != nil, backfillRootPath == rootPath { return }
        if backfill == .finished, backfillRootPath == rootPath { return }
        backfillTask?.cancel()
        backfillRootPath = rootPath
        let index = index
        backfillLastBump = 0
        let progress: @Sendable (Int, Int) -> Void = { [weak self] done, total in
            Task { @MainActor in
                guard let self, self.backfillRootPath == rootPath, self.backfillTask != nil else { return }
                self.backfill = .running(done: done, total: total)
                if done - self.backfillLastBump >= 400 {
                    self.backfillLastBump = done
                    self.backfillRevision &+= 1
                }
            }
        }
        backfillTask = Task(priority: .background) { @MainActor [weak self] in
            let updated = await index.backfillCaptureMetadata(under: root, progress: progress)
            guard let self, !Task.isCancelled, self.backfillRootPath == rootPath else { return }
            self.backfillTask = nil
            self.backfill = .finished
            if updated > 0 { self.backfillRevision &+= 1 }
        }
    }

    func stopBackfill() {
        backfillTask?.cancel()
        backfillTask = nil
        backfill = .stopped
    }

    func resumeBackfill(root: URL?) {
        guard backfill == .stopped else { return }
        backfill = .idle
        startBackfillIfNeeded(root: root)
    }

    /// The root changed or the index was rebuilt: a finished pass may need another.
    func resetBackfillIfFinished() {
        if backfill == .finished { backfill = .idle }
    }

    // MARK: Place names (reverse geocoding, only on request)

    /// "Paris, France" keyed by `placeKey` (coordinates rounded to ~1 km). Persisted.
    private(set) var placeNames: [String: String]
    private(set) var isLookingUpPlaces = false
    @ObservationIgnored private var lookupTask: Task<Void, Never>?
    @ObservationIgnored private let geocoder = CLGeocoder()

    /// Apple's geocoder allows roughly one request a second; stay under it.
    static let geocodeInterval: UInt64 = 1_300_000_000
    /// At most this many new lookups per click.
    static let geocodeBatchLimit = 40

    nonisolated static func placeKey(for coordinate: GeoCoordinate) -> String {
        String(format: "%.2f,%.2f", coordinate.latitude, coordinate.longitude)
    }

    func placeName(for coordinate: GeoCoordinate) -> String? {
        placeNames[Self.placeKey(for: coordinate)]
    }

    /// Looks up names for `coordinates` (the visible clusters), one request at a
    /// time, skipping any already cached.
    func lookUpPlaceNames(for coordinates: [GeoCoordinate]) {
        guard !isLookingUpPlaces else { return }
        var seen = Set<String>()
        let wanted = coordinates.filter { coordinate in
            let key = Self.placeKey(for: coordinate)
            return placeNames[key] == nil && seen.insert(key).inserted
        }.prefix(Self.geocodeBatchLimit)
        guard !wanted.isEmpty else { return }
        isLookingUpPlaces = true
        lookupTask = Task { @MainActor [weak self] in
            for (offset, coordinate) in wanted.enumerated() {
                guard let self, !Task.isCancelled else { return }
                if offset > 0 { try? await Task.sleep(nanoseconds: Self.geocodeInterval) }
                let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                if let placemark = try? await self.geocoder.reverseGeocodeLocation(location).first {
                    let parts = [placemark.locality ?? placemark.subAdministrativeArea, placemark.administrativeArea, placemark.country]
                        .compactMap { $0 }
                    var unique: [String] = []
                    for part in parts where !unique.contains(part) { unique.append(part) }
                    if !unique.isEmpty {
                        self.placeNames[Self.placeKey(for: coordinate)] = unique.prefix(2).joined(separator: ", ")
                        self.defaults.set(self.placeNames, forKey: Keys.placeNames)
                    }
                }
            }
            self?.isLookingUpPlaces = false
        }
    }

    func cancelPlaceLookup() {
        lookupTask?.cancel()
        geocoder.cancelGeocode()
        isLookingUpPlaces = false
    }

    /// Settings / privacy: forget every cached place name.
    func clearPlaceNames() {
        placeNames = [:]
        defaults.removeObject(forKey: Keys.placeNames)
    }
}
