import ArtOfficialFormats
import CoreGraphics
import Foundation

/// Reads an Art Official document and produces the preview HTML (images rendered
/// with `ArtOfficialRenderer` / ImageIO and embedded as `data:` URIs).
public enum PreviewContentFactory {
    public struct Output: Sendable {
        public var title: String
        public var html: String
        public init(title: String, html: String) {
            self.title = title
            self.html = html
        }
    }

    public struct Limits: Sendable {
        public var heroPixelSize = 1800
        public var shotThumbPixelSize = 320
        public var maxShotThumbs = 240
        public var maxPromptImages = 6
        public var promptImagePixelSize = 1600
        public var maxReferenceImages = 8
        public var referencePixelSize = 320
        public static let `default` = Limits()
    }

    public enum Failure: Error, CustomStringConvertible {
        case unsupported(String)
        case unreadable(String)
        public var description: String {
            switch self {
            case .unsupported(let s): return "Unsupported file type: \(s)"
            case .unreadable(let s): return s
            }
        }
    }

    public static func make(for url: URL, limits: Limits = .default) throws -> Output {
        guard let kind = ArtOfficialFileKind.detect(url: url) else {
            throw Failure.unsupported(url.pathExtension)
        }
        let fileTitle = url.deletingPathExtension().lastPathComponent
        switch kind {
        case .moodboard:
            let board = try MoodboardReader.read(from: url)
            var model = moodModel(board, limits: limits)
            if model.title.isEmpty { model.title = fileTitle }   // hidden title -> file name
            return Output(title: model.title, html: PreviewHTML.mood(model))
        case .story, .storyLegacy:
            let doc = try StoryReader.read(from: url)
            let model = storyModel(doc, fileTitle: fileTitle, limits: limits)
            return Output(title: model.projects.count == 1 ? model.projects[0].title : fileTitle,
                          html: PreviewHTML.story(model))
        case .promptLibrary, .elements:
            let data: Data
            do { data = try Data(contentsOf: url, options: [.mappedIfSafe]) } catch {
                throw Failure.unreadable(error.localizedDescription)
            }
            let isPlib = kind == .promptLibrary
            let preview = isPlib ? PlibPreview.read(data: data, fileURL: url) : AoePreview.read(data: data, fileURL: url)
            guard let preview else { throw Failure.unreadable("Not a valid \(kind.displayName) file.") }
            let details = PromptFileDetails.read(data: data, kind: isPlib ? .plib : .aoe)
            let model = promptModel(preview, details: details, kindName: kind.displayName, limits: limits)
            return Output(title: preview.title.isEmpty ? fileTitle : preview.title, html: PreviewHTML.prompt(model))
        }
    }

    // MARK: Models

    public static func moodModel(_ board: Moodboard, limits: Limits = .default) -> MoodPreviewModel {
        let image = ArtOfficialRenderer.renderMoodboard(board, maxPixelSize: limits.heroPixelSize)
        var palette = board.palette
        for hex in board.customPalette where !palette.contains(hex) { palette.append(hex) }
        var canvas: String?
        if let w = board.canvasWidth, let h = board.canvasHeight { canvas = "\(w) × \(h)" }
        else if board.aspectRatio != "auto" { canvas = board.aspectRatio }
        return MoodPreviewModel(
            title: board.hideTitle ? "" : board.title,
            subtitle: board.hideSubtitle ? "" : board.subtitle,
            boardImageURI: image.flatMap { PreviewImageEncoder.dataURI($0, forceOpaque: true) },
            palette: palette,
            imageCount: board.imageTileCount,
            tileCount: board.tiles.count,
            layout: board.boardMode == .infinite ? "freeform" : board.layoutMode.rawValue,
            canvas: canvas,
            isLegacyArchive: board.isLegacyArchive
        )
    }

