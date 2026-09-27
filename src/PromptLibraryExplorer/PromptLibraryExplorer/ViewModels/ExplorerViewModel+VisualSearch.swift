import AppKit
import Foundation

// MARK: - Visual search: scope, More Like This, colour search, similar groups
//
// HARD RULE (user decision): similar / duplicate results never mark,
// pre-select, rank for removal or suggest deleting anything. Every action here
// is inspection only: compare, select, collect, reveal, lightbox.

extension ExplorerViewModel {
    // MARK: Scope

    /// The engine scope for `choice`: the folder on screen (direct children),
    /// or everything under the root. Nil without an open folder.
    func visualScope(for choice: VisualSearchScopeChoice) -> VisualScope? {
        switch choice {
        case .folder:
            guard let folder = selectedFolderPath ?? explorerRootPath else { return nil }
            return .folder(folder.standardizedFileURL)
        case .library:
            guard let root = explorerRootPath ?? selectedFolderPath else { return nil }
            return .library(root.standardizedFileURL)
        }
    }

    var currentVisualScope: VisualScope? { visualScope(for: visualSearchScope) }

    /// "in this folder" / "in the library" for toasts and titles.
    var visualScopeDescription: String {
        switch visualSearchScope {
        case .folder: return "in \(selectedFolderPath?.lastPathComponent ?? "this folder")"
        case .library: return "in the library"
        }
    }

    // MARK: Dominant colours for the listing

    /// Something on screen needs the listing's dominant colours.
    var needsListingDominantColors: Bool {
        filterConfig.colorFilter != nil
            || groupBy == .colorFamily
            || activeSmartFolder?.criteria.dominantColor != nil
            || showTileColorStrip
    }

    /// Loads the listing's dominant colours from the visual index when
    /// needed. Also call after an indexing run finishes.
    func loadListingDominantColorsIfNeeded(force: Bool = false) {
        guard force || needsListingDominantColors else { return }
        let paths = listingSourceContents.filter { !$0.isDirectory }.map(\.path)
        guard !paths.isEmpty else { return }
        let scope = promptIndexScope
        dominantColorsTask?.cancel()
        dominantColorsTask = Task(priority: .utility) { [weak self] in
            let colors = await VisualIndexService.shared.dominantColors(forPaths: paths)
            guard !Task.isCancelled, let self, self.promptIndexScope == scope else { return }
            if colors != self.dominantColorsByPath { self.dominantColorsByPath = colors }
        }
    }

    // MARK: More Like This

    /// The file More Like This / palette search acts on: the lightbox's item
    /// while it's open, else the primary selection.
    var visualSearchTargetItem: FileEntry? {
        // The Similar Images page: its focused card.
        if let path = similarPageTargetPath { return similarImages.entry(for: path) }
        let items = processedFolderContents
        if lightboxOpen, lightboxIndex >= 0, lightboxIndex < items.count {
            return items[lightboxIndex]
        }
        guard let path = selectedItemPath else { return nil }
        return items.first(where: { $0.path == path })
    }

    var canShowMoreLikeThis: Bool {
        guard let item = visualSearchTargetItem, !item.isDirectory else { return false }
        return VisualSearchEligibility.isVisual(item.name)
    }

    var canFindMatchingPalette: Bool {
        guard let item = visualSearchTargetItem, !item.isDirectory else { return false }
        return VisualSearchEligibility.hasPalette(item.name)
    }

    /// Library ▸ More Like This and the bare M key.
    func showMoreLikeThisForTarget() {
        guard let item = visualSearchTargetItem else {
            showToast("Select an image or video first", type: .info)
            return
        }
        showMoreLikeThis(for: item)
    }

    /// Opens "Similar to <name>": the file itself first, then the most similar
    /// files in the current scope.
    func showMoreLikeThis(for item: FileEntry) {
        guard !item.isDirectory, VisualSearchEligibility.isVisual(item.name) else {
            showToast("More Like This works on images and videos", type: .info)
            return
        }
        guard let scope = currentVisualScope else { return }
        let path = item.path
        let name = item.name
        let scopeText = visualScopeDescription
        Task {
            let hits = await VisualIndexService.shared.moreLikeThis(path: path, in: scope, limit: 200)
            let ranked = [path] + hits.map(\.path).filter { $0 != path }
            guard ranked.count > 1 else {
                showToast(
                    VisualIndexController.shared.state == .indexing
                        ? "Nothing similar \(scopeText) yet — indexing is still running"
                        : "Nothing similar to \"\(name)\" \(scopeText)",
                    type: .info
                )
                return
            }
            // The listing shows in the browser (from the lightbox, once it closes).
            if !lightboxOpen { similarPage.leave() }
            openVirtualListing(
                VirtualListing(kind: .similarTo(path: path), title: "Similar to \(name)", paths: ranked),
                selecting: path
            )
        }
    }

    // MARK: Colour search

    /// Tolerance remembered from the last colour filter / palette search.
    var rememberedColorTolerance: Double {
        get { SettingsStore.shared.colorTolerance }
        set { SettingsStore.shared.colorTolerance = min(max(newValue, 0), 1) }
    }

