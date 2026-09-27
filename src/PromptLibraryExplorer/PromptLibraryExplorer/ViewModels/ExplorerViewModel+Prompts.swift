import AppKit
import Foundation

// MARK: - Prompt workflows: lineage, builder, send to generator, statistics
//
// State lives in PromptWorkflowController; this is the glue between it and
// the browser's selection, listings and search.

extension ExplorerViewModel {
    var promptWorkflows: PromptWorkflowController { PromptWorkflowController.shared }

    /// What prompt commands act on: the Similar Images page's focused card, else the selected files.
    var promptActionTargets: [FileEntry] {
        if let path = similarPageTargetPath { return [similarImages.entry(for: path)] }
        return selectedFileItems
    }

    /// The single file prompt commands act on (first target).
    var promptActionTarget: FileEntry? { promptActionTargets.first }

    // MARK: Lineage

    /// Related files for a lineage chain: two or more targets; else, for one
    /// file, the Similar Images group it's in (page or opened group listing).
    func lineagePaths(for items: [FileEntry]) -> [String] {
        let files = items.filter { !$0.isDirectory }
        if files.count >= 2 { return files.map(\.path) }
        if similarPage.isActive, let set = similarImages.selectedSet, set.paths.count >= 2 {
            return set.paths
        }
        if let listing = activeVirtualListing, case .similarGroup = listing.kind, listing.paths.count >= 2,
           files.isEmpty || listing.paths.contains(files[0].path)
        {
            return listing.paths
        }
        return []
    }

    var canShowPromptLineage: Bool { lineagePaths(for: promptActionTargets).count >= 2 }

    func showPromptLineage(for items: [FileEntry]? = nil) {
        let paths = lineagePaths(for: items ?? promptActionTargets)
        guard paths.count >= 2 else {
            showToast("Select two or more related files (or a Similar Images group) to show their prompt lineage", type: .info)
            return
        }
        let limited = Array(paths.prefix(PromptLineageBuilder.maxSteps))
        if paths.count > limited.count {
            showToast("Showing the first \(limited.count) of \(paths.count) files", type: .info)
        }
        promptWorkflows.lineageRequest = PromptLineageRequest(
            title: "\(limited.count) files",
            paths: limited
        )
    }

    /// Reads prompt, negative prompt and parameters for each path (at most four at once).
    func loadLineageInputs(_ paths: [String]) async -> [PromptLineageInput] {
        var results: [PromptLineageInput?] = Array(repeating: nil, count: paths.count)
        var next = 0
        await withTaskGroup(of: (Int, PromptLineageInput?).self) { group in
            func enqueue() {
                guard next < paths.count else { return }
                let index = next
                let path = paths[index]
                next += 1
                group.addTask { (index, await self.lineageInput(forPath: path)) }
            }
            for _ in 0..<4 { enqueue() }
            while let (index, input) = await group.next() {
                results[index] = input
                if Task.isCancelled { group.cancelAll(); break }
                enqueue()
            }
        }
        return results.compactMap { $0 }
    }

    private func lineageInput(forPath path: String) async -> PromptLineageInput? {
        let url = URL(fileURLWithPath: path)
        guard let item = await Task.detached(priority: .userInitiated, operation: { FileEntry.load(from: url) }).value,
              !item.isDirectory
        else { return nil }
        if FileHelpers.isImageFile(item.name) {
            return await Self.imageLineageInput(item)
        }
        let date = item.creationDate ?? item.modifiedDate
        guard let entry = await promptEntry(for: item) else {
            return PromptLineageInput(path: path, name: item.name, date: date, prompt: "", negative: "", parameters: GenerationParameters())
        }
        return PromptLineageInput(
            path: path, name: item.name, date: date,
            prompt: entry.prompt, negative: entry.blindPrompt ?? "", parameters: entry.promptWorkflowParameters
        )
    }

    /// Metadata only, off the main actor: no preview decode (the view shows cached thumbnails).
    nonisolated private static func imageLineageInput(_ item: FileEntry) async -> PromptLineageInput {
        let url = item.url
        let meta = await ImageMetadataParser.shared.parse(at: url)
        var params = meta.generationParameters
        if params.width == nil || params.height == nil,
           let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        {
            params.width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
            params.height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        }
        return PromptLineageInput(
            path: item.path, name: item.name, date: item.creationDate ?? item.modifiedDate,
            prompt: meta.prompt, negative: meta.negativePrompt ?? "", parameters: params
        )
    }

    // MARK: Builder

    func openPromptBuilder(from item: FileEntry? = nil) {
        guard let item, !item.isDirectory else {
            promptWorkflows.builderRequest = PromptBuilderRequest(draft: PromptDraft(), sourceName: nil)
            return
        }
        Task {
            guard let entry = await entryForPromptAction(item) else {
                showToast("Couldn't read \(item.name)", type: .error)
                return
            }
            promptWorkflows.builderRequest = PromptBuilderRequest(
                draft: PromptBuilderService.draft(from: entry),
                sourceName: item.name
            )
        }
    }

    func openPromptBuilderForTarget() {
        openPromptBuilder(from: promptActionTargets.count == 1 ? promptActionTarget : nil)
    }

    // MARK: Send to generator