    public static func storyModel(_ doc: StoryDocument, fileTitle: String, limits: Limits = .default) -> StoryPreviewModel {
        var thumbBudget = limits.maxShotThumbs
        var omitted = 0
        var projects: [StoryPreviewModel.Project] = []
        for p in doc.projects {
            if p.isUnassigned && p.shotCount == 0 && p.scenes.isEmpty { continue }
            var info: [PreviewField] = []
            info.append(.init("Scenes", String(p.scenes.filter { !$0.isUnassigned || !$0.shots.isEmpty }.count)))
            info.append(.init("Shots", String(p.shotCount)))
            if p.estimatedDurationSec > 0 { info.append(.init("Runtime", PreviewHTML.duration(p.estimatedDurationSec))) }
            info.append(.init("Aspect", p.aspectRatio))
            if let d = p.director, !d.isEmpty { info.append(.init("Director", d)) }
            if let d = p.producer, !d.isEmpty { info.append(.init("Producer", d)) }
            switch (p.dateStart?.nonEmpty, p.dateEnd?.nonEmpty) {
            case let (s?, e?): info.append(.init("Dates", "\(s) – \(e)"))
            case let (s?, nil): info.append(.init("Start", s))
            case let (nil, e?): info.append(.init("End", e))
            default: break
            }
            let sheet = p.shotCount > 0 || p.coverImage != nil
                ? ArtOfficialRenderer.renderStoryContactSheet(p, maxPixelSize: limits.heroPixelSize) : nil
            var scenes: [StoryPreviewModel.Scene] = []
            for (si, scene) in p.scenes.enumerated() {
                let sceneNumber = scene.isUnassigned ? nil : (scene.number > 0 ? scene.number : si + 1)
                var shots: [StoryPreviewModel.Shot] = []
                for (hi, shot) in scene.shots.enumerated() {
                    var uri: String?
                    if let thumb = shot.thumb, thumb.isResolvable {
                        if thumbBudget > 0 {
                            uri = thumb.cgImage(maxPixelSize: limits.shotThumbPixelSize)
                                .flatMap { PreviewImageEncoder.dataURI($0, quality: 0.78) }
                            thumbBudget -= 1
                        } else {
                            omitted += 1
                        }
                    }
                    let label = sceneNumber.map { "\($0).\(hi + 1)" } ?? "\(hi + 1)"
                    let desc = shot.description.isEmpty ? shot.detailedNotes : shot.description
                    shots.append(.init(label: label, name: shot.name, types: shot.types, description: desc,
                                       durationSec: shot.estDurationSec, status: shot.status, tags: shot.tags,
                                       thumbURI: uri))
                }
                let heading: String
                if let n = sceneNumber {
                    heading = scene.name.isEmpty ? "Scene \(n)" : "Scene \(n) · \(scene.name)"
                } else {
                    heading = scene.name.isEmpty ? StoryReader.unassignedName : scene.name
                }
                let duration = scene.shots.isEmpty ? scene.estDurationSec
                    : scene.shots.reduce(0) { $0 + max(0, $1.estDurationSec) }
                scenes.append(.init(heading: heading, slugline: scene.isUnassigned ? nil : scene.slugline,
                                    notes: scene.notes, durationSec: duration, shots: shots))
            }
            projects.append(.init(title: p.title, code: p.code, status: p.status, logline: p.logline,
                                  info: info, notes: p.productionNotes,
                                  contactSheetURI: sheet.flatMap { PreviewImageEncoder.dataURI($0, forceOpaque: true) },
                                  scenes: scenes))
        }
        return StoryPreviewModel(fileTitle: fileTitle, projects: projects, omittedThumbCount: omitted)
    }

    public static func promptModel(_ preview: PromptFilePreview, details: PromptFileDetails, kindName: String,
                                   limits: Limits = .default) -> PromptPreviewModel {
        let resolvable = preview.images.filter(\.isResolvable)
        let images = resolvable.prefix(limits.maxPromptImages).compactMap {
            $0.cgImage(maxPixelSize: limits.promptImagePixelSize).flatMap { PreviewImageEncoder.dataURI($0) }
        }
        let refs = preview.referenceImages.filter(\.isResolvable).prefix(limits.maxReferenceImages).compactMap {
            $0.cgImage(maxPixelSize: limits.referencePixelSize).flatMap { PreviewImageEncoder.dataURI($0) }
        }
        var generation = details.generation
        if let model = preview.model, !generation.contains(where: { $0.label == "Model" }) {
            generation.insert(.init("Model", model), at: 0)
        }
        return PromptPreviewModel(kindName: kindName, title: preview.title, prompt: preview.prompt,
                                  shortDescription: details.shortDescription, imageURIs: images,
                                  totalImageCount: max(preview.images.count, images.count),
                                  referenceImageURIs: refs, generation: generation, analysis: details.analysis)
    }
}

extension String {
    var nonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
