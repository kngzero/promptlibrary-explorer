import AppKit
import MapKit
import SwiftUI

/// The Map: geotagged files as clustered annotations (grid clustering per zoom
/// level; the badge is the newest file's thumbnail and the count). Click a
/// cluster for its files in the side strip; click a file to select it,
/// double-click for the lightbox walking the cluster; Show in Browser lists
/// them as a virtual listing.
///
/// Privacy: the only network use is MapKit's map tiles. Place names are looked
/// up (CLGeocoder, rate-limited, cached) only after "Look Up Place Names".
struct MapPageContentView: View {
    @Environment(ExplorerViewModel.self) private var vm

    @State private var position: MapCameraPosition = .automatic
    @State private var region: MKCoordinateRegion?
    @State private var mapWidth: CGFloat = 800
    @State private var clusters: [GeoCluster] = []
    @State private var clusterTask: Task<Void, Never>?
    @State private var didFit = false

    private var controller: GeoTimelineController { vm.mapTimeline }
    /// Annotations drawn at once (the largest clusters in view win).
    private static let annotationLimit = 350

    var body: some View {
        Group {
            if controller.geoPoints.isEmpty {
                emptyState
            } else {
                HStack(spacing: 0) {
                    mapView
                    if let cluster = controller.selectedCluster {
                        Divider().background(Color.appBorder)
                        MapClusterStrip(cluster: cluster, onZoom: { zoom(to: cluster) })
                            .frame(width: 300)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground)
    }

    // MARK: Map

    private var mapView: some View {
        GeometryReader { geometry in
            Map(position: $position) {
                ForEach(clusters) { cluster in
                    Annotation(annotationTitle(cluster), coordinate: cluster.center.clCoordinate, anchor: .center) {
                        MapClusterBadge(cluster: cluster, isSelected: controller.selectedCluster?.id == cluster.id)
                            .onTapGesture {
                                if (NSApp.currentEvent?.clickCount ?? 1) >= 2, cluster.count > 1 {
                                    zoom(to: cluster)
                                } else {
                                    select(cluster)
                                }
                            }
                            .contextMenu {
                                if cluster.count == 1 {
                                    MapTimelineItemMenu(path: cluster.newestID)
                                } else {
                                    Button("Show \(cluster.count) Files in Browser") { showInBrowser(cluster) }
                                    Button("Zoom In") { zoom(to: cluster) }
                                }
                            }
                    }
                    .annotationTitles(.hidden)
                }
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            .mapControls {
                MapZoomStepper()
                MapCompass()
                MapScaleView()
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                region = context.region
                mapWidth = geometry.size.width
                recluster()
            }
            .onAppear {
                mapWidth = geometry.size.width
                fitAll(animated: false)
                recluster()
            }
            .overlay(alignment: .topLeading) { mapOverlayControls }
        }
        .onChange(of: controller.itemsRevision) { _, _ in
            if !didFit { fitAll(animated: false) }
            recluster()
            // Show on Map before the file's location was loaded.
            focusRequestedFile()
        }
        .onChange(of: controller.mapFocusPath) { _, _ in focusRequestedFile() }
        .onAppear { focusRequestedFile() }
    }

    private var mapOverlayControls: some View {
        HStack(spacing: AppSpacing.sm) {
            Button {
                fitAll(animated: true)
            } label: {
                Label("Show All", systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(.appCaption)
            }
            .buttonStyle(AppLabeledButtonStyle(height: 26, horizontalPadding: AppSpacing.md))
            .help("Zoom out to every geotagged file")

            Button {
                controller.lookUpPlaceNames(for: clusters.prefix(GeoTimelineController.geocodeBatchLimit).map(\.center))
            } label: {
                HStack(spacing: AppSpacing.xs) {
                    if controller.isLookingUpPlaces { ProgressView().controlSize(.mini) }
                    Label("Look Up Place Names", systemImage: "mappin.and.ellipse")
                        .font(.appCaption)
                }
            }
            .buttonStyle(AppLabeledButtonStyle(height: 26, horizontalPadding: AppSpacing.md))
            .disabled(controller.isLookingUpPlaces || clusters.isEmpty)
            .help("Sends the approximate position of the places in view to Apple to get their names (one at a time, remembered). Nothing else leaves the Mac.")

            Text("\(controller.geoPoints.count.formatted()) with a location")
                .font(.appCaption)
                .foregroundStyle(Color.appMuted)
                .padding(.horizontal, AppSpacing.sm)
                .padding(.vertical, AppSpacing.xxs)
                .background(Capsule().fill(Color.appSurface.opacity(0.9)))
        }
        .padding(AppSpacing.md)
    }

    private func annotationTitle(_ cluster: GeoCluster) -> String {
        let place = controller.placeName(for: cluster.center)
        let files = "\(cluster.count) file\(cluster.count == 1 ? "" : "s")"
        return place.map { "\($0), \(files)" } ?? files
    }

    // MARK: Clustering

    private func recluster() {
        let points = controller.geoPoints
        let region = region
        let width = Double(mapWidth)
        let limit = Self.annotationLimit
        clusterTask?.cancel()
        clusterTask = Task { @MainActor in
            let result: [GeoCluster] = await Task.detached(priority: .userInitiated) {
                guard let region else { return GeoClustering.cluster(points, zoom: 2) }
                let zoom = GeoClustering.zoomLevel(longitudeDelta: region.span.longitudeDelta, viewWidth: width)
                let all = GeoClustering.cluster(points, zoom: zoom)
                let visible = all.filter { cluster in
                    GeoClustering.region(
                        centerLatitude: region.center.latitude, centerLongitude: region.center.longitude,
                        latitudeDelta: region.span.latitudeDelta, longitudeDelta: region.span.longitudeDelta,
                        contains: cluster.center
                    )
                }
                return Array(visible.prefix(limit))
            }.value
            guard !Task.isCancelled else { return }
            clusters = result
            // Keep the strip on the files it showed: re-pick the cluster holding its newest file.
            if let selected = controller.selectedCluster, !result.contains(where: { $0.id == selected.id }) {
                if let match = result.first(where: { $0.memberIDs.contains(selected.newestID) }), match.memberIDs == selected.memberIDs {
                    controller.selectedCluster = match
                }
            }
            if let path = pendingFocusPath, let match = result.first(where: { $0.memberIDs.contains(path) }) {
                pendingFocusPath = nil
                controller.selectedCluster = match
                controller.selectedPath = path
            }
        }
    }

    @State private var pendingFocusPath: String?

    private func select(_ cluster: GeoCluster) {
        controller.selectedCluster = cluster
        vm.selectMapTimelineItem(cluster.newestID)
    }

    private func showInBrowser(_ cluster: GeoCluster) {
        let title = controller.placeName(for: cluster.center) ?? "Map · \(cluster.count) files"
        vm.showMapTimelineItemsInBrowser(cluster.memberIDs, title: title, kind: .geo, selecting: controller.selectedPath)
    }

    // MARK: Camera

    private func fitAll(animated: Bool) {
        let coordinates = controller.geoPoints.map(\.coordinate)
        guard let region = Self.region(fitting: coordinates) else { return }
        didFit = true
        if animated {
            withAnimation(.easeInOut(duration: 0.35)) { position = .region(region) }
        } else {
            position = .region(region)
        }
    }

    private func zoom(to cluster: GeoCluster) {
        select(cluster)
        let coordinates = [
            GeoCoordinate(latitude: cluster.minLatitude, longitude: cluster.minLongitude),
            GeoCoordinate(latitude: cluster.maxLatitude, longitude: cluster.maxLongitude),
        ]
        guard let region = Self.region(fitting: coordinates, minimumSpan: 0.005) else { return }
        withAnimation(.easeInOut(duration: 0.35)) { position = .region(region) }
    }

    /// Show on Map: centre on the file and open its cluster.
    private func focusRequestedFile() {
        guard let path = controller.mapFocusPath else { return }
        guard let point = controller.geoPoints.first(where: { $0.id == path }) else { return }
        controller.mapFocusPath = nil
        didFit = true
        pendingFocusPath = path
        let region = MKCoordinateRegion(center: point.coordinate.clCoordinate, latitudinalMeters: 3000, longitudinalMeters: 3000)
        withAnimation(.easeInOut(duration: 0.35)) { position = .region(region) }
    }

    /// A region around `coordinates` with a margin (nil when empty).
    static func region(fitting coordinates: [GeoCoordinate], minimumSpan: Double = 0.02) -> MKCoordinateRegion? {
        guard let first = coordinates.first else { return nil }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for coordinate in coordinates.dropFirst() {
            minLat = min(minLat, coordinate.latitude); maxLat = max(maxLat, coordinate.latitude)
            minLon = min(minLon, coordinate.longitude); maxLon = max(maxLon, coordinate.longitude)
        }
        let latSpan = min(170, max(minimumSpan, (maxLat - minLat) * 1.3))
        let lonSpan = min(360, max(minimumSpan, (maxLon - minLon) * 1.3))
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: latSpan, longitudeDelta: lonSpan)
        )
    }

    // MARK: Empty state

    @ViewBuilder
    private var emptyState: some View {
        if controller.isLoading && controller.items.isEmpty {
            VStack(spacing: AppSpacing.md) {
                ProgressView()
                Text("Reading locations…")
                    .font(.appCallout)
                    .foregroundStyle(Color.appMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            EmptyContentStateView(
                systemImage: "mappin.slash",
                title: "No files with a location here",
                message: emptyMessage,
                isFocused: true
            ) {
                HStack(spacing: AppSpacing.md) {
                    Button("Show Timeline") { vm.showTimelinePage() }
                        .buttonStyle(AppPrimaryButtonStyle())
                    if controller.scope == .folder {
                        Button("Search Whole Library") { controller.scope = .library }
                            .buttonStyle(AppLabeledButtonStyle())
                    }
                }
            }
        }
    }

    private var emptyMessage: String {
        var message = "AI-generated images rarely carry GPS. Photos and phone videos usually do: the location is read from the file itself (EXIF GPS, or the QuickTime location), never looked up."
        if controller.isBackfilling || controller.isReadingDates {
            message += " Locations of already-indexed files are still being read."
        } else if controller.scope == .library, controller.libraryIsUnindexed {
            message += " Whole Library needs the library index (Library ▸ Reindex Library)."
        }
        return message
    }
}

// MARK: - Cluster badge

private struct MapClusterBadge: View {
    let cluster: GeoCluster
    let isSelected: Bool

    var body: some View {
        MapTimelineThumbnail(path: cluster.newestID, size: 44, isSelected: isSelected, cornerRadius: AppRadius.md)
            .shadow(color: Color.appShadowColor, radius: 4, y: 2)
            .overlay(alignment: .topTrailing) {
                if cluster.count > 1 {
                    Text(cluster.count > 999 ? "\(cluster.count / 1000)k" : "\(cluster.count)")
                        .font(.appMicro)
                        .monospacedDigit()
                        .foregroundStyle(Color.appOnAccent)
                        .padding(.horizontal, AppSpacing.xs)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.appAccent))
                        .offset(x: 8, y: -8)
                }
            }
            .contentShape(Rectangle())
            .help(cluster.count == 1 ? (cluster.newestID as NSString).lastPathComponent : "\(cluster.count) files · double-click to zoom in")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(cluster.count == 1 ? (cluster.newestID as NSString).lastPathComponent : "\(cluster.count) files")
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Cluster strip

/// The selected cluster's files (newest first) beside the map.
private struct MapClusterStrip: View {
    @Environment(ExplorerViewModel.self) private var vm
    let cluster: GeoCluster
    let onZoom: () -> Void

    private var controller: GeoTimelineController { vm.mapTimeline }
    private let columns = [GridItem(.adaptive(minimum: 80, maximum: 120), spacing: AppSpacing.xs)]

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                HStack(spacing: AppSpacing.sm) {
                    VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                        Text(controller.placeName(for: cluster.center) ?? "\(cluster.count) file\(cluster.count == 1 ? "" : "s")")
                            .font(.appHeadline)
                            .foregroundStyle(Color.appPrimaryText)
                            .lineLimit(1)
                        Text(controller.placeName(for: cluster.center) != nil
                             ? "\(cluster.count) file\(cluster.count == 1 ? "" : "s") · \(cluster.center.displayString)"
                             : cluster.center.displayString)
                            .font(.appCaption)
                            .foregroundStyle(Color.appMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    Button {
                        controller.selectedCluster = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.appIcon(9, weight: .semibold))
                    }
                    .buttonStyle(AppSegmentButtonStyle(width: 20, height: 20))
                    .help("Close")
                    .accessibilityLabel("Close the file strip")
                }
                HStack(spacing: AppSpacing.sm) {
                    Button {
                        let title = controller.placeName(for: cluster.center) ?? "Map · \(cluster.count) files"
                        vm.showMapTimelineItemsInBrowser(cluster.memberIDs, title: title, kind: .geo, selecting: controller.selectedPath)
                    } label: {
                        Label("Show in Browser", systemImage: "square.grid.2x2")
                            .font(.appCaption)
                    }
                    .buttonStyle(AppLabeledButtonStyle(height: 24, horizontalPadding: AppSpacing.md))
                    .help("List these files in the browser (a listing like a collection)")
                    if cluster.count > 1 {
                        Button(action: onZoom) {
                            Label("Zoom In", systemImage: "plus.magnifyingglass")
                                .font(.appCaption)
                        }
                        .buttonStyle(AppLabeledButtonStyle(height: 24, horizontalPadding: AppSpacing.md))
                    }
                }
            }
            .padding(AppSpacing.lg)
            Divider().background(Color.appBorder)
            ScrollView {
                LazyVGrid(columns: columns, spacing: AppSpacing.xs) {
                    ForEach(cluster.memberIDs, id: \.self) { path in
                        MapStripTile(path: path, cluster: cluster)
                    }
                }
                .padding(AppSpacing.md)
            }
            if let path = controller.selectedPath, cluster.memberIDs.contains(path), let item = controller.item(for: path) {
                Divider().background(Color.appBorder)
                VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                    Text(item.name)
                        .font(.appCalloutEmphasis)
                        .foregroundStyle(Color.appPrimaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(MapTimelineDateText.string(for: item)) · \(item.sourceDescription)")
                        .font(.appCaption)
                        .foregroundStyle(Color.appMuted)
                        .lineLimit(2)
                    HStack(spacing: AppSpacing.sm) {
                        MapTimelineLocateButtons(path: path)
                    }
                    .padding(.top, AppSpacing.xs)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(AppSpacing.md)
            }
        }
        .background(Color.appSurface)
    }
}

private struct MapStripTile: View {
    @Environment(ExplorerViewModel.self) private var vm
    let path: String
    let cluster: GeoCluster

    var body: some View {
        GeometryReader { geometry in
            MapTimelineThumbnail(path: path, size: geometry.size.width, isSelected: vm.mapTimeline.selectedPath == path)
        }
        .aspectRatio(1, contentMode: .fit)
        .contentShape(Rectangle())
        .onTapGesture {
            vm.selectMapTimelineItem(path)
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { vm.openMapTimelineItem(path) }
        }
        .contextMenu { MapTimelineItemMenu(path: path) }
        .help((path as NSString).lastPathComponent)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel((path as NSString).lastPathComponent)
        .accessibilityAddTraits(.isButton)
    }
}

extension GeoCoordinate {
    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
