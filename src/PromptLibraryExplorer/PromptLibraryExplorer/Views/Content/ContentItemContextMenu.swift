import SwiftUI

/// Context menu for a grid tile or list row. Actions that run on the selection
/// first make sure the right-clicked item is selected (see
/// `ContentItemActions.ensureSelected`).
struct ContentItemContextMenu: View {
    @Environment(ExplorerViewModel.self) private var vm
    let item: FileEntry
    let index: Int
    let onRename: () -> Void
    let onNewCollection: () -> Void

    /// Settings ▸ Appearance ▸ Right-Click Menu. On by default.
    @AppStorage(ContentItemContextMenu.compactKey) private var compact = true
    static let compactKey = "contextMenu.hideDetailsPanelItems"

    private var targets: [FileEntry] {
        if vm.selectedPaths.contains(item.path), !vm.selectedItems.isEmpty {
            return vm.selectedItems
        }
        return [item]
    }

    private var targetsHaveFiles: Bool {
        targets.contains(where: { !$0.isDirectory })
    }

    /// Targets that take flags and ratings (files only).
    private var cullFiles: [FileEntry] {
        targets.filter { !$0.isDirectory }
    }

    /// True when the listing is the file's own folder, so "Show in Folder" would
    /// go nowhere. Collections, virtual listings (More Like This, palette
    /// matches…) and anything listed from another folder return false.
    private var isInOwnFolder: Bool {
        let parent = item.url.deletingLastPathComponent().standardizedFileURL.path
        return vm.isFolderListing && vm.selectedFolderPath?.standardizedFileURL.path == parent
    }

    /// One file, which the details panel shows once it's selected: its Tools,
    /// Prompt, Prompt Tools, Dominant Colours and Rating & Tags cover these
    /// items, so the menu leaves them out (when `compact`). Several files keep
    /// everything, since the panel acts on one.
    private var detailsPanelCoversItem: Bool {
        compact && targets.count == 1 && !item.isDirectory
    }

