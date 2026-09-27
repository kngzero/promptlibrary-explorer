import AppKit
import Foundation
import ImageIO
import Observation

// MARK: - Requests

/// A file handed to the export sheet, with what the name template may need.
struct ExportSourceItem: Sendable, Hashable {
    var url: URL
    var modifiedDate: Date?
    var fileSize: Int64?
    var prompt: String?
    var parameters = GenerationParameters()
}

/// Opens the export sheet (`ExportController.exportRequest`).
struct ExportRequest: Identifiable {
    let id = UUID()
    var items: [ExportSourceItem]
    /// "12 selected files", "Collection “Portfolio”"…
    var sourceDescription: String
    var presetID: UUID?
}

/// Opens the contact-sheet sheet (`ExportController.contactSheetRequest`).
struct ContactSheetRequest: Identifiable {
    let id = UUID()
    var items: [ContactSheetItem]
    var sourceDescription: String
    var suggestedTitle: String
}

struct ExportProgress: Equatable {
    var title: String
    var done: Int
    var total: Int
    var currentName: String
}

/// What the export sheet shows before anything runs.
struct ExportPreview: Equatable {
    struct Sample: Equatable, Hashable {
        var source: String
        var output: String
        var action: ExportWriteAction
    }

    var imageCount = 0
    var mediaCount = 0
    var documentCount = 0
    var unsupportedCount = 0
    var estimatedBytes: Int64 = 0
    var samples: [Sample] = []
    var overwriteCount = 0
    var skipCount = 0
    /// False when the destination is chosen at export time (collisions unknown yet).
    var destinationKnown = true
    var destinationDescription = ""
    var notes: [String] = []

    var exportableCount: Int {
        imageCount + mediaCount + documentCount
    }
}

// MARK: - Planning

