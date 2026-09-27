import AppKit
import Foundation

/// Headless actions behind the App Intents (Shortcuts) and the `promptlibrary://`
/// URL scheme. Uses the services directly, so an intent works while the app has no
/// window; when the browser's view model exists it is kept in step (collections,
/// navigation).
@MainActor
enum PromptLibraryAutomation {
    /// Set by the App file once the main window's view model exists.
    static weak var viewModel: ExplorerViewModel?

    enum Failure: LocalizedError, Equatable {
        case noFiles
        case notFound(String)
        case unknownCollection(String)
        case unknownPreset(String)
        case needsDestination(String)
        case wouldReplace(Int)
        case exportRunning
        case noWindow

        var errorDescription: String? {
            switch self {
            case .noFiles:
                return "No files were given."
            case .notFound(let path):
                return "\u{201C}\(path)\u{201D} doesn't exist."
            case .unknownCollection(let name):
                return "There's no collection named \u{201C}\(name)\u{201D}."
            case .unknownPreset(let name):
                return "There's no export preset named \u{201C}\(name)\u{201D}."
            case .needsDestination(let preset):
                return "The preset \u{201C}\(preset)\u{201D} asks for a folder each time; choose a Destination Folder in the action."
            case .wouldReplace(let count):
                return "\(count) exported file\(count == 1 ? " has" : "s have") the name of an existing file. Change the preset's collision rule, or export from the app, which asks before replacing."
            case .exportRunning:
                return "An export is already running in PromptLibrary Explorer."
            case .noWindow:
                return "PromptLibrary Explorer has no window open."
            }
        }
    }

    // MARK: Search

    /// Library search (the persistent index, every library root); existing files only.
    static func search(_ query: String, limit: Int = 50) async -> [URL] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let hits = await LibraryIndexService.shared.search(trimmed, under: nil, limit: max(1, min(limit, 500)))
        return hits
            .map { URL(fileURLWithPath: $0.path) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: Collections

    static var collectionNames: [String] {
        CollectionService.shared.all().map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Adds the files (not folders) to the named collection, creating it when asked.
    /// Returns the collection's name and how many files were added.
    static func addFiles(_ urls: [URL], toCollectionNamed name: String, createIfMissing: Bool) throws -> (name: String, added: Int) {
        let paths = urls.map(\.standardizedFileURL).filter { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }.map(\.path)
        guard !paths.isEmpty else { throw Failure.noFiles }
        let service = CollectionService.shared
        let collections = service.all()
        let id: UUID
        let resolvedName: String
        if let match = AutomationCollectionMatcher.match(name, in: collections.map { (id: $0.id, name: $0.name) }) {
            id = match
            resolvedName = collections.first(where: { $0.id == match })?.name ?? name
            service.add(paths: paths, to: id)
        } else if createIfMissing {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw Failure.unknownCollection(name) }
            let created = service.create(name: trimmed, paths: paths)
            id = created.id
            resolvedName = created.name
        } else {
            throw Failure.unknownCollection(name)
        }
        if let vm = viewModel {
            vm.collections = service.all()
            if vm.activeCollectionID == id { Task { await vm.refreshFolder() } }
        }
        return (resolvedName, paths.count)
    }

    // MARK: Export

    static var presetNames: [String] {
        ExportPresetStore.shared.presets.map(\.name)
    }

    static func preset(named name: String) -> ExportPreset? {
        let presets = ExportPresetStore.shared.presets
        if let exact = presets.first(where: { $0.name == name }) { return exact }
        return presets.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Exports copies with `preset` (originals are never modified). `destination`
    /// overrides the preset's folder; it's required when the preset asks each time.
    /// Refuses to replace existing files (the app's sheet asks first; an automation can't).
    static func export(_ urls: [URL], preset: ExportPreset, destination: URL?) async throws -> [URL] {
        let sources = urls.map(\.standardizedFileURL).filter { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
        guard !sources.isEmpty else { throw Failure.noFiles }
        guard !ExportController.shared.isRunning else { throw Failure.exportRunning }
        var effective = preset
        if let destination {
            effective.destination = .fixedFolder
            effective.fixedFolderPath = destination.standardizedFileURL.path
        } else if preset.destination == .ask
                    || (preset.destination == .fixedFolder && (preset.fixedFolderPath?.isEmpty ?? true)) {
            throw Failure.needsDestination(preset.name)
        }
        let items = sources.map { url in
            let entry = FileEntry.load(from: url)
            return ExportSourceItem(url: url, modifiedDate: entry?.modifiedDate, fileSize: entry?.fileSize)
        }
        let finalPreset = effective
        let completed = await ExportController.completingTemplateData(items, template: finalPreset.filenameTemplate)
        let jobs = await Task.detached(priority: .userInitiated) {
            ExportJobPlanner.plan(items: completed, preset: finalPreset, chosenFolder: nil)
        }.value
        let replacing = jobs.filter { $0.action == .overwrite && $0.kind != .unsupported }
        guard replacing.isEmpty else { throw Failure.wouldReplace(replacing.count) }
        let summary = await Task.detached(priority: .userInitiated) {
            await ExportEngine.run(items: jobs, preset: finalPreset, progress: { _, _, _ in })
        }.value
        let written = summary.written.compactMap(\.destination)
        if let vm = viewModel {
            vm.refreshAfterExport(folders: Set(written.map { $0.deletingLastPathComponent().standardizedFileURL.path }))
        }
        return written
    }

    /// Export for Sharing: the built-in preset that strips AI metadata from copies.
    static func stripAIMetadata(_ urls: [URL], destination: URL?) async throws -> [URL] {
        try await export(urls, preset: ExportPresetStore.shared.sharingPreset, destination: destination)
    }

    // MARK: Prompt

    /// The file's positive prompt (empty when it has none, or it's online-only).
    static func prompt(of url: URL) async -> String {
        let entry = FileEntry(url: url.standardizedFileURL, isDirectory: false)
        let parsed = await ExplorerViewModel.parsePromptData(for: entry)
        return parsed.prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: Navigation (needs the window)

    /// Folder → opened as the library root; file → its folder with it selected.
    static func open(_ url: URL) async throws {
        let target = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: target.path) else { throw Failure.notFound(target.path) }
        guard let vm = viewModel else { throw Failure.noWindow }
        NSApp.activate(ignoringOtherApps: true)
        await vm.openExternalURLs([target])
    }
}
