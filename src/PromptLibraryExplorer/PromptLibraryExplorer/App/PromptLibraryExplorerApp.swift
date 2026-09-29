import AppKit
import CoreSpotlight
import SwiftUI

extension Notification.Name {
    /// Posted by File > Rename; the content browser starts an inline rename of
    /// the primary selection.
    static let beginRenameSelection = Notification.Name("beginRenameSelection")
}

/// Receives files and folders opened from Finder ("Open With", double-click
/// on a registered type) or dropped on the Dock icon.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    /// Set once the window's view model exists; URLs that arrive earlier
    /// (e.g. the app was launched by opening a file) are queued.
    @MainActor weak var viewModel: ExplorerViewModel? {
        didSet {
            // Spotlight, Shortcuts, promptlibrary:// links, cloud files (idempotent).
            viewModel?.configureSystemIntegration()
            flushPendingURLs()
            flushPendingAutomation()
        }
    }
    @MainActor private var pendingURLs: [URL] = []
    /// promptlibrary:// links and Spotlight results that arrived before the window.
    @MainActor private var pendingAutomationURLs: [URL] = []
    @MainActor private var pendingActivities: [NSUserActivity] = []

    @MainActor
    func application(_ application: NSApplication, open urls: [URL]) {
        pendingURLs.append(contentsOf: urls.filter(\.isFileURL))
        pendingAutomationURLs.append(contentsOf: urls.filter(AutomationURL.isAutomationURL))
        flushPendingURLs()
        flushPendingAutomation()
    }

    /// promptlibrary:// links arrive as a GetURL Apple Event; handling it here (rather
    /// than leaving it to SwiftUI's scene routing) never opens a second window.
    @MainActor
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @MainActor @objc
    func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: string)
        else { return }
        if url.isFileURL {
            pendingURLs.append(url)
            flushPendingURLs()
        } else if AutomationURL.isAutomationURL(url) {
            pendingAutomationURLs.append(url)
            flushPendingAutomation()
        }
    }

    /// Spotlight result (CSSearchableItemActionType): reveal the file.
    @MainActor
    func application(
        _ application: NSApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void
    ) -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType else { return false }
        pendingActivities.append(userActivity)
        flushPendingAutomation()
        return true
    }

    @MainActor
    private func flushPendingAutomation() {
        guard let viewModel, !(pendingAutomationURLs.isEmpty && pendingActivities.isEmpty) else { return }
        let urls = pendingAutomationURLs
        let activities = pendingActivities
        pendingAutomationURLs = []
        pendingActivities = []
        NSApp.activate(ignoringOtherApps: true)
        for activity in activities { viewModel.handleSpotlightActivity(activity) }
        Task {
            for url in urls { await viewModel.handleAutomationURL(url) }
        }
    }

    /// Edit ▸ Select All (⌘A). The system menu item sends `selectAll:` down the
    /// responder chain, so a focused text field still selects its own text; only
    /// when nothing earlier in the chain handles it does it reach the app delegate
    /// and select every item in the listing. (One owner: no key-monitor case.)
    @MainActor @objc
    func selectAll(_ sender: Any?) {
        // Settings (or another auxiliary window) is key with no text field
        // focused: don't select the browser's items behind it.
        guard !ModalKeyGuard.isAuxiliaryWindowKey else { return }
        guard let viewModel, !viewModel.isModalBlockingCommands, !viewModel.lightboxOpen,
              !viewModel.isSimilarImagesPageActive, !viewModel.isComparePageActive
        else { return }
        viewModel.selectAllItems()
    }

    @MainActor
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(selectAll(_:)) else { return true }
        guard let viewModel, !ModalKeyGuard.isAuxiliaryWindowKey else { return false }
        return !viewModel.isModalBlockingCommands
            && !viewModel.lightboxOpen
            && !viewModel.isSimilarImagesPageActive
            && !viewModel.isComparePageActive
            && !viewModel.processedFolderContents.isEmpty
    }

    @MainActor
    private func flushPendingURLs() {
        guard let viewModel, !pendingURLs.isEmpty else { return }
        let urls = pendingURLs
        pendingURLs = []
        NSApp.activate(ignoringOtherApps: true)
        Task { await viewModel.openExternalURLs(urls) }
    }
}

