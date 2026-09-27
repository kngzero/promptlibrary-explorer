import AppKit
import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Job model

enum ExportItemKind: String, Sendable {
    case image
    case video
    case audio
    /// Mood / Story / .plib / .aoe.
    case document
    case unsupported

    static func classify(_ url: URL) -> ExportItemKind {
        let name = url.lastPathComponent
        if FileHelpers.isArtOfficialDocumentFile(name) || FileHelpers.isPromptSnapshotFile(name) { return .document }
        if FileHelpers.isVideoFile(name) { return .video }
        if FileHelpers.isAudioFile(name) { return .audio }
        if FileHelpers.isImageFile(name) { return .image }
        return .unsupported
    }
}

struct ExportJobItem: Sendable {
    var source: URL
    var kind: ExportItemKind
    var destination: URL
    var action: ExportWriteAction
    /// Concrete output format for images and rendered documents.
    var format: ExportFormat?
}

struct ExportItemResult: Sendable {
    enum Outcome: Sendable, Equatable {
        case written
        case skipped(String)
        case failed(String)
    }

    var source: URL
    var destination: URL?
    var outcome: Outcome
    /// Something the user should know even though it worked ("copied without stripping").
    var note: String?
}

struct ExportRunSummary: Sendable {
    var results: [ExportItemResult] = []
    var cancelled = false

    var written: [ExportItemResult] { results.filter { $0.outcome == .written } }
    var skipped: [ExportItemResult] { results.filter { if case .skipped = $0.outcome { return true } else { return false } } }
    var failed: [ExportItemResult] { results.filter { if case .failed = $0.outcome { return true } else { return false } } }
    var notes: [ExportItemResult] { results.filter { $0.note != nil } }
}

// MARK: - Engine

/// Runs an export. Everything is written to a temporary file next to the destination,
/// verified, and only then moved into place — originals are never opened for writing.
enum ExportEngine {
    typealias Progress = @Sendable (_ done: Int, _ total: Int, _ currentName: String) -> Void

    static func run(items: [ExportJobItem], preset: ExportPreset, progress: Progress) async -> ExportRunSummary {
        var summary = ExportRunSummary()
        let watermarkImage = preset.watermark.isActive && preset.watermark.kind == .image
            ? ExportImageRenderer.loadWatermarkImage(path: preset.watermark.imagePath) : nil
        let sourcePaths = Set(items.map { $0.source.standardizedFileURL.path })

        for (index, item) in items.enumerated() {
            if Task.isCancelled {
                summary.cancelled = true
                break
            }
            progress(index, items.count, item.source.lastPathComponent)
            let result = await export(item, preset: preset, watermarkImage: watermarkImage, protectedPaths: sourcePaths)
            summary.results.append(result)
        }
        if Task.isCancelled { summary.cancelled = true }
        progress(summary.results.count, items.count, "")
        return summary
    }

    static func export(
        _ item: ExportJobItem,
        preset: ExportPreset,
        watermarkImage: CGImage?,
        protectedPaths: Set<String>
    ) async -> ExportItemResult {
        var result = ExportItemResult(source: item.source, destination: item.destination, outcome: .written)
        if item.action == .skip {
            result.outcome = .skipped("a file with that name already exists")
            result.destination = nil
            return result
        }
        // Belt and braces: never write over one of the originals being exported.
        if protectedPaths.contains(item.destination.standardizedFileURL.path) {
            result.outcome = .failed("the output name matches an original")
            return result
        }

        do {
            let folder = item.destination.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let temp = folder.appendingPathComponent(".plx-export-\(UUID().uuidString).\(item.destination.pathExtension)")
            defer { try? FileManager.default.removeItem(at: temp) }

            switch item.kind {
            case .image:
                result.note = try exportImage(
                    source: item.source, to: temp, format: item.format ?? .png,
                    preset: preset, watermarkImage: watermarkImage
                )
            case .document:
                guard preset.exportRenderedDocuments else {
                    result.outcome = .skipped("Mood, Story, .plib and .aoe files are only exported as rendered images when that option is on")
                    result.destination = nil
                    return result
                }
                guard let rendered = await ExportSourceImages.renderedDocumentImage(for: item.source) else {
                    throw ExportEngineError.noRenderedImage
                }
                try exportRendered(rendered, to: temp, format: item.format ?? .png, preset: preset, watermarkImage: watermarkImage)
            case .video, .audio:
                result.note = try await exportMedia(source: item.source, to: temp, strip: preset.stripMediaMetadata)
            case .unsupported:
                result.outcome = .skipped("this file type can't be exported")
                result.destination = nil
                return result
            }

            try Task.checkCancellation()
            result.destination = try place(temp, at: item.destination, action: item.action)
        } catch is CancellationError {
            result.outcome = .skipped("cancelled")
            result.destination = nil
        } catch {
            result.outcome = .failed(error.localizedDescription)
            result.destination = nil
        }
        return result
    }

