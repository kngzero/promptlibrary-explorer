import AppKit
import ArtOfficialFormats
import Foundation
import UniformTypeIdentifiers

/// Progress of a Send to Mood / Send to Story build.
struct ArtOfficialSendProgress: Equatable {
    let title: String
    var done: Int
    let total: Int
}

enum ArtOfficialSendTarget {
    case mood
    case story

    var kind: ArtOfficialDocument.Kind {
        switch self {
        case .mood: return .moodboard
        case .story: return .story
        }
    }

    var fileKind: ArtOfficialFileKind {
        switch self {
        case .mood: return .moodboard
        case .story: return .story
        }
    }

    var documentNoun: String {
        switch self {
        case .mood: return "mood board"
        case .story: return "story project"
        }
    }
}

// MARK: - Art Official document actions

extension ExplorerViewModel {
    /// The single selected file when it is a Mood board or Story project.
    var selectedArtOfficialItem: FileEntry? {
        let files = selectedFileItems
        guard files.count == 1, let item = files.first,
              FileHelpers.isArtOfficialDocumentFile(item.name) else { return nil }
        return item
    }

    static func artOfficialKind(forName name: String) -> ArtOfficialDocument.Kind? {
        if FileHelpers.isMoodboardFile(name) { return .moodboard }
        if FileHelpers.isStoryFile(name) { return .story }
        return nil
    }

    /// Opens the file in Mood / Story (by bundle id). Toast when the app isn't installed.
    func openInOwnerApp(_ item: FileEntry) {
        guard let kind = Self.artOfficialKind(forName: item.name) else { return }
        openInOwnerApp(url: item.url, kind: kind)
    }

    func openInOwnerApp(url: URL, kind: ArtOfficialDocument.Kind) {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: kind.ownerBundleID) else {
            showToast("\(kind.ownerAppName) isn't installed on this Mac", type: .info)
            return
        }
        let appName = kind.ownerAppName
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in
                self?.showToast("Couldn't open in \(appName): \(error.localizedDescription)", type: .error)
            }
        }
    }

    /// Extract Images… (Mood) / Extract Shot Thumbnails… (Story; `projectID` nil = every project).
    func extractEmbeddedImages(from item: FileEntry, projectID: String? = nil) {
        guard let kind = Self.artOfficialKind(forName: item.name) else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Extract"
        panel.message = kind == .moodboard
            ? "Choose a folder for the images in \"\(item.name)\"."
            : "Choose a folder for the shot thumbnails in \"\(item.name)\"."
        panel.directoryURL = item.url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        Task {
            guard let document = await ArtOfficialDocumentParser.shared.parse(at: item.url) else {
                showToast("Couldn't read \"\(item.name)\"", type: .error)
                return
            }
            let result = await Task.detached(priority: .userInitiated) { () -> ArtOfficialExtraction.Result in
                switch document {
                case .moodboard(let board):
                    return ArtOfficialExtraction.extractImages(from: board, to: folder)
                case .story(let story):
                    var total = ArtOfficialExtraction.Result()
                    for project in story.projects where projectID == nil || project.id == projectID {
                        let r = ArtOfficialExtraction.extractShotThumbnails(from: project, to: folder)
                        total.written += r.written
                        total.skipped += r.skipped
                    }
                    return total
                }
            }.value

            let noun = kind == .moodboard ? "image" : "thumbnail"
            if result.written == 0 {
                showToast(result.skipped > 0
                    ? "No \(noun)s could be extracted (\(result.skipped) not embedded)"
                    : "No embedded \(noun)s to extract", type: .info)
                return
            }
            var message = "Extracted \(result.written) \(noun)\(result.written == 1 ? "" : "s")"
            if result.skipped > 0 { message += " (\(result.skipped) not embedded)" }
            showToast(message, type: .success)
            await refreshIfShowing(folder)
        }
    }

    /// Export Board as PNG… (Mood) / Export Contact Sheet… (Story).
    func exportRenderedImage(of item: FileEntry, projectID: String? = nil) {
        guard let kind = Self.artOfficialKind(forName: item.name) else { return }
        let base = (item.name as NSString).deletingPathExtension
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = kind == .moodboard ? "\(base).png" : "\(base) Contact Sheet.png"
        panel.directoryURL = item.url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        Task {
            guard let document = await ArtOfficialDocumentParser.shared.parse(at: item.url) else {
                showToast("Couldn't read \"\(item.name)\"", type: .error)
                return
            }
            let written = await Task.detached(priority: .userInitiated) { () -> Bool in
                let image: CGImage?
                switch document {
                case .moodboard(let board):
                    image = ArtOfficialRenderer.renderMoodboard(board, maxPixelSize: 4096)
                case .story(let story):
                    let project = story.projects.first(where: { $0.id == projectID }) ?? story.defaultProject
                    image = project.flatMap { ArtOfficialRenderer.renderStoryContactSheet($0, maxPixelSize: 2400) }
                }
                guard let image, let data = ArtOfficialRendering.pngData(image) else { return false }
                return (try? data.write(to: destination, options: .atomic)) != nil
            }.value
            if written {
                showToast(kind == .moodboard ? "Board exported" : "Contact sheet exported", type: .success)
                await refreshIfShowing(destination.deletingLastPathComponent())
            } else {
                showToast("Couldn't export \"\(item.name)\"", type: .error)
            }
        }
    }

    /// Copy Shot List ▸ Text / CSV.
    func copyShotList(of item: FileEntry, format: ShotListFormat, projectID: String? = nil) {
        Task {
            guard let story = await ArtOfficialDocumentParser.shared.parse(at: item.url)?.story,
                  let project = story.projects.first(where: { $0.id == projectID }) ?? story.defaultProject
            else {
                showToast("Couldn't read \"\(item.name)\"", type: .error)
                return
            }
            ClipboardService.copyString(ArtOfficialTextExport.shotList(project, as: format))
            showToast("Shot list copied as \(format.title)", type: .success)
        }
    }

    /// Copy Palette ▸ HEX / CSS / JSON for a board file.
    func copyPalette(of item: FileEntry, format: PaletteCopyFormat) {
        Task {
            guard let board = await ArtOfficialDocumentParser.shared.parse(at: item.url)?.moodboard else {
                showToast("Couldn't read \"\(item.name)\"", type: .error)
                return
            }
            copyPalette(board.palette, format: format)
        }
    }

    func copyPalette(_ palette: [String], format: PaletteCopyFormat) {
        guard !ArtOfficialTextExport.normalizedPalette(palette).isEmpty else {
            showToast("This board has no palette", type: .info)
            return
        }
        ClipboardService.copyString(ArtOfficialTextExport.palette(palette, as: format))
        showToast("Palette copied as \(format.title)", type: .success)
    }

    /// Re-reads the listing when `folder` is the folder on screen, so new files appear.
    private func refreshIfShowing(_ folder: URL) async {
        guard activeCollectionID == nil,
              let current = selectedFolderPath?.standardizedFileURL.path,
              current == folder.standardizedFileURL.path
        else { return }
        await refreshFolder()
    }
}