    /// The value when every element agrees; nil when mixed or empty.
    private func commonValue<Value: Equatable>(_ values: [Value]) -> Value? {
        guard let first = values.first, values.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    /// Runs `action` after making the right-clicked item part of the selection.
    private func onSelection(_ action: @escaping () -> Void) -> () -> Void {
        { [vm, item, index] in
            ContentItemActions.ensureSelected(item, at: index, vm: vm)
            action()
        }
    }

    var body: some View {
        // Open / inspect
        if item.isDirectory || FileHelpers.isPreviewable(item) {
            Button(item.isDirectory ? "Open Folder" : "Open") {
                ContentItemActions.open(item, at: index, vm: vm)
            }
        }

        // Opens the file's folder in the browser with the file selected, as on the Timeline and Map.
        if !item.isDirectory, !isInOwnFolder {
            Button("Show in Folder") { Task { await vm.revealFile(at: item.url) } }
        }

        Button("Reveal in Finder", action: onSelection { vm.revealSelectionInFinder() })

        // Online-only cloud files: Download / Make Available Offline… (nothing otherwise).
        CloudItemMenuItems(targets: targets)

        if !detailsPanelCoversItem, !item.isDirectory, FileHelpers.isImageFile(item.name) || FileHelpers.isVideoFile(item.name) {
            let apps = FileSystemService.applicationsForFile(url: item.url)
            if !apps.isEmpty {
                Menu("Open In...") {
                    ForEach(apps, id: \.self) { appURL in
                        Button(appURL.deletingPathExtension().lastPathComponent) {
                            FileSystemService.openFile(url: item.url, withApplication: appURL)
                        }
                    }
                }
            }
        }

        if !item.isDirectory, let kind = ExplorerViewModel.artOfficialKind(forName: item.name) {
            ArtOfficialItemMenuItems(item: item, kind: kind)
        }

        // Non-destructive image edits (Views/Editor); hidden for non-images.
        if !detailsPanelCoversItem {
            EditorItemMenuItems(item: item, index: index, targets: targets)
        }

        // Video and audio tools: Save Middle Frame, Trim & Export Clip / Audio… (Views/Media).
        if !detailsPanelCoversItem, !item.isDirectory, FileHelpers.isVideoFile(item.name) || FileHelpers.isAudioFile(item.name) {
            Divider()
            MediaItemMenuItems(item: item)
        }

        // Visual search (inspection only: opens a ranked listing, changes nothing)
        if !detailsPanelCoversItem, !item.isDirectory, VisualSearchEligibility.hasPalette(item.name) {
            Divider()
            if VisualSearchEligibility.isVisual(item.name) {
                Button("More Like This") { vm.showMoreLikeThis(for: item) }
            }
            Button("Find Images Matching Palette") { vm.findImagesMatchingPalette(of: item) }
        }

        // Timeline / Map pages (Views/Timeline, Views/Map): the file's day, or its place.
        if !item.isDirectory, FileHelpers.isImageFile(item.name) || FileHelpers.isVideoFile(item.name) {
            Divider()
            Button("Show in Timeline") { vm.showInTimeline(item) }
            Button("Show on Map") { vm.showOnMap(item) }
        }

        Divider()

        // Copy
        if targetsHaveFiles, !detailsPanelCoversItem {
            Button("Copy Prompt", action: onSelection { vm.copyPromptOfSelection() })

            Menu("Copy As") {
                ForEach(PromptCopyFormat.allCases) { format in
                    Button(format.title, action: onSelection { vm.copySelection(as: format) })
                }
            }
        }

        Button(targets.count > 1 ? "Copy Paths" : "Copy Path", action: onSelection { vm.copyPathsOfSelection() })

        Button("Share…") {
            let urls = targets.map(\.url)
            ContentItemActions.ensureSelected(item, at: index, vm: vm)
            SharePresenter.share(urls)
        }

        if !detailsPanelCoversItem {
            Divider()
            cullingItems
        }

        // Suggested tags (review sheet) and version stacks (Views/Stacks).
        StackContextMenuItems(item: item, index: index, targets: targets)

        // Collections
        if targetsHaveFiles {
            Menu("Add to Collection") {
                CollectionMenuItems(vm: vm, disabledID: vm.activeCollectionID) { collection in
                    onSelection { vm.addSelection(toCollection: collection.id) }()
                }
                if !vm.collections.isEmpty {
                    Divider()
                }
                Button("New Collection from Selection…", action: onSelection { onNewCollection() })
            }
        }

        if vm.isCollectionMode {
            Button("Remove from Collection", action: onSelection { vm.removeSelectionFromActiveCollection() })
        }

        // `targets` is the selection as it will be after `ensureSelected`
        // (right-clicking an unselected item selects just that item).
        if targets.count == 2 {
            Button("Compare Prompts", action: onSelection { vm.openPromptDiff() })
        }

        // Prompt workflows: lineage, builder, send to generator (Views/Prompts).
        if !detailsPanelCoversItem {
            PromptItemMenuItems(item: item, targets: targets) {
                ContentItemActions.ensureSelected(item, at: index, vm: vm)
            }
        }

        // 2–4 images / videos side by side with synced zoom (Views/Compare).
        if let comparePaths = CompareEligibility.paths(for: targets) {
            Button("Compare Images", action: onSelection { vm.openComparePage(paths: comparePaths) })
        }

        if targets.count > 1, targets.contains(where: { vm.isEmbeddableImageFile($0.name) }) {
            Button("Batch Edit Metadata", action: onSelection { vm.openBatchMetadataEditor() })
        }

        // XMP sidecars (curation data beside the file; the original is never modified).
        if targets.contains(where: { !$0.isDirectory && SidecarLocator.supportsSidecar($0.name) }) {
            Button("Write XMP Sidecars", action: onSelection { vm.writeXMPSidecarsNow() })
        }

        if targets.contains(where: { !$0.isDirectory && ArtOfficialSendBuilder.isSendable($0.name) }) {
            Button("Send to Mood…", action: onSelection { vm.sendToArtOfficial(.mood) })
            Button("Send to Story…", action: onSelection { vm.sendToArtOfficial(.story) })
        }

        // Export suite (acts on the selection after `ensureSelected`).
        if targetsHaveFiles {
            Menu("Export") {
                ForEach(ExportPresetStore.shared.presets) { preset in
                    Button(preset.name, action: onSelection { vm.openExportSheet(presetID: preset.id) })
                }
                Divider()
                Button("Export…", action: onSelection { vm.openExportSheet() })
                Button("Export for Sharing (Strip AI Metadata)…", action: onSelection { vm.openExportForSharing() })
                Button("Export Contact Sheet…", action: onSelection { vm.openContactSheet() })
            }
            .disabled(ExportController.shared.isRunning)
        }

        Divider()

        Button("Rename") {
            onRename()
        }

        Button("Batch Rename…", action: onSelection { vm.batchRenameOpen = true })

        Button("Move") {
            let urls = targets.map(\.url)
            Task { await vm.moveItemsUsingFolderPicker(urls) }
        }

        Button("Move to Trash") {
            vm.requestTrash(at: targets.map(\.url))
        }

        Button("Delete Permanently") {
            vm.requestPermanentDelete(for: targets)
        }
    }

    /// Flag, Rating, Label, Pin and Tags (the details panel's Rating & Tags).
    @ViewBuilder
    private var cullingItems: some View {
        CullActionMenus(
            flag: commonValue(cullFiles.map { vm.flag(for: $0.path) }),
            rating: commonValue(cullFiles.map { vm.rating(for: $0.path) }),
            label: commonValue(targets.map { FinderLabel(labelNumber: $0.labelNumber) }),
            includesFileActions: targetsHaveFiles,
            perform: { action in
                // Flags and ratings are for files; Finder labels go on folders too.
                let items = action.appliesToFolders ? targets : cullFiles
                ContentItemActions.ensureSelected(item, at: index, vm: vm)
                vm.apply(action, to: items)
            }
        )

        Button(vm.isFavorite(path: item.path) ? "Unpin" : "Pin") {
            vm.toggleFavorite(path: item.path)
        }

        Menu("Tags") {
            TagAssignmentMenu(paths: targets.map(\.path))
        }
    }
}

/// Context-menu items for a Mood board / Story project file.
private struct ArtOfficialItemMenuItems: View {
    @Environment(ExplorerViewModel.self) private var vm
    let item: FileEntry
    let kind: ArtOfficialDocument.Kind

    var body: some View {
        Button("Open in \(kind.ownerAppName)") { vm.openInOwnerApp(item) }
        switch kind {
        case .moodboard:
            Button("Extract Images…") { vm.extractEmbeddedImages(from: item) }
            Button("Export Board as PNG…") { vm.exportRenderedImage(of: item) }
            Menu("Copy Palette") {
                ForEach(PaletteCopyFormat.allCases) { format in
                    Button(format.title) { vm.copyPalette(of: item, format: format) }
                }
            }
        case .story:
            Button("Extract Shot Thumbnails…") { vm.extractEmbeddedImages(from: item) }
            Button("Export Contact Sheet…") { vm.exportRenderedImage(of: item) }
            Menu("Copy Shot List") {
                ForEach(ShotListFormat.allCases) { format in
                    Button(format.title) { vm.copyShotList(of: item, format: format) }
                }
            }
        }
    }
}
