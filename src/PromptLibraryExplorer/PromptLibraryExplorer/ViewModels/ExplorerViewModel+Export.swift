import Foundation

// MARK: - Export glue

/// Menu / context-menu / palette entry points for the export suite. State lives in
/// `ExportController`; this only turns the view model's selection into requests.
extension ExplorerViewModel {
    /// Selection, else the whole listing (folder, collection or virtual listing).
    var exportSourceEntries: [FileEntry] {
        sendToSourceItems
    }

    var canExport: Bool {
        !ExportController.shared.isRunning && !isSimilarImagesPageActive && !exportSourceEntries.isEmpty
    }

    /// "3 selected files" / "All 42 files in “Renders”".
    private var exportSourceDescription: String {
        let selected = selectedFileItems.count
        if selected > 0 { return "\(selected) selected file\(selected == 1 ? "" : "s")" }
        let count = exportSourceEntries.count
        let place = activeVirtualListing?.title ?? activeCollection.map { "collection “\($0.name)”" }
            ?? selectedFolderPath.map { "“\($0.lastPathComponent)”" } ?? "this listing"
        return "All \(count) file\(count == 1 ? "" : "s") in \(place)"
    }

    private var exportSuggestedTitle: String {
        activeVirtualListing?.title ?? activeCollection?.name ?? selectedFolderPath?.lastPathComponent ?? "Contact Sheet"
    }

    func exportSourceItem(for entry: FileEntry) -> ExportSourceItem {
        ExportSourceItem(
            url: entry.url,
            modifiedDate: entry.modifiedDate,
            fileSize: entry.fileSize,
            prompt: promptTextByPath[entry.path],
            parameters: parametersByPath[entry.path] ?? GenerationParameters()
        )
    }

    func contactSheetItem(for entry: FileEntry) -> ContactSheetItem {
        ContactSheetItem(
            url: entry.url,
            name: entry.name,
            prompt: promptTextByPath[entry.path],
            rating: rating(for: entry.path),
            flag: flag(for: entry.path)
        )
    }

    // MARK: Export sheet

    /// File ▸ Export… (preset nil = last used) and File ▸ Export With Preset ▸ <preset>.
    func openExportSheet(presetID: UUID? = nil) {
        let entries = exportSourceEntries
        guard !entries.isEmpty else {
            showToast("Select files to export", type: .info)
            return
        }
        guard !ExportController.shared.isRunning else {
            showToast("An export is already running", type: .info)
            return
        }
        ExportController.shared.exportRequest = ExportRequest(
            items: entries.map(exportSourceItem(for:)),
            sourceDescription: exportSourceDescription,
            presetID: presetID
        )
    }

    /// File ▸ Export for Sharing (Strip AI Metadata)…
    func openExportForSharing() {
        openExportSheet(presetID: ExportController.shared.store.sharingPreset.id)
    }

    /// Collection sidebar row ▸ Export (collection order).
    func exportCollection(_ id: UUID, presetID: UUID? = nil) {
        guard let collection = collections.first(where: { $0.id == id }) else { return }
        let paths = collection.paths
        Task {
            let entries = await Task.detached(priority: .userInitiated) {
                paths.compactMap { FileEntry.load(from: URL(fileURLWithPath: $0)) }.filter { !$0.isDirectory }
            }.value
            guard !entries.isEmpty else {
                showToast("“\(collection.name)” has no files to export", type: .info)
                return
            }
            ExportController.shared.exportRequest = ExportRequest(
                items: entries.map(exportSourceItem(for:)),
                sourceDescription: "Collection “\(collection.name)” · \(entries.count) file\(entries.count == 1 ? "" : "s")",
                presetID: presetID
            )
        }
    }

    // MARK: Contact sheet

    /// File ▸ Export Contact Sheet…
    func openContactSheet() {
        let entries = exportSourceEntries
        guard !entries.isEmpty else {
            showToast("Select files for the contact sheet", type: .info)
            return
        }
        guard !ExportController.shared.isRunning else {
            showToast("An export is already running", type: .info)
            return
        }
        let description = exportSourceDescription
        let title = exportSuggestedTitle
        ExportController.shared.contactSheetRequest = ContactSheetRequest(
            items: entries.map(contactSheetItem(for:)), sourceDescription: description, suggestedTitle: title
        )
    }

    func contactSheetForCollection(_ id: UUID) {
        guard let collection = collections.first(where: { $0.id == id }) else { return }
        let paths = collection.paths
        Task {
            let entries = await Task.detached(priority: .userInitiated) {
                paths.compactMap { FileEntry.load(from: URL(fileURLWithPath: $0)) }.filter { !$0.isDirectory }
            }.value
            guard !entries.isEmpty else {
                showToast("“\(collection.name)” has no files", type: .info)
                return
            }
            ExportController.shared.contactSheetRequest = ContactSheetRequest(
                items: entries.map(contactSheetItem(for:)),
                sourceDescription: "Collection “\(collection.name)” · \(entries.count) file\(entries.count == 1 ? "" : "s")",
                suggestedTitle: collection.name
            )
        }
    }

    // MARK: After export

    /// Re-reads the listing when an export wrote into the folder on screen.
    func refreshAfterExport(folders: Set<String>) {
        guard isFolderListing, let current = selectedFolderPath?.standardizedFileURL.path else { return }
        let touchesListing = folders.contains(current)
            || folders.contains { URL(fileURLWithPath: $0).deletingLastPathComponent().standardizedFileURL.path == current }
        guard touchesListing else { return }
        Task { await refreshFolder() }
    }
}
