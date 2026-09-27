import SwiftUI
import UniformTypeIdentifiers

struct FileTreeView: View {
    @Environment(ExplorerViewModel.self) private var vm
    @AppStorage("sidebar.favorites.expanded") private var favoritesExpanded = true
    @AppStorage("sidebar.folders.expanded") private var foldersExpanded = true
    @State private var folderQuery = ""
    @State private var folderMatches: [FolderSearchService.Match] = []
    @State private var isSearchingFolders = false

    private var isFilteringFolders: Bool {
        !folderQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                // Favorites
                SidebarSectionHeader(title: "Favorites", isExpanded: $favoritesExpanded, isFirstSection: true)
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
                if favoritesExpanded {
                    FavoriteItemView(name: "Desktop", icon: "desktopcomputer", favorite: .desktop)
                    FavoriteItemView(name: "Documents", icon: "doc.text", favorite: .documents)
                    FavoriteItemView(name: "Pictures", icon: "photo", favorite: .pictures)
                }

                // Ingest Inbox (only with a watched folder configured)
                InboxSidebarSection()

                // Recent Folders
                RecentFoldersSidebarSection()

                // Smart Folders
                SmartFolderSidebarView(smartFolders: vm.smartFolders)

                // Collections
                CollectionsSidebarSection()

                // Tags
                TagFilterSidebarView()

                // Folder Tree
                if vm.explorerRootPath != nil {
                    // Headers are inline rows (not the Section `header:` slot) so
                    // macOS doesn't attach its native hover-reveal section-collapse
                    // chevron, and sections don't add their large inter-section gaps.
                    SidebarSectionHeader(
                        title: "Folders",
                        isExpanded: $foldersExpanded,
                        isCollapsed: vm.isSidebarTreeCollapsed,
                        expandedIcon: "rectangle.compress.vertical",
                        collapsedIcon: "rectangle.expand.vertical",
                        helpText: vm.isSidebarTreeCollapsed ? "Restore Folder Expansion" : "Collapse Top-Level Folders"
                    ) {
                        vm.toggleSidebarTreeCollapse()
                    }
                    .listRowSeparator(.hidden)
                    .selectionDisabled()

                    if foldersExpanded {
                        SidebarFilterField(
                            placeholder: "Filter Folders",
                            text: $folderQuery,
                            isBusy: isSearchingFolders
                        )

                        if isFilteringFolders {
                            ForEach(folderMatches) { match in
                                FolderSearchResultRow(match: match, query: folderQuery)
                            }
                            if !isSearchingFolders, folderMatches.isEmpty {
                                Text("No folders match \u{201C}\(folderQuery)\u{201D}")
                                    .font(.appSidebarDetail)
                                    .foregroundStyle(Color.appSidebarSecondaryText)
                                    .padding(.leading, AppSpacing.xl + AppSpacing.xs)
                                    .padding(.vertical, AppSpacing.xxs)
                                    .selectionDisabled()
                            }
                        } else {
                            ForEach(vm.sidebarFolders) { folder in
                                SidebarFolderRow(item: folder)
                                    .id(folder.id)
                            }
                        }
                    }
                }
            }
            .onAppear {
                scrollToSelection(using: proxy)
            }
            .onChange(of: vm.selectedFolderPath?.standardizedFileURL.path) { _, _ in
                scrollToSelection(using: proxy)
            }
            .onChange(of: vm.sidebarFolders) { _, _ in
                scrollToSelection(using: proxy)
            }
            .task(id: FolderSearchKey(query: folderQuery, root: vm.explorerRootPath?.path)) {
                await searchFolders()
            }
            .onChange(of: vm.explorerRootPath) { _, _ in
                folderQuery = ""
            }
            .onChange(of: vm.activePane) { _, activePane in
                guard activePane == .sidebar else { return }
                scrollToSelection(using: proxy)
            }
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 24)
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
        // Same toolbar id as the browser toolbar, so the window keeps a single
        // customizable toolbar (see BrowserToolbarItemID).
        .toolbar(id: BrowserToolbarItemID.toolbar) {
            ToolbarItem(id: BrowserToolbarItemID.openFolder, placement: .primaryAction) {
                Button {
                    Task { await vm.openFolder() }
                } label: {
                    Label("Open Folder", systemImage: "folder.badge.plus")
                }
                .help("Open Folder")
                .accessibilityLabel("Open Folder")
            }
            ToolbarItem(id: BrowserToolbarItemID.appearance, placement: .primaryAction) {
                AppearanceToggleButton()
            }
        }
    }

    /// Debounced walk of the whole root; the task is cancelled when the query changes.
    private func searchFolders() async {
        let query = folderQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let root = vm.explorerRootPath else {
            folderMatches = []
            isSearchingFolders = false
            return
        }
        isSearchingFolders = true
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard !Task.isCancelled else { return }
        let matches = await FolderSearchService.findFolders(matching: query, under: root)
        guard !Task.isCancelled else { return }
        folderMatches = matches
        isSearchingFolders = false
    }

    private func scrollToSelection(using proxy: ScrollViewProxy) {
        guard let selectionPath = vm.selectedFolderPath?.standardizedFileURL.path else { return }
        guard vm.sidebarFolders.contains(where: { $0.id == selectionPath }) else { return }

        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.16)) {
                proxy.scrollTo(selectionPath, anchor: .center)
            }
        }
    }
}

