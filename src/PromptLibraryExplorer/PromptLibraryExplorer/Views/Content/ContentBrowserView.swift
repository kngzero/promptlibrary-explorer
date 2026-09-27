import SwiftUI
import UniformTypeIdentifiers

struct ContentBrowserView: View {
    @Environment(ExplorerViewModel.self) private var vm
    @State private var inlineRenamePath: String?
    @State private var inlineRenameValue = ""
    @State private var reorderIndicator: ExplorerReorderIndicator?
    /// Owned by MainContentView so keyboard navigation can skip collapsed sections.
    @Binding var collapsedGroups: Set<String>
    @State private var isShowingNewCollectionPrompt = false
    @State private var newCollectionName = ""
    private let gridSpacing: CGFloat = AppSpacing.xs
    private let gridPadding: CGFloat = AppSpacing.md

    private var itemSize: CGFloat {
        let base: CGFloat = 80
        let scale = CGFloat(vm.thumbnailSize)
        return base + (scale * 32) // 80..240
    }

    private var baseCellWidth: CGFloat {
        itemSize + 8
    }

    var body: some View {
        VStack(spacing: 0) {
            if vm.isLoadingFolder {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.processedFolderContents.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .contextMenu {
                        backgroundContextMenu
                    }
                    .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil, perform: handleBackgroundDrop)
            } else if vm.viewMode == .list {
                FileListView(
                    groups: vm.contentGroups,
                    collapsedGroups: $collapsedGroups,
                    inlineRenamePath: $inlineRenamePath,
                    inlineRenameValue: $inlineRenameValue,
                    onRenameCommit: commitInlineRename(for:),
                    onRenameCancel: cancelInlineRename,
                    onRenameStart: startInlineRename(for:),
                    onNewCollection: promptForNewCollection
                )
                .background {
                    Color.clear
                        .contentShape(Rectangle())
                        .contextMenu {
                            backgroundContextMenu
                        }
                }
                .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil, perform: handleBackgroundDrop)
            } else {
                gridView
            }