    enum ExportEngineError: LocalizedError {
        case unreadable
        case encodeFailed(String)
        case noRenderedImage
        case mediaExportFailed(String)

        var errorDescription: String? {
            switch self {
            case .unreadable: return "The file couldn't be read."
            case .encodeFailed(let format): return "The image couldn't be written as \(format)."
            case .noRenderedImage: return "The document has no image to export."
            case .mediaExportFailed(let detail): return "The media couldn't be exported (\(detail))."
            }
        }
    }

    // MARK: Images

    /// Returns a note when something worth telling happened (e.g. re-encoded to strip).
    static func exportImage(
        source url: URL,
        to temp: URL,
        format: ExportFormat,
        preset: ExportPreset,
        watermarkImage: CGImage?
    ) throws -> String? {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let size = ExportImageRenderer.orientedSize(of: source)
        else { throw ExportEngineError.unreadable }

        let policy = preset.metadata
        let plan = ExportGeometry.plan(sourceWidth: size.width, sourceHeight: size.height, sizing: preset.sizing)
        let sourceType = CGImageSourceGetType(source) as String?
        let sameFormat = sourceType == format.utType?.identifier
        let needsPixels = !sameFormat
            || plan.changesPixels
            || preset.watermark.isActive
            || ExportImageRenderer.needsColorConversion(preset.colorProfile, source: source)
        let parsed = policy.mode == .keepAll ? nil : ImageMetadataParser.readMetadataUncached(at: url)

        var note: String?
        if !needsPixels {
            if policy.mode == .keepAll {
                try FileManager.default.copyItem(at: url, to: temp)
                return nil
            }
            do {
                let output: Data
                if format == .png {
                    output = try ExportMetadata.strippedPNG(data, policy: policy, parsed: parsed)
                } else {
                    output = try ExportMetadata.losslessRewrite(data, policy: policy, parsed: parsed)
                }
                try output.write(to: temp)
                try verify(temp, policy: policy)
                return nil
            } catch let failure as ExportMetadata.Failure {
                if case .leaked = failure { throw failure }
                // Fall through to a re-encode (at full size), and say so.
                note = "re-encoded to remove metadata (\(failure.localizedDescription))"
            }
        }

        let isAnimated = CGImageSourceGetCount(source) > 1
        guard let decoded = ExportImageRenderer.decodeForPlan(
            source, orientedWidth: size.width, orientedHeight: size.height, plan: plan
        ) else { throw ExportEngineError.unreadable }
        let space = ExportImageRenderer.colorSpace(for: preset.colorProfile, sourceImage: decoded)
        guard let rendered = ExportImageRenderer.render(
            decoded,
            orientedSourceWidth: size.width,
            plan: plan,
            colorSpace: space,
            opaque: !format.supportsAlpha,
            watermark: preset.watermark,
            watermarkImage: watermarkImage
        ) else { throw ExportEngineError.encodeFailed(format.title) }

        let metadata = reencodeMetadata(source: source, sourceData: data, sourceType: sourceType, output: format, policy: policy, parsed: parsed ?? ImageMetadataParser.readMetadataUncached(at: url))
        guard var output = ExportImageRenderer.encode(rendered, format: format, quality: preset.quality, metadata: metadata.xmp) else {
            throw ExportEngineError.encodeFailed(format.title)
        }
        if format == .png, !metadata.pngChunks.isEmpty {
            output = try ExportMetadata.splice(metadata.pngChunks, into: output)
        }
        try output.write(to: temp)
        try verify(temp, policy: policy)
        if isAnimated, note == nil { note = "animated image exported as a still (first frame)" }
        return note
    }

