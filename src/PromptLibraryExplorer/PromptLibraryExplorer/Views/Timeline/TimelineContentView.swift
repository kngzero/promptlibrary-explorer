import AppKit
import SwiftUI

/// The Timeline: a vertical, virtualized list of periods (year / month / day)
/// with sticky headers and dense thumbnail rows, newest first, plus a month
/// density scrubber along the right edge. Click selects, double-click opens
/// the lightbox walking that day's files, right-click is the item menu.
struct TimelineContentView: View {
    @Environment(ExplorerViewModel.self) private var vm

    private var controller: GeoTimelineController { vm.mapTimeline }

    var body: some View {
        VStack(spacing: 0) {
            if controller.items.isEmpty {
                emptyState
            } else {
                HStack(spacing: 0) {
                    TimelineScrollView()
                    Divider().background(Color.appBorder)
                    TimelineScrubber(bins: controller.monthBins) { bin in
                        if let id = TimelineBucketer.sectionID(for: bin, in: controller.sections) {
                            controller.scrollTargetSectionID = id
                        }
                    }
                    .frame(width: 56)
                }
                if let path = controller.selectedPath, let item = controller.item(for: path) {
                    Divider().background(Color.appBorder)
                    TimelineSelectionBar(item: item)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground)
    }

    @ViewBuilder
    private var emptyState: some View {
        if controller.isLoading {
            VStack(spacing: AppSpacing.md) {
                ProgressView()
                Text("Reading dates…")
                    .font(.appCallout)
                    .foregroundStyle(Color.appMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if controller.scope == .library, controller.libraryIsUnindexed {
            EmptyContentStateView(
                systemImage: "calendar.badge.clock",
                title: "The library isn't indexed yet",
                message: "Whole Library reads dates from the library index. Index the library, or switch to This Folder.",
                isFocused: true
            ) {
                HStack(spacing: AppSpacing.md) {
                    Button("Index Library") { vm.reindexLibrary() }
                        .buttonStyle(AppPrimaryButtonStyle())
                        .disabled(vm.isLibraryIndexing)
                    Button("Show This Folder") { controller.scope = .folder }
                        .buttonStyle(AppLabeledButtonStyle())
                }
            }
        } else {
            EmptyContentStateView(
                systemImage: "calendar",
                title: "Nothing to show",
                message: controller.unfilteredCount > 0
                    ? "The filters hide every file here. Change them in the toolbar's Filter menu."
                    : "There are no files with dates here.",
                isFocused: true
            ) {
                if controller.scope == .folder {
                    Button("Show Whole Library") { controller.scope = .library }
                        .buttonStyle(AppLabeledButtonStyle())
                }
            }
        }
    }
}

// MARK: - Scroll view

private struct TimelineScrollView: View {
    @Environment(ExplorerViewModel.self) private var vm
    private var controller: GeoTimelineController { vm.mapTimeline }
    private static let spacing: CGFloat = AppSpacing.xs
    private static let horizontalPadding: CGFloat = AppSpacing.xl

    var body: some View {
        let zoom = controller.sections.first?.zoom ?? controller.zoom
        let tile = CGFloat(zoom.thumbnailSize)
        GeometryReader { geometry in
            let usable = max(tile, geometry.size.width - Self.horizontalPadding * 2)
            let columns = max(1, Int((usable + Self.spacing) / (tile + Self.spacing)))
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(controller.sections) { section in
                            Section {
                                // Every row needs an identity that is unique across the
                                // WHOLE lazy stack. Plain 0..<n row indexes repeat in every
                                // section, and with pinned headers the LazyVStack then
                                // recycled the wrong rows: the same image reappeared at the
                                // top while scrolling and other rows went blank.
                                // The first row doubles as the section's scroll anchor.
                                ForEach(TimelineRow.rows(for: section, columns: columns)) { row in
                                    HStack(spacing: Self.spacing) {
                                        ForEach(row.items) { item in
                                            TimelineTile(item: item, size: tile)
                                                // Fresh thumbnail state per file, so a reused
                                                // cell never shows another file's image.
                                                .id(item.path)
                                        }
                                    }
                                    .padding(.horizontal, Self.horizontalPadding)
                                    .padding(.bottom, Self.spacing)
                                    .padding(.bottom, row.isLast ? AppSpacing.md : 0)
                                }
                            } header: {
                                TimelineSectionHeader(section: section)
                            }
                        }
                    }
                    .padding(.bottom, AppSpacing.xl)
                }
                .simultaneousGesture(
                    MagnifyGesture()
                        .onEnded { value in
                            if value.magnification > 1.25, let next = controller.zoom.zoomedIn {
                                controller.zoom = next
                            } else if value.magnification < 0.8, let next = controller.zoom.zoomedOut {
                                controller.zoom = next
                            }
                        }
                )
                .onChange(of: controller.scrollTargetSectionID) { _, _ in
                    scrollToPendingTarget(proxy)
                }
                // A target set before its period was bucketed (Show in Timeline).
                .onChange(of: controller.sectionsRevision) { _, _ in
                    scrollToPendingTarget(proxy)
                }
                // Changing the zoom keeps the selected file's period in view.
                .onChange(of: controller.sections.first?.zoom) { _, _ in
                    guard let path = controller.selectedPath, let item = controller.item(for: path) else { return }
                    let id = controller.sectionID(containing: item)
                    DispatchQueue.main.async { proxy.scrollTo(id, anchor: .top) }
                }
                .onAppear {
                    DispatchQueue.main.async { scrollToPendingTarget(proxy) }
                }
            }
        }
    }
}

/// One row of tiles in a timeline section, with a globally unique id.
private struct TimelineRow: Identifiable {
    /// The section's id for its first row (the scroll anchor), else "section|index".
    let id: String
    let items: ArraySlice<TimelineItem>
    let isLast: Bool

    static func rows(for section: TimelineSection, columns: Int) -> [TimelineRow] {
        let columns = max(1, columns)
        var rows: [TimelineRow] = []
        var start = 0
        var index = 0
        while start < section.items.count {
            let end = min(start + columns, section.items.count)
            rows.append(TimelineRow(
                id: index == 0 ? section.id : "\(section.id)|\(index)",
                items: section.items[start..<end],
                isLast: end == section.items.count
            ))
            start = end
            index += 1
        }
        return rows
    }
}

extension TimelineScrollView {
    /// Scrolls to `scrollTargetSectionID` once that section exists.
    fileprivate func scrollToPendingTarget(_ proxy: ScrollViewProxy) {
        guard let id = controller.scrollTargetSectionID,
              controller.sections.contains(where: { $0.id == id })
        else { return }
        proxy.scrollTo(id, anchor: .top)
        controller.scrollTargetSectionID = nil
    }
}

private struct TimelineSectionHeader: View {
    @Environment(ExplorerViewModel.self) private var vm
    let section: TimelineSection

    private var title: String { TimelineBucketer.title(for: section) }

    var body: some View {
        let count = section.items.count
        let byFileDate = count - section.capturedCount
        HStack(spacing: AppSpacing.md) {
            Text(title)
                .font(.appHeadline)
                .foregroundStyle(Color.appPrimaryText)
            Text("\(count.formatted()) file\(count == 1 ? "" : "s")")
                .font(.appCaption)
                .foregroundStyle(Color.appMuted)
                .monospacedDigit()
            if byFileDate > 0 {
                Text("\(byFileDate.formatted()) by file date")
                    .font(.appFootnote)
                    .foregroundStyle(Color.appMuted)
                    .help("These files have no embedded capture date; they're placed by their creation (or modification) date")
            }
            Spacer(minLength: AppSpacing.md)
            if let zoomIn = section.zoom.zoomedIn {
                Button {
                    // The zoom change scrolls to the selected file's period.
                    if let first = section.items.first { vm.selectMapTimelineItem(first.path) }
                    vm.mapTimeline.zoom = zoomIn
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                        .font(.appIcon(11, weight: .medium))
                }
                .buttonStyle(AppSegmentButtonStyle(width: 24, height: 22))
                .help("Zoom in to \(zoomIn.title.lowercased())")
                .accessibilityLabel("Zoom in to \(zoomIn.title.lowercased())")
            }
            Button {
                vm.showMapTimelineItemsInBrowser(section.items.map(\.path), title: title, kind: .timeline,
                                                 selecting: vm.mapTimeline.selectedPath)
            } label: {
                Image(systemName: "square.grid.2x2")
                    .font(.appIcon(11, weight: .medium))
            }
            .buttonStyle(AppSegmentButtonStyle(width: 24, height: 22))
            .help("Show these \(count) files in the browser")
            .accessibilityLabel("Show \(title) in the browser")
        }
        .padding(.horizontal, AppSpacing.xl)
        .padding(.vertical, AppSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Opaque: pinned over scrolling tiles, a translucent header showed them through.
        .background(Color.appBackground)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title), \(count) files")
    }
}

private struct TimelineTile: View {
    @Environment(ExplorerViewModel.self) private var vm
    let item: TimelineItem
    let size: CGFloat

    var body: some View {
        let selected = vm.mapTimeline.selectedPath == item.path
        MapTimelineThumbnail(path: item.path, size: size, isSelected: selected)
            .overlay(alignment: .topTrailing) {
                let flag = vm.flag(for: item.path)
                if size >= 60, flag != .unflagged {
                    TileCullBadges(flag: flag, label: .none, side: 16)
                        .padding(AppSpacing.xxs)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                // Immediate select on the first click, open on the second.
                if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                    vm.selectMapTimelineItem(item.path)
                    vm.openMapTimelineItem(item.path)
                } else {
                    vm.selectMapTimelineItem(item.path)
                }
            }
            .contextMenu {
                MapTimelineItemMenu(path: item.path)
            }
            .help(helpText)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.name)
            .accessibilityValue("\(item.date.formatted(date: .abbreviated, time: .shortened)), \(item.sourceDescription)")
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var helpText: String {
        "\(item.name)\n\(item.date.formatted(date: .abbreviated, time: .shortened)) · \(item.sourceDescription)"
    }
}

/// The selected file: name, date and which date it is, location, actions.
private struct TimelineSelectionBar: View {
    @Environment(ExplorerViewModel.self) private var vm
    let item: TimelineItem

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            MapTimelineThumbnail(path: item.path, size: 32)
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text(item.name)
                    .font(.appCalloutEmphasis)
                    .foregroundStyle(Color.appPrimaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: AppSpacing.sm) {
                    Text(MapTimelineDateText.string(for: item))
                    Text("·")
                    Text(item.sourceDescription)
                    if let coordinate = item.coordinate {
                        Text("·")
                        Text(vm.mapTimeline.placeName(for: coordinate) ?? coordinate.displayString)
                    }
                }
                .font(.appCaption)
                .foregroundStyle(Color.appMuted)
                .lineLimit(1)
            }
            Spacer(minLength: AppSpacing.md)
            if item.coordinate != nil {
                Button {
                    vm.mapTimeline.mapFocusPath = item.path
                    vm.showMapPage()
                } label: {
                    Label("Show on Map", systemImage: "map")
                        .font(.appCaption)
                }
                .buttonStyle(AppLabeledButtonStyle(height: 24, horizontalPadding: AppSpacing.md))
            }
            Button {
                vm.openMapTimelineItem(item.path)
            } label: {
                Label("Open", systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(.appCaption)
            }
            .buttonStyle(AppLabeledButtonStyle(height: 24, horizontalPadding: AppSpacing.md))
            .help("Open in the lightbox; ← / → step through this day (Space)")
        }
        .padding(.horizontal, AppSpacing.xl)
        .padding(.vertical, AppSpacing.sm)
        .background(Color.appSurface)
    }
}