            if vm.showStatusBar {
                ContentStatusBarView()
            }
        }
        .background(Color.appBackground)
        // Back/forward, breadcrumbs, view, sort/group/filter, search… live in the
        // window's native toolbar over this column (user-customizable).
        .toolbar(id: BrowserToolbarItemID.toolbar) {
            BrowserToolbar(vm: vm)
        }
        .onChange(of: vm.selectedFolderPath?.standardizedFileURL.path) { _, _ in
            cancelInlineRename()
        }
        .onChange(of: vm.groupBy) { _, _ in
            collapsedGroups = []
        }
        .onChange(of: vm.selectedItemIndex) { _, newIndex in
            let items = vm.processedFolderContents
            let selectedPath = newIndex >= 0 && newIndex < items.count ? items[newIndex].path : nil
            if let inlineRenamePath, selectedPath != inlineRenamePath {
                cancelInlineRename()
            }
            expandGroupContaining(newIndex)
        }
        .onReceive(NotificationCenter.default.publisher(for: .beginRenameSelection)) { _ in
            beginRenameOfSelection()
        }
        .alert("New Collection", isPresented: $isShowingNewCollectionPrompt) {
            TextField("Collection name", text: $newCollectionName)
            Button("Create") {
                let name = newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines)
                vm.createCollection(named: name.isEmpty ? defaultCollectionName : name, withSelection: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let count = vm.selectedFileItems.count
            Text("The \(count == 1 ? "selected file" : "\(count) selected files") will be added to the new collection.")
        }
    }

    // MARK: Grid

    private var gridView: some View {
        GeometryReader { geometry in
            let availableGridWidth = gridContentWidth(for: geometry.size.width)
            let columnCount = fittedColumnCount(for: availableGridWidth)
            let cellWidth = fittedCellWidth(for: availableGridWidth, columnCount: columnCount)
            let fittedItemSize = max(80, cellWidth - 8)
            let columns = Array(
                repeating: GridItem(.flexible(minimum: cellWidth, maximum: cellWidth), spacing: gridSpacing),
                count: columnCount
            )
            let items = vm.processedFolderContents
            let groups = vm.contentGroups

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: gridSpacing, pinnedViews: [.sectionHeaders]) {
                        if groups.isEmpty {
                            gridCells(
                                items.indices.map { IndexedEntry(index: $0, item: items[$0]) },
                                size: fittedItemSize,
                                cellWidth: cellWidth
                            )
                        } else {
                            ForEach(groups) { group in
                                let entries = group.indices
                                    .filter { $0 >= 0 && $0 < items.count }
                                    .map { IndexedEntry(index: $0, item: items[$0]) }
                                Section {
                                    if !collapsedGroups.contains(group.id) {
                                        gridCells(entries, size: fittedItemSize, cellWidth: cellWidth)
                                    }
                                } header: {
                                    ContentGroupHeader(
                                        title: group.title,
                                        count: entries.count,
                                        isCollapsed: collapsedGroups.contains(group.id),
                                        onToggle: { toggleGroup(group.id) }
                                    )
                                }
                            }
                        }
                    }
                    .frame(width: availableGridWidth, alignment: .leading)
                    .overlayPreferenceValue(ExplorerItemBoundsPreferenceKey.self) { anchors in
                        GeometryReader { proxy in
                            if let reorderIndicator,
                               let anchor = anchors[reorderIndicator.itemPath]
                            {
                                ExplorerReorderIndicatorView(
                                    position: reorderIndicator.position,
                                    itemRect: proxy[anchor]
                                )
                            }
                        }
                    }
                    .padding(gridPadding)
                    .background {
                        Color.clear
                            .contentShape(Rectangle())
                            .contextMenu {
                                backgroundContextMenu
                            }
                    }
                }
                .background {
                    Color.clear
                        .task(id: "\(Int(geometry.size.width.rounded())):\(columnCount)") {
                            updateGridColumnCount(columnCount)
                        }
                }
                .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil, perform: handleBackgroundDrop)
                .onChange(of: vm.selectedItemIndex) { _, newIndex in
                    let items = vm.processedFolderContents
                    if newIndex >= 0, newIndex < items.count {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            proxy.scrollTo(items[newIndex].id, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func gridCells(_ entries: [IndexedEntry], size: CGFloat, cellWidth: CGFloat) -> some View {
        ForEach(entries) { entry in
            ExplorerItemView(
                item: entry.item,
                index: entry.index,
                size: size,
                cellWidth: cellWidth,
                reorderIndicator: $reorderIndicator,
                inlineRenamePath: $inlineRenamePath,
                inlineRenameValue: $inlineRenameValue,
                onRenameCommit: { commitInlineRename(for: entry.item) },
                onRenameCancel: cancelInlineRename
            )
            .id(entry.item.id)
            .contextMenu {
                ContentItemContextMenu(
                    item: entry.item,
                    index: entry.index,
                    onRename: { startInlineRename(for: entry.item) },
                    onNewCollection: promptForNewCollection
                )
            }
        }
    }

    // MARK: Empty states

    @ViewBuilder
    private var emptyState: some View {
        let isFocused = vm.activePane == .content
        if vm.isCollectionMode && vm.listingSourceContents.isEmpty {
            EmptyContentStateView(
                systemImage: "rectangle.stack",
                title: "\(vm.activeCollection?.name ?? "This collection") is empty",
                message: "Right-click files in any folder and choose Add to Collection, or use File ▸ Add to Collection.",
                isFocused: isFocused
            ) {
                Button("Back to Folder") {
                    vm.openCollection(nil)
                }
                .buttonStyle(AppLabeledButtonStyle())
            }
        } else if vm.hiddenItemCount > 0 && hasClearableFilters {
            let hidden = vm.hiddenItemCount
            EmptyContentStateView(
                systemImage: "line.3.horizontal.decrease.circle",
                title: hidden == 1 ? "1 item hidden by filters" : "\(hidden) items hidden by filters",
                message: filterSummary,
                isFocused: isFocused
            ) {
                Button("Clear Filters", action: clearFilters)
                    .buttonStyle(AppPrimaryButtonStyle(font: .appCalloutEmphasis))
            }
        } else if vm.selectedFolderPath == nil && !vm.isCollectionMode {
            EmptyContentStateView(
                systemImage: "folder.badge.questionmark",
                title: "No folder open",
                message: "Choose a folder in the sidebar to browse its prompts and images.",
                isFocused: isFocused
            ) { EmptyView() }
        } else {
            EmptyContentStateView(
                systemImage: "folder",
                title: vm.hiddenItemCount > 0 ? "No supported files" : "This folder is empty",
                message: vm.hiddenItemCount > 0
                    ? "\(vm.hiddenItemCount) unsupported file\(vm.hiddenItemCount == 1 ? " is" : "s are") hidden. Show them from the Filter menu."
                    : "Drop files here to copy them into the folder.",
                isFocused: isFocused
            ) {
                if vm.canCreateFolder {
                    Button("New Folder") {
                        vm.isShowingNewFolderPrompt = true
                    }
                    .buttonStyle(AppLabeledButtonStyle())
                }
            }
        }
    }

    private var filterSummary: String {
        var parts: [String] = []
        if !vm.searchQuery.isEmpty { parts.append("search \u{201C}\(vm.searchQuery)\u{201D}") }
        if vm.filterConfig != FilterConfig() { parts.append("file type, rating, flag or label filters") }
        if vm.filterByTagID != nil { parts.append("a tag filter") }
        if let smart = vm.activeSmartFolder { parts.append("smart folder \u{201C}\(smart.name)\u{201D}") }
        guard !parts.isEmpty else { return "Nothing here matches the current filters." }
        return "Nothing matches " + ListFormatter.localizedString(byJoining: parts) + "."
    }

    /// Search / type / rating / tag / smart-folder narrowing (not the collection itself).
    private var hasClearableFilters: Bool {
        !vm.searchQuery.isEmpty || vm.filterConfig != FilterConfig()
            || vm.filterByTagID != nil || vm.activeSmartFolder != nil
    }

    /// Clears search / type / tag / smart-folder filters. In a collection this
    /// keeps the collection open (`clearAllFilters()` would also leave it).
    private func clearFilters() {
        guard vm.isCollectionMode else {
            vm.clearAllFilters()
            return
        }
        if !vm.searchQuery.isEmpty { vm.searchQuery = "" }
        vm.updateContentSearch()
        if vm.filterConfig != FilterConfig() {
            vm.filterConfig = FilterConfig()
            vm.persistFilterConfig()
        }
        if vm.filterByTagID != nil { vm.filterByTagID = nil }
        if vm.activeSmartFolder != nil { vm.activeSmartFolder = nil }
    }

    @ViewBuilder
    private var backgroundContextMenu: some View {
        if vm.canCreateFolder {
            Button("Create Folder") {
                vm.isShowingNewFolderPrompt = true
            }

            Divider()
        }

        Menu("View As") {
            ForEach(BrowserViewMode.allCases) { mode in
                Toggle(mode.title, isOn: Binding(
                    get: { vm.viewMode == mode },
                    set: { if $0 { vm.viewMode = mode } }
                ))
            }
        }

        Menu("Group By") {
            ForEach(GroupByField.allCases) { field in
                Toggle(field.title, isOn: Binding(
                    get: { vm.groupBy == field },
                    set: { if $0 { vm.groupBy = field } }
                ))
            }
        }

        if hasClearableFilters {
            Button("Clear Filters", action: clearFilters)
        }

        Divider()

        Button("Refresh") {
            Task { await vm.refreshFolder() }
        }
    }

    private func handleBackgroundDrop(_ providers: [NSItemProvider]) -> Bool {
        Task {
            let urls = await URLDropLoader.loadURLs(from: providers)
            await vm.importExternalFiles(urls)
        }
        return true
    }

    // MARK: Groups

    private func toggleGroup(_ id: String) {
        if collapsedGroups.contains(id) {
            collapsedGroups.remove(id)
        } else {
            collapsedGroups.insert(id)
        }
    }

    /// Keyboard navigation can land in a collapsed section; open it so the
    /// selection stays visible.
    private func expandGroupContaining(_ index: Int) {
        guard index >= 0, !collapsedGroups.isEmpty else { return }
        if let group = vm.contentGroups.first(where: { $0.indices.contains(index) }),
           collapsedGroups.contains(group.id)
        {
            collapsedGroups.remove(group.id)
        }
    }

    // MARK: Collections

    private var defaultCollectionName: String {
        let existing = Set(vm.collections.map(\.name))
        var name = "New Collection"
        var counter = 2
        while existing.contains(name) {
            name = "New Collection \(counter)"
            counter += 1
        }
        return name
    }

    private func promptForNewCollection() {
        guard !vm.selectedFileItems.isEmpty else {
            vm.showToast("Select files to add to the collection", type: .info)
            return
        }
        newCollectionName = defaultCollectionName
        isShowingNewCollectionPrompt = true
    }

    // MARK: Inline rename

    /// File ▸ Rename (posted as `.beginRenameSelection`).
    private func beginRenameOfSelection() {
        // Rename the one selected item. `selectedItemIndex` is the last-clicked
        // anchor and can point at an item that was just ⌘-deselected.
        guard !vm.isAnyModalOpen, !vm.lightboxOpen, vm.selectedIndices.count == 1,
              let index = vm.selectedIndices.first else { return }
        let items = vm.processedFolderContents
        guard index >= 0, index < items.count else { return }
        expandGroupContaining(index)
        startInlineRename(for: items[index])
    }

    private func startInlineRename(for item: FileEntry) {
        inlineRenamePath = item.path
        inlineRenameValue = item.name
    }

    private func cancelInlineRename() {
        inlineRenamePath = nil
        inlineRenameValue = ""
    }

    private func commitInlineRename(for item: FileEntry) {
        let trimmed = inlineRenameValue.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            vm.showToast("Name cannot be empty.", type: .error)
            return
        }

        guard trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\")) == nil else {
            vm.showToast("Name cannot contain path separators.", type: .error)
            return
        }

        if trimmed == item.name {
            cancelInlineRename()
            return
        }

        let url = item.url
        Task {
            if await vm.renameItem(at: url, to: trimmed) {
                cancelInlineRename()
            }
        }
    }

    // MARK: Grid metrics

    private func updateGridColumnCount(_ count: Int) {
        if vm.gridColumnCount != count {
            vm.gridColumnCount = count
        }
    }

    private func gridContentWidth(for availableWidth: CGFloat) -> CGFloat {
        max(availableWidth - (gridPadding * 2), baseCellWidth)
    }

    private func fittedColumnCount(for availableGridWidth: CGFloat) -> Int {
        max(1, Int((availableGridWidth + gridSpacing) / (baseCellWidth + gridSpacing)))
    }

    private func fittedCellWidth(for availableGridWidth: CGFloat, columnCount: Int) -> CGFloat {
        let totalSpacing = CGFloat(max(0, columnCount - 1)) * gridSpacing
        return (availableGridWidth - totalSpacing) / CGFloat(max(columnCount, 1))
    }
}

