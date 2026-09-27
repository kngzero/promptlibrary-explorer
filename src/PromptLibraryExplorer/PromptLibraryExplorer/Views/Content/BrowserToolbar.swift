import SwiftUI
import UniformTypeIdentifiers

/// Stable identifiers for the browser's toolbar items. They key the user's
/// Customize Toolbar… layout (persisted by AppKit under the toolbar id), so
/// never rename one; `WindowTitleConfigurator` matches them to set overflow priority.
enum BrowserToolbarItemID {
    static let toolbar = "browser.toolbar"
    static let navigation = "browser.navigation"
    static let breadcrumbs = "browser.breadcrumbs"
    static let indexing = "browser.indexing"
    static let viewMode = "browser.viewMode"
    static let sort = "browser.sort"
    static let groupBy = "browser.groupBy"
    static let filter = "browser.filter"
    static let undoRedo = "browser.undoRedo"
    static let newFolder = "browser.newFolder"
    static let refresh = "browser.refresh"
    static let settings = "browser.settings"
    static let searchMode = "browser.searchMode"
    static let search = "browser.search"
    // Declared by other views, but in the same customizable toolbar: every
    // `.toolbar` on the window must share this id, or AppKit turns off
    // "Customize Toolbar…" for the whole window.
    static let identity = "browser.identity"
    static let openFolder = "browser.openFolder"
    static let appearance = "browser.appearance"

    /// Kept visible longest when the window narrows.
    static let highPriority: Set<String> = [navigation, breadcrumbs, search]
    /// First to move into the » overflow menu.
    static let lowPriority: Set<String> = [refresh, groupBy, sort, indexing]
}

/// The content browser's controls, hosted in the window's native (customizable)
/// toolbar over the content column. Attached with
/// `.toolbar(id: BrowserToolbarItemID.toolbar) { BrowserToolbar(vm: vm) }`.
///
/// Shortcut owners are unchanged: these buttons have no key equivalents of
/// their own (⌘[ ⌘] ⌘1 ⌘2 ⇧⌘N ⌘R ⌘Z ⇧⌘Z ⌘, ⌘F stay with the menus).
struct BrowserToolbar: CustomizableToolbarContent {
    @Bindable var vm: ExplorerViewModel

    var body: some CustomizableToolbarContent {
        // Split in two: a toolbar builder takes at most ten items.
        browsingItems
        actionItems
    }