    /// Rendered Mood / Story / .plib / .aoe image: no source metadata to carry.
    static func exportRendered(_ image: CGImage, to temp: URL, format: ExportFormat, preset: ExportPreset, watermarkImage: CGImage?) throws {
        let plan = ExportGeometry.plan(sourceWidth: image.width, sourceHeight: image.height, sizing: preset.sizing)
        let space = ExportImageRenderer.colorSpace(for: preset.colorProfile, sourceImage: image)
        guard let rendered = ExportImageRenderer.render(
            image, orientedSourceWidth: image.width, plan: plan, colorSpace: space,
            opaque: !format.supportsAlpha, watermark: preset.watermark, watermarkImage: watermarkImage
        ), let output = ExportImageRenderer.encode(rendered, format: format, quality: preset.quality, metadata: nil)
        else { throw ExportEngineError.encodeFailed(format.title) }
        try output.write(to: temp)
    }

    struct ReencodeMetadata {
        var xmp: CGImageMetadata?
        /// Encoded PNG chunks spliced in after ImageIO writes the file.
        var pngChunks: [Data] = []
    }

    /// Metadata for a re-encoded image: the filtered source metadata with orientation
    /// reset (pixels are already upright) and the AI text re-expressed for the output format.
    static func reencodeMetadata(
        source: CGImageSource,
        sourceData: Data,
        sourceType: String?,
        output format: ExportFormat,
        policy: ExportMetadataPolicy,
        parsed: ImageMetadataParser.Metadata
    ) -> ReencodeMetadata {
        let xmp = ExportMetadata.filteredXMP(CGImageSourceCopyMetadataAtIndex(source, 0, nil), policy: policy)
        for path in ["exif:PixelXDimension", "exif:PixelYDimension"] {
            CGImageMetadataRemoveTagWithPath(xmp, nil, path as CFString)
        }
        _ = CGImageMetadataSetValueMatchingImageProperty(
            xmp, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, 1 as CFNumber
        )

        var result = ReencodeMetadata()
        let sourceIsPNG = sourceType == UTType.png.identifier
        let sourceParameters = sourceIsPNG ? pngText(sourceData, keyword: "parameters") : nil
        let fullBlock = ExportMetadata.synthesizedParameters(from: parsed, policy: .init(mode: .keepOnly, keptFields: Set(ExportMetadataField.allCases)))

        switch policy.mode {
        case .keepAll:
            if format == .png {
                if sourceIsPNG {
                    result.pngChunks = ExportMetadata.keptPNGTextChunks(sourceData, policy: .keepAll, excludingXMP: true)
                } else if let block = fullBlock {
                    result.pngChunks = [ExportMetadata.pngTextChunk(keyword: "parameters", text: block)]
                }
            } else if sourceIsPNG, let text = sourceParameters ?? fullBlock {
                ExportMetadata.applySynthesized(text, prompt: parsed.prompt.isEmpty ? nil : parsed.prompt, to: xmp)
            }
        case .keepOnly:
            let block = ExportMetadata.synthesizedParameters(from: parsed, policy: policy)
            if format == .png {
                if let block { result.pngChunks.append(ExportMetadata.pngTextChunk(keyword: "parameters", text: block)) }
                if sourceIsPNG, policy.keptFields.contains(.workflow) {
                    result.pngChunks += ExportMetadata.keptPNGTextChunks(sourceData, policy: policy, excludingXMP: true)
                }
            } else {
                ExportMetadata.applySynthesized(block, prompt: ExportMetadata.keptPrompt(from: parsed, policy: policy), to: xmp)
            }
        case .stripAI:
            if format == .png, sourceIsPNG {
                result.pngChunks = ExportMetadata.keptPNGTextChunks(sourceData, policy: policy, excludingXMP: true)
            }
        case .stripAll:
            break
        }
        result.xmp = xmp
        return result
    }

    private static func pngText(_ data: Data, keyword: String) -> String? {
        guard let chunks = try? ExportMetadata.pngChunks(data) else { return nil }
        for chunk in chunks where chunk.type == "tEXt" && ExportMetadata.keyword(of: chunk, in: data) == keyword {
            let payload = data.subdata(in: (data.startIndex + chunk.dataRange.lowerBound)..<(data.startIndex + chunk.dataRange.upperBound))
            guard let nul = payload.firstIndex(of: 0) else { continue }
            let body = payload[payload.index(after: nul)...]
            return String(data: body, encoding: .utf8) ?? String(data: body, encoding: .isoLatin1)
        }
        return nil
    }

    private static func verify(_ url: URL, policy: ExportMetadataPolicy) throws {
        let leaks = ExportMetadata.leakedAIMetadata(at: url, policy: policy)
        if !leaks.isEmpty { throw ExportMetadata.Failure.leaked(leaks) }
    }

    // MARK: Video / audio

