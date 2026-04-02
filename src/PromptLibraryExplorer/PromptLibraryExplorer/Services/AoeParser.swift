import AppKit
import Foundation

/// Parses .aoe (Art Official Elements) JSON files and caches results.
actor AoeParser {
    static let shared = AoeParser()

    private var cache: [String: PromptEntry] = [:]

    func parse(at url: URL) async -> PromptEntry? {
        let path = url.path
        if let cached = cache[path] { return cached }

        do {
            let data = try Data(contentsOf: url)
            let file = try JSONDecoder().decode(AoeFile.self, from: data)

            // Normalize image
            guard let imageResult = normalizeImage(file.image) else {
                return nil
            }

            // Extract prompt
            let fullPrompt = file.analysis?.fullPrompt?.trimmingCharacters(in: .whitespaces) ?? ""
            let shortDesc = file.analysis?.shortDescription?.trimmingCharacters(in: .whitespaces) ?? ""
            let hint = file.hint?.trimmingCharacters(in: .whitespaces) ?? ""

            let resolvedPrompt: String
            if !fullPrompt.isEmpty {
                resolvedPrompt = fullPrompt
            } else if !hint.isEmpty {
                resolvedPrompt = hint
            } else if !shortDesc.isEmpty {
                resolvedPrompt = shortDesc
            } else {
                resolvedPrompt = "Recovered snapshot"
            }

            let timestampMs = file.timestamp ?? Date().timeIntervalSince1970 * 1000
            let date = Date(timeIntervalSince1970: timestampMs / 1000)
            let isoFormatter = ISO8601DateFormatter()
            let timestampStr = isoFormatter.string(from: date)

            let entry = PromptEntry(
                prompt: resolvedPrompt,
                blindPrompt: shortDesc.isEmpty ? nil : shortDesc,
                hint: hint.isEmpty ? nil : hint,
                generationInfo: GenerationInfo(
                    aspectRatio: .notAvailable,
                    model: file.model ?? "Art Official Elements Snapshot",
                    timestamp: timestampStr,
                    numberOfImages: 1
                ),
                images: [imageResult.image],
                referenceImages: [],
                rawImages: [imageResult.raw],
                rawReferenceImages: [],
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

    // MARK: - Private

    private struct NormalizedImage {
        let image: NSImage
        let raw: String
    }

    private func normalizeImage(_ block: AoeImageBlock?) -> NormalizedImage? {
        guard let block else { return nil }

        let mimeType = block.mimeType?.trimmingCharacters(in: .whitespaces) ?? "image/jpeg"

        // Try previewUrl first (could be a file path or URL)
        if let previewUrl = block.previewUrl?.trimmingCharacters(in: .whitespaces), !previewUrl.isEmpty {
            if FileHelpers.isLikelyAbsolutePath(previewUrl), let img = NSImage(contentsOfFile: previewUrl) {
                return NormalizedImage(image: img, raw: block.base64 ?? previewUrl)
            }
            if let url = URL(string: previewUrl), let img = NSImage(contentsOf: url) {
                return NormalizedImage(image: img, raw: block.base64 ?? previewUrl)
            }
        }

        // Try base64
        if let base64 = block.base64?.trimmingCharacters(in: .whitespaces), !base64.isEmpty {
            if let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
               let img = NSImage(data: data)
            {
                return NormalizedImage(image: img, raw: base64)
            }
        }

        return nil
    }
}
