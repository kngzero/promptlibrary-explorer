import SwiftUI
import UniformTypeIdentifiers

struct HeaderBarView: View {
    @Environment(ExplorerViewModel.self) private var vm

    var body: some View {
        @Bindable var vm = vm

        HStack(spacing: AppSpacing.lg) {
            // Back + Forward pill
            HStack(spacing: 0) {
                Button {
                    Task { await vm.navigateBack() }
                } label: {
                    Image(systemName: "chevron.backward")
                        .font(.appCalloutEmphasis)
                }
                .buttonStyle(AppSegmentButtonStyle())
                .disabled(!vm.canNavigateBack)
                .help("\(vm.backNavigationTitle) (⌘[)")
                .accessibilityLabel("Back")

                Divider()
                    .frame(height: 14)

                Button {
                    Task { await vm.navigateForward() }
                } label: {
                    Image(systemName: "chevron.forward")
                        .font(.appCalloutEmphasis)
                }
                .buttonStyle(AppSegmentButtonStyle())
                .disabled(!vm.canNavigateForward)
                .help("\(vm.forwardNavigationTitle) (⌘])")
                .accessibilityLabel("Forward")
            }
            .background(
                Capsule(style: .continuous)
                    .fill(Color.appSurface)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.appBorder, lineWidth: 1)
            )

            // Breadcrumbs (fills the free space so the whole strip is a drop target)
            BreadcrumbBar()

            if vm.isLibraryIndexing {
                LibraryIndexingIndicator(progress: vm.libraryIndexProgress)
            }

            ViewModeToggle()

            // Search + Search Mode + Sort + Filter bar
            HStack(spacing: 0) {
                // Search field
                SearchFieldView(text: $vm.searchQuery)
                    .frame(width: 180, height: 28)
                    .padding(.horizontal, 10)
                    .onChange(of: vm.searchQuery) { _, _ in
                        vm.updateContentSearch()
                    }

                Divider()
                    .frame(height: 14)

                // Search mode picker
                Menu {
                    ForEach(SearchMode.allCases, id: \.self) { mode in
                        Button {
                            vm.searchMode = mode
                            vm.persistSearchMode()
                            vm.updateContentSearch()
                        } label: {
                            HStack {
                                Image(systemName: mode.icon)
                                Text(mode.displayName)
                                if vm.searchMode == mode {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: vm.searchMode.icon)
                        .font(.appCaption)
                        .foregroundStyle(vm.searchMode == .filename ? Color.appMuted : Color.appAccent)
                        .frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Search mode: \(vm.searchMode.displayName)")
                .accessibilityLabel("Search Mode")
                .accessibilityValue(vm.searchMode.displayName)

                Divider()
                    .frame(height: 14)

                // Sort
                Menu {
                    ForEach(Array(Self.sortMenuFields.enumerated()), id: \.element) { index, field in
                        if index > 0 {
                            Divider()
                        }
                        if field.supportsDirection {
                            ForEach([SortDirection.asc, SortDirection.desc], id: \.self) { direction in
                                Button("Sort by \(field.title) (\(Self.directionLabel(field, direction)))") {
                                    vm.sortConfig = SortConfig(field: field, direction: direction)
                                    vm.persistSortConfig()
                                }
                            }
                        } else {
                            Button(field.title) {
                                vm.sortConfig = SortConfig(field: field, direction: .asc)
                                vm.persistSortConfig()
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: currentSortModeIcon)
                            .foregroundStyle(Color.appAccent)
                        Image(systemName: "arrow.up.arrow.down")
                            .foregroundStyle(Color.appMuted)
                    }
                    .padding(.horizontal, AppSpacing.sm)
                    .padding(.vertical, AppSpacing.sm)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(currentSortModeHelpText)
                .accessibilityLabel("Sort")
                .accessibilityValue(currentSortModeHelpText.replacingOccurrences(of: "Sort mode: ", with: ""))

                Divider()
                    .frame(height: 14)

                // Group by
                Menu {
                    ForEach(GroupByField.allCases) { field in
                        Button {
                            vm.groupBy = field
                        } label: {
                            HStack {
                                Text(field.title)
                                if vm.groupBy == field {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        if field == .none {
                            Divider()
                        }
                    }
                } label: {
                    Image(systemName: "rectangle.3.group")
                        .foregroundStyle(vm.groupBy == .none ? Color.appMuted : Color.appAccent)
                        .padding(.horizontal, AppSpacing.sm)
                        .padding(.vertical, AppSpacing.sm)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(vm.groupBy == .none ? "Group By" : "Grouped by \(vm.groupBy.title)")
                .accessibilityLabel("Group By")
                .accessibilityValue(vm.groupBy.title)

                Divider()
                    .frame(height: 14)

                // Filter
                Menu {
                    Button("Show All File Types") {
                        vm.filterConfig.hiddenFileTypes.removeAll()
                        vm.persistFilterConfig()
                    }
                    .disabled(vm.filterConfig.hiddenFileTypes.isEmpty)

                    Divider()

                    Toggle(FileTypeFilter.plib.displayName, isOn: filterBinding(for: .plib))
                    Toggle(FileTypeFilter.aoe.displayName, isOn: filterBinding(for: .aoe))

                    Divider()

                    Toggle(FileTypeFilter.png.displayName, isOn: filterBinding(for: .png))
                    Toggle(FileTypeFilter.jpg.displayName, isOn: filterBinding(for: .jpg))
                    Toggle(FileTypeFilter.webp.displayName, isOn: filterBinding(for: .webp))
                    Toggle(FileTypeFilter.gif.displayName, isOn: filterBinding(for: .gif))
                    Toggle(FileTypeFilter.otherImages.displayName, isOn: filterBinding(for: .otherImages))

                    Divider()

                    Toggle(FileTypeFilter.video.displayName, isOn: filterBinding(for: .video))
                    Toggle(FileTypeFilter.audio.displayName, isOn: filterBinding(for: .audio))

                    Divider()

                    Toggle(FileTypeFilter.unsupported.displayName, isOn: filterBinding(for: .unsupported))

                    Divider()
                    Menu("Minimum Rating") {
                        Button("Show All") {
                            vm.filterConfig.filterMinRating = 0
                            vm.persistFilterConfig()
                        }
                        ForEach(1...5, id: \.self) { stars in
                            Button("\(stars)+ Stars") {
                                vm.filterConfig.filterMinRating = stars
                                vm.persistFilterConfig()
                            }
                        }
                    }
                } label: {
                    HStack(spacing: AppSpacing.xxs) {
                        Image(systemName: "line.3.horizontal.decrease")
                            .foregroundStyle(Color.appMuted)
                        if vm.filterConfig.activeCount > 0 {
                            Text("\(vm.filterConfig.activeCount)")
                                .font(.appFootnote.weight(.semibold))
                                .foregroundStyle(Color.appOnAccent)
                                .padding(.horizontal, AppSpacing.xs)
                                .background(Color.appAccent, in: Capsule())
                        }
                    }
                    .padding(.horizontal, AppSpacing.sm)
                    .padding(.vertical, AppSpacing.sm)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(vm.filterConfig.activeCount > 0 ? "Filter (\(vm.filterConfig.activeCount) active)" : "Filter")
                .accessibilityLabel("Filter")
                .accessibilityValue(vm.filterConfig.activeCount > 0 ? "\(vm.filterConfig.activeCount) active" : "None active")
            }
            .background(
                Capsule(style: .continuous)
                    .fill(Color.appSurface)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.appBorder, lineWidth: 1)
            )
            .clipShape(Capsule(style: .continuous))

            // Undo + Redo pill
            HStack(spacing: 0) {
                Button {
                    Task { await vm.undoLastFolderAction() }
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.appCalloutEmphasis)
                }
                .buttonStyle(AppSegmentButtonStyle())
                .disabled(!vm.canUndoFolderAction)
                .help(vm.undoMenuTitle)
                .accessibilityLabel(vm.undoMenuTitle)

                Divider()
                    .frame(height: 14)

                Button {
                    Task { await vm.redoLastFolderAction() }
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                        .font(.appCalloutEmphasis)
                }
                .buttonStyle(AppSegmentButtonStyle())
                .disabled(!vm.canRedoFolderAction)
                .help(vm.redoMenuTitle)
                .accessibilityLabel(vm.redoMenuTitle)
            }
            .background(
                Capsule(style: .continuous)
                    .fill(Color.appSurface)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.appBorder, lineWidth: 1)
            )

            // New Folder
            if vm.canCreateFolder {
                Button {
                    vm.isShowingNewFolderPrompt = true
                } label: {
                    Image(systemName: "plus.rectangle.on.folder")
                        .font(.appHeadline)
                }
                .buttonStyle(AppIconButtonStyle())
                .help("New Folder (⇧⌘N)")
                .accessibilityLabel("New Folder")
            }

            // Refresh
            Button {
                Task { await vm.refreshFolder() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.appBody)
            }
            .buttonStyle(AppLabeledButtonStyle())
            // Natural width: the labeled style fills its proposal, which let Refresh
            // take half the free space and squeezed/centred the breadcrumbs.
            .fixedSize()
            .help("Refresh")

            Button {
                vm.openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.appHeadline)
            }
            .buttonStyle(AppIconButtonStyle(showsRestingChrome: false))
            .help("Settings")
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, AppSpacing.lg)
        .frame(height: LayoutMetrics.panelHeaderHeight)
        .background(Color.appBackground)
        .overlay(alignment: .bottom) {
            Divider().background(Color.appBorder)
        }
    }

    private func filterBinding(for fileType: FileTypeFilter) -> Binding<Bool> {
        Binding(
            get: { vm.filterConfig.hides(fileType) },
            set: {
                vm.filterConfig.setHidden($0, for: fileType)
                vm.persistFilterConfig()
            }
        )
    }

    private var currentSortModeIcon: String {
        let field = vm.sortConfig.field
        if field == .name && vm.sortConfig.direction == .desc {
            return "textformat.abc.dottedunderline"
        }
        return field.systemImage
    }

    private var currentSortModeHelpText: String {
        let field = vm.sortConfig.field
        guard field.supportsDirection else { return "Sort mode: \(field.title)" }
        return "Sort mode: \(field.title) (\(Self.directionLabel(field, vm.sortConfig.direction)))"
    }

    /// Every sort field, with Custom Order kept at the bottom of the menu.
    private static var sortMenuFields: [SortField] {
        SortField.allCases.filter { $0 != .custom } + [.custom]
    }

    /// Menu/help wording for a sort direction. Rating's `.asc` has always meant
    /// high-to-low in this app, so it keeps that wording.
    private static func directionLabel(_ field: SortField, _ direction: SortDirection) -> String {
        let asc = direction == .asc
        switch field {
        case .rating:
            return asc ? "High-Low" : "Low-High"
        case .dateModified, .dateCreated:
            return asc ? "Oldest First" : "Newest First"
        case .size:
            return asc ? "Smallest First" : "Largest First"
        default:
            return asc ? "A-Z" : "Z-A"
        }
    }
}

// MARK: - NSSearchField wrapper (reliable text input that works with macOS focus system)

struct SearchFieldView: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search..."
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.maximumRecents = 0
        field.sendsSearchStringImmediately = true

        // Remove the magnifying glass to prevent it overlapping text when focused
        (field.cell as? NSSearchFieldCell)?.searchButtonCell = nil

        // Listen for Cmd+F to focus
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.focusField),
            name: .focusSearchField,
            object: nil
        )
        context.coordinator.field = field

        return field
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    class Coordinator: NSObject, NSSearchFieldDelegate {
        @Binding var text: String
        weak var field: NSSearchField?
        private var outsideClickMonitor: Any?

        init(text: Binding<String>) {
            _text = text
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
            stopOutsideClickMonitoring()
        }

        func controlTextDidChange(_ obj: Notification) {
            if let field = obj.object as? NSSearchField {
                text = field.stringValue
            }
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            startOutsideClickMonitoring()
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            stopOutsideClickMonitoring()
        }

        @objc func focusField() {
            field?.window?.makeFirstResponder(field)
            field?.selectText(nil)
            startOutsideClickMonitoring()
        }

        @objc func blurField() {
            guard let field, let window = field.window else { return }
            if window.firstResponder === field || window.firstResponder is NSTextView {
                window.makeFirstResponder(nil)
            }
            stopOutsideClickMonitoring()
        }

        private func startOutsideClickMonitoring() {
            guard outsideClickMonitor == nil else { return }

            outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let field = self.field, let window = field.window, event.window === window else {
                    return event
                }

                let fieldFrameInWindow = field.convert(field.bounds, to: nil)
                if !fieldFrameInWindow.contains(event.locationInWindow) {
                    self.blurField()
                }

                return event
            }
        }

        private func stopOutsideClickMonitoring() {
            if let outsideClickMonitor {
                NSEvent.removeMonitor(outsideClickMonitor)
                self.outsideClickMonitor = nil
            }
        }
    }
}

// MARK: - Breadcrumb Bar

struct BreadcrumbBar: View {
    @Environment(ExplorerViewModel.self) private var vm
    @State private var isDropTarget = false

    var body: some View {
        // Crumbs keep their natural width first; the spacer soaks up the free
        // space so the drop target still spans it (same layout as crumbs + Spacer).
        HStack(spacing: 0) {
            if let collection = vm.activeCollection {
                CollectionCrumb(collection: collection)
            } else {
                folderCrumbs
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppSpacing.xxs)
        .frame(minHeight: 26)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.sm)
                .fill(isDropTarget ? Color.appAccent.opacity(0.12) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.sm)
                .strokeBorder(isDropTarget ? Color.appAccent : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        // Quick navigation: drop a folder to open it, or a file to open its folder
        // with the file selected. Navigation only — nothing is moved or copied.
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTarget) { providers in
            Task {
                let urls = await URLDropLoader.loadURLs(from: providers)
                guard let url = urls.first else { return }
                await vm.navigate(toDropped: url)
            }
            return true
        }
        .help("Drop a file or folder here to go to it")
    }

    private var folderCrumbs: some View {
        HStack(spacing: AppSpacing.xxs) {
            // Up button
            if vm.selectedFolderPath != vm.explorerRootPath {
                Button {
                    if let current = vm.selectedFolderPath {
                        let parent = current.deletingLastPathComponent()
                        Task { await vm.selectFolder(parent) }
                    }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.caption)
                }
                .buttonStyle(AppSegmentButtonStyle(width: 22, height: 22))
                .help("Enclosing Folder")
                .accessibilityLabel("Enclosing Folder")
            }

            ForEach(Array(vm.breadcrumbs.enumerated()), id: \.offset) { idx, crumb in
                if idx > 0 {
                    Image(systemName: "chevron.right")
                        .font(.appIcon(9))
                        .foregroundStyle(Color.appMuted.opacity(0.5))
                        .accessibilityHidden(true)
                }

                Button {
                    Task { await vm.selectFolder(crumb.url) }
                } label: {
                    Text(crumb.name)
                        .font(.appCaption)
                        .lineLimit(1)
                }
                .buttonStyle(
                    AppLabeledButtonStyle(
                        height: 22,
                        horizontalPadding: 6,
                        cornerRadius: AppRadius.sm,
                        showsRestingChrome: false,
                        restingForeground: crumb.url == vm.selectedFolderPath
                            ? Color.appPrimaryText
                            : Color.appMuted
                    )
                )
            }
        }
    }
}

/// Stands in for the breadcrumbs while a collection is the listing.
private struct CollectionCrumb: View {
    @Environment(ExplorerViewModel.self) private var vm
    let collection: FileCollection

