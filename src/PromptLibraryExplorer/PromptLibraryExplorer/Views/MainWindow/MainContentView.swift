import SwiftUI

struct MainContentView: View {
    @Environment(ExplorerViewModel.self) private var vm
    @Environment(\.openSettings) private var openSettings
    @State private var splitViewVisibility: NavigationSplitViewVisibility =
        SettingsStore.shared.sidebarVisible ? .all : .doubleColumn
    /// Collapsed group sections of the content browser. Owned here so arrow-key
    /// navigation can skip the items of collapsed sections.
    @State private var collapsedGroups: Set<String> = []

    var body: some View {
        @Bindable var vm = vm

        ZStack {
            VStack(spacing: 0) {
                contentStack
            }

            if vm.lightboxOpen {
                LightboxView()
                    .ignoresSafeArea()
                    .transition(.opacity.animation(.easeInOut(duration: 0.15)))
                    .zIndex(100)
            }
        }
        .background(Color.appBackground)
        .sheet(isPresented: $vm.helpOpen) {
            HelpView()
                .environment(vm)
        }
        .sheet(item: $vm.comparisonSession) { session in
            AoeComparisonView(sourceA: session.sourceA, sourceB: session.sourceB)
        }
        .sheet(isPresented: $vm.statisticsOpen) {
            FolderStatisticsView()
                .environment(vm)
        }
        .sheet(isPresented: $vm.showSmartFolderEditor) {
            SmartFolderEditorView(folder: vm.editingSmartFolder) { folder in
                vm.saveSmartFolder(folder)
            }
            .environment(vm)
            .onDisappear {
                vm.editingSmartFolder = nil
            }
        }
        .sheet(item: $vm.promptDiffSession) { session in
            PromptDiffView(session: session)
        }
        .sheet(isPresented: $vm.batchMetadataEditorOpen) {
            BatchMetadataEditorView()
                .environment(vm)
        }
        .sheet(isPresented: $vm.librarySearchOpen) {
            LibrarySearchView()
                .environment(vm)
        }
        .sheet(isPresented: $vm.duplicatesOpen) {
            SimilarPromptsView()
                .environment(vm)
        }
        .sheet(isPresented: $vm.batchRenameOpen) {
            BatchRenameView()
                .environment(vm)
        }
        .sheet(isPresented: $vm.snippetsOpen) {
            SnippetsView()
                .environment(vm)
        }
        .alert(
            vm.deleteConfirmationRequest?.title ?? "Delete Permanently?",
            isPresented: Binding(
                get: { vm.deleteConfirmationRequest != nil },
                set: { isPresented in
                    if !isPresented {
                        vm.clearDeleteConfirmation()
                    }
                }
            ),
            presenting: vm.deleteConfirmationRequest
        ) { request in
            Button("Cancel", role: .cancel) {
                vm.clearDeleteConfirmation()
            }
            Button(request.confirmButtonTitle, role: .destructive) {
                vm.clearDeleteConfirmation()
                Task {
                    switch request.kind {
                    case .trash:
                        await vm.trashItems(at: request.urls)
                    case .permanent:
                        await vm.deleteItemsPermanently(at: request.urls)
                    }
                }
            }
        } message: { request in
            Text(request.message)
        }
        .alert("New Folder", isPresented: $vm.isShowingNewFolderPrompt) {
            TextField("Folder name", text: $vm.newFolderName)
            Button("Create") {
                Task { await vm.createNewFolder() }
            }
            Button("Cancel", role: .cancel) {
                vm.newFolderName = "untitled folder"
            }
        } message: {
            Text("Enter a name for the new folder.")
        }
        .toolbar(id: BrowserToolbarItemID.toolbar) {
            ToolbarItem(id: BrowserToolbarItemID.identity, placement: .principal) {
                TitlebarIdentityView()
            }
            // The app name stays put; everything else can be customized.
            .customizationBehavior(.disabled)
        }
        .toolbar(vm.lightboxOpen ? .hidden : .automatic, for: .windowToolbar)
        .animation(.easeInOut(duration: 0.2), value: vm.toastMessage?.message)
        .background(WindowTitleConfigurator())
        .onGlobalKeyDown { event in
            handleGlobalKey(event)
        }
        .onChange(of: splitViewVisibility) { _, visibility in
            SettingsStore.shared.sidebarVisible = visibility != .doubleColumn && visibility != .detailOnly
        }
        // Settings is the app's `Settings` scene; callers outside a view (the
        // command palette, the toolbar gear via the view model) post this.
        .onReceive(NotificationCenter.default.publisher(for: .openSettingsWindow)) { _ in
            openSettings()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleCommandPalette)) { _ in
            if vm.commandPaletteOpen {
                closeCommandPalette()
            } else {
                withAnimation(.easeOut(duration: 0.15)) {
                    vm.commandPaletteOpen = true
                }
            }
        }
    }

    private var contentStack: some View {
        Group {
            if vm.explorerRootPath != nil {
                NavigationSplitView(columnVisibility: $splitViewVisibility) {
                    FileTreeView()
                        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
                } content: {
                    ContentBrowserView(collapsedGroups: $collapsedGroups)
                        .navigationSplitViewColumnWidth(min: 400, ideal: 600)
                } detail: {
                    MetadataPanelView()
                        .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 400)
                }
                .navigationSplitViewStyle(.balanced)
                .styledSplitViewDividers()
            } else {
                FirstRunView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground)
        .overlay(alignment: .top) {
            if let toast = vm.toastMessage {
                ToastView(message: toast.message, type: toast.type)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(200)
                    .id(vm.toastID)
            }
        }
        .overlay {
            if vm.commandPaletteOpen {
                // Dimmed backdrop
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture { vm.commandPaletteOpen = false }
                    .zIndex(250)

                VStack {
                    Spacer().frame(height: 80)
                    CommandPaletteView()
                        .environment(vm)
                    Spacer()
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
                .zIndex(260)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if vm.selectedAoeItems.count >= 2 && !vm.lightboxOpen {
                CompareAoeBanner(
                    selectedCount: vm.selectedAoeItems.count,
                    isLoading: vm.isLoadingComparison
                ) {
                    Task { await vm.openComparison() }
                }
                .padding(AppSpacing.xl)
                .zIndex(150)
            }
        }
    }

    /// Central keyboard dispatcher — routes keys based on app state.
    ///
    /// Keys with a menu key equivalent (⌘F, ⌘K, ⇧⌘N, ⌘D, ⌘⌫, ⌘↑, ⌘[, ⌘] …) are
    /// owned by the menus in `PromptLibraryExplorerApp`; this monitor must pass
    /// them through, or a single press would run twice.
    private func handleGlobalKey(_ event: NSEvent) -> Bool {
        // Anything modal (sheets, alerts, save panels, the Quick Look panel) owns
        // the keyboard until it is dismissed, and any other key window (Settings)
        // owns its own keys. The monitor is app-wide, so it would otherwise see
        // those keys first and drive the grid behind them.
        guard !ModalKeyGuard.shouldMainWindowMonitorStandDown else { return false }

        // Lightbox handles its own keys via its own .onGlobalKeyDown
        guard !vm.lightboxOpen else { return false }

        let isCommand = event.modifierFlags.contains(.command)

        // Don't intercept keys when a text field is focused
        if let responder = NSApp.keyWindow?.firstResponder,
           responder is NSTextView || responder is NSTextField
        {
            // Escape closes the command palette (its field has focus while open).
            // Otherwise it goes to the field, so handlers such as the inline
            // rename's `.onExitCommand` cancel get to run. ⌘K is the Go menu's.
            if vm.commandPaletteOpen, event.keyCode == KeyCode.escape.rawValue {
                closeCommandPalette()
                return true
            }

            // The toolbar search field has no Escape handler of its own, so
            // keep the old behaviour there: Escape hands focus back to the grid.
            if event.keyCode == KeyCode.escape.rawValue,
               (responder as? NSTextView)?.delegate is NSSearchField || responder is NSSearchField
            {
                NSApp.keyWindow?.makeFirstResponder(nil)
                return true
            }
            return false  // let the text field handle it
        }

        // While the palette is up it owns the keyboard: nothing drives the grid.
        if vm.commandPaletteOpen {
            if event.keyCode == KeyCode.escape.rawValue {
                closeCommandPalette()
                return true
            }
            return false
        }

        // No root path = nothing to navigate
        guard vm.explorerRootPath != nil else { return false }

        let items = vm.processedFolderContents
        let selectionModifiers = contentSelectionModifiers(for: event)

        switch event.keyCode {
        // Cmd+[ and Cmd+] are owned by the Go menu; Cmd+←/→ are extra aliases
        // with no menu item, so they live here.
        case KeyCode.leftArrow.rawValue where event.modifierFlags.contains(.command):
            Task { await vm.navigateBack() }
            return true

        case KeyCode.rightArrow.rawValue where event.modifierFlags.contains(.command):
            Task { await vm.navigateForward() }
            return true

        case KeyCode.leftArrow.rawValue:
            if vm.activePane == .sidebar {
                Task {
                    await vm.navigateUpToParentFolder()
                    vm.activePane = .sidebar
                }
                return true
            }
            handleContentLeft(items: items, modifiers: selectionModifiers)
            return true

        case KeyCode.rightArrow.rawValue:
            if vm.activePane == .sidebar {
                let rows = navigationLayout.rows
                if !rows.isEmpty, let targetIndex = rows[min(vm.sidebarContentRowHint, rows.count - 1)].first {
                    vm.selectItem(at: targetIndex, modifiers: selectionModifiers)
                } else {
                    vm.focusContent()
                }
            } else {
                handleContentRight(items: items, modifiers: selectionModifiers)
            }
            return true

        // Cmd+↑ (Enclosing Folder) and Cmd+↓ belong to the menus / system.
        case KeyCode.upArrow.rawValue where isCommand,
             KeyCode.downArrow.rawValue where isCommand:
            return false

        case KeyCode.upArrow.rawValue:
            if vm.activePane == .sidebar {
                Task { await vm.navigateSidebar(by: -1) }
            } else {
                handleContentVertical(direction: -1, items: items, modifiers: selectionModifiers)
            }
            return true

        case KeyCode.downArrow.rawValue:
            if vm.activePane == .sidebar {
                Task { await vm.navigateSidebar(by: 1) }
            } else {
                handleContentVertical(direction: 1, items: items, modifiers: selectionModifiers)
            }
            return true

        case KeyCode.returnKey.rawValue:
            guard vm.activePane == .content else { return true }
            if vm.selectedItemIndex >= 0, vm.selectedItemIndex < items.count {
                let idx = vm.selectedItemIndex
                let item = items[idx]
                if item.isDirectory {
                    Task { await vm.selectFolder(item.url) }
                } else if FileHelpers.isPreviewable(item) {
                    vm.lightboxIndex = idx
                    vm.lightboxOpen = true
                }
            }
            return true

        case KeyCode.space.rawValue:
            if vm.activePane == .sidebar {
                _ = vm.toggleSelectedSidebarFolderExpansion()
                return true
            }

            if vm.selectedItemIndex >= 0, vm.selectedItemIndex < items.count {
                let idx = vm.selectedItemIndex
                let item = items[idx]
                if FileHelpers.isPreviewable(item) {
                    vm.lightboxIndex = idx
                    vm.lightboxOpen = true
                }
            }
            return true

        case KeyCode.escape.rawValue:
            vm.clearSelection()
            return true

        // Cmd+Delete is File > Move to Trash.
        case KeyCode.delete.rawValue where isCommand, KeyCode.forwardDelete.rawValue where isCommand:
            return false

        case KeyCode.delete.rawValue, KeyCode.forwardDelete.rawValue:
            if event.modifierFlags.contains(.shift) {
                guard vm.activePane == .content, !vm.selectedItems.isEmpty else { return true }
                vm.requestPermanentDelete(for: vm.selectedItems)
                return true
            }

            Task { await vm.navigateUpToParentFolder() }
            return true

        // Cmd+F, Cmd+K, Shift+Cmd+N, Cmd+D, Cmd+Z / Shift+Cmd+Z are owned by
        // the menus; handling them here too would run them twice.

        default:
            return false
        }
    }

    private func closeCommandPalette() {
        withAnimation(.easeOut(duration: 0.15)) {
            vm.commandPaletteOpen = false
        }
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    private func contentSelectionModifiers(for event: NSEvent) -> EventModifiers {
        event.modifierFlags.contains(.shift) ? [.shift] : []
    }

    /// The listing as laid out on screen: grouped sections start new rows,
    /// collapsed sections are skipped, the list view is one column.
    private var navigationLayout: ContentNavigationLayout {
        ContentNavigationLayout(
            itemCount: vm.processedFolderContents.count,
            groups: vm.contentGroups,
            collapsedGroups: collapsedGroups,
            columns: vm.viewMode == .list ? 1 : vm.gridColumnCount
        )
    }

    private func handleContentLeft(items: [FileEntry], modifiers: EventModifiers = []) {
        let layout = navigationLayout
        guard !items.isEmpty, !layout.order.isEmpty else {
            vm.focusSidebar(preservingContentRow: 0)
            return
        }
        let current = vm.selectedItemIndex
        guard current >= 0 else {
            if let first = layout.order.first { vm.selectItem(at: first, modifiers: modifiers) }
            return
        }

        // From the first column, ← moves focus to the sidebar.
        if let position = layout.position(of: current), position.column == 0 {
            vm.focusSidebar(preservingContentRow: position.row)
        } else if let previous = layout.neighbor(of: current, step: -1) {
            vm.selectItem(at: previous, modifiers: modifiers)
        } else {
            vm.focusSidebar(preservingContentRow: 0)
        }
    }

    private func handleContentRight(items: [FileEntry], modifiers: EventModifiers = []) {
        let layout = navigationLayout
        guard !items.isEmpty, let first = layout.order.first else { return }
        let current = vm.selectedItemIndex
        guard current >= 0 else {
            vm.selectItem(at: first, modifiers: modifiers)
            return
        }

        if let next = layout.neighbor(of: current, step: 1) {
            vm.selectItem(at: next, modifiers: modifiers)
        }
    }

    private func handleContentVertical(direction: Int, items: [FileEntry], modifiers: EventModifiers = []) {
        let layout = navigationLayout
        guard !items.isEmpty, let first = layout.order.first else { return }
        let current = vm.selectedItemIndex
        guard current >= 0 else {
            vm.selectItem(at: first, modifiers: modifiers)
            return
        }

        if let target = layout.vertical(from: current, direction: direction) {
            vm.selectItem(at: target, modifiers: modifiers)
        }
    }
}

struct CompareAoeBanner: View {
    let selectedCount: Int
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: AppSpacing.lg) {
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text("Compare .aoe snapshots")
                    .font(.appHeadline)
                    .foregroundStyle(Color.appPrimaryText)
                Text("Uses the first two of \(selectedCount) selected files")
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
            }

            Button(action: action) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 60)
                } else {
                    Text("Open")
                        .font(.appCalloutEmphasis)
                        .padding(.horizontal, AppSpacing.lg)
                        .padding(.vertical, AppSpacing.sm)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.appAccent)
            .disabled(isLoading)
        }
        .padding(AppSpacing.lg)
        .background(Color.appSurface.opacity(0.94))
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(Color.appAccent.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: Color.appShadowColor.opacity(0.9), radius: 12, y: 6)
    }
}

// MARK: - Notification for search focus

extension Notification.Name {
    static let focusSearchField = Notification.Name("focusSearchField")
    /// Posted by Go > Command Palette (⌘K); MainContentView toggles the palette.
    static let toggleCommandPalette = Notification.Name("toggleCommandPalette")
    /// Posted by `ExplorerViewModel.openSettings()`; MainContentView opens the Settings window.
    static let openSettingsWindow = Notification.Name("openSettingsWindow")
}

// MARK: - Empty State

struct EmptyStateView: View {
    @Environment(ExplorerViewModel.self) private var vm

    var body: some View {
        VStack(spacing: AppSpacing.xl) {
            Image(systemName: "folder.badge.plus")
                .font(.appIcon(56))
                .foregroundStyle(Color.appAccent)

            Text("PromptLibrary Explorer")
                .font(.appLargeTitle)

            Text("Open a folder to browse your prompt library")
                .foregroundStyle(Color.appMuted)

            // ⌘O is owned by File > Open Folder…
            Button("Open Folder…") {
                Task { await vm.openFolder() }
            }
            .buttonStyle(AppPrimaryButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground)
    }
}
