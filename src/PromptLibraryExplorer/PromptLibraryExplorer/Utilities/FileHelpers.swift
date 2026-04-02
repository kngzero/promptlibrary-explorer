import Foundation
import UniformTypeIdentifiers

enum FileHelpers {
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "webp", "gif", "bmp",
        "tif", "tiff", "psd", "psb", "heic", "heif", "avif", "icns"
    ]
    static let promptExtensions: Set<String> = ["plib", "aoe"]
    static let droppableExtensions: Set<String> = promptExtensions.union(imageExtensions)

    static func fileExtension(_ path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty ? nil : ext
    }

    static func isImageFile(_ name: String) -> Bool {
        guard let ext = fileExtension(name) else { return false }
        if imageExtensions.contains(ext) {
            return true
        }

        guard let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image)
    }

    static func isPlibFile(_ name: String) -> Bool {
        name.lowercased().hasSuffix(".plib")
    }

    static func isAoeFile(_ name: String) -> Bool {
        name.lowercased().hasSuffix(".aoe")
    }

    static func isPromptSnapshotFile(_ name: String) -> Bool {
        guard let ext = fileExtension(name) else { return false }
        return promptExtensions.contains(ext)
    }

    static func isPreviewable(_ entry: FileEntry) -> Bool {
        guard !entry.isDirectory else { return false }
        return isPromptSnapshotFile(entry.name) || isImageFile(entry.name)
    }

    static func isDroppable(_ path: String) -> Bool {
        guard let ext = fileExtension(path) else { return false }
        return droppableExtensions.contains(ext)
    }

    static func describeFileType(_ ext: String) -> String {
        switch ext.lowercased() {
        case "png": return "PNG Image"
        case "jpg", "jpeg": return "JPEG Image"
        case "gif": return "GIF Image"
        case "bmp": return "Bitmap Image"
        case "webp": return "WebP Image"
        case "tiff", "tif": return "TIFF Image"
        case "psd": return "Photoshop Document"
        case "psb": return "Large Photoshop Document"
        case "heic": return "HEIC Image"
        case "heif": return "HEIF Image"
        case "avif": return "AVIF Image"
        case "icns": return "Apple Icon Image"
        case "plib": return "Prompt Library File"
        case "aoe": return "Art Official Elements File"
        case "": return "File"
        default: return "\(ext.uppercased()) File"
        }
    }

    /// Returns the type-sort rank for an entry (directories first, then prompts, images, other).
    static func typeRank(for entry: FileEntry) -> Int {
        if entry.isDirectory { return 0 }
        let name = entry.name.lowercased()
        if name.hasSuffix(".plib") || name.hasSuffix(".aoe") { return 1 }
        if isImageFile(name) { return 2 }
        return 3
    }

    static func isLikelyBase64(_ value: String) -> Bool {
        guard value.count > 100 else { return false }
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "+/="))
            .union(.whitespacesAndNewlines)
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    static func isLikelyAbsolutePath(_ value: String) -> Bool {
        value.hasPrefix("/") || value.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil
    }

    static func mimeFromExtension(_ ext: String?) -> String {
        guard let ext = ext?.lowercased() else { return "application/octet-stream" }
        let map: [String: String] = [
            "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
            "webp": "image/webp", "gif": "image/gif", "bmp": "image/bmp",
            "tif": "image/tiff", "tiff": "image/tiff",
            "psd": "image/vnd.adobe.photoshop", "psb": "image/vnd.adobe.photoshop",
            "heic": "image/heic", "heif": "image/heif", "avif": "image/avif",
            "icns": "image/icns",
        ]
        return map[ext] ?? "application/octet-stream"
    }
}