// MARK: - Empty state

struct EmptyContentStateView<Actions: View>: View {
    let systemImage: String
    let title: String
    let message: String
    let isFocused: Bool
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(spacing: AppSpacing.lg) {
            Image(systemName: systemImage)
                .font(.appIcon(40))
                .foregroundStyle(isFocused ? Color.appAccent.opacity(0.85) : Color.appMuted)
                .accessibilityHidden(true)

            VStack(spacing: AppSpacing.xs) {
                Text(title)
                    .font(.appHeadline)
                    .foregroundStyle(isFocused ? Color.appPrimaryText : Color.appMuted)
                    .multilineTextAlignment(.center)

                Text(message)
                    .font(.appCallout)
                    .foregroundStyle(Color.appMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            actions()
        }
        .frame(maxWidth: 340)
        .padding(.horizontal, AppSpacing.xxl)
        .padding(.vertical, AppSpacing.xxl)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .fill(Color.appSurface.opacity(0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .strokeBorder(isFocused ? Color.appAccent : Color.appBorder, lineWidth: isFocused ? 1.5 : 1)
        )
        .accessibilityElement(children: .contain)
    }
}

struct ContentStatusBarView: View {
    @Environment(ExplorerViewModel.self) private var vm

    /// Cached stats — recomputed only when folderContents changes, not on every render.
    @State private var stats = FolderStats()

    var body: some View {
        @Bindable var vm = vm

        HStack(spacing: 10) {
            Text(itemCountLabel)
                .font(.appCaption)
                .foregroundStyle(Color.appPrimaryText)

            Divider().frame(height: 10)

            if stats.promptCount > 0 {
                statusBadge(icon: "text.quote", value: "\(stats.promptCount)", color: .badgePlibText)
                Divider().frame(height: 10)
            }

            if stats.imageCount > 0 {
                statusBadge(icon: "photo", value: "\(stats.imageCount)", color: .badgeImageText)
                Divider().frame(height: 10)
            }

            if stats.videoCount > 0 {
                statusBadge(icon: "film", value: "\(stats.videoCount)", color: .badgeVideoText)
                Divider().frame(height: 10)
            }

            if stats.audioCount > 0 {
                statusBadge(icon: "waveform", value: "\(stats.audioCount)", color: .badgeAudioText)
                Divider().frame(height: 10)
            }

            if stats.folderCount > 0 {
                statusBadge(icon: "folder", value: "\(stats.folderCount)", color: .appAccent)
                Divider().frame(height: 10)
            }

            Text(hiddenCountLabel)
                .font(.appCaption)
                .foregroundStyle(Color.appMuted)

            Spacer(minLength: 0)

            // Active tag filter indicator
            if let tagID = vm.filterByTagID,
               let tag = vm.allTags.first(where: { $0.id == tagID }) {
                HStack(spacing: AppSpacing.xs) {
                    Circle().fill(tag.color).frame(width: 6, height: 6)
                    Text(tag.name)
                        .font(.appIcon(9))
                        .foregroundStyle(Color.appMuted)
                    Button {
                        vm.filterByTagID = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.appIcon(9))
                    }
                    .buttonStyle(AppIconButtonStyle(width: 16, height: 16, cornerRadius: AppRadius.md, showsRestingChrome: false))
                    .help("Clear Tag Filter")
                    .accessibilityLabel("Clear \(tag.name) tag filter")
                }
            }

            if vm.searchMode != .filename {
                Text("Search: \(vm.searchMode.displayName)")
                    .font(.appIcon(9, weight: .medium))
                    .foregroundStyle(Color.appAccent)
                    .padding(.horizontal, 5)
                    .padding(.vertical, AppSpacing.xxs)
                    .background(Color.appAccent.opacity(0.12))
                    .cornerRadius(AppRadius.xs)
            }

            Divider().frame(height: 10)

            Button {
                vm.thumbnailsOnly.toggle()
                vm.persistThumbnailsOnly()
            } label: {
                Image(systemName: vm.thumbnailsOnly ? "text.below.photo.fill" : "text.below.photo")
                    .font(.appIcon(11, weight: .medium))
            }
            .buttonStyle(
                AppIconButtonStyle(
                    width: 26,
                    height: 22,
                    cornerRadius: AppRadius.sm,
                    showsRestingChrome: false,
                    restingForeground: vm.thumbnailsOnly ? Color.appAccent : Color.appMuted
                )
            )
            .help(vm.thumbnailsOnly ? "Show file names" : "Thumbnails only")
            .accessibilityLabel(vm.thumbnailsOnly ? "Show file names" : "Thumbnails only")

            Button {
                vm.statisticsOpen = true
            } label: {
                Image(systemName: "chart.bar")
                    .font(.appIcon(11, weight: .medium))
            }
            .buttonStyle(AppIconButtonStyle(width: 26, height: 22, cornerRadius: AppRadius.sm, showsRestingChrome: false))
            .help("Folder Statistics")
            .accessibilityLabel("Folder Statistics")

            Divider().frame(height: 10)

            // Thumbnail Size
            HStack(spacing: AppSpacing.xs) {
                Image(systemName: "square.grid.3x3")
                    .font(.caption)
                    .foregroundStyle(Color.appMuted)
                Slider(value: $vm.thumbnailSize, in: 1...10, step: 1)
                    .frame(width: 80)
                    .onChange(of: vm.thumbnailSize) { _, _ in
                        vm.persistThumbnailSize()
                    }
            }
        }
        .padding(.horizontal, AppSpacing.lg)
        .frame(height: LayoutMetrics.panelHeaderHeight)
        .background(Color.appBackground)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.appBorder)
                .frame(height: 1)
        }
        .onChange(of: statsKey) { _, _ in
            recomputeStats()
        }
        .onAppear { recomputeStats() }
    }

    /// Changes whenever the folder or its contents change — not just the item count,
    /// which can be equal across two different folders.
    private var statsKey: StatsKey {
        StatsKey(
            folderPath: vm.selectedFolderPath?.standardizedFileURL.path,
            contentIDs: vm.folderContents.map(\.id)
        )
    }

    private struct StatsKey: Equatable {
        let folderPath: String?
        let contentIDs: [String]
    }

    private func recomputeStats() {
        let contents = vm.folderContents
        var s = FolderStats()
        for item in contents {
            if item.isDirectory {
                s.folderCount += 1
            } else if FileHelpers.isPromptSnapshotFile(item.name) {
                s.promptCount += 1
            } else if FileHelpers.isImageFile(item.name) {
                s.imageCount += 1
            } else if FileHelpers.isVideoFile(item.name) {
                s.videoCount += 1
            } else if FileHelpers.isAudioFile(item.name) {
                s.audioCount += 1
            }
        }
        stats = s
    }

    private var itemCountLabel: String {
        let count = vm.visibleItemCount
        return count == 1 ? "1 item" : "\(count) items"
    }

    private var hiddenCountLabel: String {
        let count = vm.hiddenItemCount
        return count == 1 ? "1 hidden" : "\(count) hidden"
    }

    @ViewBuilder
    private func statusBadge(icon: String, value: String, color: Color) -> some View {
        HStack(spacing: AppSpacing.xxs) {
            Image(systemName: icon)
                .font(.appIcon(9))
                .foregroundStyle(color)
            Text(value)
                .font(.appIcon(10, weight: .medium))
                .foregroundStyle(Color.appMuted)
        }
    }
}

