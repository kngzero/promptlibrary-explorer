import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Rendered stand-ins for edited images where the app hands a FILE to the system (the
/// in-app Quick Look panel): `Caches/…/edit-previews/<digest>/<name> (edited).jpg`.
/// Originals are never touched; entries older than a day are pruned.
enum EditPreviewFiles {
    static let maxPixelSize: CGFloat = 2560

    static let directory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("com.artofficial.promptlibrary-explorer/edit-previews", isDirectory: true)
    }()

    private static let pruneOnce: Void = {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        guard let folders = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for folder in folders {
            let date = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if date < cutoff { try? fm.removeItem(at: folder) }
        }
    }()

    /// Where the preview for `url` with `recipe` lives (path, mtime and recipe digest).
    static func previewURL(for url: URL, recipe: EditRecipe) -> URL {
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let digest = SHA256.hash(data: Data("\(url.standardizedFileURL.path)|\(mtime)|\(recipe.hashToken)".utf8))
        let folder = directory.appendingPathComponent(digest.prefix(12).map { String(format: "%02x", $0) }.joined(), isDirectory: true)
        let base = url.deletingPathExtension().lastPathComponent
        return folder.appendingPathComponent("\(base) (edited).jpg")
    }

    static func existing(for url: URL, recipe: EditRecipe) -> URL? {
        let preview = previewURL(for: url, recipe: recipe)
        return FileManager.default.fileExists(atPath: preview.path) ? preview : nil
    }

    /// Renders the preview file if it isn't there yet. Call off the main actor.
    @discardableResult
    static func prepare(for url: URL, recipe: EditRecipe) -> URL? {
        _ = pruneOnce
        if let existing = existing(for: url, recipe: recipe) { return existing }
        guard let image = EditRenderer.render(url: url, recipe: recipe, maxPixelSize: maxPixelSize) else { return nil }
        let destination = previewURL(for: url, recipe: recipe)
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).jpg")
        guard let output = CGImageDestinationCreateWithURL(temp as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(output) else { return nil }
        do {
            try FileManager.default.moveItem(at: temp, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temp)
        }
        return existing(for: url, recipe: recipe)
    }
}
