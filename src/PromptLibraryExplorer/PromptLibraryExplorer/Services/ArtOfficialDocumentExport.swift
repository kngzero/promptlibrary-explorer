import ArtOfficialFormats
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Rendering

/// Non-UI rendering entry points for Mood boards and Story projects. Pure and
/// synchronous: call off the main actor.
enum ArtOfficialRendering {
    /// Grid tile / preview image: the rendered board, or the default project's cover /
    /// contact sheet.
    static func overview(of document: ArtOfficialDocument, maxPixelSize: Int) -> CGImage? {
        switch document {
        case .moodboard(let board):
            return ArtOfficialRenderer.renderMoodboard(board, maxPixelSize: maxPixelSize)
        case .story(let story):
            guard let project = story.defaultProject else { return nil }
            return ArtOfficialRenderer.renderStoryContactSheet(project, maxPixelSize: maxPixelSize)
        }
    }

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    static func jpegData(_ image: CGImage, quality: Double = 0.9) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

// MARK: - Text exports

enum PaletteCopyFormat: String, CaseIterable, Identifiable {
    case hexList
    case cssVariables
    case json

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hexList: return "HEX List"
        case .cssVariables: return "CSS Variables"
        case .json: return "JSON"
        }
    }
}

enum ShotListFormat: String, CaseIterable, Identifiable {
    case text
    case csv

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: return "Text"
        case .csv: return "CSV"
        }
    }
}

enum ArtOfficialTextExport {
    /// `#RRGGBB` uppercase, invalid entries dropped.
    static func normalizedPalette(_ palette: [String]) -> [String] {
        palette.compactMap { value in
            var hex = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if hex.hasPrefix("#") { hex.removeFirst() }
            if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
            guard hex.count == 6, hex.allSatisfy(\.isHexDigit) else { return nil }
            return "#" + hex.uppercased()
        }
    }

    static func palette(_ palette: [String], as format: PaletteCopyFormat) -> String {
        let colors = normalizedPalette(palette)
        switch format {
        case .hexList:
            return colors.joined(separator: "\n")
        case .cssVariables:
            let lines = colors.enumerated().map { "  --palette-\($0.offset + 1): \($0.element);" }
            return ":root {\n" + lines.joined(separator: "\n") + "\n}"
        case .json:
            let quoted = colors.map { "\"\($0)\"" }
            return "[" + quoted.joined(separator: ", ") + "]"
        }
    }

    static func shotList(_ project: StoryProject, as format: ShotListFormat) -> String {
        let steps = project.storyboardSteps
        switch format {
        case .text:
            var lines: [String] = [project.title]
            var currentScene: String?
            for step in steps {
                if currentScene != step.scene.id {
                    currentScene = step.scene.id
                    let heading = step.scene.isUnassigned
                        ? StoryReader.unassignedName
                        : "Scene \(step.sceneNumber): \(step.scene.name)"
                    lines.append("")
                    lines.append(heading)
                }
                var line = "  \(step.shotNumber). \(step.shot.name.isEmpty ? "Untitled shot" : step.shot.name)"
                let types = step.shot.types.filter { !$0.isEmpty }
                if !types.isEmpty { line += " [\(types.joined(separator: ", "))]" }
                line += " (\(formatDuration(step.shot.estDurationSec)))"
                lines.append(line)
                let description = step.shot.description.trimmingCharacters(in: .whitespacesAndNewlines)
                if !description.isEmpty { lines.append("     \(description)") }
            }
            return lines.joined(separator: "\n")
        case .csv:
            var rows = [["Scene", "Scene Name", "Shot", "Name", "Type", "Duration (s)", "Description", "Notes", "Tags"]]
            for step in steps {
                rows.append([
                    step.scene.isUnassigned ? "" : String(step.sceneNumber),
                    step.scene.name,
                    String(step.shotNumber),
                    step.shot.name,
                    step.shot.types.joined(separator: "; "),
                    String(step.shot.estDurationSec),
                    step.shot.description,
                    step.shot.detailedNotes,
                    step.shot.tags.joined(separator: "; "),
                ])
            }
            return rows.map { $0.map(csvField).joined(separator: ",") }.joined(separator: "\n")
        }
    }