/// Date + time in the capture's own zone when it has one.
enum MapTimelineDateText {
    static func string(for item: TimelineItem) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        if let offset = item.utcOffset, let zone = TimeZone(secondsFromGMT: offset) {
            formatter.timeZone = zone
        }
        return formatter.string(from: item.date)
    }
}

// MARK: - Density scrubber

/// One bar per month (newest at the top, like the timeline); click or drag to jump.
struct TimelineScrubber: View {
    let bins: [TimelineMonthBin]
    let onJump: (TimelineMonthBin) -> Void

    @State private var hoverIndex: Int?

    var body: some View {
        GeometryReader { geometry in
            let count = max(bins.count, 1)
            let rowHeight = max(0.5, (geometry.size.height - AppSpacing.md * 2) / CGFloat(count))
            let maxValue = max(1, bins.map(\.count).max() ?? 1)
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    let barArea = size.width - 22
                    for (index, bin) in bins.enumerated() where bin.count > 0 {
                        let fraction = sqrt(Double(bin.count) / Double(maxValue))
                        let width = max(2, barArea * fraction)
                        let rect = CGRect(
                            x: size.width - AppSpacing.xs - width,
                            y: AppSpacing.md + CGFloat(index) * rowHeight,
                            width: width,
                            height: max(1, rowHeight - (rowHeight > 3 ? 1 : 0))
                        )
                        context.fill(Path(rect), with: .color(index == hoverIndex ? Color.appAccent : Color.appAccent.opacity(0.55)))
                    }
                    // Year marks where a year starts (newest month of each year).
                    var lastLabelY = -CGFloat.infinity
                    for (index, bin) in bins.enumerated() {
                        let isYearStart = index == 0 || bins[index - 1].year != bin.year
                        guard isYearStart else { continue }
                        let y = AppSpacing.md + CGFloat(index) * rowHeight
                        context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 0.5)), with: .color(Color.appBorder))
                        guard y - lastLabelY >= 14 else { continue }
                        lastLabelY = y
                        context.draw(
                            Text(verbatim: "\(bin.year)").font(.appMicro).foregroundColor(Color.appMuted),
                            at: CGPoint(x: 2, y: y + 1),
                            anchor: .topLeading
                        )
                    }
                }
                if let hoverIndex, bins.indices.contains(hoverIndex) {
                    let bin = bins[hoverIndex]
                    Text("\(TimelineBucketer.title(for: bin)) · \(bin.count.formatted())")
                        .font(.appMicro)
                        .foregroundStyle(Color.appPrimaryText)
                        .padding(.horizontal, AppSpacing.xs)
                        .padding(.vertical, AppSpacing.xxs)
                        .background(RoundedRectangle(cornerRadius: AppRadius.xs).fill(Color.appElevatedSurface))
                        .fixedSize()
                        .offset(x: -64, y: AppSpacing.md + CGFloat(hoverIndex) * rowHeight - 6)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard let index = index(at: value.location.y, rowHeight: rowHeight) else { return }
                        hoverIndex = index
                        onJump(bins[index])
                    }
            )
            .onContinuousHover { phase in
                switch phase {
                case let .active(point): hoverIndex = index(at: point.y, rowHeight: rowHeight)
                case .ended: hoverIndex = nil
                }
            }
        }
        .background(Color.appSurface)
        .help("Files per month: click or drag to jump")
        .accessibilityElement()
        .accessibilityLabel("Timeline scrubber")
        .accessibilityValue(bins.isEmpty ? "Empty" : "\(bins.count) months")
        .accessibilityAdjustableAction { direction in
            guard !bins.isEmpty else { return }
            let current = hoverIndex ?? 0
            let next = direction == .increment ? max(0, current - 1) : min(bins.count - 1, current + 1)
            hoverIndex = next
            onJump(bins[next])
        }
    }

    private func index(at y: CGFloat, rowHeight: CGFloat) -> Int? {
        guard !bins.isEmpty else { return nil }
        let raw = Int((y - AppSpacing.md) / rowHeight)
        return min(max(raw, 0), bins.count - 1)
    }
}