struct SidebarSectionHeader: View {
    let title: String
    /// When provided, renders an always-visible leading disclosure chevron that
    /// collapses/expands the section. Static content (not a Button) so macOS
    /// doesn't auto-hide it until hover in a sidebar List header.
    var isExpanded: Binding<Bool>? = nil
    var isCollapsed: Bool? = nil
    var expandedIcon: String = "chevron.down"
    var collapsedIcon: String = "chevron.right"
    var helpText: String? = nil
    /// The topmost section draws no separator above itself.
    var isFirstSection = false
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            if let isExpanded {
                HStack(spacing: AppSpacing.md) {
                    Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.appIcon(10, weight: .bold))
                        .foregroundStyle(Color.appSidebarSecondaryText)
                        .frame(width: 12)

                    Text(title)
                        .font(.appSidebarHeader)
                        .foregroundStyle(Color.appSidebarHeaderText)
                }
                .contentShape(Rectangle())
                .onTapGesture { isExpanded.wrappedValue.toggle() }
                // Static content for layout reasons (see above), so expose it to
                // VoiceOver as a toggle button explicitly.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityValue(isExpanded.wrappedValue ? "Expanded" : "Collapsed")
                .accessibilityHint(isExpanded.wrappedValue ? "Collapses the \(title) section" : "Expands the \(title) section")
                .accessibilityAddTraits([.isButton, .isHeader])
                .accessibilityAction { isExpanded.wrappedValue.toggle() }
            } else {
                Text(title)
                    .font(.appSidebarHeader)
                    .foregroundStyle(Color.appSidebarHeaderText)
                    .accessibilityAddTraits(.isHeader)
            }

            Spacer(minLength: 0)

            if let action, let isCollapsed {
                // Rendered as static content (not a Button) so macOS doesn't
                // auto-hide it until hover the way it does for controls placed
                // in a sidebar List section header.
                Image(systemName: isCollapsed ? collapsedIcon : expandedIcon)
                    .font(.appIcon(11, weight: .semibold))
                    .foregroundStyle(Color.appSidebarSecondaryText)
                    .frame(width: 20, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.sm)
                            .fill(Color.appSurface.opacity(0.7))
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { action() }
                    .help(helpText ?? "")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(helpText ?? title)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { action() }
            }
        }
        .padding(.vertical, 5)
        // The whole row (not just the title) toggles the section; nested
        // controls keep their own taps because child gestures take priority.
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { isExpanded?.wrappedValue.toggle() }
        .textCase(nil)
        .sidebarSectionStart(isFirst: isFirstSection)
    }
}

// MARK: - Appearance toggle