private struct FolderStats {
    var promptCount = 0
    var imageCount = 0
    var videoCount = 0
    var audioCount = 0
    var folderCount = 0
}

private struct StatusBarIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                    .fill(Color.appSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                    .strokeBorder(Color.appBorder, lineWidth: 1)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.42)
    }
}

private struct ExplorerItemView: View {
    @Environment(ExplorerViewModel.self) private var vm
    let item: FileEntry
    let index: Int
    let size: CGFloat
    let cellWidth: CGFloat
    @Binding var reorderIndicator: ExplorerReorderIndicator?
    @Binding var inlineRenamePath: String?
    @Binding var inlineRenameValue: String
    let onRenameCommit: () -> Void
    let onRenameCancel: () -> Void

    @State private var thumbnail: NSImage?
    @State private var loadTaskID: String = ""
    @State private var isDropTarget = false
    @FocusState private var renameFieldFocused: Bool

    private var isSelected: Bool {
        vm.selectedIndices.contains(index)
    }

    private var isRenaming: Bool {
        inlineRenamePath == item.path
    }

    private var flag: FileFlag {
        item.isDirectory ? .unflagged : vm.flag(for: item.path)
    }

    private var loadKey: String {
        "\(item.id)|\(Int(size.rounded()))"
    }

    private var badgeKind: PreviewBadgeKind? {
        if item.isDirectory { return nil }
        let name = item.name.lowercased()
        if name.hasSuffix(".plib") {
            return .plib
        } else if name.hasSuffix(".aoe") {
            return .aoe
        } else if name.hasSuffix(".png") {
            return .png
        } else if name.hasSuffix(".jpg") || name.hasSuffix(".jpeg") {
            return .jpg
        } else if name.hasSuffix(".webp") {
            return .webp
        } else if name.hasSuffix(".gif") {
            return .gif
        } else if FileHelpers.isVideoFile(name) {
            return .video
        } else if FileHelpers.isAudioFile(name) {
            return .audio
        } else if FileHelpers.isImageFile(name) {
            return .image
        } else {
            return .file
        }
    }