    func canSendToGenerator(_ kind: GeneratorKind, item: FileEntry?) -> Bool {
        guard let item, !item.isDirectory else { return false }
        switch kind {
        case .comfyUI: return FileHelpers.isImageFile(item.name)
        case .a1111: return FileHelpers.isImageFile(item.name) || FileHelpers.isPlibFile(item.name) || FileHelpers.isAoeFile(item.name)
        }
    }

    func sendToGenerator(_ kind: GeneratorKind, item: FileEntry) {
        Task {
            guard let entry = await entryForPromptAction(item) else {
                showToast("Couldn't read \(item.name)", type: .error)
                return
            }
            if kind == .comfyUI, entry.comfyPromptJSON == nil, entry.comfyWorkflowJSON == nil {
                showToast("\(item.name) has no embedded ComfyUI graph", type: .info)
                return
            }
            if kind == .a1111, entry.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                showToast("\(item.name) has no prompt to send", type: .info)
                return
            }
            promptWorkflows.generatorRequest = GeneratorSendRequest(
                kind: kind,
                sourcePath: item.path,
                sourceName: item.name,
                prompt: entry.prompt,
                negative: entry.blindPrompt ?? "",
                parameters: entry.promptWorkflowParameters,
                comfyGraphJSON: entry.comfyPromptJSON,
                comfyWorkflowJSON: entry.comfyWorkflowJSON
            )
        }
    }

    func sendTargetToGenerator(_ kind: GeneratorKind) {
        guard let item = promptActionTarget, promptActionTargets.count == 1 else {
            showToast("Select one file to send", type: .info)
            return
        }
        sendToGenerator(kind, item: item)
    }

    /// Settings ▸ Generators (base URLs, Test Connection).
    func openGeneratorSettings() {
        UserDefaults.standard.set(SettingsPage.generators.rawValue, forKey: SettingsView.selectedPageKey)
        openSettings()
    }

    /// The details panel's entry when it's for `item`, else a fresh read.
    private func entryForPromptAction(_ item: FileEntry) async -> PromptEntry? {
        if let entry = selectedPromptEntry, entry.sourcePath == item.path { return entry }
        return await promptEntry(for: item)
    }

    // MARK: Statistics

    func openPromptStatistics(scope: PromptStatisticsScope = .folder) {
        guard explorerRootPath != nil else {
            showToast("Open a folder first", type: .info)
            return
        }
        promptWorkflows.statisticsRequest = PromptStatisticsRequest(scope: selectedFolderPath == nil ? .library : scope)
    }

    /// Rows for `scope`, with ratings and flags. The library scope reads the
    /// search index; the folder scope uses the listing's files, reading any the
    /// index doesn't hold yet.
    func loadPromptStatsRows(scope: PromptStatisticsScope) async -> [PromptStatsRow] {
        var rows: [PromptStatsRow]
        switch scope {
        case .library:
            guard let root = explorerRootPath else { return [] }
            rows = await LibraryIndexService.shared.statsRows(under: root)
        case .folder:
            let files = processedFolderContents.filter { !$0.isDirectory && LibraryIndexService.isIndexable($0.name) }
            let paths = files.map(\.path)
            rows = await LibraryIndexService.shared.statsRows(under: nil, paths: paths)
            let known = Set(rows.map(\.path))
            let missing = files.filter { !known.contains($0.path) }.prefix(3000).map {
                LibraryIndexCandidate(
                    path: $0.path, name: $0.name, folder: $0.url.deletingLastPathComponent().path,
                    mtime: $0.modifiedDate?.timeIntervalSince1970 ?? 0, size: $0.fileSize ?? 0
                )
            }
            if !missing.isEmpty {
                rows += await Task.detached(priority: .userInitiated) {
                    var extra: [PromptStatsRow] = []
                    for candidate in missing {
                        if Task.isCancelled { break }
                        let record = await LibraryIndexExtractor.record(for: candidate)
                        extra.append(PromptStatsRow(
                            path: record.path,
                            date: record.mtime > 0 ? Date(timeIntervalSince1970: record.mtime) : nil,
                            prompt: record.prompt,
                            model: record.parameters.model,
                            sampler: record.parameters.sampler,
                            steps: record.parameters.steps,
                            cfg: record.parameters.cfg
                        ))
                    }
                    return extra
                }.value
            }
        }
        for index in rows.indices {
            rows[index].rating = rating(for: rows[index].path)
            rows[index].flag = flag(for: rows[index].path).rawValue
        }
        return rows
    }

    /// Statistics click-through: a word or phrase opens Find in Library for it.
    func searchLibrary(forPhrase phrase: String) {
        let text = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        promptWorkflows.statisticsRequest = nil
        librarySearchQuery = text.contains(" ") ? "\"\(text)\"" : text
        Task { @MainActor in
            // Let the statistics sheet finish closing before the next sheet opens.
            try? await Task.sleep(for: .milliseconds(350))
            librarySearchOpen = true
            runLibrarySearch()
        }
    }

    /// Statistics click-through: lists `paths` (a model's or sampler's files) in the browser.
    func showPromptStatsListing(title: String, paths: [String]) {
        guard !paths.isEmpty else { return }
        promptWorkflows.statisticsRequest = nil
        let limit = 5000
        if paths.count > limit { showToast("Listing the newest \(limit) of \(paths.count) files", type: .info) }
        openVirtualListing(VirtualListing(kind: .similarGroup(exact: false), title: title, paths: Array(paths.prefix(limit))))
    }
}
