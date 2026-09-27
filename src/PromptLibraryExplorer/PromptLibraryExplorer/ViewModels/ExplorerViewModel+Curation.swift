import Foundation

// MARK: - Curation safety & sync glue (see Services/CurationController.swift)

extension ExplorerViewModel {
    /// Lets the curation controller reload this model's copies of the stores after it
    /// changed them (library sync from another Mac, import / restore, Finder tags, XMP).
    func installCurationHooks() {
        CurationController.shared.attach(
            reload: { [weak self] in self?.reloadCurationStateFromStores() },
            refreshListing: { [weak self] in
                guard let self else { return }
                Task { await self.refreshFolder() }
            }
        )
    }

    /// A root folder was opened: start syncing its library data file.
    func curationRootDidOpen(_ root: URL) {
        CurationController.shared.rootDidOpen(root)
    }

    /// Files a "Write XMP Sidecars Now" acts on: the selected files, else every file in
    /// the current listing.
    var xmpSidecarTargets: [FileEntry] {
        let selected = selectedItems.filter { !$0.isDirectory }
        let items = selected.isEmpty ? listingSourceContents.filter { !$0.isDirectory } : selected
        return items.filter { SidecarLocator.supportsSidecar($0.name) }
    }

    /// Library ▸ Write XMP Sidecars Now / context menu: writes (or updates) the sidecar of
    /// every target file, with its rating, label, tags, flag and prompts. Originals are
    /// never modified.
    func writeXMPSidecarsNow() {
        let targets = xmpSidecarTargets
        guard !targets.isEmpty else {
            showToast("No images, videos or audio files to write sidecars for", type: .info)
            return
        }
        Task {
            let written = await CurationController.shared.writeSidecars(paths: targets.map(\.path), force: true)
            let unchanged = targets.count - written
            var message = written == 1 ? "Wrote 1 XMP sidecar" : "Wrote \(written) XMP sidecars"
            if unchanged > 0 { message += " (\(unchanged) already up to date)" }
            showToast(message, type: .success)
        }
    }
}
