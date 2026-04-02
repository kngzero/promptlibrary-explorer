import AppKit
import Foundation

/// Parses .plib JSON files and caches results.
actor PlibParser {
    static let shared = PlibParser()

    private var cache: [String: PromptEntry] = [:]

    func parse(at url: URL) async -> PromptEntry? {
        let path = url.path
        if let cached = cache[path] { return cached }

        do {
            let data = try Data(contentsOf: url)
            let file = try JSONDecoder().decode(PlibFile.self, from: data)

            let hasPrompt = file.prompt?.trimmingCharacters(in: .whitespaces).isEmpty == false
            let hasBlindPrompt = file.blindPrompt?.trimmingCharacters(in: .whitespaces).isEmpty == false
            let hasImages = (file.images?.count ?? 0) > 0
            let hasGenInfo = file.generationInfo != nil

            guard (hasPrompt || hasBlindPrompt) && hasImages && hasGenInfo else {
                return nil
            }

            let prompt = hasPrompt ? file.prompt! : (file.blindPrompt ?? "")
            let rawImages = file.images ?? []
            let rawRefImages = file.referenceImages ?? []

            let images = rawImages.compactMap { decodeImageString($0, relativeTo: url) }
            let refImages = rawRefImages.compactMap { decodeImageString($0, relativeTo: url) }

            let entry = PromptEntry(
                prompt: prompt,
                blindPrompt: file.blindPrompt,
                hint: file.hint,
                generationInfo: file.generationInfo!,
                images: images,
                referenceImages: refImages,
                rawImages: rawImages,
                rawReferenceImages: rawRefImages,
                sourcePath: path,
                analysis: file.analysis
            )

            cache[path] = entry
            return entry
        } catch {
            return nil
        }
    }

    func clearCache() {
        cache.removeAll()
    }

    // MARK: - Image Decoding

    private func decodeImageString(_ value: String, relativeTo fileURL: URL) -> NSImage? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)

        // Data URL: data:image/...;base64,...
        if trimmed.hasPrefix("data:") {
            if let commaIndex = trimmed.firstIndex(of: ",") {
                let base64Part = String(trimmed[trimmed.index(after: commaIndex)...])
                if let data = Data(base64Encoded: base64Part, options: .ignoreUnknownCharacters) {
                    return NSImage(data: data)
                }
            }
            return nil
        }

        // Raw base64
        if FileHelpers.isLikelyBase64(trimmed) {
            if let data = Data(base64Encoded: trimmed, options: .ignoreUnknownCharacters) {
                return NSImage(data: data)
            }
            return nil
        }

        // Absolute file path
        if FileHelpers.isLikelyAbsolutePath(trimmed) {
            return NSImage(contentsOfFile: trimmed)
        }

        // Relative path (relative to the .plib file)
        let parent = fileURL.deletingLastPathComponent()
        let resolvedURL = parent.appendingPathComponent(trimmed)
        return NSImage(contentsOf: resolvedURL)
    }
}
