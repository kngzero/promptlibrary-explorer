import ArtOfficialFormats
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One file handed to Send to Mood / Send to Story, with the app data that goes with it.
struct ArtOfficialSendItem: Sendable {
    let url: URL
    var name: String { url.lastPathComponent }
    /// Positive prompt (Story shot description).
    var prompt: String = ""
    /// App tag names (Story shot tags).
    var tags: [String] = []
}

/// The draft plus what went into it.
struct ArtOfficialSendResult<Draft: Sendable>: Sendable {
    var draft: Draft
    var addedCount: Int
    /// Files that were not images, or could not be decoded.
    var skippedNames: [String]
}

/// Builds `.mlmboard` / `.stry` drafts from image files. Non-UI and synchronous (call off
/// the main actor); the view model wraps it with the save panel, progress and the writer.
enum ArtOfficialSendBuilder {
    /// Mood board images are downscaled to this long edge.
    static let maxMoodImagePixels = 2560
    /// Downsample size used for palette extraction.
    static let paletteSamplePixels = 256
    static let paletteColorCount = 7

    typealias Progress = @Sendable (_ done: Int, _ total: Int) -> Void

    static func isSendable(_ name: String) -> Bool {
        FileHelpers.isImageFile(name)
    }

    // MARK: Mood

    static func moodboardDraft(
        title: String,
        items: [ArtOfficialSendItem],
        progress: Progress? = nil
    ) -> ArtOfficialSendResult<MoodboardDraft> {
        var images: [MoodboardDraft.Image] = []
        var samples: [CGImage] = []
        var skipped: [String] = []
        let total = items.count

        for (offset, item) in items.enumerated() {
            defer { progress?(offset + 1, total) }
            guard isSendable(item.name),
                  let source = CGImageSourceCreateWithURL(item.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let prepared = preparedMoodImage(source: source, url: item.url, name: item.name)
            else {
                skipped.append(item.name)
                continue
            }
            images.append(prepared)
            if samples.count < 24, let sample = thumbnail(source, maxPixelSize: paletteSamplePixels) {
                samples.append(sample)
            }
        }

        let palette = MoodboardPalette.extract(from: samples, count: paletteColorCount)
        let draft = MoodboardDraft(
            title: title,
            subtitle: "",
            images: images,
            palette: palette.isEmpty ? nil : palette,
            columns: images.count <= 4 ? max(images.count, 1) : 4
        )
        return ArtOfficialSendResult(draft: draft, addedCount: images.count, skippedNames: skipped)
    }

    /// PNG and JPEG files within the size limit (and upright) pass through unchanged;
    /// everything else is decoded, downscaled to `maxMoodImagePixels` and re-encoded:
    /// PNG when the source is PNG or has alpha, JPEG otherwise.
    static func preparedMoodImage(source: CGImageSource, url: URL, name: String) -> MoodboardDraft.Image? {
        guard CGImageSourceGetCount(source) > 0 else { return nil }
        let type = (CGImageSourceGetType(source) as String?) ?? ""
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        guard width > 0, height > 0 else { return nil }

        let isPNG = type == UTType.png.identifier
        let isJPEG = type == UTType.jpeg.identifier
        if (isPNG || isJPEG), max(width, height) <= maxMoodImagePixels, orientation == 1,
           let data = try? Data(contentsOf: url)
        {
            return MoodboardDraft.Image(name: name, data: data, mimeType: isPNG ? "image/png" : "image/jpeg")
        }

        let target = min(maxMoodImagePixels, max(width, height))
        guard let image = thumbnail(source, maxPixelSize: target) else { return nil }
        let keepsAlpha = isPNG || hasAlpha(image)
        let data = keepsAlpha ? ArtOfficialRendering.pngData(image) : ArtOfficialRendering.jpegData(image, quality: 0.9)
        guard let data else { return nil }
        return MoodboardDraft.Image(name: name, data: data, mimeType: keepsAlpha ? "image/png" : "image/jpeg")
    }

    // MARK: Story

    static func storyDraft(
        title: String,
        items: [ArtOfficialSendItem],
        progress: Progress? = nil
    ) -> ArtOfficialSendResult<StoryDraft> {
        var shots: [StoryDraft.Shot] = []
        var skipped: [String] = []
        let total = items.count

        for (offset, item) in items.enumerated() {
            defer { progress?(offset + 1, total) }
            guard isSendable(item.name),
                  let source = CGImageSourceCreateWithURL(item.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = thumbnail(source, maxPixelSize: StoryWriter.maxThumbPixelSize),
                  let data = ArtOfficialRendering.jpegData(image, quality: 0.9)
            else {
                skipped.append(item.name)
                continue
            }
            shots.append(StoryDraft.Shot(
                name: item.name,
                imageData: data,
                description: item.prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                tags: item.tags
            ))
        }

        let draft = StoryDraft(title: title, shots: shots)
        return ArtOfficialSendResult(draft: draft, addedCount: shots.count, skippedNames: skipped)
    }

    // MARK: Helpers

    /// Default document title: the collection or folder name, trimmed, never empty.
    static func defaultTitle(_ name: String?, fallback: String) -> String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }

    /// A file name for the save panel (no path separators).
    static func suggestedFileName(title: String, fileExtension: String) -> String {
        let safe = ArtOfficialExtraction.sanitizedBaseName(title, fallback: "Untitled")
        return "\(safe).\(fileExtension)"
    }

    private static func thumbnail(_ source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: max(maxPixelSize, 1),
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }
}