// MARK: - Send to Mood / Send to Story

extension ExplorerViewModel {
    /// The files Send to acts on: the selection, else the whole listing (folder or
    /// collection), in display order.
    var sendToSourceItems: [FileEntry] {
        let selected = selectedFileItems
        if !selected.isEmpty { return selected }
        return processedFolderContents.filter { !$0.isDirectory }
    }

    var canSendToArtOfficial: Bool {
        artOfficialSendProgress == nil
            && sendToSourceItems.contains(where: { ArtOfficialSendBuilder.isSendable($0.name) })
    }

    /// File ▸ Send to Mood… / Send to Story… and the grid context menu.
    func sendToArtOfficial(_ target: ArtOfficialSendTarget) {
        let title = ArtOfficialSendBuilder.defaultTitle(
            activeCollection?.name ?? selectedFolderPath?.lastPathComponent,
            fallback: target == .mood ? "Mood Board" : "Story"
        )
        send(sendToSourceItems, title: title, to: target)
    }

    /// Collection sidebar row ▸ Send to Mood… / Send to Story… (collection order).
    func sendCollection(_ id: UUID, to target: ArtOfficialSendTarget) {
        guard let collection = collections.first(where: { $0.id == id }) else { return }
        let paths = collection.paths
        Task {
            let entries = await Task.detached(priority: .userInitiated) {
                paths.compactMap { FileEntry.load(from: URL(fileURLWithPath: $0)) }
            }.value
            send(entries.filter { !$0.isDirectory }, title: collection.name, to: target)
        }
    }

