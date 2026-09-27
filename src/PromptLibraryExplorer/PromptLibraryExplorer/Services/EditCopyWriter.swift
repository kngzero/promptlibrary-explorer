import Foundation

/// File ▸ Save Edited Copy…: writes the edited image as a NEW file next to the original
/// ("Name (edited).png", then "Name (edited 2).png", …). The original and its metadata
/// are only read. The copy keeps the original's prompt metadata unless the user asks to
/// strip AI metadata. Runs through the export engine (temp file, verify, then place).
enum EditCopyWriter {
    enum Failure: LocalizedError {
        case notEditable
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notEditable: return "Only edited images can be saved as an edited copy."
            case let .failed(detail): return "The edited copy couldn't be written (\(detail))."
            }
        }
    }

    /// The first free "<base> (edited).<ext>" name beside `source`.
    static func destination(for source: URL, fileExtension ext: String, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> URL {
        let folder = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        var n = 1
        while true {
            let suffix = n == 1 ? " (edited)" : " (edited \(n))"
            let candidate = folder.appendingPathComponent(ext.isEmpty ? base + suffix : "\(base)\(suffix).\(ext)")
            if candidate.standardizedFileURL.path != source.standardizedFileURL.path, !exists(candidate.path) {
                return candidate
            }
            n += 1
        }
    }

    static func preset(stripAIMetadata: Bool) -> ExportPreset {
        var preset = ExportPreset(name: "Edited Copy")
        preset.format = .keepOriginal
        preset.quality = 0.95
        preset.metadata = stripAIMetadata ? ExportMetadataPolicy(mode: .stripAI) : ExportMetadataPolicy(mode: .keepAll)
        return preset
    }

    /// Writes the copy and returns where it went. Call off the main actor.
    static func write(source: URL, recipe: EditRecipe, stripAIMetadata: Bool) async throws -> URL {
        let source = source.standardizedFileURL
        guard EditEligibility.isEditable(source.lastPathComponent), !recipe.isIdentity else { throw Failure.notEditable }
        let preset = preset(stripAIMetadata: stripAIMetadata)
        let output = ExportJobPlanner.output(for: source, kind: .image, preset: preset)
        let destination = destination(for: source, fileExtension: output.ext)
        let job = ExportJobItem(
            source: source, kind: .image, destination: destination,
            action: .write, format: output.format, edit: recipe
        )
        let result = await ExportEngine.export(job, preset: preset, watermarkImage: nil, protectedPaths: [source.path])
        switch result.outcome {
        case .written:
            guard let written = result.destination else { throw Failure.failed("no file") }
            return written
        case let .skipped(reason), let .failed(reason):
            throw Failure.failed(reason)
        }
    }
}