/// Flips between dark and light. When following the system it switches to the
/// opposite of what's showing; right-click to choose System / Dark / Light.
private struct AppearanceToggleButton: View {
    @Environment(ExplorerViewModel.self) private var vm
    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        Button {
            set(isDark ? .light : .dark)
        } label: {
            Label("Appearance", systemImage: isDark ? "sun.max" : "moon")
        }
        .help(isDark ? "Switch to Light Mode" : "Switch to Dark Mode")
        .accessibilityLabel(isDark ? "Switch to Light Mode" : "Switch to Dark Mode")
        .contextMenu {
            ForEach(AppAppearanceMode.allCases) { mode in
                Button {
                    set(mode)
                } label: {
                    if vm.appearanceMode == mode {
                        Label(mode.title, systemImage: "checkmark")
                    } else {
                        Text(mode.title)
                    }
                }
            }
        }
    }

    private func set(_ mode: AppAppearanceMode) {
        vm.appearanceMode = mode
        vm.persistAppearanceMode()
        mode.applyToApp()
    }
}

// MARK: - Section separation

extension View {
    /// Marks the start of a top-level sidebar section: a hairline rule with
    /// breathing room above the section's header row.
    func sidebarSectionStart(isFirst: Bool = false) -> some View {
        modifier(SidebarSectionStart(isFirst: isFirst))
    }
}

private struct SidebarSectionStart: ViewModifier {
    let isFirst: Bool

    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            if !isFirst {
                Rectangle()
                    .fill(Color.appBorder)
                    .frame(height: 1)
                    .padding(.top, AppSpacing.md)
                    .padding(.bottom, AppSpacing.sm)
                    .accessibilityHidden(true)
            }
            content
        }
    }
}

// MARK: - Favorite Item

struct FavoriteItemView: View {
    @Environment(ExplorerViewModel.self) private var vm
    let name: String
    let icon: String
    let favorite: FavoriteFolder

    var body: some View {
        Button {
            vm.activePane = .sidebar
            Task { await vm.selectFavorite(favorite) }
        } label: {
            HStack(spacing: AppSpacing.md) {
                Image(systemName: icon)
                    .foregroundStyle(Color.appAccent)
                    .frame(width: 18)

                Text(name)
                    .font(.appSidebarItem)
                    .foregroundStyle(Color.appSidebarText)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, AppSpacing.xxs)
    }
}

// MARK: - Sidebar Folder Row

struct SidebarFolderRow: View {
    @Environment(ExplorerViewModel.self) private var vm
    let item: SidebarFolderItem

    @State private var isDropTarget: Bool = false

    private var isSelected: Bool {
        vm.selectedFolderPath == item.url
    }

    private var isActiveSelection: Bool {
        isSelected && vm.activePane == .sidebar
    }

    var body: some View {
        folderRow
    }

