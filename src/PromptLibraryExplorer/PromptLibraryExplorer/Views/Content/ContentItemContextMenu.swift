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

        Button("Quick Look", action: onSelection { vm.quickLookSelection() })

        Button("Reveal in Finder", action: onSelection { vm.revealSelectionInFinder() })

        if !item.isDirectory, FileHelpers.isImageFile(item.name) || FileHelpers.isVideoFile(item.name) {
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

        Divider()

        // Copy
        if targetsHaveFiles {
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

        Divider()

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

        if targets.count > 1, targets.contains(where: { vm.isEmbeddableImageFile($0.name) }) {
            Button("Batch Edit Metadata", action: onSelection { vm.openBatchMetadataEditor() })
        }

        if targets.contains(where: { !$0.isDirectory && ArtOfficialSendBuilder.isSendable($0.name) }) {
            Button("Send to Mood…", action: onSelection { vm.sendToArtOfficial(.mood) })
            Button("Send to Story…", action: onSelection { vm.sendToArtOfficial(.story) })
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