    var body: some View {
        HStack(spacing: AppSpacing.sm) {
            Image(systemName: "rectangle.stack.fill")
                .font(.appIcon(11, weight: .medium))
                .foregroundStyle(Color.appAccent)
                .accessibilityHidden(true)
            ForEach(vm.collectionSetAncestors(ofParent: collection.parentID)) { set in
                Text(set.name)
                    .font(.appCallout)
                    .foregroundStyle(Color.appMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.right")
                    .font(.appIcon(8, weight: .semibold))
                    .foregroundStyle(Color.appMuted)
                    .accessibilityHidden(true)
            }
            Text(collection.name)
                .font(.appCalloutEmphasis)
                .foregroundStyle(Color.appPrimaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(collection.paths.count)")
                .font(.appMicro)
                .foregroundStyle(Color.appMuted)
                .padding(.horizontal, AppSpacing.xs)
                .padding(.vertical, AppSpacing.xxs)
                .background(Capsule().fill(Color.appElevatedSurface))
                .accessibilityLabel("\(collection.paths.count) items")
            Button {
                vm.openCollection(nil)
            } label: {
                Image(systemName: "xmark")
                    .font(.appIcon(9, weight: .semibold))
            }
            .buttonStyle(AppSegmentButtonStyle(width: 20, height: 20))
            .help("Close Collection")
            .accessibilityLabel("Close Collection \(collection.name)")
        }
        .padding(.leading, AppSpacing.sm)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Collection \(collection.name)")
    }
}

// MARK: - View mode toggle

/// Grid / List segmented pill.
private struct ViewModeToggle: View {
    @Environment(ExplorerViewModel.self) private var vm

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(BrowserViewMode.allCases.enumerated()), id: \.element) { offset, mode in
                if offset > 0 {
                    Divider().frame(height: 14)
                }
                let isActive = vm.viewMode == mode
                Button {
                    vm.viewMode = mode
                } label: {
                    Image(systemName: mode.systemImage)
                        .font(.appCalloutEmphasis)
                }
                .buttonStyle(AppSegmentButtonStyle(restingForeground: isActive ? Color.appAccent : Color.appMuted))
                .background(
                    Capsule(style: .continuous)
                        .fill(isActive ? Color.appSelected : Color.clear)
                )
                .help("View as \(mode.title)")
                .accessibilityLabel("View as \(mode.title)")
                .accessibilityAddTraits(isActive ? [.isSelected] : [])
            }
        }
        .background(
            Capsule(style: .continuous)
                .fill(Color.appSurface)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.appBorder, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("View Mode")
    }
}

// MARK: - Library indexing indicator

private struct LibraryIndexingIndicator: View {
    let progress: (done: Int, total: Int)?

    private var helpText: String {
        guard let progress, progress.total > 0 else { return "Indexing library…" }
        return "Indexing \(progress.done)/\(progress.total)"
    }

    var body: some View {
        Group {
            if let progress, progress.total > 0 {
                ProgressView(value: Double(min(progress.done, progress.total)), total: Double(progress.total))
            } else {
                ProgressView()
            }
        }
        .progressViewStyle(.circular)
        .controlSize(.small)
        .tint(Color.appAccent)
        .frame(width: 18, height: 18)
        .help(helpText)
        .accessibilityLabel("Library indexing")
        .accessibilityValue(helpText)
    }
}