    @ToolbarContentBuilder
    private var browsingItems: some CustomizableToolbarContent {
        ToolbarItem(id: BrowserToolbarItemID.navigation, placement: .navigation) {
            ControlGroup {
                Button {
                    Task { await vm.navigateBack() }
                } label: {
                    Label("Back", systemImage: "chevron.backward")
                }
                .disabled(!vm.canNavigateBack)
                .help("\(vm.backNavigationTitle) (⌘[)")
                .accessibilityLabel("Back")

                Button {
                    Task { await vm.navigateForward() }
                } label: {
                    Label("Forward", systemImage: "chevron.forward")
                }
                .disabled(!vm.canNavigateForward)
                .help("\(vm.forwardNavigationTitle) (⌘])")
                .accessibilityLabel("Forward")
            } label: {
                Label("Back/Forward", systemImage: "chevron.backward")
            }
            .controlGroupStyle(.navigation)
        }

        // Crumbs keep a flexible width so the whole strip stays a drop target.
        ToolbarItem(id: BrowserToolbarItemID.breadcrumbs, placement: .navigation) {
            BreadcrumbBar()
                .frame(minWidth: 120, idealWidth: 300, maxWidth: 480, alignment: .leading)
        }

        ToolbarItem(id: BrowserToolbarItemID.indexing, placement: .primaryAction) {
            // Empty unless indexing; the item stays so a customized layout is stable.
            LibraryIndexingIndicator(
                isIndexing: vm.isLibraryIndexing,
                progress: vm.libraryIndexProgress
            )
        }

        ToolbarItem(id: BrowserToolbarItemID.viewMode, placement: .primaryAction) {
            Picker("View", selection: $vm.viewMode) {
                ForEach(BrowserViewMode.allCases) { mode in
                    Label("View as \(mode.title)", systemImage: mode.systemImage)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .help("View as Grid (⌘1) or List (⌘2)")
            .accessibilityLabel("View Mode")
            .accessibilityValue(vm.viewMode.title)
        }

        ToolbarItem(id: BrowserToolbarItemID.sort, placement: .primaryAction) {
            sortMenu
        }

        ToolbarItem(id: BrowserToolbarItemID.groupBy, placement: .primaryAction) {
            groupByMenu
        }

        ToolbarItem(id: BrowserToolbarItemID.filter, placement: .primaryAction) {
            filterMenu
        }

    }

    @ToolbarContentBuilder
    private var actionItems: some CustomizableToolbarContent {
        ToolbarItem(id: BrowserToolbarItemID.newFolder, placement: .primaryAction) {
            Button {
                vm.isShowingNewFolderPrompt = true
            } label: {
                Label("New Folder", systemImage: "plus.rectangle.on.folder")
            }
            // Disabled rather than removed, so the toolbar doesn't reflow.
            .disabled(!vm.canCreateFolder)
            .help("New Folder (⇧⌘N)")
            .accessibilityLabel("New Folder")
        }

        ToolbarItem(id: BrowserToolbarItemID.undoRedo, placement: .primaryAction) {
            ControlGroup {
                Button {
                    Task { await vm.undoLastFolderAction() }
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(!vm.canUndoFolderAction)
                .help(vm.undoMenuTitle)
                .accessibilityLabel(vm.undoMenuTitle)

                Button {
                    Task { await vm.redoLastFolderAction() }
                } label: {
                    Label("Redo", systemImage: "arrow.uturn.forward")
                }
                .disabled(!vm.canRedoFolderAction)
                .help(vm.redoMenuTitle)
                .accessibilityLabel(vm.redoMenuTitle)
            } label: {
                Label("Undo/Redo", systemImage: "arrow.uturn.backward")
            }
        }

        ToolbarItem(id: BrowserToolbarItemID.refresh, placement: .primaryAction) {
            Button {
                Task { await vm.refreshFolder() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Refresh (⌘R)")
            .accessibilityLabel("Refresh")
        }

        ToolbarItem(id: BrowserToolbarItemID.settings, placement: .primaryAction) {
            Button {
                vm.openSettings()
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Settings (⌘,)")
            .accessibilityLabel("Settings")
        }

        ToolbarItem(id: BrowserToolbarItemID.searchMode, placement: .primaryAction) {
            searchModeMenu
        }

        ToolbarItem(id: BrowserToolbarItemID.search, placement: .primaryAction) {
            SearchFieldView(text: $vm.searchQuery)
                .frame(minWidth: 140, idealWidth: 200, maxWidth: 260)
                .onChange(of: vm.searchQuery) { _, _ in
                    vm.updateContentSearch()
                }
                .help("Search this folder (⌘F)")
                .accessibilityLabel("Search")
        }
    }

    // MARK: - Menus

    private var searchModeMenu: some View {
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
            Label("Search Mode", systemImage: vm.searchMode.icon)
                .foregroundStyle(vm.searchMode == .filename ? Color.appMuted : Color.appAccent)
        }
        .help("Search mode: \(vm.searchMode.displayName)")
        .accessibilityLabel("Search Mode")
        .accessibilityValue(vm.searchMode.displayName)
    }

    private var sortMenu: some View {
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
            Label("Sort", systemImage: currentSortModeIcon)
        }
        .help(currentSortModeHelpText)
        .accessibilityLabel("Sort")
        .accessibilityValue(currentSortModeHelpText.replacingOccurrences(of: "Sort mode: ", with: ""))
    }

    private var groupByMenu: some View {
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
            Label("Group By", systemImage: "rectangle.3.group")
                .foregroundStyle(vm.groupBy == .none ? Color.appMuted : Color.appAccent)
        }
        .help(vm.groupBy == .none ? "Group By" : "Grouped by \(vm.groupBy.title)")
        .accessibilityLabel("Group By")
        .accessibilityValue(vm.groupBy.title)
    }

    private var filterMenu: some View {
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
            // A toolbar menu shows only its label's icon, so an active filter
            // switches to the filled glyph (in the accent) instead of a count badge.
            Label(
                "Filter",
                systemImage: vm.filterConfig.activeCount > 0
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle"
            )
            .foregroundStyle(vm.filterConfig.activeCount > 0 ? Color.appAccent : Color.appMuted)
        }
        .help(vm.filterConfig.activeCount > 0 ? "Filter (\(vm.filterConfig.activeCount) active)" : "Filter")
        .accessibilityLabel("Filter")
        .accessibilityValue(vm.filterConfig.activeCount > 0 ? "\(vm.filterConfig.activeCount) active" : "None active")
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
        // Native bezeled search field (magnifier + clear button) so it matches
        // the window toolbar it lives in.
        field.placeholderString = "Search"
        field.delegate = context.coordinator
        field.maximumRecents = 0
        field.sendsSearchStringImmediately = true

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

    /// The path from `dropping` crumbs in; each crumb keeps its natural width
    /// (the labeled button style would otherwise stretch to fill the item).
    private func crumbRow(dropping dropped: Int) -> some View {
        let crumbs = Array(vm.breadcrumbs.enumerated()).dropFirst(dropped)
        return HStack(spacing: AppSpacing.xxs) {
            if dropped > 0 {
                Text("…")
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
                    .accessibilityHidden(true)
            }
            ForEach(Array(crumbs), id: \.offset) { idx, crumb in
                if idx > dropped || dropped > 0 {
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
                .fixedSize()
            }
        }
        .fixedSize()
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

            // A toolbar item can't grow past its width, so long paths drop their
            // leading crumbs (behind "…") instead of clipping the current folder.
            ViewThatFits(in: .horizontal) {
                crumbRow(dropping: 0)
                crumbRow(dropping: min(2, max(vm.breadcrumbs.count - 1, 0)))
                crumbRow(dropping: max(vm.breadcrumbs.count - 2, 0))
                crumbRow(dropping: max(vm.breadcrumbs.count - 1, 0))
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

// MARK: - Library indexing indicator

private struct LibraryIndexingIndicator: View {
    let isIndexing: Bool
    let progress: (done: Int, total: Int)?

    private var helpText: String {
        guard let progress, progress.total > 0 else { return "Indexing library…" }
        return "Indexing \(progress.done)/\(progress.total)"
    }

    var body: some View {
        if isIndexing {
            spinner
        } else {
            // Collapses to nothing between runs; the toolbar item itself stays.
            Color.clear.frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    private var spinner: some View {
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
