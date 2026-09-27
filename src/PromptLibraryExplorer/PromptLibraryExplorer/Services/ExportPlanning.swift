import CoreGraphics
import Foundation

// MARK: - Resize math

/// Output pixel size and the source region that fills it.
struct ExportResizePlan: Equatable, Sendable {
    var outputWidth: Int
    var outputHeight: Int
    /// Region of the (oriented) source that is drawn, top-left origin, in source pixels.
    var sourceCrop: CGRect

    var changesPixels: Bool {
        Int(sourceCrop.width.rounded()) != outputWidth || Int(sourceCrop.height.rounded()) != outputHeight
            || sourceCrop.origin != .zero
    }
}

enum ExportGeometry {
    /// Largest side any export produces.
    static let maxDimension = 16384

    static func plan(sourceWidth: Int, sourceHeight: Int, sizing: ExportSizing) -> ExportResizePlan {
        let w = max(1, sourceWidth)
        let h = max(1, sourceHeight)
        let full = CGRect(x: 0, y: 0, width: w, height: h)

        func scaled(_ factor: Double) -> ExportResizePlan {
            let ow = clamp(Int((Double(w) * factor).rounded()))
            let oh = clamp(Int((Double(h) * factor).rounded()))
            return ExportResizePlan(outputWidth: ow, outputHeight: oh, sourceCrop: full)
        }

        switch sizing.mode {
        case .original:
            return ExportResizePlan(outputWidth: w, outputHeight: h, sourceCrop: full)

        case .longEdge:
            let target = max(1, sizing.longEdge)
            let long = max(w, h)
            if long <= target, !sizing.allowUpscale {
                return ExportResizePlan(outputWidth: w, outputHeight: h, sourceCrop: full)
            }
            return scaled(Double(target) / Double(long))

        case .scale:
            let percent = min(1000, max(1, sizing.scalePercent))
            if abs(percent - 100) < 0.0001 {
                return ExportResizePlan(outputWidth: w, outputHeight: h, sourceCrop: full)
            }
            return scaled(percent / 100)

        case .exact:
            let tw = clamp(sizing.width)
            let th = clamp(sizing.height)
            let sourceAspect = Double(w) / Double(h)
            let targetAspect = Double(tw) / Double(th)
            var crop = full
            if sourceAspect > targetAspect {
                // Source is wider: trim the sides.
                let cropWidth = Double(h) * targetAspect
                crop = CGRect(x: (Double(w) - cropWidth) / 2, y: 0, width: cropWidth, height: Double(h))
            } else if sourceAspect < targetAspect {
                let cropHeight = Double(w) / targetAspect
                crop = CGRect(x: 0, y: (Double(h) - cropHeight) / 2, width: Double(w), height: cropHeight)
            }
            return ExportResizePlan(outputWidth: tw, outputHeight: th, sourceCrop: crop)
        }
    }

    private static func clamp(_ value: Int) -> Int {
        min(maxDimension, max(1, value))
    }
}

// MARK: - Output names

/// What happens to one output file.
enum ExportWriteAction: String, Sendable, Equatable {
    case write
    /// An existing file of that name is replaced (moved to the Trash first).
    case overwrite
    /// An existing file of that name is left alone and this item isn't exported.
    case skip
}

struct ExportNameRequest: Sendable {
    var source: URL
    var context: RenameTemplateContext
    /// Extension of the output (e.g. "jpg"), or the source's for copy-through.
    var outputExtension: String
    var folder: URL
}

struct ExportPlannedName: Sendable, Equatable {
    var source: URL
    var destination: URL
    var action: ExportWriteAction
}

enum ExportNamePlanner {
    /// Renders the template for each request and resolves collisions within the batch and
    /// against files already in each destination folder. A name that would land on one of
    /// the batch's own originals always gets a number, whatever the policy.
    static func plan(
        template: String,
        requests: [ExportNameRequest],
        collision: ExportCollisionPolicy,
        existingNames: (URL) -> Set<String> = ExportNamePlanner.existingNames(in:)
    ) -> [ExportPlannedName] {
        let effectiveTemplate = template.trimmingCharacters(in: .whitespaces).isEmpty ? "{name}" : template
        let sourcePaths = Set(requests.map { $0.source.standardizedFileURL.path.lowercased() })
        var existingByFolder: [String: Set<String>] = [:]
        var plannedByFolder: [String: Set<String>] = [:]
        var result: [ExportPlannedName] = []
        result.reserveCapacity(requests.count)

        for request in requests {
            let folder = request.folder.standardizedFileURL
            let key = folder.path
            if existingByFolder[key] == nil {
                existingByFolder[key] = Set(existingNames(folder).map { $0.lowercased() })
            }
            let existing = existingByFolder[key] ?? []
            var planned = plannedByFolder[key] ?? []

            var context = request.context
            context.url = request.source.deletingPathExtension().appendingPathExtension(request.outputExtension)
            let rendered = RenameTemplateService.render(template: effectiveTemplate, context: context)

            func isOriginal(_ name: String) -> Bool {
                sourcePaths.contains(folder.appendingPathComponent(name).path.lowercased())
            }
            func unique(from name: String) -> String {
                let ext = (name as NSString).pathExtension
                let base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
                for n in 2...99_999 {
                    let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
                    let lower = candidate.lowercased()
                    if !existing.contains(lower), !planned.contains(lower), !isOriginal(candidate) {
                        return candidate
                    }
                }
                return "\(base) \(UUID().uuidString.prefix(8))" + (ext.isEmpty ? "" : ".\(ext)")
            }

            let lower = rendered.lowercased()
            var name = rendered
            var action = ExportWriteAction.write
            if planned.contains(lower) || isOriginal(rendered) {
                name = unique(from: rendered)
            } else if existing.contains(lower) {
                switch collision {
                case .unique: name = unique(from: rendered)
                case .overwrite: action = .overwrite
                case .skip: action = .skip
                }
            }
            if action != .skip {
                planned.insert(name.lowercased())
                plannedByFolder[key] = planned
            }
            result.append(ExportPlannedName(
                source: request.source,
                destination: folder.appendingPathComponent(name),
                action: action
            ))
        }
        return result
    }

    static func existingNames(in folder: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
    }
}

// MARK: - Size estimates

enum ExportEstimator {
    /// Rough output size in bytes. Copy-through and lossless metadata rewrites keep the
    /// source size; re-encodes use per-format bytes-per-pixel figures typical of
    /// generated images, scaled from the source's own compression when formats match.
    static func estimatedBytes(
        sourceBytes: Int64,
        sourcePixels: Int,
        outputPixels: Int,
        sourceFormat: ExportFormat,
        outputFormat: ExportFormat,
        quality: Double,
        reencodes: Bool
    ) -> Int64 {
        guard reencodes, outputPixels > 0 else { return sourceBytes }
        let q = min(1, max(0.05, quality))
        let bytesPerPixel: Double
        switch outputFormat {
        case .jpeg, .keepOriginal:
            bytesPerPixel = 0.08 + 0.6 * q * q
        case .heic:
            bytesPerPixel = (0.08 + 0.6 * q * q) * 0.55
        case .webp:
            bytesPerPixel = (0.08 + 0.6 * q * q) * 0.7
        case .png:
            if sourceFormat == .png, sourcePixels > 0, sourceBytes > 0 {
                bytesPerPixel = Double(sourceBytes) / Double(sourcePixels)
            } else {
                bytesPerPixel = 1.7
            }
        case .tiff:
            bytesPerPixel = 4
        }
        return Int64(Double(outputPixels) * bytesPerPixel) + 2_048
    }
}
