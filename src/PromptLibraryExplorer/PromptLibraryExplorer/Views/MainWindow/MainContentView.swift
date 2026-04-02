import SwiftUI

struct MainContentView: View {
    @Environment(ExplorerViewModel.self) private var vm
    @State private var splitViewVisibility: NavigationSplitViewVisibility = .all

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
        .sheet(isPresented: $vm.settingsOpen) {
            SettingsView()
                .environment(vm)
        }
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
            Button("Delete", role: .destructive) {
                vm.clearDeleteConfirmation()
                Task { await vm.deleteItemsPermanently(at: request.urls) }
            }
        } message: { request in
            Text(request.message)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                TitlebarIdentityView()
            }
        }
        .toolbar(vm.lightboxOpen ? .hidden : .automatic, for: .windowToolbar)
        .animation(.easeInOut(duration: 0.2), value: vm.toastMessage?.message)
        .background(WindowTitleConfigurator())
        .onGlobalKeyDown { event in
            handleGlobalKey(event)
        }
    }

    private var contentStack: some View {
        Group {
            if vm.explorerRootPath != nil {
                NavigationSplitView(columnVisibility: $splitViewVisibility) {
                    FileTreeView()
                        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
                } content: {
                    ContentBrowserView()
                        .navigationSplitViewColumnWidth(min: 400, ideal: 600)
                } detail: {
                    MetadataPanelView()
                        .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 400)
                }
                .navigationSplitViewStyle(.balanced)
                .styledSplitViewDividers()
            } else {
                EmptyStateView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground)
        .overlay(alignment: .top) {
            if let toast = vm.toastMessage {
                ToastView(message: toast.message, type: toast.type)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(200)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            withAnimation { vm.toastMessage = nil }
                        }
                    }
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
                .padding(16)
                .zIndex(150)
            }
        }
    }

    /// Central keyboard dispatcher — routes keys based on app state.
    private func handleGlobalKey(_ event: NSEvent) -> Bool {
        // Lightbox handles its own keys via its own .onGlobalKeyDown
        guard !vm.lightboxOpen else { return false }

        // Don't intercept keys when a text field is focused
        if let responder = NSApp.keyWindow?.firstResponder,
           responder is NSTextView || responder is NSTextField
        {
            // But still allow Escape to blur the text field
            if event.keyCode == KeyCode.escape.rawValue {
                NSApp.keyWindow?.makeFirstResponder(nil)
                return true
            }
            return false  // let the text field handle it
        }

        // No root path = nothing to navigate
        guard vm.explorerRootPath != nil else { return false }

        let items = vm.processedFolderContents
        let selectionModifiers = contentSelectionModifiers(for: event)

        switch event.keyCode {
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
                if let targetIndex = vm.firstColumnIndexFromSidebarHint() {
                    vm.selectItem(at: targetIndex, modifiers: selectionModifiers)
                } else {
                    vm.focusContent()
                }
            } else {
                handleContentRight(items: items, modifiers: selectionModifiers)
            }
            return true

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

        case KeyCode.delete.rawValue, KeyCode.forwardDelete.rawValue:
            if event.modifierFlags.contains(.shift) {
                guard vm.activePane == .content, !vm.selectedItems.isEmpty else { return true }
                vm.requestPermanentDelete(for: vm.selectedItems)
                return true
            }

            Task { await vm.navigateUpToParentFolder() }
            return true

        case KeyCode.f.rawValue where event.modifierFlags.contains(.command):
            // Cmd+F -> focus search field
            // Post notification that search should focus
            NotificationCenter.default.post(name: .focusSearchField, object: nil)
            return true

        case KeyCode.z.rawValue where event.modifierFlags.contains(.command):
            if event.modifierFlags.contains(.shift) {
                Task { await vm.redoLastFolderAction() }
            } else {
                Task { await vm.undoLastFolderAction() }
            }
            return true

        default:
            return false
        }
    }

    private func contentSelectionModifiers(for event: NSEvent) -> EventModifiers {
        event.modifierFlags.contains(.shift) ? [.shift] : []
    }

    private func handleContentLeft(items: [FileEntry], modifiers: EventModifiers = []) {
        guard !items.isEmpty else {
            vm.focusSidebar(preservingContentRow: 0)
            return
        }
        guard vm.selectedItemIndex >= 0 else {
            vm.selectItem(at: 0, modifiers: modifiers)
            return
        }

        let current = vm.selectedItemIndex
        let columns = max(1, vm.gridColumnCount)
        if current % columns == 0 {
            vm.focusSidebar(preservingContentRow: current / columns)
        } else {
            vm.selectItem(at: current - 1, modifiers: modifiers)
        }
    }

    private func handleContentRight(items: [FileEntry], modifiers: EventModifiers = []) {
        guard !items.isEmpty else { return }
        guard vm.selectedItemIndex >= 0 else {
            vm.selectItem(at: 0, modifiers: modifiers)
            return
        }

        let next = min(items.count - 1, vm.selectedItemIndex + 1)
        vm.selectItem(at: next, modifiers: modifiers)
    }

    private func handleContentVertical(direction: Int, items: [FileEntry], modifiers: EventModifiers = []) {
        guard !items.isEmpty else { return }
        guard vm.selectedItemIndex >= 0 else {
            vm.selectItem(at: 0, modifiers: modifiers)
            return
        }

        let columns = max(1, vm.gridColumnCount)
        let current = vm.selectedItemIndex
        let currentRow = current / columns
        let currentColumn = current % columns
        let lastRow = (items.count - 1) / columns
        let targetRow = max(0, min(lastRow, currentRow + direction))

        guard targetRow != currentRow else { return }

        let rowStart = targetRow * columns
        let rowEnd = min(items.count - 1, rowStart + columns - 1)
        let targetIndex = min(rowStart + currentColumn, rowEnd)
        vm.selectItem(at: targetIndex, modifiers: modifiers)
    }
}

struct CompareAoeBanner: View {
    let selectedCount: Int
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Compare .aoe snapshots")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.appPrimaryText)
                Text("Uses the first two of \(selectedCount) selected files")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.appMuted)
            }

            Button(action: action) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 60)
                } else {
                    Text("Open")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.appAccent)
            .disabled(isLoading)
        }
        .padding(14)
        .background(Color.appSurface.opacity(0.94))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.appAccent.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: Color.appShadowColor.opacity(0.9), radius: 12, y: 6)
    }
}

// MARK: - Notification for search focus

extension Notification.Name {
    static let focusSearchField = Notification.Name("focusSearchField")
}

// MARK: - Empty State

struct EmptyStateView: View {
    @Environment(ExplorerViewModel.self) private var vm

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 56))
                .foregroundStyle(Color.appAccent)

            Text("PromptLibrary Explorer")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Open a folder to browse your prompt library")
                .foregroundStyle(Color.appMuted)

            Button("Open Folder...") {
                Task { await vm.openFolder() }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.appAccent)
            .keyboardShortcut("o", modifiers: .command)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground)
    }
}