    /// Sets (or with nil clears) the Filter menu's colour filter.
    func setColorFilter(_ filter: ColorFilter?) {
        guard filterConfig.colorFilter != filter else { return }
        filterConfig.colorFilter = filter
        if let filter { rememberedColorTolerance = filter.tolerance }
        persistFilterConfig()
    }

    /// Details panel swatch click: filter the listing by that one colour.
    func filterByColor(_ hex: String) {
        guard let filter = ColorFilter(palette: [hex], tolerance: rememberedColorTolerance) else { return }
        setColorFilter(filter)
        showToast("Filtering by \(filter.summary)", type: .info)
    }

    /// Find Images Matching Palette for the target item.
    func findImagesMatchingPaletteForTarget() {
        guard let item = visualSearchTargetItem else {
            showToast("Select an image or Mood board first", type: .info)
            return
        }
        findImagesMatchingPalette(of: item)
    }

    /// A Mood board searches with its own palette; an image or video with its
    /// dominant colours.
    func findImagesMatchingPalette(of item: FileEntry) {
        guard !item.isDirectory else { return }
        if FileHelpers.isMoodboardFile(item.name) {
            Task {
                guard let board = await ArtOfficialDocumentParser.shared.parse(at: item.url)?.moodboard else {
                    showToast("Couldn't read \"\(item.name)\"", type: .error)
                    return
                }
                let palette = ArtOfficialTextExport.normalizedPalette(board.palette)
                guard !palette.isEmpty else {
                    showToast("This board has no palette", type: .info)
                    return
                }
                findImagesMatchingPalette(Array(palette.prefix(5)), title: "Matching \(item.name) palette")
            }
            return
        }
        guard VisualSearchEligibility.isVisual(item.name) else {
            showToast("Palette search works on images, videos and Mood boards", type: .info)
            return
        }
        let path = item.path
        Task {
            let colors = await VisualIndexService.shared.dominantColors(forPaths: [path])[path] ?? []
            let palette = colors
                .filter { $0.weight >= PaletteMatcher.minimumWeight }
                .prefix(ColorFilter.maxColors)
                .map(\.hex)
            guard !palette.isEmpty else {
                showToast("\"\(item.name)\" hasn't been indexed yet", type: .info)
                return
            }
            findImagesMatchingPalette(Array(palette), title: "Matching \(item.name) colours", reference: path)
        }
    }

    /// Opens a virtual listing ranked by how well files match `palette`.
    func findImagesMatchingPalette(_ palette: [String], title: String? = nil, reference: String? = nil) {
        let colors = palette.compactMap(PaletteColor.normalizedHex)
        guard !colors.isEmpty, let scope = currentVisualScope else { return }
        let tolerance = rememberedColorTolerance
        let scopeText = visualScopeDescription
        Task {
            let hits = await VisualIndexService.shared.colorMatches(
                palette: colors,
                tolerance: tolerance,
                in: scope,
                limit: 300
            )
            var ranked = hits.map(\.path)
            if let reference {
                ranked.removeAll { $0 == reference }
                ranked.insert(reference, at: 0)
            }
            guard !hits.isEmpty else {
                showToast("No images match that palette \(scopeText)", type: .info)
                return
            }
            if !lightboxOpen { similarPage.leave() }
            openVirtualListing(
                VirtualListing(
                    kind: .palette(colors: colors),
                    title: title ?? "Matching \(colors.joined(separator: " "))",
                    paths: ranked
                ),
                selecting: reference
            )
        }
    }

    // MARK: Similar Images groups (inspection only)

    /// The browser listing for one Similar Images group, in the group's own order.
    func similarGroupListing(_ set: SimilarSet) -> VirtualListing {
        let noun = set.kind == .exact ? "Exact Copies" : "Similar Images"
        let first = set.paths.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        return VirtualListing(
            kind: .similarGroup(exact: set.kind == .exact),
            title: "\(noun) · \(first)",
            paths: set.paths
        )
    }

    /// Shows a group as a virtual listing (every file visible), optionally
    /// selecting all of it or one file.
    func openSimilarGroup(_ set: SimilarSet, selecting path: String? = nil, selectAll: Bool = false) {
        openVirtualListing(similarGroupListing(set), selecting: path, selectAll: selectAll)
    }

    func addPaths(_ paths: [String], toCollection collection: FileCollection) {
        guard !paths.isEmpty else { return }
        CollectionService.shared.add(paths: paths, to: collection.id)
        collections = CollectionService.shared.all()
        showToast("Added \(paths.count) file\(paths.count == 1 ? "" : "s") to \"\(collection.name)\"", type: .success)
        if activeCollectionID == collection.id {
            Task { await reloadCollectionContents() }
        }
    }

    func createCollection(named name: String, paths: [String], fallbackName: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let collection = CollectionService.shared.create(name: trimmed.isEmpty ? fallbackName : trimmed, paths: paths)
        collections = CollectionService.shared.all()
        showToast("Created \"\(collection.name)\" with \(paths.count) files", type: .success)
    }

    // MARK: Similarity sort

    /// Sort ▸ Similarity: back to the virtual listing's rank order.
    func restoreVirtualListingRank() {
        guard activeVirtualListing != nil else { return }
        virtualListingRanked = true
    }
}