    private var badgeSide: CGFloat {
        min(max(size * 0.22, 20), 30)
    }

    private var tileStrokeColor: Color {
        if isDropTarget {
            return Color.appAccent.opacity(0.8)
        }
        if isSelected && vm.activePane == .content {
            return Color.appAccent
        }
        return .clear
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipped()
                .cornerRadius(AppRadius.sm)
        } else if item.isDirectory {
            Image(systemName: "folder.fill")
                .font(.system(size: size * 0.35))
                .foregroundStyle(Color.appAccent.opacity(0.6))
        } else {
            Image(systemName: iconForFile(item.name))
                .font(.system(size: size * 0.25))
                .foregroundStyle(Color.appMuted)
        }
    }

    @ViewBuilder
    private var fileNameLabel: some View {
        if !vm.thumbnailsOnly {
            if isRenaming {
                TextField("", text: $inlineRenameValue)
                    .textFieldStyle(.plain)
                    .font(.appCaption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.appPrimaryText)
                    .padding(.horizontal, AppSpacing.md)
                    .padding(.vertical, AppSpacing.sm)
                    .frame(width: cellWidth - 8, alignment: .top)
                    .frame(minHeight: 38, alignment: .top)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.sm)
                            .fill(Color.appSurface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.sm)
                            .strokeBorder(renameFieldFocused ? Color.appAccent : Color.appBorder, lineWidth: 1)
                    )
                    .focused($renameFieldFocused)
                    .onSubmit(onRenameCommit)
                    .onExitCommand(perform: onRenameCancel)
                    // onExitCommand is not always delivered to a focused TextField on
                    // macOS; handle Escape directly as well.
                    .onKeyPress(.escape) {
                        onRenameCancel()
                        return .handled
                    }
                    .task(id: isRenaming) {
                        renameFieldFocused = isRenaming
                    }
                    .onChange(of: isRenaming) { _, renaming in
                        renameFieldFocused = renaming
                    }
            } else {
                Text(item.name)
                    .font(.appCaption)
                    .lineLimit(2)
                    .lineSpacing(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(isSelected ? Color.appPrimaryText : Color.appMuted)
                    .padding(.horizontal, AppSpacing.md)
                    .padding(.bottom, AppSpacing.xs)
                    .frame(width: cellWidth, alignment: .top)
                    .frame(minHeight: 38, alignment: .top)
            }
        }
    }

    var body: some View {
        VStack(spacing: AppSpacing.sm) {
            ZStack(alignment: .bottomTrailing) {
                ZStack {
                    thumbnailView
                }
                .frame(width: size, height: size)
                .background(Color.appSurface)
                // Rejects stay listed but recede.
                .opacity(flag == .reject ? 0.38 : 1)
                .cornerRadius(AppRadius.md)
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.md)
                        .strokeBorder(tileStrokeColor, lineWidth: 2)
                )
                .overlay(alignment: .topLeading) {
                    CompactStarBadge(rating: vm.rating(for: item.path))
                        .offset(x: 4, y: 4)
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .topLeading) {
                    // Pin badge — only shown when pinned (uses lightweight check)
                    FavoritePinBadge(isPinned: vm.isFavorite(path: item.path))
                        .offset(x: 4, y: -6)
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .topTrailing) {
                    TileCullBadges(
                        flag: flag,
                        label: FinderLabel(labelNumber: item.labelNumber),
                        side: badgeSide
                    )
                    .offset(x: -4, y: 4)
                    .allowsHitTesting(false)
                }

                if let badgeKind {
                    PreviewBadgeView(kind: badgeKind, side: badgeSide)
                        .offset(x: -3, y: -3)
                        .allowsHitTesting(false)
                }
            }

            fileNameLabel
        }
        .frame(width: cellWidth)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .fill(
                    isSelected
                        ? Color.appSelected
                        : (isDropTarget ? Color.appAccent.opacity(0.1) : Color.clear)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .strokeBorder(isDropTarget ? Color.appAccent.opacity(0.5) : Color.clear, lineWidth: 1)
        )
        .overlay {
            if !isRenaming {
                FileDragSource(
                    dragURLs: dragURLs,
                    isSelected: { isSelected },
                    onSelect: { modifiers in vm.selectItem(at: index, modifiers: modifiers) },
                    onDoubleClick: handleDoubleClick,
                    externalOperation: { vm.externalDragOperation },
                    onDragEnded: { operation in
                        // A receiving app that took the original leaves a stale grid.
                        if operation.contains(.move) {
                            Task { await vm.refreshFolder() }
                        }
                    }
                )
            }
        }
        // One VoiceOver element per tile. Accessibility modifiers don't affect hit
        // testing, so FileDragSource's click/drag handling is unchanged. While renaming,
        // keep children separate so the text field stays reachable.
        .accessibilityElement(children: isRenaming ? .contain : .combine)
        .accessibilityLabel(item.name)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityAction(named: item.isDirectory ? "Open Folder" : "Open") {
            handleDoubleClick()
        }
        .accessibilityAction {
            handleDoubleClick()
        }
        .anchorPreference(key: ExplorerItemBoundsPreferenceKey.self, value: .bounds) {
            [item.path: $0]
        }
        .task(id: loadKey) {
            if loadTaskID != loadKey {
                thumbnail = nil
                loadTaskID = loadKey
            }
            await loadThumbnail()
        }
        .onChange(of: loadKey) { _, newKey in
            if loadTaskID != newKey {
                thumbnail = nil
                loadTaskID = newKey
            }
        }
        .onDrop(
            of: [UTType.fileURL.identifier],
            delegate: ExplorerItemDropDelegate(
                item: item,
                cellWidth: cellWidth,
                isDropTarget: $isDropTarget,
                reorderIndicator: $reorderIndicator,
                dropHandler: { urls, intent in
                    handleDrop(urls, intent: intent)
                }
            )
        )
    }

    /// Every selected file when this item is part of a multi-selection,
    /// otherwise just this item.
    private func dragURLs() -> [URL] {
        ContentItemActions.dragURLs(for: item, at: index, vm: vm)
    }

    private func handleDoubleClick() {
        ContentItemActions.open(item, at: index, vm: vm)
    }

    private func loadThumbnail() async {
        guard !item.isDirectory else { return }
        let expectedID = item.id
        let loaded = await ContentThumbnailLoader.load(for: item, maxPixelSize: size * 2)
        guard !Task.isCancelled, item.id == expectedID else { return }
        thumbnail = loaded
    }

    private func iconForFile(_ name: String) -> String {
        if FileHelpers.isPlibFile(name) { return "doc.text" }
        if FileHelpers.isAoeFile(name) { return "doc.richtext" }
        if FileHelpers.isVideoFile(name) { return "film" }
        if FileHelpers.isAudioFile(name) { return "waveform" }
        if FileHelpers.isImageFile(name) { return "photo" }
        return "doc"
    }

    private func handleDrop(_ urls: [URL], intent: ExplorerDropIntent?) -> Bool {
        let standardizedURLs = urls.map(\.standardizedFileURL)
        guard let sourceURL = standardizedURLs.first else { return false }
        let availablePaths = Set(vm.processedFolderContents.map(\.path))
        let isInternalDrag = standardizedURLs.allSatisfy { availablePaths.contains($0.path) }

        if item.isDirectory, !isInternalDrag {
            Task { await vm.importExternalFiles(standardizedURLs, to: item.url) }
            return true
        }

        // Files from Finder dropped onto a non-folder tile: import into the current
        // folder, the same as dropping on the grid background.
        if !isInternalDrag {
            Task { await vm.importExternalFiles(standardizedURLs) }
            return true
        }

        if intent == .moveIntoFolder {
            Task { await vm.moveDraggedItems(standardizedURLs, to: item.url) }
            return true
        }

        guard case let .reorder(position)? = intent else { return false }

        let sourcePath = sourceURL.path
        guard availablePaths.contains(sourcePath) else { return false }

        let sourcePaths: [String]
        if vm.selectedPaths.contains(sourcePath), vm.selectedIndices.count > 1 {
            sourcePaths = vm.selectedPaths
        } else {
            sourcePaths = [sourcePath]
        }

        let sourceIndices = sourcePaths.compactMap { path in
            vm.processedFolderContents.firstIndex(where: { $0.path == path })
        }
        guard !sourceIndices.isEmpty else { return false }

        vm.reorderItems(sourcePaths: sourcePaths, targetPath: item.path, position: position)
        return true
    }
}

