import AppKit
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
        didSet { flushPendingURLs() }
    }
    @MainActor private var pendingURLs: [URL] = []

    @MainActor
    func application(_ application: NSApplication, open urls: [URL]) {
        pendingURLs.append(contentsOf: urls.filter(\.isFileURL))
        flushPendingURLs()
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
        guard let viewModel, !viewModel.isModalBlockingCommands, !viewModel.lightboxOpen else { return }
        viewModel.selectAllItems()
    }

    @MainActor
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(selectAll(_:)) else { return true }
        guard let viewModel, !ModalKeyGuard.isAuxiliaryWindowKey else { return false }
        return !viewModel.isModalBlockingCommands
            && !viewModel.lightboxOpen
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
                .environment(explorerVM)
                .frame(minWidth: 900, minHeight: 600)
                .preferredColorScheme(explorerVM.appearanceMode.preferredColorScheme)
                .onAppear { appDelegate.viewModel = explorerVM }
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
                .disabled(isBlocked || !explorerVM.canCreateFolder)

                Button("Rename") {
                    // The inline rename field lives in the browser, under the lightbox.
                    runInMainWindow(allowInLightbox: false) { NotificationCenter.default.post(name: .beginRenameSelection, object: nil) }
                }
                .disabled(isBlocked || explorerVM.lightboxOpen || explorerVM.selectedIndices.count != 1)

                Button("Batch Rename…") {
                    run { explorerVM.batchRenameOpen = true }
                }
                .disabled(isBlocked || explorerVM.batchRenameTargets.isEmpty)

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
                .disabled(isBlocked || !hasSelection)

                Button("Reveal in Finder") {
                    run { explorerVM.revealSelectionInFinder() }
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(isBlocked || (!hasSelection && explorerVM.selectedFolderPath == nil))

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
                .disabled(isBlocked || explorerVM.selectedFileItems.isEmpty)

                Button("New Collection from Selection") {
                    run { explorerVM.createCollection(named: defaultCollectionName, withSelection: true) }
                }
                .disabled(isBlocked || explorerVM.selectedFileItems.isEmpty)

                if explorerVM.isCollectionMode {
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
                .disabled(isBlocked || !explorerVM.canSendToArtOfficial)

                Button("Send to Story…") {
                    runInMainWindow { explorerVM.sendToArtOfficial(.story) }
                }
                .disabled(isBlocked || !explorerVM.canSendToArtOfficial)
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
                .disabled(isBlocked || explorerVM.selectedFileItems.isEmpty)

                Menu("Copy Prompt As") {
                    ForEach(PromptCopyFormat.allCases) { format in
                        Button(format.title) {
                            run { explorerVM.copySelection(as: format) }
                        }
                    }
                }
                .disabled(isBlocked || explorerVM.selectedFileItems.isEmpty)

                Button("Copy Path") {
                    run { explorerVM.copyPathsOfSelection() }
                }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(isBlocked || !hasSelection)
            }
            CommandGroup(replacing: .textEditing) {
                Button("Find") {
                    // Works from a focused text field too. The search field sits
                    // under the lightbox, so close it first.
                    runClosingLightbox { NotificationCenter.default.post(name: .focusSearchField, object: nil) }
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(isBlocked || explorerVM.explorerRootPath == nil)

                Button("Find in Library…") {
                    run { explorerVM.librarySearchOpen = true }
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(isBlocked || explorerVM.explorerRootPath == nil)

                Button("Clear All Filters") {
                    run { explorerVM.clearAllFilters() }
                }
                .disabled(isBlocked || !explorerVM.hasActiveFilters)
            }

            // MARK: View
            CommandGroup(after: .sidebar) {
                Toggle("as Grid", isOn: viewModeBinding(.grid))
                    .keyboardShortcut("1", modifiers: .command)
                    .disabled(isBlocked)

                Toggle("as List", isOn: viewModeBinding(.list))
                    .keyboardShortcut("2", modifiers: .command)
                    .disabled(isBlocked)

                Divider()

                Picker("Group By", selection: Binding(
                    get: { explorerVM.groupBy },
                    set: { field in run { explorerVM.groupBy = field } }
                )) {
                    ForEach(GroupByField.allCases) { field in
                        Text(field.title).tag(field)
                    }
                }
                .disabled(isBlocked)

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
                .disabled(isBlocked)

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
                .disabled(isBlocked)

                Divider()

                Button("Quick Look") {
                    // Allowed while the Quick Look panel itself is key (⌘Y closes it).
                    guard !explorerVM.isModalBlockingCommands, !explorerVM.lightboxOpen else { return }
                    explorerVM.quickLookSelection()
                }
                .keyboardShortcut("y", modifiers: .command)
                .disabled(explorerVM.isAnyModalOpen || explorerVM.lightboxOpen || !hasSelection)

                Button("Compare Prompts") {
                    run { explorerVM.openPromptDiff() }
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(isBlocked || explorerVM.selectedIndices.count != 2)

                Button("Compare Selected .aoe Files") {
                    run { Task { await explorerVM.openComparison() } }
                }
                .disabled(isBlocked || explorerVM.selectedAoeItems.count < 2 || explorerVM.isLoadingComparison)

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
                .disabled(isBlocked || explorerVM.selectedFolderPath == nil)

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

                Divider()

                // Visual search. Inspection only — nothing here removes files.
                Button("Find Similar Images…") {
                    run(allowInLightbox: false) { explorerVM.similarImagesOpen = true }
                }
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

                if explorerVM.isVirtualListingMode {
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
            }

            // MARK: Cull, Help
            // (A commands builder takes at most ten items, hence the Group.)
            Group {
                cullCommands

                CommandGroup(replacing: .help) {
                    Button("PromptLibrary Explorer Help") {
                        explorerVM.helpOpen = true
                    }

                    Divider()

                    Button("Developer Website") {
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
            .disabled(isBlocked || explorerVM.lightboxOpen || explorerVM.explorerRootPath == nil)

            Button("Move Rejects to Trash…") {
                runInMainWindow(allowInLightbox: false) { explorerVM.requestTrashRejects() }
            }
            .disabled(isBlocked || explorerVM.lightboxOpen || explorerVM.explorerRootPath == nil)
        }
    }

    // MARK: - Command helpers

    /// Observable "a sheet/modal is up" state used to disable menu items.
    private var isBlocked: Bool { explorerVM.isAnyModalOpen }

    private var hasSelection: Bool { !explorerVM.selectedIndices.isEmpty }

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
        canNativeUndo || explorerVM.canUndoFolderAction
    }

    private var canRedo: Bool {
        canNativeRedo || explorerVM.canRedoFolderAction
    }

    private var undoCommandTitle: String {
        if let nativeUndoActionName {
            return "Undo \(nativeUndoActionName)"
        }
        if explorerVM.canUndoFolderAction {
            return explorerVM.undoMenuTitle
        }
        return "Undo"
    }

    private var redoCommandTitle: String {
        if let nativeRedoActionName {
            return "Redo \(nativeRedoActionName)"
        }
        if explorerVM.canRedoFolderAction {
            return explorerVM.redoMenuTitle
        }
        return "Redo"
    }

    private func performUndo() {
        if canNativeUndo {
            NSApp.sendAction(undoSelector, to: nil, from: nil)
            return
        }

        guard explorerVM.canUndoFolderAction else { return }
        Task { await explorerVM.undoLastFolderAction() }
    }

    private func performRedo() {
        if canNativeRedo {
            NSApp.sendAction(redoSelector, to: nil, from: nil)
            return
        }

        guard explorerVM.canRedoFolderAction else { return }
        Task { await explorerVM.redoLastFolderAction() }
    }
}
