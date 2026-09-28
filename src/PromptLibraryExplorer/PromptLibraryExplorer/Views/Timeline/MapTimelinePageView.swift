import AppKit
import SwiftUI

/// View ▸ Timeline and View ▸ Map: a full page over the content browser and
/// the details panel (the sidebar stays), like the Similar Images page. The
/// browser keeps running underneath and is shown exactly as it was when the
/// page closes (Done, Esc, View ▸ Show Browser).
///
/// Keys are owned by the main window's key monitor
/// (`ExplorerViewModel.handleMapTimelinePageKey`).
struct MapTimelinePageView: View {
    @Environment(ExplorerViewModel.self) private var vm
    @State private var newCollectionName = ""

    private var controller: GeoTimelineController { vm.mapTimeline }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.appBorder)
            controlsBar
            Divider().background(Color.appBorder)
            ZStack {
                // Both stay mounted-by-page; only the active one is built.
                if controller.page == .map {
                    MapPageContentView()
                } else {
                    TimelineContentView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.appBackground)
        // This Folder follows the browser's listing, filters and search.
        .onChange(of: vm.mapTimelineListingSignature) { old, new in
            vm.mapTimelineListingDidChange(from: old, to: new)
        }
        .onChange(of: controller.scope) { _, _ in
            vm.reloadMapTimeline()
        }
        .onChange(of: controller.backfillRevision) { _, _ in
            if controller.scope == .library { vm.reloadMapTimeline() }
        }
        .onChange(of: vm.isLibraryIndexing) { _, indexing in
            // A finished index pass has new rows (and capture dates).
            guard !indexing else { return }
            controller.resetBackfillIfFinished()
            controller.startBackfillIfNeeded(root: vm.explorerRootPath)
            if controller.scope == .library { vm.reloadMapTimeline() }
        }
        .alert(
            "New Collection",
            isPresented: Binding(
                get: { controller.pendingNewCollectionPaths != nil },
                set: { if !$0 { controller.pendingNewCollectionPaths = nil } }
            )
        ) {
            TextField("Collection name", text: $newCollectionName)
            Button("Create") {
                if let paths = controller.pendingNewCollectionPaths {
                    vm.createCollection(named: newCollectionName, paths: paths, fallbackName: controller.page?.title ?? "Timeline")
                }
                controller.pendingNewCollectionPaths = nil
            }
            Button("Cancel", role: .cancel) { controller.pendingNewCollectionPaths = nil }
        } message: {
            Text("Create a collection with the selected files.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(controller.page?.title ?? "Timeline")
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: AppSpacing.md) {
            Image(systemName: controller.page?.systemImage ?? "calendar")
                .font(.appIcon(15, weight: .semibold))
                .foregroundStyle(Color.appAccent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text(controller.page?.title ?? "Timeline")
                    .font(.appTitle)
                    .foregroundStyle(Color.appPrimaryText)
                Text(subtitle)
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: AppSpacing.lg)

            Picker("Page", selection: Binding(
                get: { controller.page ?? .timeline },
                set: { vm.showMapTimelinePage($0) }
            )) {
                Label("Timeline", systemImage: MapTimelinePage.timeline.systemImage).tag(MapTimelinePage.timeline)
                Label("Map", systemImage: MapTimelinePage.map.systemImage).tag(MapTimelinePage.map)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Switch between the Timeline and the Map")
            .accessibilityLabel("Page")

            // Esc is owned by the key monitor (no key equivalent here).
            Button {
                vm.leaveMapTimelinePage()
            } label: {
                Text("Done")
                    .font(.appCalloutEmphasis)
            }
            .buttonStyle(AppPrimaryButtonStyle(verticalPadding: AppSpacing.xs))
            .help("Back to the browser (Esc)")
        }
        .padding(.horizontal, AppSpacing.xl)
        .padding(.vertical, AppSpacing.md)
        .background(Color.appSurface)
    }

    private var subtitle: String {
        let count = controller.items.count
        let files = "\(count.formatted()) file\(count == 1 ? "" : "s")"
        switch controller.page {
        case .map:
            let geotagged = controller.geoPoints.count
            return "\(geotagged.formatted()) of \(files) have a location · \(scopeName). Locations come from the files; nothing is sent anywhere except map tile requests."
        default:
            let captured = controller.items.reduce(0) { $0 + ($1.source == .captured ? 1 : 0) }
            guard count > 0 else { return scopeName }
            return "\(files) · \(captured.formatted()) by capture date, the rest by file date · \(scopeName)"
        }
    }

    private var scopeName: String {
        switch controller.scope {
        case .folder:
            if let collection = vm.activeCollection { return "Collection: \(collection.name)" }
            if let listing = vm.activeVirtualListing { return listing.title }
            return "This Folder: \((vm.selectedFolderPath ?? vm.explorerRootPath)?.lastPathComponent ?? "—")"
        case .library:
            return "Whole Library: \(vm.explorerRootPath?.lastPathComponent ?? "—")"
        }
    }

    // MARK: Controls

    private var controlsBar: some View {
        @Bindable var controller = controller
        return HStack(spacing: AppSpacing.lg) {
            Picker("Scope", selection: $controller.scope) {
                ForEach(VisualSearchScopeChoice.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("This Folder uses the browser's listing with its filters and search; Whole Library uses every indexed file (with the filters)")
            .accessibilityLabel("Scope")

            if controller.page != .map {
                Picker("Zoom", selection: $controller.zoom) {
                    ForEach(TimelineZoom.allCases) { zoom in
                        Text(zoom.title).tag(zoom)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Group by year, month or day (pinch the timeline to zoom)")
                .accessibilityLabel("Timeline zoom")
            }

            if vm.filterConfig.activeCount > 0 {
                Label("Filtered", systemImage: "line.3.horizontal.decrease.circle.fill")
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
                    .help("The browser's filters apply here too (Filter menu in the toolbar)")
            }

            Spacer(minLength: AppSpacing.md)

            if controller.isLoading || controller.isReadingDates {
                HStack(spacing: AppSpacing.xs) {
                    ProgressView().controlSize(.small)
                    Text(controller.isReadingDates ? "Reading capture dates…" : "Loading…")
                        .font(.appCaption)
                        .foregroundStyle(Color.appMuted)
                }
            }

            BackfillStatusView()
        }
        .padding(.horizontal, AppSpacing.xl)
        .padding(.vertical, AppSpacing.sm)
        .background(Color.appSurface)
    }
}

/// The capture-date backfill of older index rows: progress with Stop / Resume.
private struct BackfillStatusView: View {
    @Environment(ExplorerViewModel.self) private var vm

    private var controller: GeoTimelineController { vm.mapTimeline }

    var body: some View {
        switch controller.backfill {
        case let .running(done, total):
            HStack(spacing: AppSpacing.xs) {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .progressViewStyle(.linear)
                    .frame(width: 80)
                    .tint(Color.appAccent)
                Text("Dating \(done.formatted()) / \(total.formatted())")
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
                    .monospacedDigit()
                Button {
                    controller.stopBackfill()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.appIcon(9, weight: .semibold))
                }
                .buttonStyle(AppSegmentButtonStyle(width: 20, height: 20))
                .help("Stop reading capture dates of already-indexed files (Resume continues later)")
                .accessibilityLabel("Stop reading capture dates")
            }
            .help("Reading capture dates and locations of files indexed before this feature existed")
        case .stopped:
            Button {
                controller.resumeBackfill(root: vm.explorerRootPath)
            } label: {
                Label("Resume Dating", systemImage: "play.fill")
                    .font(.appCaption)
            }
            .buttonStyle(AppLabeledButtonStyle(height: 22, horizontalPadding: AppSpacing.md))
            .help("Continue reading capture dates and locations of already-indexed files")
        case .idle, .finished:
            EmptyView()
        }
    }
}

// MARK: - Thumbnails & menus shared by the Timeline and Map

/// A square thumbnail from ThumbnailService (downsampled), with an accent ring when selected.
struct MapTimelineThumbnail: View {
    let path: String
    let size: CGFloat
    var isSelected = false
    var cornerRadius: CGFloat = AppRadius.sm

    @State private var image: NSImage?
    /// The path `image` belongs to (cells can be reused for another file).
    @State private var loadedPath: String?

    private var url: URL { URL(fileURLWithPath: path) }
    private var name: String { url.lastPathComponent }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.appSurface)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipped()
            } else {
                Image(systemName: FileHelpers.isVideoFile(name) ? "film" : FileHelpers.isAudioFile(name) ? "waveform" : "photo")
                    .font(.appIcon(max(10, size * 0.3)))
                    .foregroundStyle(Color.appMuted.opacity(0.7))
            }
            if FileHelpers.isVideoFile(name), size >= 60 {
                Image(systemName: "play.fill")
                    .font(.appIcon(10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(AppSpacing.xs)
                    .background(Circle().fill(Color.black.opacity(0.45)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(AppSpacing.xs)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(isSelected ? Color.appAccent : Color.appBorder, lineWidth: isSelected ? 2.5 : 1)
        )
        .task(id: path) {
            // Thumbnail requests are rounded up so sizes share cache entries.
            let requested = max(64, (size / 64).rounded(.up) * 64)
            if let cached = ThumbnailService.shared.cachedThumbnail(for: url, size: requested) {
                image = cached
                return
            }
            // Keep showing an image only if it's this file's; never another file's.
            if loadedPath != path { image = nil }
            let loaded = await ThumbnailService.shared.thumbnail(for: url, size: requested)
            // A load cancelled by fast scrolling leaves the current image alone; the
            // task runs again when the tile reappears.
            guard !Task.isCancelled, let loaded else { return }
            image = loaded
            loadedPath = path
        }
    }
}

/// Right-click menu for a Timeline / Map file: the browser's normal item menu
/// when the file is in the browser's listing, otherwise the actions that don't
/// need the listing.
struct MapTimelineItemMenu: View {
    @Environment(ExplorerViewModel.self) private var vm
    let path: String

    var body: some View {
        if let listed = vm.listedEntry(for: path) {
            ContentItemContextMenu(
                item: listed.entry,
                index: listed.index,
                onRename: { vm.renameFromMapTimeline(path) },
                onNewCollection: { vm.mapTimeline.pendingNewCollectionPaths = vm.selectedPaths }
            )
        } else {
            libraryMenu
        }
    }

    @ViewBuilder
    private var libraryMenu: some View {
        let entry = vm.mapTimelineEntry(for: path)
        Button("Open") { vm.openMapTimelineItem(path) }
        Button("Show in Folder") { vm.revealMapTimelineItem(path) }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }

        if VisualSearchEligibility.isVisual(entry.name) {
            Divider()
            Button("More Like This") { vm.showMoreLikeThis(for: entry) }
        }

        Divider()

        Button("Copy Prompt") {
            let name = entry.name
            Task {
                let prompt = await SimilarImagesModel.readPrompt(atPath: path)
                guard !prompt.isEmpty else {
                    vm.showToast("\"\(name)\" has no prompt", type: .info)
                    return
                }
                ClipboardService.copyString(prompt)
                vm.showToast("Prompt copied", type: .success)
            }
        }
        Button("Copy Path") {
            ClipboardService.copyString(path)
            vm.showToast("Path copied", type: .success)
        }

        Divider()

        CullActionMenus(
            flag: vm.flag(for: path),
            rating: vm.rating(for: path),
            label: FinderLabel(labelNumber: entry.labelNumber),
            perform: { action in vm.apply(action, to: [entry]) }
        )

        Menu("Add to Collection") {
            CollectionMenuItems(vm: vm) { collection in
                vm.addPaths([path], toCollection: collection)
            }
            if !vm.collections.isEmpty { Divider() }
            Button("New Collection…") { vm.mapTimeline.pendingNewCollectionPaths = [path] }
        }
    }
}

// MARK: - Indexing status popover row

/// The indexing popover's row for the capture-date backfill (hidden when idle).
struct CaptureDateStatusSection: View {
    @Environment(ExplorerViewModel.self) private var vm

    private var controller: GeoTimelineController { .shared }

    var body: some View {
        switch controller.backfill {
        case let .running(done, total):
            Divider()
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                HStack(spacing: AppSpacing.sm) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.appIcon(12, weight: .medium))
                        .foregroundStyle(Color.appAccent)
                        .accessibilityHidden(true)
                    Text("Capture Dates")
                        .font(.appHeadline)
                        .foregroundStyle(Color.appPrimaryText)
                    Spacer(minLength: 0)
                    Text("\(done.formatted()) / \(total.formatted())")
                        .font(.appCaption)
                        .foregroundStyle(Color.appMuted)
                        .monospacedDigit()
                }
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .progressViewStyle(.linear)
                    .tint(Color.appAccent)
                Text("Reading dates and locations of files indexed earlier (Timeline, Map)")
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
                Button {
                    controller.stopBackfill()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.appCallout)
                }
                .buttonStyle(AppLabeledButtonStyle(height: 24))
                .help("Stops reading capture dates; the Timeline or Map page can resume it")
                .accessibilityLabel("Stop reading capture dates")
            }
        case .stopped:
            Divider()
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: "calendar.badge.clock")
                    .font(.appIcon(12, weight: .medium))
                    .foregroundStyle(Color.appMuted)
                    .accessibilityHidden(true)
                Text("Capture dates: stopped")
                    .font(.appCallout)
                    .foregroundStyle(Color.appMuted)
                Spacer(minLength: 0)
                Button("Resume") { controller.resumeBackfill(root: vm.explorerRootPath) }
                    .buttonStyle(AppLabeledButtonStyle(height: 24))
                    .font(.appCallout)
            }
        case .idle, .finished:
            EmptyView()
        }
    }
}