    static func csvField(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// "1:05", "12s", "1:02:03".
    static func formatDuration(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s < 60 { return "\(s)s" }
        let hours = s / 3600, minutes = (s % 3600) / 60, secs = s % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }
}

// MARK: - Extraction

enum ArtOfficialExtraction {
    struct Result: Sendable {
        var written = 0
        var skipped = 0
    }

    /// Writes every resolvable embedded image of `board` into `folder` (names from the
    /// assets, made unique). Logo/background assets are included.
    static func extractImages(from board: Moodboard, to folder: URL) -> Result {
        var result = Result()
        var used = existingNames(in: folder)
        for (offset, asset) in board.assets.enumerated() {
            guard let data = asset.image.data() else {
                result.skipped += 1
                continue
            }
            let ext = fileExtension(mimeType: asset.image.mimeType, data: data)
            let fallback = "image-\(offset + 1)"
            let base = sanitizedBaseName(asset.name, fallback: fallback)
            let url = uniqueURL(in: folder, base: base, ext: ext, used: &used)
            if (try? data.write(to: url, options: .atomic)) != nil {
                result.written += 1
            } else {
                result.skipped += 1
            }
        }
        return result
    }

    /// Writes each shot thumbnail of `project` as "S01-SH02 Name.ext".
    static func extractShotThumbnails(from project: StoryProject, to folder: URL) -> Result {
        var result = Result()
        var used = existingNames(in: folder)
        for step in project.storyboardSteps {
            guard let thumb = step.shot.thumb, let data = thumb.data() else {
                if step.shot.thumb != nil { result.skipped += 1 }
                continue
            }
            let prefix = step.scene.isUnassigned
                ? String(format: "U-SH%02d", step.shotNumber)
                : String(format: "S%02d-SH%02d", step.sceneNumber, step.shotNumber)
            let name = sanitizedBaseName(step.shot.name, fallback: "")
            let base = name.isEmpty ? prefix : "\(prefix) \(name)"
            let url = uniqueURL(in: folder, base: base, ext: fileExtension(mimeType: thumb.mimeType, data: data), used: &used)
            if (try? data.write(to: url, options: .atomic)) != nil {
                result.written += 1
            } else {
                result.skipped += 1
            }
        }
        return result
    }

    static func existingNames(in folder: URL) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return Set(names.map { $0.lowercased() })
    }

    /// `base.ext`, then `base 2.ext`, `base 3.ext`… not in `used` (case-insensitive).
    static func uniqueURL(in folder: URL, base: String, ext: String, used: inout Set<String>) -> URL {
        var candidate = "\(base).\(ext)"
        var counter = 2
        while used.contains(candidate.lowercased()) {
            candidate = "\(base) \(counter).\(ext)"
            counter += 1
        }
        used.insert(candidate.lowercased())
        return folder.appendingPathComponent(candidate)
    }

    /// Strips path separators and an existing image extension; empty -> `fallback`.
    static func sanitizedBaseName(_ name: String, fallback: String) -> String {
        var base = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let ext = (base as NSString).pathExtension.lowercased()
        if !ext.isEmpty, FileHelpers.imageExtensions.contains(ext) {
            base = (base as NSString).deletingPathExtension
        }
        base = base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        while base.hasPrefix(".") { base.removeFirst() }
        base = String(base.prefix(120)).trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? fallback : base
    }

    static func fileExtension(mimeType: String?, data: Data) -> String {
        switch mimeType?.lowercased() {
        case "image/png": return "png"
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/webp": return "webp"
        case "image/gif": return "gif"
        case "image/heic": return "heic"
        case "image/tiff": return "tiff"
        case "image/bmp": return "bmp"
        default: break
        }
        // Sniff the bytes.
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if bytes.starts(with: [0xFF, 0xD8]) { return "jpg" }
        if bytes.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
        if bytes.count >= 12, Array(bytes[8...11]) == [0x57, 0x45, 0x42, 0x50] { return "webp" }
        return "png"
    }
}