/// Turns sources + a preset into concrete jobs. Pure (file-system reads are injected).
enum ExportJobPlanner {
    /// The output format and extension for one source.
    static func output(for url: URL, kind: ExportItemKind, preset: ExportPreset) -> (format: ExportFormat?, ext: String) {
        let sourceExt = url.pathExtension
        switch kind {
        case .image:
            let format = preset.format.resolved(forSourceExtension: sourceExt)
            let sameAsSource = ExportFormat.keepOriginal.resolved(forSourceExtension: sourceExt) == format
                && ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "webp"].contains(sourceExt.lowercased())
            return (format, sameAsSource ? sourceExt.lowercased() : (format.fileExtension ?? "png"))
        case .document:
            let format: ExportFormat = preset.format == .keepOriginal || !preset.format.isAvailable ? .png : preset.format
            return (format, format.fileExtension ?? "png")
        case .video, .audio, .unsupported:
            return (nil, sourceExt)
        }
    }

    static func sanitizedSubfolderName(_ name: String) -> String {
        let cleaned = RenameTemplateService.sanitize(name)
        return cleaned.isEmpty ? "Exports" : cleaned
    }

    /// Destination folder for a source, given the preset and (for Ask) the chosen folder.
    static func folder(for source: URL, preset: ExportPreset, chosenFolder: URL?) -> URL? {
        switch preset.destination {
        case .ask:
            return chosenFolder
        case .fixedFolder:
            guard let path = preset.fixedFolderPath, !path.isEmpty else { return chosenFolder }
            return URL(fileURLWithPath: path, isDirectory: true)
        case .subfolder:
            return source.deletingLastPathComponent()
                .appendingPathComponent(sanitizedSubfolderName(preset.subfolderName), isDirectory: true)
        }
    }

    static func plan(
        items: [ExportSourceItem],
        preset: ExportPreset,
        chosenFolder: URL?,
        existingNames: (URL) -> Set<String> = ExportNamePlanner.existingNames(in:)
    ) -> [ExportJobItem] {
        var requests: [ExportNameRequest] = []
        var kinds: [ExportItemKind] = []
        var formats: [ExportFormat?] = []
        let placeholder = FileManager.default.temporaryDirectory.appendingPathComponent("plx-export-preview", isDirectory: true)
        for (index, item) in items.enumerated() {
            let kind = ExportItemKind.classify(item.url)
            let output = output(for: item.url, kind: kind, preset: preset)
            let folder = folder(for: item.url, preset: preset, chosenFolder: chosenFolder) ?? placeholder
            let params = item.parameters
            let context = RenameTemplateContext(
                url: item.url, index: index, modifiedDate: item.modifiedDate, prompt: item.prompt,
                model: params.model, seed: params.seed, sampler: params.sampler, steps: params.steps,
                cfg: params.cfg, width: params.width, height: params.height
            )
            requests.append(ExportNameRequest(source: item.url, context: context, outputExtension: output.ext, folder: folder))
            kinds.append(kind)
            formats.append(output.format)
        }
        let names = ExportNamePlanner.plan(
            template: preset.filenameTemplate,
            requests: requests,
            collision: preset.collision,
            existingNames: existingNames
        )
        return zip(names.indices, names).map { index, name in
            ExportJobItem(
                source: name.source, kind: kinds[index], destination: name.destination,
                action: kinds[index] == .unsupported ? .skip : name.action, format: formats[index]
            )
        }
    }

    /// Counts, sample names and a size estimate. Reads image headers (no decoding); for
    /// big batches the estimate is extrapolated from the first `sampleLimit` images.
    static func preview(
        items: [ExportSourceItem],
        preset: ExportPreset,
        chosenFolder: URL?,
        sampleLimit: Int = 400,
        existingNames: (URL) -> Set<String> = ExportNamePlanner.existingNames(in:)
    ) -> ExportPreview {
        var preview = ExportPreview()
        let destinationKnown = preset.destination != .ask || chosenFolder != nil
            || (preset.destination == .fixedFolder && preset.fixedFolderPath?.isEmpty == false)
        preview.destinationKnown = destinationKnown
        let jobs = plan(items: items, preset: preset, chosenFolder: chosenFolder, existingNames: destinationKnown ? existingNames : { _ in [] })

        var estimatedImages = 0
        var imageBytes: Int64 = 0
        for (item, job) in zip(items, jobs) {
            switch job.kind {
            case .image: preview.imageCount += 1
            case .video, .audio: preview.mediaCount += 1
            case .document: preview.documentCount += 1
            case .unsupported: preview.unsupportedCount += 1
            }
            if job.kind != .unsupported {
                if job.action == .overwrite { preview.overwriteCount += 1 }
                if job.action == .skip { preview.skipCount += 1 }
            }
            let sourceBytes = item.fileSize ?? ((try? item.url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0)
            switch job.kind {
            case .image where estimatedImages < sampleLimit:
                estimatedImages += 1
                imageBytes += estimate(item.url, sourceBytes: sourceBytes, format: job.format ?? .png, preset: preset)
            case .video, .audio:
                preview.estimatedBytes += sourceBytes
            case .document where preset.exportRenderedDocuments:
                preview.estimatedBytes += 3_000_000
            default:
                break
            }
            if preview.samples.count < 6, job.kind != .unsupported, !(job.kind == .document && !preset.exportRenderedDocuments) {
                preview.samples.append(.init(source: item.url.lastPathComponent, output: job.destination.lastPathComponent, action: job.action))
            }
        }
        if estimatedImages > 0 {
            let perImage = Double(imageBytes) / Double(estimatedImages)
            preview.estimatedBytes += Int64(perImage * Double(preview.imageCount))
        }

        switch preset.destination {
        case .ask:
            preview.destinationDescription = chosenFolder.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "A folder you choose when you export"
        case .fixedFolder:
            preview.destinationDescription = preset.fixedFolderPath.map { ($0 as NSString).abbreviatingWithTildeInPath }
                ?? "A folder you choose when you export (no fixed folder set)"
        case .subfolder:
            preview.destinationDescription = "“\(sanitizedSubfolderName(preset.subfolderName))” next to each original"
        }

        if preview.documentCount > 0 {
            preview.notes.append(preset.exportRenderedDocuments
                ? "\(preview.documentCount) Mood, Story, .plib or .aoe file\(preview.documentCount == 1 ? "" : "s") will be exported as rendered images."
                : "\(preview.documentCount) Mood, Story, .plib or .aoe file\(preview.documentCount == 1 ? "" : "s") will be skipped (turn on “Export rendered previews” to include them).")
        }
        if preview.mediaCount > 0 {
            preview.notes.append(preset.stripMediaMetadata
                ? "Videos and audio are re-wrapped without metadata where possible (no re-encoding); other formats are copied as they are."
                : "Videos and audio are copied as they are.")
        }
        if preview.unsupportedCount > 0 {
            preview.notes.append("\(preview.unsupportedCount) file\(preview.unsupportedCount == 1 ? "" : "s") of other types will be skipped.")
        }
        if preset.format == .webp, !ExportFormat.webp.isAvailable {
            preview.notes.append("This Mac can't write WebP; images will be written as PNG.")
        }
        return preview
    }

    private static func estimate(_ url: URL, sourceBytes: Int64, format: ExportFormat, preset: ExportPreset) -> Int64 {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let size = ExportImageRenderer.orientedSize(of: source)
        else { return sourceBytes }
        let plan = ExportGeometry.plan(sourceWidth: size.width, sourceHeight: size.height, sizing: preset.sizing)
        let sourceFormat = ExportFormat.keepOriginal.resolved(forSourceExtension: url.pathExtension)
        let sameFormat = (CGImageSourceGetType(source) as String?) == format.utType?.identifier
        let reencodes = !sameFormat || plan.changesPixels || preset.watermark.isActive
        return ExportEstimator.estimatedBytes(
            sourceBytes: sourceBytes,
            sourcePixels: size.width * size.height,
            outputPixels: plan.outputWidth * plan.outputHeight,
            sourceFormat: sourceFormat,
            outputFormat: format,
            quality: preset.quality,
            reencodes: reencodes
        )
    }
}

