import Foundation

/// Minimal, lenient preview of the app's own `.plib` / `.aoe` files — independent
/// of the app's parsers (safe for extensions). Images stay undecoded.
public struct PromptFilePreview: Sendable {
    public var title: String
    public var prompt: String
    public var model: String?
    public var images: [EmbeddedImage]
    public var referenceImages: [EmbeddedImage]

    public init(title: String, prompt: String, model: String? = nil, images: [EmbeddedImage] = [],
                referenceImages: [EmbeddedImage] = []) {
        self.title = title
        self.prompt = prompt
        self.model = model
        self.images = images
        self.referenceImages = referenceImages
    }
}

/// `.plib` (Prompt Library): `{ prompt, blindPrompt, hint, images: [String], referenceImages,
/// generationInfo: { model, ... }, analysis: { full_prompt, short_description, ... } }`.
/// Image strings may be data URLs, bare base64, absolute paths or paths relative to the file.
public enum PlibPreview {
    public static func read(from url: URL) -> PromptFilePreview? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        return read(data: data, fileURL: url)
    }

    public static func read(data: Data, fileURL: URL?) -> PromptFilePreview? {
        guard let root = JSON.parseObject(data) else { return nil }
        let base = fileURL?.deletingLastPathComponent()
        let images = JSON.strings(root, "images").compactMap { EmbeddedImage.parse($0, relativeTo: base) }
        let refs = JSON.strings(root, "referenceImages").compactMap { EmbeddedImage.parse($0, relativeTo: base) }
        let analysis = JSON.object(root, "analysis")
        let prompt = JSON.nonEmptyString(root, "prompt")
            ?? JSON.nonEmptyString(root, "blindPrompt")
            ?? JSON.nonEmptyString(analysis, "full_prompt", "fullPrompt")
            ?? JSON.nonEmptyString(root, "hint")
            ?? ""
        guard !prompt.isEmpty || !images.isEmpty else { return nil }
        return PromptFilePreview(
            title: title(for: fileURL),
            prompt: prompt,
            model: JSON.nonEmptyString(JSON.object(root, "generationInfo"), "model"),
            images: images,
            referenceImages: refs
        )
    }

    static func title(for url: URL?) -> String {
        url.map { $0.deletingPathExtension().lastPathComponent } ?? ""
    }
}

/// `.aoe` (Art Official Elements): `{ timestamp, image: { previewUrl, base64, mimeType },
/// analysis: { full_prompt, short_description, ... }, model, hint }`.
/// Remote `previewUrl`s are never fetched; `base64` is used instead.
public enum AoePreview {
    public static func read(from url: URL) -> PromptFilePreview? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        return read(data: data, fileURL: url)
    }

    public static func read(data: Data, fileURL: URL?) -> PromptFilePreview? {
        guard let root = JSON.parseObject(data) else { return nil }
        let block = JSON.object(root, "image")
        let mime = JSON.nonEmptyString(block, "mimeType")
        var images: [EmbeddedImage] = []
        if let preview = JSON.string(block, "previewUrl"), let img = EmbeddedImage.parse(preview), img.isResolvable {
            images.append(img)
        } else if let raw = JSON.string(block, "base64"), case let b64 = EmbeddedImage.cheapTrim(raw), !b64.isEmpty {
            if b64.hasPrefix("data:"), let img = EmbeddedImage.dataURL(b64) {
                images.append(img)
            } else {
                images.append(EmbeddedImage(kind: .base64, mimeType: mime,
                                            storage: .encoded(b64, payloadStart: b64.startIndex, isBase64: true)))
            }
        }
        let analysis = JSON.object(root, "analysis")
        let prompt = JSON.nonEmptyString(analysis, "full_prompt", "fullPrompt")
            ?? JSON.nonEmptyString(root, "hint")
            ?? JSON.nonEmptyString(analysis, "short_description", "shortDescription")
            ?? (images.isEmpty ? "" : "Recovered snapshot")
        guard !images.isEmpty || !prompt.isEmpty else { return nil }
        return PromptFilePreview(title: PlibPreview.title(for: fileURL), prompt: prompt,
                                 model: JSON.nonEmptyString(root, "model"), images: images)
    }
}
