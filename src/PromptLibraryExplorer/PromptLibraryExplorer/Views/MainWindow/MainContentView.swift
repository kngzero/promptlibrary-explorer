import SwiftUI

struct MainContentView: View {
    @Environment(ExplorerViewModel.self) private var vm
    @Environment(\.openSettings) private var openSettings
    @State private var splitViewVisibility: NavigationSplitViewVisibility =
        SettingsStore.shared.sidebarVisible ? .all : .doubleColumn
    /// Collapsed group sections of the content browser. Owned here so arrow-key
    /// navigation can skip the items of collapsed sections.
    @State private var collapsedGroups: Set<String> = []
    /// Sizes of the content and details columns and of the split view, so the
    /// Similar Images page can cover exactly those two columns. Sizes, not
    /// positions: the columns live in their own hosting views, whose
    /// coordinate spaces needn't match the split view's.
    @State private var contentColumnSize: CGSize = .zero
    @State private var detailColumnSize: CGSize = .zero
    @State private var splitSize: CGSize = .zero

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
        // Library ▸ Apply Suggested Tags… (Views/Stacks); applies nothing unconfirmed.
        .sheet(item: Binding(
            get: { TagSuggestionController.shared.session },
            set: { if $0 == nil { TagSuggestionController.shared.closeReview() } }
        )) { session in
            ApplySuggestedTagsSheet(session: session) { TagSuggestionController.shared.closeReview() }
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
        // The principal item carries the app identity; with a customizable toolbar
        // macOS 15 otherwise adds the window title as its own toolbar item.
        .modifier(HideToolbarTitle())
        .onGlobalKeyDown { event in
            handleGlobalKey(event)
        }
        .onChange(of: vm.isSimilarImagesPageActive) { _, _ in
            // Nothing in the covered (or uncovered) browser keeps keyboard focus.
            ModalKeyGuard.mainBrowserWindow?.makeFirstResponder(nil)
        }
        .onChange(of: vm.isComparePageActive) { _, _ in
            // Same for the Compare page (Views/Compare).
            ModalKeyGuard.mainBrowserWindow?.makeFirstResponder(nil)
        }
        .onChange(of: vm.isSimilarImagesPageActive) { _, active in
            // The Similar Images page replaces the Compare page.
            if active { vm.closeComparePage() }
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
                        .coveredBySimilarImagesPage(vm.isSimilarImagesPageActive || vm.isComparePageActive)
                        .background(SizeReporter(size: $contentColumnSize))
                        .navigationSplitViewColumnWidth(min: 400, ideal: 600)
                } detail: {
                    MetadataPanelView()
                        .coveredBySimilarImagesPage(vm.isSimilarImagesPageActive || vm.isComparePageActive)
                        .background(SizeReporter(size: $detailColumnSize))
                        .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 400)
                }
                .navigationSplitViewStyle(.balanced)
                .styledSplitViewDividers()
                .background(SizeReporter(size: $splitSize))
                // Similar Images page: covers the content and details columns
                // (the sidebar stays), anchored to the window's bottom-trailing
                // corner where those columns end. The browser keeps running
                // underneath, so leaving shows it exactly as it was.
                .overlay(alignment: .bottomTrailing) {
                    if vm.isSimilarImagesPageActive, contentColumnSize.width > 0 {
                        SimilarImagesPageView()
                            .frame(width: similarPageWidth, height: max(0, contentColumnSize.height))
                            .transition(.opacity.animation(.easeInOut(duration: 0.12)))
                    }
                }
                // Compare page (View ▸ Compare Images): same footprint as the
                // Similar Images page, same "browser untouched underneath".
                .overlay(alignment: .bottomTrailing) {
                    if let compare = vm.comparePageModel, !vm.isSimilarImagesPageActive, contentColumnSize.width > 0 {
                        ComparePageView(model: compare)
                            .id(compare.id)
                            .frame(width: similarPageWidth, height: max(0, contentColumnSize.height))
                            .transition(.opacity.animation(.easeInOut(duration: 0.12)))
                    }
                }
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
        .overlay(alignment: .bottom) {
            if let progress = vm.artOfficialSendProgress {
                ArtOfficialSendProgressView(progress: progress)
                    .transition(.opacity)
                    .zIndex(200)
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
            if vm.selectedAoeItems.count >= 2 && !vm.lightboxOpen && !vm.isSimilarImagesPageActive {
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

    /// Content column + its (thin, 1 pt) divider + details column.
    private var similarPageWidth: CGFloat {
        let width = contentColumnSize.width + detailColumnSize.width + (detailColumnSize.width > 0 ? 1 : 0)
        return max(0, splitSize.width > 0 ? min(width, splitSize.width) : width)
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

        // The Compare page: Esc closes it; the browser's bare keys stop here.
        if vm.isComparePageActive {
            return vm.handleComparePageKey(
                keyCode: event.keyCode,
                characters: event.charactersIgnoringModifiers,
                modifiers: event.modifierFlags
            )
        }

        // The Similar Images page owns the bare keys while it's up; nothing may
        // leak into the browser hidden underneath (no grid moves, no culling
        // auto-advance there, no Delete / Shift-Delete on its selection).
        if vm.isSimilarImagesPageActive {
            guard let action = SimilarPageKeyAction.action(
                keyCode: event.keyCode,
                characters: event.charactersIgnoringModifiers,
                modifiers: event.modifierFlags
            ) else { return false }
            vm.performSimilarPageKey(action, isRepeat: event.isARepeat)
            return true
        }

        let items = vm.processedFolderContents
        let selectionModifiers = contentSelectionModifiers(for: event)

        // Culling keys (bare P X U 0–9) belong to this monitor only; the Cull
        // menu shows them as text, never as key equivalents, so they can't fire
        // while typing in a text field (handled above).
        if let action = CullAction(event: event) {
            guard vm.activePane == .content, !vm.selectedItems.isEmpty else { return false }
            // A held key must not flag a whole folder by auto-advancing.
            if !event.isARepeat { applyCullKey(action) }
            return true
        }

        // More Like This: bare M, owned by this monitor (and the lightbox's).
        // The Library menu shows "(M)" in the title but binds no key equivalent.
        if VisualSearchKeys.isMoreLikeThis(event) {
            guard vm.activePane == .content, vm.canShowMoreLikeThis else { return false }
            if !event.isARepeat { vm.showMoreLikeThisForTarget() }
            return true
        }

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

    /// Applies a culling key to the selection. With one item selected, auto-advance
    /// (culling mode) moves to the next item; if the item left the listing (a
    /// flag / label filter now hides it), the item that took its place is selected.
    private func applyCullKey(_ action: CullAction) {
        let wasSingle = vm.selectedIndices.count == 1
        let pathBefore = vm.selectedItemPath
        let indexBefore = vm.selectedItemIndex
        guard vm.performCullAction(action) > 0, wasSingle else { return }

        if pathBefore != nil, vm.selectedItemPath == pathBefore {
            if vm.isCullAutoAdvanceActive,
               let next = navigationLayout.neighbor(of: vm.selectedItemIndex, step: 1)
            {
                vm.selectItem(at: next)
            }
        } else if vm.selectedIndices.isEmpty {
            let count = vm.processedFolderContents.count
            if count > 0 {
                vm.selectItem(at: min(max(indexBefore, 0), count - 1))
            }
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

// MARK: - Similar Images page support

/// Reports a view's size.
private struct SizeReporter: View {
    @Binding var size: CGSize

    var body: some View {
        GeometryReader { proxy in
            let current = proxy.size
            Color.clear
                .onAppear { size = current }
                .onChange(of: current) { _, value in size = value }
        }
    }
}

private extension View {
    /// The browser columns stay alive under the Similar Images page (state,
    /// scroll position and toolbar are kept) but take no clicks and are
    /// hidden from VoiceOver while covered.
    func coveredBySimilarImagesPage(_ covered: Bool) -> some View {
        allowsHitTesting(!covered)
            .accessibilityHidden(covered)
    }
}

/// Removes the automatic window-title item from the toolbar (macOS 15+), and
/// keeps SwiftUI from re-setting the window title on earlier systems.
private struct HideToolbarTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbar(removing: .title)
        } else {
            content.navigationTitle("")
        }
    }
}