    /// Copies the file, or with `strip` re-muxes it (passthrough, no re-encode) without
    /// metadata where AVFoundation can write that container. Returns a note when the file
    /// had to be copied as-is.
    static func exportMedia(source: URL, to temp: URL, strip: Bool) async throws -> String? {
        guard strip else {
            try FileManager.default.copyItem(at: source, to: temp)
            return nil
        }
        let ext = source.pathExtension.lowercased()
        let fileType: AVFileType?
        switch ext {
        case "mov", "qt": fileType = .mov
        case "mp4": fileType = .mp4
        case "m4v": fileType = .m4v
        case "m4a": fileType = .m4a
        default: fileType = nil
        }
        let asset = AVURLAsset(url: source)
        guard let fileType,
              let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough),
              session.supportedFileTypes.contains(fileType)
        else {
            try FileManager.default.copyItem(at: source, to: temp)
            return "copied unchanged: metadata can't be removed from .\(ext) files"
        }
        session.outputURL = temp
        session.outputFileType = fileType
        session.metadata = []
        session.metadataItemFilter = AVMetadataItemFilter.forSharing()
        session.shouldOptimizeForNetworkUse = false

        let box = SessionBox(session: session)
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                box.session.exportAsynchronously { continuation.resume() }
            }
        } onCancel: {
            box.session.cancelExport()
        }
        try Task.checkCancellation()
        guard session.status == .completed else {
            throw ExportEngineError.mediaExportFailed(session.error?.localizedDescription ?? "status \(session.status.rawValue)")
        }

        // Report anything the re-mux carried over anyway.
        let remaining = (try? await AVURLAsset(url: temp).load(.metadata)) ?? []
        let userFacing = remaining.filter { item in
            let key = (item.commonKey?.rawValue ?? (item.key as? String) ?? "").lowercased()
            return !["creationdate", "encoder", "software"].contains(key)
        }
        return userFacing.isEmpty ? nil : "some metadata (\(userFacing.count) item\(userFacing.count == 1 ? "" : "s")) couldn't be removed"
    }

    /// AVAssetExportSession is thread-safe for export/cancel but not marked Sendable.
    private final class SessionBox: @unchecked Sendable {
        let session: AVAssetExportSession
        init(session: AVAssetExportSession) { self.session = session }
    }

    // MARK: Placing

    /// Moves the finished temp file to `destination`. Overwrite moves the existing file to
    /// the Trash first; a name taken since planning gets a number.
    static func place(_ temp: URL, at destination: URL, action: ExportWriteAction) throws -> URL {
        let fm = FileManager.default
        var target = destination
        if fm.fileExists(atPath: target.path) {
            if action == .overwrite {
                try fm.trashItem(at: target, resultingItemURL: nil)
            } else {
                let folder = target.deletingLastPathComponent()
                let ext = target.pathExtension
                let base = target.deletingPathExtension().lastPathComponent
                var n = 2
                repeat {
                    target = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
                    n += 1
                } while fm.fileExists(atPath: target.path)
            }
        }
        try fm.moveItem(at: temp, to: target)
        return target
    }
}

// MARK: - Rendered previews

/// Images for Mood / Story / .plib / .aoe files and video frames, used by rendered
/// document export and the contact sheet.
enum ExportSourceImages {
    static func renderedDocumentImage(for url: URL, maxPixelSize: Int = 4096) async -> CGImage? {
        let name = url.lastPathComponent
        if FileHelpers.isArtOfficialDocumentFile(name) {
            guard let document = await ArtOfficialDocumentParser.shared.parse(at: url) else { return nil }
            return ArtOfficialRendering.overview(of: document, maxPixelSize: maxPixelSize)
        }
        if FileHelpers.isPromptSnapshotFile(name) {
            let entry = FileHelpers.isPlibFile(name)
                ? await PlibParser.shared.parse(at: url)
                : await AoeParser.shared.parse(at: url)
            guard let image = entry?.images.first else { return nil }
            var rect = CGRect(origin: .zero, size: image.size)
            return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
        return nil
    }

    /// A downsampled picture of any file: images, video frames, rendered documents.
    static func previewImage(for url: URL, maxPixelSize: Int) async -> CGImage? {
        let name = url.lastPathComponent
        if FileHelpers.isArtOfficialDocumentFile(name) || FileHelpers.isPromptSnapshotFile(name) {
            return await renderedDocumentImage(for: url, maxPixelSize: maxPixelSize)
        }
        if FileHelpers.isVideoFile(name) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
            return try? await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return ExportImageRenderer.orientedImage(from: source, maxPixelSize: maxPixelSize)
    }
}