// MARK: - Controller

/// Owns the export and contact-sheet sheets and the running job. Views and the view
/// model's `+Export` glue talk to this instead of adding state to the view model.
@MainActor @Observable
final class ExportController {
    static let shared = ExportController()

    let store: ExportPresetStore
    var exportRequest: ExportRequest?
    var contactSheetRequest: ContactSheetRequest?
    private(set) var progress: ExportProgress?

    var contactSheetOptions: ContactSheetOptions {
        didSet { persistContactSheetOptions() }
    }

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults
    static let contactSheetOptionsKey = "export.contactSheetOptions"
    static let lastPresetKey = "export.lastPresetID"

    init(store: ExportPresetStore? = nil, defaults: UserDefaults = .standard) {
        self.store = store ?? .shared
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.contactSheetOptionsKey),
           let options = try? JSONDecoder().decode(ContactSheetOptions.self, from: data)
        {
            contactSheetOptions = options
        } else {
            contactSheetOptions = ContactSheetOptions()
        }
    }

    var isRunning: Bool { progress != nil }
    var isPresenting: Bool { exportRequest != nil || contactSheetRequest != nil }

    var lastPresetID: UUID? {
        get { defaults.string(forKey: Self.lastPresetKey).flatMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue?.uuidString, forKey: Self.lastPresetKey) }
    }

    private func persistContactSheetOptions() {
        if let data = try? JSONEncoder().encode(contactSheetOptions) {
            defaults.set(data, forKey: Self.contactSheetOptionsKey)
        }
    }

    func cancel() {
        task?.cancel()
    }

    // MARK: Export

    /// Fills in prompt / parameters for sources that lack them, when the template needs them.
    static func completingTemplateData(_ items: [ExportSourceItem], template: String) async -> [ExportSourceItem] {
        guard RenameTemplateService.usesAnyToken(RenameTemplateService.parsedDataTokens, in: template) else { return items }
        var result = items
        for index in result.indices where result[index].prompt == nil && result[index].parameters == GenerationParameters() {
            let entry = FileEntry(url: result[index].url, isDirectory: false)
            let parsed = await ExplorerViewModel.parsePromptData(for: entry)
            result[index].prompt = parsed.prompt
            result[index].parameters = parsed.parameters
        }
        return result
    }

    /// Runs the export. Asks for a folder when the preset says so (or has none set) and
    /// confirms replacements. `completion` gets nil when the user backed out.
    func runExport(_ request: ExportRequest, preset: ExportPreset, completion: @escaping (ExportRunSummary?) -> Void) {
        guard !isRunning else { return }
        var chosenFolder: URL?
        let needsFolder = preset.destination == .ask
            || (preset.destination == .fixedFolder && (preset.fixedFolderPath?.isEmpty ?? true))
        if needsFolder {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "Export"
            panel.message = "Choose a folder for the exported files."
            panel.directoryURL = request.items.first?.url.deletingLastPathComponent()
            guard panel.runModal() == .OK, let url = panel.url else {
                completion(nil)
                return
            }
            chosenFolder = url
        } else if preset.destination == .fixedFolder, let path = preset.fixedFolderPath {
            chosenFolder = URL(fileURLWithPath: path, isDirectory: true)
        }

        progress = ExportProgress(title: "Preparing…", done: 0, total: request.items.count, currentName: "")
        let folder = chosenFolder
        task = Task { [weak self] in
            let items = await Self.completingTemplateData(request.items, template: preset.filenameTemplate)
            let jobs = await Task.detached(priority: .userInitiated) {
                ExportJobPlanner.plan(items: items, preset: preset, chosenFolder: folder)
            }.value
            guard let self else { return }
            if Task.isCancelled {
                self.progress = nil
                self.task = nil
                completion(ExportRunSummary(results: [], cancelled: true))
                return
            }

            let overwriting = jobs.filter { $0.action == .overwrite && $0.kind != .unsupported }
            if !overwriting.isEmpty, !Self.confirmOverwrite(count: overwriting.count) {
                self.progress = nil
                completion(nil)
                return
            }
            self.progress = ExportProgress(title: "Exporting", done: 0, total: jobs.count, currentName: "")
            let report: ExportEngine.Progress = { [weak self] done, total, name in
                Task { @MainActor in
                    guard self?.progress != nil else { return }
                    self?.progress = ExportProgress(title: "Exporting", done: done, total: total, currentName: name)
                }
            }
            let worker = Task.detached(priority: .userInitiated) {
                await ExportEngine.run(items: jobs, preset: preset, progress: report)
            }
            let summary = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            self.progress = nil
            self.task = nil
            completion(summary)
        }
    }

    private static func confirmOverwrite(count: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Replace \(count) Existing File\(count == 1 ? "" : "s")?"
        alert.informativeText = "\(count) exported file\(count == 1 ? " has" : "s have") the same name as a file already in the destination. The existing file\(count == 1 ? "" : "s") will be moved to the Trash. Originals being exported are never replaced."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// The completion alert: counts, anything skipped or noted, Reveal in Finder.
    func presentCompletion(_ summary: ExportRunSummary) {
        let alert = NSAlert()
        let written = summary.written.count
        alert.messageText = summary.cancelled
            ? "Export Cancelled"
            : (written == 0 ? "Nothing Was Exported" : "Exported \(written) File\(written == 1 ? "" : "s")")
        var lines: [String] = []
        if summary.cancelled { lines.append("\(written) file\(written == 1 ? " was" : "s were") exported before you cancelled.") }
        let skipped = summary.skipped.filter { $0.outcome != .skipped("cancelled") }
        if !skipped.isEmpty {
            lines.append("Skipped \(skipped.count):")
            lines += Self.describe(skipped) { if case .skipped(let why) = $0.outcome { return why } else { return "" } }
        }
        if !summary.failed.isEmpty {
            lines.append("Failed \(summary.failed.count):")
            lines += Self.describe(summary.failed) { if case .failed(let why) = $0.outcome { return why } else { return "" } }
        }
        let noted = summary.written.filter { $0.note != nil }
        if !noted.isEmpty {
            lines.append("Notes:")
            lines += Self.describe(noted) { $0.note ?? "" }
        }
        lines.append("Your original files were not changed.")
        alert.informativeText = lines.joined(separator: "\n")
        let revealable = summary.written.compactMap(\.destination)
        if !revealable.isEmpty { alert.addButton(withTitle: "Reveal in Finder") }
        alert.addButton(withTitle: "Done")
        if alert.runModal() == .alertFirstButtonReturn, !revealable.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(Array(revealable.prefix(200)))
        }
    }

    /// Up to five "name — reason" lines, then "…and N more".
    private static func describe(_ results: [ExportItemResult], reason: (ExportItemResult) -> String) -> [String] {
        var lines = results.prefix(5).map { "• \($0.source.lastPathComponent) — \(reason($0))" }
        if results.count > 5 { lines.append("• …and \(results.count - 5) more") }
        return lines
    }

    // MARK: Contact sheet

    func runContactSheet(_ request: ContactSheetRequest, options: ContactSheetOptions, completion: @escaping (URL?) -> Void) {
        guard !isRunning else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.title = "Export Contact Sheet"
        let base = options.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? request.suggestedTitle : options.title
        panel.nameFieldStringValue = RenameTemplateService.sanitize(base.isEmpty ? "Contact Sheet" : base) + ".pdf"
        panel.directoryURL = request.items.first?.url.deletingLastPathComponent()
        guard panel.runModal() == .OK, var destination = panel.url else {
            completion(nil)
            return
        }
        if destination.pathExtension.lowercased() != "pdf" { destination.appendPathExtension("pdf") }

        progress = ExportProgress(title: "Building contact sheet", done: 0, total: request.items.count, currentName: "")
        let items = request.items
        let url = destination
        task = Task { [weak self] in
            let report: @Sendable (Int, Int) -> Void = { [weak self] done, total in
                Task { @MainActor in
                    guard self?.progress != nil else { return }
                    self?.progress = ExportProgress(title: "Building contact sheet", done: done, total: total, currentName: "")
                }
            }
            let worker = Task.detached(priority: .userInitiated) { () -> Result<Void, Error> in
                let temp = url.deletingLastPathComponent().appendingPathComponent(".plx-contact-\(UUID().uuidString).pdf")
                do {
                    var items = items
                    if options.captionPrompt {
                        // Prompts the listing hasn't parsed yet (only needed for captions).
                        for index in items.indices where items[index].prompt == nil {
                            try Task.checkCancellation()
                            let entry = FileEntry(url: items[index].url, isDirectory: false)
                            items[index].prompt = await ExplorerViewModel.parsePromptData(for: entry).prompt
                        }
                    }
                    try await ContactSheetRenderer.renderPDF(items: items, options: options, to: temp, progress: report)
                    try Task.checkCancellation()
                    if FileManager.default.fileExists(atPath: url.path) {
                        // The save panel already confirmed replacing it.
                        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    }
                    try FileManager.default.moveItem(at: temp, to: url)
                    return .success(())
                } catch {
                    try? FileManager.default.removeItem(at: temp)
                    return .failure(error)
                }
            }
            let outcome = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard let self else { return }
            self.progress = nil
            self.task = nil
            switch outcome {
            case .success:
                completion(url)
            case .failure(let error):
                if !(error is CancellationError) {
                    let alert = NSAlert()
                    alert.messageText = "Couldn't Create the Contact Sheet"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
                completion(nil)
            }
        }
    }

    func presentContactSheetCompletion(_ url: URL, pageCount: Int) {
        let alert = NSAlert()
        alert.messageText = "Contact Sheet Created"
        alert.informativeText = "“\(url.lastPathComponent)” has \(pageCount) page\(pageCount == 1 ? "" : "s")."
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Reveal in Finder")
        alert.addButton(withTitle: "Done")
        switch alert.runModal() {
        case .alertFirstButtonReturn: NSWorkspace.shared.open(url)
        case .alertSecondButtonReturn: NSWorkspace.shared.activateFileViewerSelecting([url])
        default: break
        }
    }
}