/// Favorite pin badge. `isPinned` is derived from the view model's observable
/// `favoritePaths`, so Pin/Unpin updates the tile immediately.
private struct FavoritePinBadge: View {
    let isPinned: Bool

    var body: some View {
        if isPinned {
            Image(systemName: "pin.fill")
                .font(.appFootnote)
                .foregroundStyle(Color.favoriteGoldText)
                .accessibilityLabel("Pinned")
        }
    }
}

/// Small in-memory cache of downsampled .plib/.aoe tile thumbnails, keyed by
/// path + modification date + pixel size.
enum SnapshotThumbnailCache {
    static let shared: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 400
        return cache
    }()

    static func key(for url: URL, maxPixelSize: CGFloat) -> NSString {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
        return "\(url.standardizedFileURL.path)|\(modified)|\(Int(maxPixelSize.rounded()))" as NSString
    }

    /// Redraws `image` so its longest side is at most `maxPixelSize` pixels.
    /// Returns nil when the image is already small enough or can't be rasterized.
    static func downsample(_ image: NSImage, maxPixelSize: CGFloat) -> NSImage? {
        guard maxPixelSize > 0,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }

        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let longest = max(width, height)
        guard longest > maxPixelSize else { return nil }

        let scale = maxPixelSize / longest
        let targetWidth = max(Int((width * scale).rounded()), 1)
        let targetHeight = max(Int((height * scale).rounded()), 1)

        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        guard let scaled = context.makeImage() else { return nil }
        return NSImage(cgImage: scaled, size: NSSize(width: targetWidth, height: targetHeight))
    }
}