@main
struct PromptLibraryExplorerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var explorerVM = ExplorerViewModel()

    private let undoSelector = NSSelectorFromString("undo:")
    private let redoSelector = NSSelectorFromString("redo:")

    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        WindowGroup {
            MainContentView()
                .exportSheetsHost()
                .ingestSheetsHost()
                .mediaSheetsHost()
                .promptSheetsHost()
                // Welcome tour (Views/Onboarding): first launch, Help ▸ Welcome Tour….
                .onboardingHost()
                .environment(explorerVM)
                .frame(minWidth: 900, minHeight: 600)
                .preferredColorScheme(explorerVM.appearanceMode.preferredColorScheme)
                .onAppear { appDelegate.viewModel = explorerVM }
                // Spotlight results, when SwiftUI routes the activity to the scene
                // instead of the delegate (deduplicated in handleSpotlightActivity).
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    explorerVM.handleSpotlightActivity(activity)
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1280, height: 800)
        .commands { mainCommands }

        // PromptLibrary Explorer ▸ Settings… (⌘,) comes from this scene: it is the
        // single owner of ⌘,. `ExplorerViewModel.openSettings()` opens it too.
        Settings {
            SettingsView()
                .environment(explorerVM)
                .preferredColorScheme(explorerVM.appearanceMode.preferredColorScheme)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: SettingsView.defaultSize.width, height: SettingsView.defaultSize.height)
    }

    @CommandsBuilder
    private var mainCommands: some Commands {
            // View ▸ Show/Hide Toolbar (⌥⌘T) and Customize Toolbar… for the
            // customizable browser toolbar. ⌥⌘T has no other owner.
            ToolbarCommands()

            // MARK: File
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") {
                    Task { await explorerVM.openFolder() }
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(isBlocked)

                Menu("Open Recent") {
                    recentFolderItems

                    Divider()

                    Menu("Remove from Recents") {
                        ForEach(explorerVM.recentFolders) { item in
                            Button(item.name) {
                                explorerVM.removeRecentFolder(item)
                            }
                        }
                    }
                    .disabled(explorerVM.recentFolders.isEmpty)

                    Button("Clear Recents") {
                        explorerVM.clearRecentFolders()
                    }
                    .disabled(explorerVM.recentFolders.isEmpty)
                }

                Divider()

                Button("New Folder") {
                    run { explorerVM.isShowingNewFolderPrompt = true }
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(isBlocked || browserHidden || !explorerVM.canCreateFolder)

                Button("Rename") {
                    // The inline rename field lives in the browser, under the lightbox.
                    runInMainWindow(allowInLightbox: false) { NotificationCenter.default.post(name: .beginRenameSelection, object: nil) }
                }
                .disabled(isBlocked || browserHidden || explorerVM.lightboxOpen || explorerVM.selectedIndices.count != 1)

                Button("Batch Rename…") {
                    run { explorerVM.batchRenameOpen = true }
                }
                .disabled(isBlocked || browserHidden || explorerVM.batchRenameTargets.isEmpty)

                Divider()

                Button("Move to Trash") {
                    // A focused text field uses ⌘⌫ for "delete to line start";
                    // the menu's key equivalent would otherwise steal it.
                    if ModalKeyGuard.isTextInputFocused {
                        NSApp.sendAction(#selector(NSText.deleteToBeginningOfLine(_:)), to: nil, from: nil)
                        return
                    }
                    runInMainWindow(allowInLightbox: false) { explorerVM.trashSelection() }
                }
                .keyboardShortcut(.delete, modifiers: .command)
                // Never from the Similar Images page (nothing there is ever trashed).
                .disabled(isBlocked || browserHidden || !hasSelection)

                Button("Reveal in Finder") {
                    run { explorerVM.revealSelectionInFinder() }
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(isBlocked || (browserHidden
                    ? explorerVM.similarPageTargetPath == nil
                    : (!hasSelection && explorerVM.selectedFolderPath == nil)))

                // Online-only cloud files in the selection (no key equivalent).
                Button("Download from Cloud") {
                    run { explorerVM.downloadCloudFiles(explorerVM.selectedItems) }
                }
                .disabled(isBlocked || browserHidden || explorerVM.cloudOnlyItems(in: explorerVM.selectedItems).isEmpty)

                Divider()

                Menu("Add to Collection") {
                    if explorerVM.collections.isEmpty {
                        Text("No Collections")
                    } else {
                        CollectionMenuItems(vm: explorerVM) { collection in
                            run { explorerVM.addSelection(toCollection: collection.id) }
                        }
                    }
                }
                .disabled(isBlocked || browserHidden || explorerVM.selectedFileItems.isEmpty)

                Button("New Collection from Selection") {
                    run { explorerVM.createCollection(named: defaultCollectionName, withSelection: true) }
                }
                .disabled(isBlocked || browserHidden || explorerVM.selectedFileItems.isEmpty)

                if explorerVM.isCollectionMode, !browserHidden {
                    Button("Remove from Collection") {
                        run { explorerVM.removeSelectionFromActiveCollection() }
                    }
                    .disabled(isBlocked || !hasSelection)
                }

                Divider()

                // Mood boards / Story projects: open in the owner app. No shortcuts.
                if let document = explorerVM.selectedArtOfficialItem,
                   let kind = ExplorerViewModel.artOfficialKind(forName: document.name)
                {
                    Button("Open in \(kind.ownerAppName)") {
                        run { explorerVM.openInOwnerApp(document) }
                    }
                    .disabled(isBlocked)
                }

                // Selection (or the whole listing when nothing is selected), images only.
                Button("Send to Mood…") {
                    runInMainWindow { explorerVM.sendToArtOfficial(.mood) }
                }
                .disabled(isBlocked || browserHidden || !explorerVM.canSendToArtOfficial)

                Button("Send to Story…") {
                    runInMainWindow { explorerVM.sendToArtOfficial(.story) }
                }
                .disabled(isBlocked || browserHidden || !explorerVM.canSendToArtOfficial)

                // Export suite: selection, else the whole listing. No shortcuts.
                Group {
                    Divider()

                    Button("Export…") {
                        runInMainWindow { explorerVM.openExportSheet() }
                    }
                    .disabled(isBlocked || browserHidden || !explorerVM.canExport)

                    Menu("Export With Preset") {
                        ForEach(ExportPresetStore.shared.presets) { preset in
                            Button(preset.name) {
                                runInMainWindow { explorerVM.openExportSheet(presetID: preset.id) }
                            }
                        }
                    }
                    .disabled(isBlocked || browserHidden || !explorerVM.canExport)

                    Button("Export for Sharing (Strip AI Metadata)…") {
                        runInMainWindow { explorerVM.openExportForSharing() }
                    }
                    .disabled(isBlocked || browserHidden || !explorerVM.canExport)

                    Button("Export Contact Sheet…") {
                        runInMainWindow { explorerVM.openContactSheet() }
                    }
                    .disabled(isBlocked || browserHidden || !explorerVM.canExport)
                }

                // Video tools (selection or the lightbox video). No shortcuts.
                Group {
                    Divider()

                    Button("Save Middle Frame") {
                        runInMainWindow { explorerVM.saveMiddleFramesForTarget() }
                    }
                    .disabled(isBlocked || !explorerVM.canSaveMiddleFrame)

                    Button("Trim & Export Clip…") {
                        runInMainWindow { explorerVM.openTrimForTarget() }
                    }
                    .disabled(isBlocked || !explorerVM.canTrimVideo)
                }
            }

            // MARK: Edit
            CommandGroup(replacing: .undoRedo) {
                Button(undoCommandTitle) {
                    performUndo()
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!canUndo)

                Button(redoCommandTitle) {
                    performRedo()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!canRedo)
            }
            CommandGroup(after: .pasteboard) {
                Divider()

                Button("Copy Prompt") {
                    run { explorerVM.copyPromptOfSelection() }
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(isBlocked || (browserHidden
                    ? explorerVM.similarPageTargetPath == nil
                    : explorerVM.selectedFileItems.isEmpty))

                Menu("Copy Prompt As") {
                    ForEach(PromptCopyFormat.allCases) { format in
                        Button(format.title) {
                            run { explorerVM.copySelection(as: format) }
                        }
                    }
                }
                .disabled(isBlocked || browserHidden || explorerVM.selectedFileItems.isEmpty)

                Button("Copy Path") {
                    run { explorerVM.copyPathsOfSelection() }
                }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(isBlocked || (browserHidden ? explorerVM.similarPageTargetPath == nil : !hasSelection))
            }
            CommandGroup(replacing: .textEditing) {
                Button("Find") {
                    // Works from a focused text field too. The search field sits
                    // under the lightbox, so close it first.
                    runClosingLightbox { NotificationCenter.default.post(name: .focusSearchField, object: nil) }
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(isBlocked || browserHidden || explorerVM.explorerRootPath == nil)

                Button("Find in Library…") {
                    run { explorerVM.librarySearchOpen = true }
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(isBlocked || explorerVM.explorerRootPath == nil)

                Button("Clear All Filters") {
                    run { explorerVM.clearAllFilters() }
                }
                .disabled(isBlocked || browserHidden || !explorerVM.hasActiveFilters)
            }

            // MARK: View
            CommandGroup(after: .sidebar) {
                // Leaves the Similar Images page (same as its Done button / Esc).
                Button("Show Browser") {
                    run {
                        explorerVM.requestCancelEditor()
                        explorerVM.leaveSimilarImagesPage()
                        explorerVM.closeComparePage()
                        explorerVM.leaveMapTimelinePage()
                    }
                }
                .disabled(isBlocked || !browserHidden)

                // Pages of the main window (checked while showing), like
                // Similar Images. No key equivalents; Esc / Done leave them.
                Toggle("Timeline", isOn: Binding(
                    get: { explorerVM.isTimelinePageActive },
                    set: { show in
                        run(allowInLightbox: false) {
                            if show { explorerVM.showTimelinePage() } else { explorerVM.leaveMapTimelinePage() }
                        }
                    }
                ))
                .disabled(isBlocked || explorerVM.explorerRootPath == nil || explorerVM.lightboxOpen)

                Toggle("Map", isOn: Binding(
                    get: { explorerVM.isMapPageActive },
                    set: { show in
                        run(allowInLightbox: false) {
                            if show { explorerVM.showMapPage() } else { explorerVM.leaveMapTimelinePage() }
                        }
                    }
                ))
                .disabled(isBlocked || explorerVM.explorerRootPath == nil || explorerVM.lightboxOpen)

                Divider()

                Toggle("as Grid", isOn: viewModeBinding(.grid))
                    .keyboardShortcut("1", modifiers: .command)
                    .disabled(isBlocked || browserHidden)

                Toggle("as List", isOn: viewModeBinding(.list))
                    .keyboardShortcut("2", modifiers: .command)
                    .disabled(isBlocked || browserHidden)

                Divider()

                Picker("Group By", selection: Binding(
                    get: { explorerVM.groupBy },
                    set: { field in run { explorerVM.groupBy = field } }
                )) {
                    ForEach(GroupByField.allCases) { field in
                        Text(field.title).tag(field)
                    }
                }
                .disabled(isBlocked || browserHidden)

                Menu("Sort By") {
                    Picker("Sort By", selection: Binding(
                        get: { explorerVM.sortConfig.field },
                        set: { field in run { setSortField(field) } }
                    )) {
                        ForEach(SortField.allCases) { field in
                            Text(field.title).tag(field)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()

                    Divider()

                    Picker("Direction", selection: Binding(
                        get: { explorerVM.sortConfig.direction },
                        set: { direction in
                            run {
                                explorerVM.sortConfig.direction = direction
                                explorerVM.persistSortConfig()
                            }
                        }
                    )) {
                        ForEach(SortDirection.allCases, id: \.self) { direction in
                            Text(direction.title).tag(direction)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .disabled(!explorerVM.sortConfig.field.supportsDirection)
                }
                .disabled(isBlocked || browserHidden)

                // Version stacks (per folder / collection). No key equivalents.
                Group {
                    Divider()

                    Toggle("Stack Variants", isOn: Binding(
                        get: { explorerVM.isStackingEnabled },
                        set: { _ in run { explorerVM.toggleStackingForCurrentListing() } }
                    ))
                    .disabled(isBlocked || browserHidden || explorerVM.stackScope == nil)

                    Menu("Stacks") {
                        Button("Stack Selected") {
                            runInMainWindow(allowInLightbox: false) { explorerVM.stackSelection() }
                        }
                        .disabled(!explorerVM.canStackSelection)

                        Button("Unstack") {
                            runInMainWindow(allowInLightbox: false) { explorerVM.unstackSelection() }
                        }
                        .disabled(explorerVM.selectedStack == nil)

                        Button("Set as Cover") {
                            runInMainWindow(allowInLightbox: false) { explorerVM.setSelectionAsStackCover() }
                        }
                        .disabled(!explorerVM.canSetSelectionAsStackCover)

                        Button("Remove from Stack") {
                            runInMainWindow(allowInLightbox: false) { explorerVM.removeSelectionFromStack() }
                        }
                        .disabled(!explorerVM.canRemoveSelectionFromStack)

                        Divider()

                        Button(explorerVM.selectedStack.map { explorerVM.stackController.isExpanded($0.id) } == true ? "Collapse Stack" : "Expand Stack") {
                            runInMainWindow(allowInLightbox: false) { explorerVM.toggleSelectedStackExpansion() }
                        }
                        .disabled(explorerVM.selectedStack == nil)

                        Button("Expand All Stacks") {
                            run { explorerVM.stackController.setAllExpanded(true) }
                        }
                        .disabled(!explorerVM.isStackingEnabled || explorerVM.stackController.stacks.isEmpty)

                        Button("Collapse All Stacks") {
                            run { explorerVM.stackController.setAllExpanded(false) }
                        }
                        .disabled(!explorerVM.isStackingEnabled || explorerVM.stackController.expanded.isEmpty)
                    }
                    .disabled(isBlocked || browserHidden || explorerVM.lightboxOpen)
                }

                Divider()
            }
            CommandGroup(after: .toolbar) {
                Toggle("Status Bar", isOn: Binding(
                    get: { explorerVM.showStatusBar },
                    set: { newValue in
                        explorerVM.showStatusBar = newValue
                        explorerVM.persistStatusBarVisibility()
                    }
                ))

                Button(explorerVM.previewPaneCollapsed ? "Show Preview Pane" : "Hide Preview Pane") {
                    run { explorerVM.togglePreviewPane() }
                }
                .disabled(isBlocked || browserHidden)

                Divider()

                Button("Quick Look") {
                    // Allowed while the Quick Look panel itself is key (⌘Y closes it).
                    guard !explorerVM.isModalBlockingCommands, !explorerVM.lightboxOpen else { return }
                    explorerVM.quickLookSelection()
                }
                .keyboardShortcut("y", modifiers: .command)
                .disabled(explorerVM.isAnyModalOpen || explorerVM.lightboxOpen || browserHidden || !hasSelection)

                Button("Compare Prompts") {
                    run { explorerVM.openPromptDiff() }
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(isBlocked || browserHidden || explorerVM.selectedIndices.count != 2)

                Button("Compare Selected .aoe Files") {
                    run { Task { await explorerVM.openComparison() } }
                }
                .disabled(isBlocked || browserHidden || explorerVM.selectedAoeItems.count < 2 || explorerVM.isLoadingComparison)

                // Viewing tools (Views/Compare, Views/Viewing). No key
                // equivalents; nothing here deletes or marks files.
                Group {
                    Divider()

                    // 2–4 selected images / videos; on the Similar Images page
                    // it toggles the group's synced compare.
                    Button("Compare Images") {
                        run(allowInLightbox: false) { explorerVM.compareImagesCommand() }
                    }
                    .disabled(isBlocked || explorerVM.lightboxOpen || explorerVM.isComparePageActive || !explorerVM.canCompareImages)

                    // Selection (2+), else the listing: folder, collection or virtual listing.
                    Button("Start Slideshow") {
                        runInMainWindow(allowInLightbox: false) { explorerVM.startSlideshow() }
                    }
                    .disabled(isBlocked || explorerVM.lightboxOpen || !explorerVM.canStartSlideshow)

                    // Lightbox loupe and histogram (also buttons in the lightbox header).
                    Toggle("Loupe", isOn: viewingBinding(\.loupeEnabled))

                    Menu("Loupe Magnification") {
                        Picker("Loupe Magnification", selection: viewingBinding(\.loupeMagnification)) {
                            ForEach(ViewingController.loupeMagnifications, id: \.self) { Text("\($0)×").tag($0) }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()

                        Divider()

                        Toggle("Crisp Pixels (Nearest Neighbour)", isOn: viewingBinding(\.loupeNearestNeighbour))
                    }

                    Toggle("Histogram", isOn: viewingBinding(\.histogramEnabled))
                }

                Divider()

                Button("Refresh") {
                    run { Task { await explorerVM.refreshFolder() } }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(isBlocked)

                Button("Folder Statistics") {
                    run { explorerVM.statisticsOpen = true }
                }
                .disabled(isBlocked || explorerVM.selectedFolderPath == nil)

                Button("New Smart Folder...") {
                    run {
                        explorerVM.editingSmartFolder = nil
                        explorerVM.showSmartFolderEditor = true
                    }
                }
                .disabled(isBlocked)
            }

            // MARK: Go
            CommandMenu("Go") {
                Button("Back") {
                    run { Task { await explorerVM.navigateBack() } }
                }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(isBlocked || !explorerVM.canNavigateBack)

                Button("Forward") {
                    run { Task { await explorerVM.navigateForward() } }
                }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(isBlocked || !explorerVM.canNavigateForward)

                Button("Enclosing Folder") {
                    // In a text field ⌘↑ moves to the start of the text.
                    if ModalKeyGuard.isTextInputFocused {
                        NSApp.sendAction(#selector(NSResponder.moveToBeginningOfDocument(_:)), to: nil, from: nil)
                        return
                    }
                    runInMainWindow {
                        if explorerVM.isVirtualListingMode {
                            explorerVM.closeVirtualListing()
                        } else if explorerVM.isCollectionMode {
                            explorerVM.openCollection(nil)
                        } else {
                            Task { await explorerVM.navigateUpToParentFolder() }
                        }
                    }
                }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(isBlocked || browserHidden || explorerVM.selectedFolderPath == nil)

                Divider()

                Button("Command Palette") {
                    // The palette is an overlay under the lightbox; close it first.
                    runClosingLightbox { NotificationCenter.default.post(name: .toggleCommandPalette, object: nil) }
                }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(isBlocked || explorerVM.explorerRootPath == nil)

                Divider()

                Menu("Recent Folders") {
                    recentFolderItems
                }
                .disabled(isBlocked)

                Menu("Collections") {
                    if explorerVM.collections.isEmpty {
                        Text("No Collections")
                    } else {
                        CollectionMenuItems(vm: explorerVM, disabledID: explorerVM.activeCollectionID) { collection in
                            run { explorerVM.openCollection(collection.id) }
                        }
                    }
                    if explorerVM.isCollectionMode {
                        Divider()
                        Button("Close Collection") {
                            run { explorerVM.openCollection(nil) }
                        }
                    }
                }
                .disabled(isBlocked)
            }

            // MARK: Library
            CommandMenu("Library") {
                Button("Find in Library…") {
                    run { explorerVM.librarySearchOpen = true }
                }
                .disabled(isBlocked || explorerVM.explorerRootPath == nil)

                Button("Find Similar Prompts…") {
                    run { explorerVM.duplicatesOpen = true }
                }
                .disabled(isBlocked || explorerVM.explorerRootPath == nil)

                Button("Prompt Snippets…") {
                    run { explorerVM.snippetsOpen = true }
                }
                .disabled(isBlocked)

                // Prompt workflows (Views/Prompts). No key equivalents.
                Group {
                    Button("Prompt Builder…") {
                        run { explorerVM.openPromptBuilderForTarget() }
                    }
                    .disabled(isBlocked)

                    Button("Show Prompt Lineage") {
                        run { explorerVM.showPromptLineage() }
                    }
                    .disabled(isBlocked || !explorerVM.canShowPromptLineage)

                    Menu("Send to Generator") {
                        Button("Re-run in ComfyUI…") {
                            run { explorerVM.sendTargetToGenerator(.comfyUI) }
                        }
                        .disabled(!explorerVM.canSendToGenerator(.comfyUI, item: explorerVM.promptActionTarget))
                        Button("Send to A1111 / Forge…") {
                            run { explorerVM.sendTargetToGenerator(.a1111) }
                        }
                        .disabled(!explorerVM.canSendToGenerator(.a1111, item: explorerVM.promptActionTarget))
                        Divider()
                        Button("Generator Settings…") { explorerVM.openGeneratorSettings() }
                    }
                    .disabled(isBlocked)

                    Button("Prompt Statistics…") {
                        run { explorerVM.openPromptStatistics() }
                    }
                    .disabled(isBlocked || explorerVM.explorerRootPath == nil)
                }

                Divider()

                // Visual search. Inspection only — nothing here removes files.
                // A page of the main window (checked while it shows); View ▸
                // Show Browser, its Done button and Esc return to the browser.
                Toggle("Similar Images", isOn: Binding(
                    get: { explorerVM.isSimilarImagesPageActive },
                    set: { show in
                        run(allowInLightbox: false) {
                            if show { explorerVM.showSimilarImagesPage() } else { explorerVM.leaveSimilarImagesPage() }
                        }
                    }
                ))
                .disabled(isBlocked || explorerVM.explorerRootPath == nil || explorerVM.lightboxOpen)

                // Bare M is owned by the key monitors (grid + lightbox); like the
                // Cull menu, the key is shown in the title, never bound here.
                Button("More Like This (M)") {
                    runInMainWindow { explorerVM.showMoreLikeThisForTarget() }
                }
                .disabled(isBlocked || !explorerVM.canShowMoreLikeThis)

                Button("Find Images Matching Palette") {
                    runInMainWindow { explorerVM.findImagesMatchingPaletteForTarget() }
                }
                .disabled(isBlocked || !explorerVM.canFindMatchingPalette)

                Menu("Visual Search Scope") {
                    ForEach(VisualSearchScopeChoice.allCases) { choice in
                        Toggle(choice.title, isOn: Binding(
                            get: { explorerVM.visualSearchScope == choice },
                            set: { if $0 { explorerVM.visualSearchScope = choice } }
                        ))
                    }
                }
                .disabled(isBlocked)

                if explorerVM.isVirtualListingMode, !browserHidden {
                    Button("Close \"\(explorerVM.activeVirtualListing?.title ?? "Listing")\"") {
                        runInMainWindow { explorerVM.closeVirtualListing() }
                    }
                    .disabled(isBlocked)
                }

                Divider()

                Button(explorerVM.isLibraryIndexing ? "Indexing Library…" : "Reindex Library") {
                    run { explorerVM.reindexLibrary() }
                }
                .disabled(isBlocked || explorerVM.explorerRootPath == nil || explorerVM.isLibraryIndexing)

                // Curation data beside the files (Settings ▸ Data has the rest).
                Button("Write XMP Sidecars Now") {
                    runInMainWindow { explorerVM.writeXMPSidecarsNow() }
                }
                .disabled(isBlocked || explorerVM.explorerRootPath == nil)

                // Review sheet; nothing is applied without confirmation.
                Button("Apply Suggested Tags…") {
                    runInMainWindow(allowInLightbox: false) { explorerVM.openApplySuggestedTags() }
                }
                .disabled(isBlocked || explorerVM.lightboxOpen || !explorerVM.canApplySuggestedTags)

                // Ingest inbox (Settings ▸ Ingest has the watched folders). No key equivalents.
                Group {
                    Divider()

                    Button("Show Inbox") {
                        runInMainWindow { explorerVM.openInbox() }
                    }
                    .disabled(isBlocked || browserHidden || !IngestController.shared.hasSources)

                    Button("Mark Inbox as Seen") {
                        run { explorerVM.markInboxSeen() }
                    }
                    .disabled(isBlocked || IngestController.shared.unseenCount == 0)

                    Button("Ingest Log…") {
                        run { explorerVM.showIngestLog() }
                    }
                    .disabled(isBlocked)

                    Button("Watched Folders…") {
                        explorerVM.openIngestSettings()
                    }
                }
            }

            // MARK: Cull, Help
            // (A commands builder takes at most ten items, hence the Group.)
            Group {
                cullCommands

                // Edit ▸ Edit Image… / Save Edited Copy… / Revert to Original.
                editorCommands

                // PromptLibrary Explorer ▸ About: the standard panel with ArtOfficial credits.
                CommandGroup(replacing: .appInfo) {
                    Button("About PromptLibrary Explorer") { AboutPanel.show() }
                }

                CommandGroup(replacing: .help) {
                    Button("PromptLibrary Explorer Help") {
                        explorerVM.helpOpen = true
                    }
                    // A second sheet can't present over the tour or another sheet.
                    .disabled(isBlocked)

                    // Onboarding (Views/Onboarding, Views/Help). No key equivalents.
                    Button("Keyboard Shortcuts") {
                        explorerVM.openHelp(focus: .section(.keyboard))
                    }
                    .disabled(isBlocked)

                    Button("Welcome Tour…") {
                        explorerVM.presentWelcomeTour()
                    }
                    .disabled(isBlocked)

                    Divider()

                    Toggle("Show Tips", isOn: Binding(
                        get: { OnboardingTipsController.shared.tipsEnabled },
                        set: { OnboardingTipsController.shared.tipsEnabled = $0 }
                    ))

                    Button("Reset Tips") {
                        explorerVM.resetTips()
                    }

                    Divider()

                    Button("Visit artofficial.world") {
                        explorerVM.openDeveloperWebsite()
                    }
                }
            }
    }

    @CommandsBuilder
    private var cullCommands: some Commands {
        // Bare-key culling shortcuts (P X U 0–9) are owned by the key monitors
        // (`handleGlobalKey`, the lightbox's), never by these items: a bare-letter
        // key equivalent would fire while typing in a text field. The key is
        // shown in each title instead.
        CommandMenu("Cull") {
            Toggle("Culling Mode", isOn: Binding(
                get: { explorerVM.cullingModeEnabled },
                set: { explorerVM.cullingModeEnabled = $0 }
            ))

            Toggle("Auto-advance After Flag, Rating or Label", isOn: Binding(
                get: { explorerVM.cullAutoAdvance },
                set: { explorerVM.cullAutoAdvance = $0 }
            ))
            .disabled(!explorerVM.cullingModeEnabled)

            Divider()

            ForEach(FileFlag.menuOrder) { flag in
                Button(flag.menuTitle) { cull(.flag(flag)) }
                    .disabled(!canCull(.flag(flag)))
            }

            Divider()

            Menu("Rating") {
                ForEach(0...5, id: \.self) { stars in
                    Button(CullMenuText.rating(stars)) { cull(.rating(stars)) }
                }
            }
            .disabled(!canCull(.rating(0)))

            Menu("Label") {
                ForEach(FinderLabel.menuOrder) { label in
                    Button {
                        cull(.label(label))
                    } label: {
                        Label {
                            Text(label.menuTitle)
                        } icon: {
                            Image(nsImage: label.menuSwatch)
                        }
                    }
                }
                Divider()
                Button("No Label") { cull(.label(.none)) }
            }
            .disabled(!canCull(.label(.none)))

            Divider()

            Button("Select Rejects") {
                runInMainWindow(allowInLightbox: false) { explorerVM.selectRejects() }
            }
            .disabled(isBlocked || browserHidden || explorerVM.lightboxOpen || explorerVM.explorerRootPath == nil)

            // Browser only: never offered from the Similar Images page.
            Button("Move Rejects to Trash…") {
                runInMainWindow(allowInLightbox: false) { explorerVM.requestTrashRejects() }
            }
            .disabled(isBlocked || browserHidden || explorerVM.lightboxOpen || explorerVM.explorerRootPath == nil)
        }
    }

    // MARK: - Image editor commands

    /// Non-destructive image editor (Views/Editor), in the Edit menu. No key equivalents.
    @CommandsBuilder
    private var editorCommands: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()

            Button(explorerVM.editImageUnavailableReason.map { "Edit Image — \($0)" } ?? "Edit Image…") {
                runInMainWindow { explorerVM.openEditImageForTarget() }
            }
            .disabled(isBlocked || !explorerVM.canEditImage)

            Button("Save Edited Copy…") {
                runInMainWindow { explorerVM.saveEditedCopyForTarget() }
            }
            .disabled(isBlocked || !explorerVM.canSaveEditedCopy)

            Button("Revert to Original") {
                runInMainWindow { explorerVM.revertTargetsToOriginal() }
            }
            .disabled(isBlocked || explorerVM.isEditorPageActive || explorerVM.editedTargetPaths.isEmpty)
        }
    }

    // MARK: - Command helpers

    /// Observable "a sheet/modal is up" state used to disable menu items.
    private var isBlocked: Bool { explorerVM.isAnyModalOpen || ExportController.shared.isPresenting || PromptWorkflowController.shared.isPresenting || OnboardingController.shared.isTourPresented }

    private var hasSelection: Bool { !explorerVM.selectedIndices.isEmpty }

    /// The Similar Images page covers the browser: browser-only commands are
    /// disabled; Cull, Copy Prompt, Copy Path, Reveal and More Like This act on
    /// the page's focused card instead of the hidden selection.
    private var browserHidden: Bool { explorerVM.isSimilarImagesPageActive || explorerVM.isComparePageActive || explorerVM.isEditorPageActive || explorerVM.isMapTimelinePageActive || explorerVM.isTrimPageActive }

    /// Cull menu actions: the lightbox's item while it's open, else the selection.
    private func cull(_ action: CullAction) {
        runInMainWindow { explorerVM.performCullAction(action) }
    }

    private func canCull(_ action: CullAction) -> Bool {
        !isBlocked && !explorerVM.cullTargets(for: action).isEmpty
    }

    private var defaultCollectionName: String {
        let existing = Set(explorerVM.collections.map(\.name))
        var name = "New Collection"
        var counter = 2
        while existing.contains(name) {
            name = "New Collection \(counter)"
            counter += 1
        }
        return name
    }

    /// Runs a menu action unless something modal owns the window (menu key
    /// equivalents still fire while a sheet is up).
    private func run(allowInLightbox: Bool = true, _ action: () -> Void) {
        guard !explorerVM.isModalBlockingCommands else { return }
        if !allowInLightbox, explorerVM.lightboxOpen { return }
        action()
    }

    /// For commands that act on the browser window's own UI (inline rename, the
    /// focused selection, Enclosing Folder): no-op while Settings or another
    /// auxiliary window is key, so a key press there never reaches the grid.
    private func runInMainWindow(allowInLightbox: Bool = true, _ action: () -> Void) {
        guard !ModalKeyGuard.isAuxiliaryWindowKey else { return }
        run(allowInLightbox: allowInLightbox, action)
    }

    /// For commands whose target (the toolbar search field, the command
    /// palette) sits underneath the lightbox: close the lightbox, then act on
    /// the next run-loop turn once the browser chrome is back. Main-window only.
    private func runClosingLightbox(_ action: @escaping () -> Void) {
        guard !explorerVM.isModalBlockingCommands, !ModalKeyGuard.isAuxiliaryWindowKey else { return }
        guard explorerVM.lightboxOpen else {
            action()
            return
        }
        explorerVM.lightboxOpen = false
        DispatchQueue.main.async { action() }
    }

    /// Loupe / histogram settings (`ViewingController`).
    private func viewingBinding<Value>(_ keyPath: ReferenceWritableKeyPath<ViewingController, Value>) -> Binding<Value> {
        Binding(
            get: { ViewingController.shared[keyPath: keyPath] },
            set: { ViewingController.shared[keyPath: keyPath] = $0 }
        )
    }

    private func viewModeBinding(_ mode: BrowserViewMode) -> Binding<Bool> {
        Binding(
            get: { explorerVM.viewMode == mode },
            set: { _ in run { explorerVM.viewMode = mode } }
        )
    }

    private func setSortField(_ field: SortField) {
        if field == .custom {
            explorerVM.ensureCustomSortForCurrentFolder()
            return
        }
        explorerVM.sortConfig = SortConfig(field: field, direction: explorerVM.sortConfig.direction)
        explorerVM.persistSortConfig()
    }

    @ViewBuilder
    private var recentFolderItems: some View {
        if explorerVM.recentFolders.isEmpty {
            Text("No Recent Folders")
        } else {
            ForEach(explorerVM.recentFolders) { item in
                Button(item.name) {
                    run { Task { await explorerVM.openRecentFolder(item) } }
                }
            }
        }
    }

    private var currentUndoManager: UndoManager? {
        NSApp.keyWindow?.undoManager ?? NSApp.mainWindow?.undoManager
    }

    private var canNativeUndo: Bool {
        currentUndoManager?.canUndo == true
    }

    private var canNativeRedo: Bool {
        currentUndoManager?.canRedo == true
    }

    private var nativeUndoActionName: String? {
        guard canNativeUndo else { return nil }
        let name = currentUndoManager?.undoActionName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? nil : name
    }

    private var nativeRedoActionName: String? {
        guard canNativeRedo else { return nil }
        let name = currentUndoManager?.redoActionName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? nil : name
    }

    private var canUndo: Bool {
        // The image editor's session has its own undo while it's open.
        if let session = explorerVM.editorSession { return session.canUndo }
        return canNativeUndo || explorerVM.canUndoFolderAction
    }

    private var canRedo: Bool {
        if let session = explorerVM.editorSession { return session.canRedo }
        return canNativeRedo || explorerVM.canRedoFolderAction
    }

    private var undoCommandTitle: String {
        if explorerVM.editorSession != nil { return "Undo Edit" }
        if let nativeUndoActionName {
            return "Undo \(nativeUndoActionName)"
        }
        if explorerVM.canUndoFolderAction {
            return explorerVM.undoMenuTitle
        }
        return "Undo"
    }

    private var redoCommandTitle: String {
        if explorerVM.editorSession != nil { return "Redo Edit" }
        if let nativeRedoActionName {
            return "Redo \(nativeRedoActionName)"
        }
        if explorerVM.canRedoFolderAction {
            return explorerVM.redoMenuTitle
        }
        return "Redo"
    }

    private func performUndo() {
        if let session = explorerVM.editorSession, !ModalKeyGuard.isAuxiliaryWindowKey {
            session.undo()
            return
        }
        if canNativeUndo {
            NSApp.sendAction(undoSelector, to: nil, from: nil)
            return
        }

        guard explorerVM.canUndoFolderAction else { return }
        Task { await explorerVM.undoLastFolderAction() }
    }

    private func performRedo() {
        if let session = explorerVM.editorSession, !ModalKeyGuard.isAuxiliaryWindowKey {
            session.redo()
            return
        }
        if canNativeRedo {
            NSApp.sendAction(redoSelector, to: nil, from: nil)
            return
        }

        guard explorerVM.canRedoFolderAction else { return }
        Task { await explorerVM.redoLastFolderAction() }
    }
}

// MARK: - About

/// The About panel: app icon, name, version and build, plus "Made by ArtOfficial"
/// with a link to artofficial.world. Copyright comes from NSHumanReadableCopyright.
enum AboutPanel {
    static let websiteURL = URL(string: "https://artofficial.world")!

    @MainActor
    static func show() {
        let info = Bundle.main.infoDictionary ?? [:]
        // MAJOR.FEATURE.FIXES (scripts/bump_version.sh); build = git commit count.
        let version = info["CFBundleShortVersionString"] as? String ?? "1.0.00"
        let build = info["CFBundleVersion"] as? String
        let commit = info["PLXGitCommit"] as? String
        let buildText = [build.map { "Build \($0)" }, commit].compactMap { $0 }.joined(separator: " · ")
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "PromptLibrary Explorer",
            .applicationVersion: version,
            .version: buildText,
            .credits: credits
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    static var credits: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 4
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph
        ]
        let text = NSMutableAttributedString(
            string: "A prompt-aware library for AI images, video and audio.\n",
            attributes: body
        )
        text.append(NSAttributedString(string: "Made by ", attributes: body))
        var strong = body
        strong[.font] = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        strong[.foregroundColor] = NSColor.labelColor
        text.append(NSAttributedString(string: "ArtOfficial", attributes: strong))
        text.append(NSAttributedString(string: "\n", attributes: body))
        var link = body
        link[.link] = websiteURL
        text.append(NSAttributedString(string: "artofficial.world", attributes: link))
        return text
    }
}