    private func send(_ items: [FileEntry], title: String, to target: ArtOfficialSendTarget) {
        guard artOfficialSendProgress == nil else {
            showToast("Already building a \(target.documentNoun)", type: .info)
            return
        }
        let images = items.filter { ArtOfficialSendBuilder.isSendable($0.name) }
        let nonImageCount = items.count - images.count
        guard !images.isEmpty else {
            showToast("Select images to send to \(target.kind.ownerAppName)", type: .info)
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [target.fileKind.utType]
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true
        panel.title = target == .mood ? "Send to Mood" : "Send to Story"
        panel.message = "\(images.count) image\(images.count == 1 ? "" : "s") will go into the new \(target.documentNoun)."
        panel.nameFieldStringValue = ArtOfficialSendBuilder.suggestedFileName(
            title: title,
            fileExtension: target.fileKind.fileExtension
        )
        if activeCollectionID == nil, let folder = selectedFolderPath {
            panel.directoryURL = folder
        }
        guard panel.runModal() == .OK, var destination = panel.url else { return }
        if destination.pathExtension.lowercased() != target.fileKind.fileExtension {
            destination.appendPathExtension(target.fileKind.fileExtension)
        }

        artOfficialSendProgress = ArtOfficialSendProgress(
            title: target == .mood ? "Building mood board" : "Building story project",
            done: 0,
            total: images.count
        )

        Task {
            // Story shots carry the prompt and tags the app knows for each file.
            var sendItems: [ArtOfficialSendItem] = []
            for item in images {
                var sendItem = ArtOfficialSendItem(url: item.url)
                if target == .story {
                    if let prompt = promptTextByPath[item.path], !prompt.isEmpty {
                        sendItem.prompt = prompt
                    } else {
                        sendItem.prompt = await Self.parsePromptData(for: item).prompt ?? ""
                    }
                    sendItem.tags = tagsForFile(at: item.path).map(\.name)
                }
                sendItems.append(sendItem)
            }

            let progress: ArtOfficialSendBuilder.Progress = { [weak self] done, _ in
                Task { @MainActor in self?.artOfficialSendProgress?.done = done }
            }
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<(added: Int, skipped: [String]), Error> in
                do {
                    switch target {
                    case .mood:
                        let built = ArtOfficialSendBuilder.moodboardDraft(title: title, items: sendItems, progress: progress)
                        guard built.addedCount > 0 else { return .success((0, built.skippedNames)) }
                        try MoodboardWriter.write(built.draft, to: destination)
                        return .success((built.addedCount, built.skippedNames))
                    case .story:
                        let built = ArtOfficialSendBuilder.storyDraft(title: title, items: sendItems, progress: progress)
                        guard built.addedCount > 0 else { return .success((0, built.skippedNames)) }
                        try StoryWriter.write(built.draft, to: destination)
                        return .success((built.addedCount, built.skippedNames))
                    }
                } catch {
                    return .failure(error)
                }
            }.value
            artOfficialSendProgress = nil

            switch outcome {
            case .failure(let error):
                showToast("Couldn't write \(destination.lastPathComponent): \(error.localizedDescription)", type: .error)
            case .success(let result) where result.added == 0:
                showToast("None of the images could be read", type: .error)
            case .success(let result):
                await refreshIfShowing(destination.deletingLastPathComponent())
                presentSendCompletion(
                    target: target,
                    destination: destination,
                    added: result.added,
                    skippedUnreadable: result.skipped.count,
                    skippedNonImages: nonImageCount
                )
            }
        }
    }

    private func presentSendCompletion(
        target: ArtOfficialSendTarget,
        destination: URL,
        added: Int,
        skippedUnreadable: Int,
        skippedNonImages: Int
    ) {
        let alert = NSAlert()
        alert.messageText = target == .mood ? "Mood Board Created" : "Story Project Created"
        let unit = target == .mood ? "image" : "shot"
        var info = "\"\(destination.lastPathComponent)\" has \(added) \(unit)\(added == 1 ? "" : "s")."
        if skippedNonImages > 0 {
            info += " \(skippedNonImages) item\(skippedNonImages == 1 ? " was" : "s were") skipped because only images can be sent."
        }
        if skippedUnreadable > 0 {
            info += " \(skippedUnreadable) image\(skippedUnreadable == 1 ? "" : "s") couldn't be read."
        }
        alert.informativeText = info
        alert.addButton(withTitle: "Open in \(target.kind.ownerAppName)")
        alert.addButton(withTitle: "Reveal in Finder")
        alert.addButton(withTitle: "Done")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            openInOwnerApp(url: destination, kind: target.kind)
        case .alertSecondButtonReturn:
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        default:
            break
        }
    }
}