private enum PreviewBadgeKind {
    case plib
    case aoe
    case png
    case jpg
    case webp
    case gif
    case video
    case audio
    case image
    case file
}

private struct PreviewBadgeView: View {
    let kind: PreviewBadgeKind
    let side: CGFloat

    private var backgroundColor: Color {
        switch kind {
        case .plib: return .badgePlib
        case .aoe: return .badgeAoe
        case .png: return .badgePng
        case .jpg: return .badgeJpg
        case .webp: return .badgeWebp
        case .gif: return .badgeGif
        case .video: return .badgeVideo
        case .audio: return .badgeAudio
        case .image: return .badgeImage
        case .file: return .badgeFile
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: side * 0.18, style: .continuous)
                .fill(backgroundColor)

            glyph
                .foregroundStyle(.white)
                .padding(side * 0.14)
        }
        .frame(width: side, height: side)
        .shadow(color: Color.appShadowColor.opacity(0.85), radius: side * 0.1, y: side * 0.04)
    }

    @ViewBuilder
    private var glyph: some View {
        switch kind {
        case .plib:
            PlibPreviewGlyph()
        case .aoe:
            AoePreviewGlyph()
        case .png, .jpg, .webp, .gif, .image:
            Image(systemName: "photo.fill")
                .font(.system(size: side * 0.54, weight: .semibold))
        case .video:
            Image(systemName: "film.fill")
                .font(.system(size: side * 0.54, weight: .semibold))
        case .audio:
            Image(systemName: "waveform")
                .font(.system(size: side * 0.54, weight: .semibold))
        case .file:
            Image(systemName: "doc.fill")
                .font(.system(size: side * 0.54, weight: .semibold))
        }
    }
}

private struct ExplorerReorderIndicator: Equatable {
    let itemPath: String
    let position: ReorderPosition
}

private struct ExplorerItemBoundsPreferenceKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]

    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct ExplorerReorderIndicatorView: View {
    let position: ReorderPosition
    let itemRect: CGRect

    var body: some View {
        Rectangle()
            .fill(Color.appAccent)
            .frame(width: 3, height: max(itemRect.height - 12, 0))
            .position(
                x: position == .after ? (itemRect.maxX - 2) : (itemRect.minX + 2),
                y: itemRect.midY
            )
            .allowsHitTesting(false)
    }
}

