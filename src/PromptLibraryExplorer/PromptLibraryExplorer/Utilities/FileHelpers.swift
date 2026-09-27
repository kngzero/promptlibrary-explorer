import ArtOfficialFormats
import Foundation
import UniformTypeIdentifiers

enum FileHelpers {
    struct TypeSortDescriptor {
        let rank: Int
        let typeLabel: String
        let canonicalExtension: String
    }

    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "webp", "gif", "bmp",
        "tif", "tiff", "psd", "psb", "heic", "heif", "avif", "icns"
    ]
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]
    static let audioExtensions: Set<String> = [
        "mp3", "wav", "m4a", "flac", "aac", "ogg", "aiff", "aif", "wma", "alac"
    ]
    static let promptExtensions: Set<String> = ["plib", "aoe"]
    /// Art Official documents owned by other apps: Mood boards and Story projects.
    static let moodboardExtensions: Set<String> = ["mlmboard"]
    static let storyExtensions: Set<String> = ["stry", "mlseq"]
    static let artOfficialDocumentExtensions: Set<String> = moodboardExtensions.union(storyExtensions)
    static let droppableExtensions: Set<String> = promptExtensions
        .union(artOfficialDocumentExtensions)
        .union(imageExtensions)
        .union(videoExtensions)
        .union(audioExtensions)

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

    /// `.mlmboard` (Mood).
    static func isMoodboardFile(_ name: String) -> Bool {
        ArtOfficialFileKind.detect(pathExtension: (name as NSString).pathExtension) == .moodboard
    }

    /// `.stry` or legacy `.mlseq` (Story).
    static func isStoryFile(_ name: String) -> Bool {
        ArtOfficialFileKind.detect(pathExtension: (name as NSString).pathExtension)?.isStory == true
    }

    /// A Mood board or Story project.
    static func isArtOfficialDocumentFile(_ name: String) -> Bool {
        isMoodboardFile(name) || isStoryFile(name)
    }

    static func isPromptSnapshotFile(_ name: String) -> Bool {
        guard let ext = fileExtension(name) else { return false }
        return promptExtensions.contains(ext)
    }

    static func isVideoFile(_ name: String) -> Bool {
        guard let ext = fileExtension(name) else { return false }
        if videoExtensions.contains(ext) {
            return true
        }

        guard let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .movie)
    }

    static func isAudioFile(_ name: String) -> Bool {
        guard let ext = fileExtension(name) else { return false }
        if audioExtensions.contains(ext) {
            return true
        }

        guard let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .audio)
    }

    static func isPreviewable(_ entry: FileEntry) -> Bool {
        guard !entry.isDirectory else { return false }
        return isPromptSnapshotFile(entry.name) || isArtOfficialDocumentFile(entry.name) || isImageFile(entry.name) || isVideoFile(entry.name) || isAudioFile(entry.name)
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
        case "mp4": return "MPEG-4 Video"
        case "mov": return "QuickTime Movie"
        case "m4v": return "M4V Video"
        case "mp3": return "MP3 Audio"
        case "wav": return "WAV Audio"
        case "m4a": return "M4A Audio"
        case "flac": return "FLAC Audio"
        case "aac": return "AAC Audio"
        case "ogg": return "OGG Audio"
        case "aiff", "aif": return "AIFF Audio"
        case "wma": return "WMA Audio"
        case "alac": return "ALAC Audio"
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
        case "mlmboard": return "Mood Board"
        case "stry": return "Story Project"
        case "mlseq": return "Story Project (Legacy)"
        case "": return "File"
        default: return "\(ext.uppercased()) File"
        }
    }

    static func filterType(for entry: FileEntry) -> FileTypeFilter? {
        guard !entry.isDirectory else { return nil }
        return filterType(forName: entry.name)
    }

    static func filterType(forName name: String) -> FileTypeFilter {
        let lowercasedName = name.lowercased()
        let ext = canonicalTypeExtension(fileExtension(lowercasedName))

        switch ext {
        case "plib":
            return .plib
        case "aoe":
            return .aoe
        case "mlmboard":
            return .moodboard
        case "stry", "mlseq":
            return .story
        case "png":
            return .png
        case "jpg":
            return .jpg
        case "webp":
            return .webp
        case "gif":
            return .gif
        default:
            break
        }

        if isImageFile(lowercasedName) {
            return .otherImages
        }

        if isVideoFile(lowercasedName) {
            return .video
        }

        if isAudioFile(lowercasedName) {
            return .audio
        }

        return .unsupported
    }

    static func typeSortDescriptor(for entry: FileEntry) -> TypeSortDescriptor {
        if entry.isDirectory {
            return TypeSortDescriptor(rank: 0, typeLabel: "Folder", canonicalExtension: "")
        }

        let name = entry.name.lowercased()
        let ext = canonicalTypeExtension(fileExtension(name))
        let rank: Int

        if isPromptSnapshotFile(name) || isArtOfficialDocumentFile(name) {
            rank = 1
        } else if isImageFile(name) {
            rank = 2
        } else if isVideoFile(name) {
            rank = 3
        } else if isAudioFile(name) {
            rank = 4
        } else {
            rank = 5
        }

        return TypeSortDescriptor(
            rank: rank,
            typeLabel: describeFileType(ext),
            canonicalExtension: ext
        )
    }

    /// Returns the top-level type-sort rank for an entry.
    static func typeRank(for entry: FileEntry) -> Int {
        typeSortDescriptor(for: entry).rank
    }

    static func canonicalTypeExtension(_ ext: String?) -> String {
        switch ext?.lowercased() {
        case "jpeg": return "jpg"
        case "tif": return "tiff"
        case "aif": return "aiff"
        default: return ext?.lowercased() ?? ""
        }
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
            "mp4": "video/mp4", "mov": "video/quicktime", "m4v": "video/x-m4v",
            "mp3": "audio/mpeg", "wav": "audio/wav", "m4a": "audio/mp4",
            "flac": "audio/flac", "aac": "audio/aac", "ogg": "audio/ogg",
            "aiff": "audio/aiff", "aif": "audio/aiff", "wma": "audio/x-ms-wma",
            "alac": "audio/mp4",
        ]
        return map[ext] ?? "application/octet-stream"
    }
}