    private var folderRow: some View {
        HStack(spacing: AppSpacing.md) {
            Group {
                if item.hasChildren {
                    // Rendered as static content (not a Button) so macOS doesn't
                    // auto-hide the disclosure arrow until hover the way it does
                    // for controls placed in sidebar List rows.
                    Image(systemName: item.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.appIcon(10, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.appPrimaryText.opacity(0.9) : Color.appSidebarSecondaryText)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            vm.activePane = .sidebar
                            vm.toggleSidebarFolderExpansion(for: item.url)
                        }
                        .help(item.isExpanded ? "Collapse" : "Expand")
                        .accessibilityLabel(item.isExpanded ? "Collapse \(item.name)" : "Expand \(item.name)")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction {
                            vm.activePane = .sidebar
                            vm.toggleSidebarFolderExpansion(for: item.url)
                        }
                } else {
                    Color.clear
                        .frame(width: 20, height: 20)
                }
            }

            Image(systemName: "folder.fill")
                .foregroundStyle(isSelected ? Color.appAccent : Color.appSidebarSecondaryText)
                .font(.appIcon(14))
                .accessibilityHidden(true)

            Text(item.name)
                .font(.appSidebarItem)
                .foregroundStyle(isSelected ? Color.appPrimaryText : Color.appSidebarText)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityLabel("\(item.name) folder")
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                .accessibilityAction {
                    vm.activePane = .sidebar
                    Task { await vm.selectFolder(item.url) }
                }

            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(item.depth) * 14)
        .padding(.vertical, AppSpacing.xs)
        .padding(.horizontal, AppSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .fill(isSelected ? Color.appSelected : (isDropTarget ? Color.appAccent.opacity(0.1) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .strokeBorder(isActiveSelection ? Color.appAccent : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            vm.activePane = .sidebar
            Task { await vm.selectFolder(item.url) }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTarget) { providers in
            Task {
                let urls = await URLDropLoader.loadURLs(from: providers)
                guard !urls.isEmpty else { return }

                let internalPaths = Set(vm.processedFolderContents.map(\.path))
                let isInternalDrag = urls.allSatisfy { internalPaths.contains($0.standardizedFileURL.path) }

                if isInternalDrag {
                    await vm.moveDraggedItems(urls, to: item.url)
                } else {
                    await vm.importExternalFiles(urls, to: item.url)
                }
            }
            return true
        }
    }
}

// MARK: - Folder Search

private struct FolderSearchKey: Equatable {
    let query: String
    let root: String?
}

/// A folder found by the sidebar filter: name plus where it lives under the root.
struct FolderSearchResultRow: View {
    @Environment(ExplorerViewModel.self) private var vm
    let match: FolderSearchService.Match
    let query: String

    private var isSelected: Bool {
        vm.selectedFolderPath?.standardizedFileURL.path == match.url.standardizedFileURL.path
    }

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            Image(systemName: "folder.fill")
                .foregroundStyle(isSelected ? Color.appAccent : Color.appSidebarSecondaryText)
                .font(.appIcon(14))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                Text(sidebarHighlighted(match.name, query: query))
                    .font(.appSidebarItem)
                    .foregroundStyle(isSelected ? Color.appPrimaryText : Color.appSidebarText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !match.relativeParent.isEmpty {
                    Text(match.relativeParent)
                        .font(.appSidebarDetail)
                        .foregroundStyle(Color.appSidebarSecondaryText)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, AppSpacing.xxs)
        .padding(.horizontal, AppSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .fill(isSelected ? Color.appSelected : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            vm.activePane = .sidebar
            Task { await vm.selectFolder(match.url) }
        }
        .help(match.relativeParent.isEmpty ? match.name : "\(match.relativeParent)/\(match.name)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(match.name) folder")
        .accessibilityValue(match.relativeParent.isEmpty ? "" : "in \(match.relativeParent)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { Task { await vm.selectFolder(match.url) } }
    }
}

// MARK: - Recent Folders

struct RecentFoldersSidebarSection: View {
    @Environment(ExplorerViewModel.self) private var vm
    @AppStorage("sidebar.recent.expanded") private var isExpanded = false

    var body: some View {
        if !vm.recentFolders.isEmpty {
            Group {
                SidebarSectionHeader(title: "Recent", isExpanded: $isExpanded)
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
                if isExpanded {
                ForEach(vm.recentFolders) { item in
                    RecentFolderRow(
                        item: item,
                        onOpen: {
                            vm.activePane = .sidebar
                            Task { await vm.openRecentFolder(item) }
                        },
                        onRemove: { vm.removeRecentFolder(item) }
                    )
                    .padding(.vertical, AppSpacing.xxs)
                }

                Button {
                    vm.clearRecentFolders()
                } label: {
                    HStack(spacing: AppSpacing.md) {
                        Image(systemName: "xmark.circle")
                            .foregroundStyle(Color.appSidebarSecondaryText)
                            .frame(width: 18)

                        Text("Clear Recents")
                            .font(.appSidebarItem)
                            .foregroundStyle(Color.appSidebarSecondaryText)

                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, AppSpacing.xxs)
                }
            }
        }
    }
}

/// A recent-folder row: click to open, hover for the remove affordance.
/// The remove button is a sibling rather than nested inside the row button,
/// since nested buttons swallow each other's clicks on macOS.
private struct RecentFolderRow: View {
    let item: RecentItem
    let onOpen: () -> Void
    let onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: AppSpacing.xs) {
            Button(action: onOpen) {
                HStack(spacing: AppSpacing.md) {
                    Image(systemName: "clock")
                        .foregroundStyle(Color.appSidebarSecondaryText)
                        .frame(width: 18)

                    Text(item.name)
                        .font(.appSidebarItem)
                        .foregroundStyle(Color.appSidebarText)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(item.path)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.appIcon(10, weight: .bold))
                    .foregroundStyle(Color.appSidebarSecondaryText)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isHovering ? 1 : 0)
            .help("Remove from Recents")
            .accessibilityLabel("Remove \(item.name) from Recents")
        }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Remove from Recents") {
                onRemove()
            }
        }
    }
}