private struct PlibPreviewGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let topLeft = CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.08)
        let topRight = CGPoint(x: rect.maxX - rect.width * 0.14, y: rect.minY + rect.height * 0.24)
        let rightMid = CGPoint(x: rect.maxX - rect.width * 0.14, y: rect.midY + rect.height * 0.18)
        let bottom = CGPoint(x: rect.midX, y: rect.maxY - rect.height * 0.08)
        let leftMid = CGPoint(x: rect.minX + rect.width * 0.14, y: rect.midY + rect.height * 0.18)
        let topLeftShoulder = CGPoint(x: rect.minX + rect.width * 0.14, y: rect.minY + rect.height * 0.24)
        let center = CGPoint(x: rect.midX, y: rect.midY + rect.height * 0.02)

        var path = Path()

        path.move(to: topLeft)
        path.addLine(to: topRight)
        path.addLine(to: center)
        path.addLine(to: topLeftShoulder)
        path.closeSubpath()

        path.move(to: topLeftShoulder)
        path.addLine(to: center)
        path.addLine(to: center.applying(.init(translationX: 0, y: rect.height * 0.02)))
        path.addLine(to: bottom)
        path.addLine(to: leftMid)
        path.closeSubpath()

        path.move(to: center)
        path.addLine(to: topRight)
        path.addLine(to: rightMid)
        path.addLine(to: bottom)
        path.addLine(to: center.applying(.init(translationX: 0, y: rect.height * 0.02)))
        path.closeSubpath()

        return path
    }
}

private struct AoePreviewGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let centerX = rect.midX
        let widths: [CGFloat] = [
            rect.width * 0.64,
            rect.width * 0.76,
            rect.width * 0.82,
            rect.width * 0.72,
        ]
        let yPositions: [CGFloat] = [
            rect.minY + rect.height * 0.24,
            rect.minY + rect.height * 0.40,
            rect.minY + rect.height * 0.57,
            rect.minY + rect.height * 0.74,
        ]
        let layerHeight = rect.height * 0.16

        for (index, width) in widths.enumerated() {
            let y = yPositions[index]
            let inset = width * 0.18
            let topLeft = CGPoint(x: centerX - width / 2, y: y)
            let topRight = CGPoint(x: centerX + width / 2, y: y)
            let bottomRight = CGPoint(x: centerX + width / 2 - inset, y: y + layerHeight)
            let bottomLeft = CGPoint(x: centerX - width / 2 + inset, y: y + layerHeight)

            path.move(to: topLeft)
            path.addLine(to: topRight)
            path.addLine(to: bottomRight)
            path.addLine(to: bottomLeft)
            path.closeSubpath()
        }

        return path
    }
}

enum ExplorerDropIntent: Equatable {
    case moveIntoFolder
    case reorder(ReorderPosition)
}

private struct ExplorerItemDropDelegate: DropDelegate {
    let item: FileEntry
    let cellWidth: CGFloat
    @Binding var isDropTarget: Bool
    @Binding var reorderIndicator: ExplorerReorderIndicator?
    // Note: switching the folder to Custom sort happens only when an internal reorder
    // is actually performed (`vm.reorderItems` calls `ensureCustomSortForCurrentFolder`),
    // never while a drag merely hovers — Finder drags and cancelled drags must not
    // change the folder's sort.
    let dropHandler: ([URL], ExplorerDropIntent?) -> Bool

    func dropEntered(info: DropInfo) {
        updatePreview(for: resolvedIntent(for: info.location.x))
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let intent = resolvedIntent(for: info.location.x)
        updatePreview(for: intent)
        switch intent {
        case .moveIntoFolder:
            return DropProposal(operation: .copy)
        case .reorder:
            return DropProposal(operation: .move)
        case nil:
            return nil
        }
    }

    func dropExited(info: DropInfo) {
        resetPreview()
    }

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [UTType.fileURL.identifier])
        guard !providers.isEmpty else {
            resetPreview()
            return false
        }

        let dropIntent = resolvedIntent(for: info.location.x)
        Task {
            let urls = await loadURLs(from: providers)
            _ = await MainActor.run {
                dropHandler(urls, dropIntent)
            }
        }

        resetPreview()
        return true
    }

    private func updatePreview(for intent: ExplorerDropIntent?) {
        switch intent {
        case .moveIntoFolder:
            isDropTarget = true
            clearReorderIndicator()
        case let .reorder(position):
            isDropTarget = false
            reorderIndicator = ExplorerReorderIndicator(itemPath: item.path, position: position)
        case nil:
            resetPreview()
        }
    }

    private func resetPreview() {
        isDropTarget = false
        clearReorderIndicator()
    }

    private func clearReorderIndicator() {
        if reorderIndicator?.itemPath == item.path {
            reorderIndicator = nil
        }
    }

    private func resolvedIntent(for x: CGFloat) -> ExplorerDropIntent? {
        if item.isDirectory {
            let edgeThreshold = min(max(cellWidth * 0.18, 24), 48)
            if x <= edgeThreshold {
                return .reorder(.before)
            }
            if x >= (cellWidth - edgeThreshold) {
                return .reorder(.after)
            }
            return .moveIntoFolder
        }

        return .reorder(x >= (cellWidth / 2) ? .after : .before)
    }

    private func loadURLs(from providers: [NSItemProvider]) async -> [URL] {
        await URLDropLoader.loadURLs(from: providers)
    }
}
