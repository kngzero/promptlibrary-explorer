import CoreGraphics
import CryptoKit
import Foundation

// MARK: - Edit recipe (non-destructive image edits)
//
// A recipe describes how to show an image; the file itself is never touched. Recipes are
// curation data keyed by absolute path (EditStore), follow renames / moves / trash-undo
// like ratings, travel in curation bundles and sync through the library data file.
//
// Pipeline (EditRenderer): oriented source → straighten (about the centre, frame kept) →
// crop (normalized to that frame) → quarter turns (clockwise) → flips (in the output's
// own space, so ↔ always mirrors what you see) → colour adjustments.
//
// JSON (schema `version` 1; every key optional, unknown keys ignored):
//   { "version": 1, "crop": { "x", "y", "width", "height" },   // 0…1, top-left origin
//     "aspect": "free" | "original" | "1:1" | "4:5" | "3:2" | "16:9" | "9:16" | "2:3",
//     "straighten": -45…45 (degrees, positive = clockwise), "quarterTurns": 0…3,
//     "flipHorizontal": bool, "flipVertical": bool,
//     "exposure": -2…2 (EV), "contrast": -1…1, "saturation": -1…1, "temperature": -1…1 }
// A legacy / hand-written "rotation" in degrees (a multiple of 90) reads as quarter turns.

/// A normalized rectangle (0…1 of the frame it lives in, top-left origin).
struct EditRect: Codable, Equatable, Hashable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    static let full = EditRect(x: 0, y: 0, width: 1, height: 1)

    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    var midX: Double { x + width / 2 }
    var midY: Double { y + height / 2 }
    var maxX: Double { x + width }
    var maxY: Double { y + height }

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(_ rect: CGRect) {
        self.init(x: Double(rect.minX), y: Double(rect.minY), width: Double(rect.width), height: Double(rect.height))
    }

    init(centerX: Double, centerY: Double, width: Double, height: Double) {
        self.init(x: centerX - width / 2, y: centerY - height / 2, width: width, height: height)
    }

    var isFull: Bool {
        abs(x) < 1e-6 && abs(y) < 1e-6 && abs(width - 1) < 1e-6 && abs(height - 1) < 1e-6
    }

    /// Clamped inside the unit square (size first, then position).
    var clampedToUnit: EditRect {
        let w = min(1, max(EditGeometry.minimumCropFraction, width))
        let h = min(1, max(EditGeometry.minimumCropFraction, height))
        return EditRect(x: min(max(0, x), 1 - w), y: min(max(0, y), 1 - h), width: w, height: h)
    }

    func lerp(to other: EditRect, _ t: Double) -> EditRect {
        EditRect(
            x: x + (other.x - x) * t,
            y: y + (other.y - y) * t,
            width: width + (other.width - width) * t,
            height: height + (other.height - height) * t
        )
    }
}

/// Crop aspect presets. Ratios are for the OUTPUT (after quarter turns).
enum EditAspect: String, Codable, CaseIterable, Identifiable, Sendable {
    case free
    case original
    case square = "1:1"
    case portrait4x5 = "4:5"
    case landscape3x2 = "3:2"
    case landscape16x9 = "16:9"
    case portrait9x16 = "9:16"
    case portrait2x3 = "2:3"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .free: return "Free"
        case .original: return "Original"
        default: return rawValue
        }
    }

    /// Width / height of the output, or nil for Free. `originalRatio` is the output
    /// frame's ratio (the source's, turned by the quarter turns).
    func ratio(originalRatio: Double) -> Double? {
        switch self {
        case .free: return nil
        case .original: return originalRatio
        case .square: return 1
        case .portrait4x5: return 4.0 / 5.0
        case .landscape3x2: return 3.0 / 2.0
        case .landscape16x9: return 16.0 / 9.0
        case .portrait9x16: return 9.0 / 16.0
        case .portrait2x3: return 2.0 / 3.0
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = EditAspect(rawValue: raw) ?? .free
    }
}

struct EditRecipe: Codable, Equatable, Hashable, Sendable {
    static let currentVersion = 1
    static let straightenRange: ClosedRange<Double> = -45...45
    static let exposureRange: ClosedRange<Double> = -2...2
    static let unitRange: ClosedRange<Double> = -1...1

    var version: Int = EditRecipe.currentVersion
    /// Normalized to the straightened frame (same size as the oriented source). nil = all.
    var crop: EditRect?
    var aspect: EditAspect = .free
    /// Degrees, positive = clockwise on screen.
    var straighten: Double = 0
    /// Clockwise quarter turns, 0…3.
    var quarterTurns: Int = 0
    var flipHorizontal = false
    var flipVertical = false
    var exposure: Double = 0
    var contrast: Double = 0
    var saturation: Double = 0
    var temperature: Double = 0

    init() {}

    static let identity = EditRecipe()

    enum CodingKeys: String, CodingKey {
        case version, crop, aspect, straighten, quarterTurns, flipHorizontal, flipVertical
        case exposure, contrast, saturation, temperature
        case rotation   // legacy / hand-written: degrees, a multiple of 90
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func double(_ key: CodingKeys) -> Double {
            let value = (try? c.decodeIfPresent(Double.self, forKey: key)) ?? 0
            return value.isFinite ? value : 0
        }
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        crop = try? c.decodeIfPresent(EditRect.self, forKey: .crop)
        aspect = (try? c.decodeIfPresent(EditAspect.self, forKey: .aspect)) ?? .free
        straighten = double(.straighten)
        if let turns = try? c.decodeIfPresent(Int.self, forKey: .quarterTurns) {
            quarterTurns = turns
        } else if let degrees = try? c.decodeIfPresent(Double.self, forKey: .rotation), degrees.isFinite {
            quarterTurns = Int((degrees / 90).rounded())
        }
        flipHorizontal = (try? c.decodeIfPresent(Bool.self, forKey: .flipHorizontal)) ?? false
        flipVertical = (try? c.decodeIfPresent(Bool.self, forKey: .flipVertical)) ?? false
        exposure = double(.exposure)
        contrast = double(.contrast)
        saturation = double(.saturation)
        temperature = double(.temperature)
        self = normalized()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encodeIfPresent(crop, forKey: .crop)
        if aspect != .free { try c.encode(aspect, forKey: .aspect) }
        if straighten != 0 { try c.encode(straighten, forKey: .straighten) }
        if quarterTurns != 0 { try c.encode(quarterTurns, forKey: .quarterTurns) }
        if flipHorizontal { try c.encode(true, forKey: .flipHorizontal) }
        if flipVertical { try c.encode(true, forKey: .flipVertical) }
        if exposure != 0 { try c.encode(exposure, forKey: .exposure) }
        if contrast != 0 { try c.encode(contrast, forKey: .contrast) }
        if saturation != 0 { try c.encode(saturation, forKey: .saturation) }
        if temperature != 0 { try c.encode(temperature, forKey: .temperature) }
    }

    // MARK: Queries

    var hasGeometry: Bool {
        !(crop?.isFull ?? true) || straighten != 0 || quarterTurns != 0 || flipHorizontal || flipVertical
    }

    var hasAdjustments: Bool {
        exposure != 0 || contrast != 0 || saturation != 0 || temperature != 0
    }

    /// Shows the image exactly as the file does (the aspect preset alone changes nothing).
    var isIdentity: Bool { !hasGeometry && !hasAdjustments }

    /// True when the output's width and height are swapped relative to the source.
    var swapsAxes: Bool { quarterTurns % 2 == 1 }

    /// Values clamped to their ranges and rounded (so recipes compare and hash the same
    /// after a JSON round trip on another Mac).
    func normalized() -> EditRecipe {
        var copy = self
        func round6(_ value: Double) -> Double { (value * 1_000_000).rounded() / 1_000_000 }
        copy.version = max(1, version)
        copy.straighten = round6(min(max(straighten, Self.straightenRange.lowerBound), Self.straightenRange.upperBound))
        copy.quarterTurns = ((quarterTurns % 4) + 4) % 4
        copy.exposure = round6(min(max(exposure, Self.exposureRange.lowerBound), Self.exposureRange.upperBound))
        copy.contrast = round6(min(max(contrast, -1), 1))
        copy.saturation = round6(min(max(saturation, -1), 1))
        copy.temperature = round6(min(max(temperature, -1), 1))
        if let crop {
            let clamped = crop.clampedToUnit
            let rounded = EditRect(x: round6(clamped.x), y: round6(clamped.y), width: round6(clamped.width), height: round6(clamped.height))
            copy.crop = rounded.isFull ? nil : rounded
        }
        return copy
    }

    /// Short stable digest of the rendering-relevant values (thumbnail cache keys).
    var hashToken: String {
        let recipe = normalized()
        var parts: [String] = ["v\(recipe.version)"]
        if let crop = recipe.crop { parts.append("c\(crop.x),\(crop.y),\(crop.width),\(crop.height)") }
        parts.append("s\(recipe.straighten)|q\(recipe.quarterTurns)|h\(recipe.flipHorizontal ? 1 : 0)|v\(recipe.flipVertical ? 1 : 0)")
        parts.append("e\(recipe.exposure)|k\(recipe.contrast)|a\(recipe.saturation)|t\(recipe.temperature)")
        let digest = SHA256.hash(data: Data(parts.joined(separator: "|").utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// "Cropped · Rotated · Adjusted"
    var summary: String {
        var parts: [String] = []
        if !(crop?.isFull ?? true) { parts.append("Cropped") }
        if straighten != 0 { parts.append("Straightened \(String(format: "%.1f", straighten))°") }
        if quarterTurns != 0 { parts.append("Rotated \(quarterTurns * 90)°") }
        if flipHorizontal || flipVertical { parts.append("Flipped") }
        if hasAdjustments { parts.append("Adjusted") }
        return parts.isEmpty ? "No changes" : parts.joined(separator: " · ")
    }
}

// MARK: - Eligibility

enum EditEligibility {
    /// Raster images the editor can work on (videos, audio, Mood / Story, .plib / .aoe,
    /// vector and icon files are not).
    static func isEditable(_ name: String) -> Bool {
        guard FileHelpers.isImageFile(name) else { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        return !["icns", "svg", "pdf", "ico"].contains(ext)
    }

    /// Why a file can't be edited, for disabled menu items and help tags.
    static func reason(forName name: String) -> String? {
        if isEditable(name) { return nil }
        if FileHelpers.isVideoFile(name) { return "Videos can't be edited" }
        if FileHelpers.isAudioFile(name) { return "Audio files can't be edited" }
        if FileHelpers.isArtOfficialDocumentFile(name) { return "Mood boards and Story projects are edited in their own apps" }
        if FileHelpers.isPromptSnapshotFile(name) { return ".plib and .aoe snapshots can't be edited" }
        return "Only images can be edited"
    }
}

// MARK: - Geometry (pure)

/// Crop / straighten / rotation math. Pixel sizes are the ORIENTED source size (W×H).
/// The crop lives in the straightened frame, which has the source's size; a crop is
/// valid when every corner lands on the rotated image (no empty corners).
enum EditGeometry {
    static let minimumCropFraction = 0.02

    /// Output pixel size for `recipe` on a W×H source (crop in pixels, turned).
    static func outputSize(for recipe: EditRecipe, sourceSize: CGSize) -> CGSize {
        let crop = pixelRect(for: recipe.crop ?? .full, in: sourceSize)
        return recipe.swapsAxes ? CGSize(width: crop.height, height: crop.width) : crop.size
    }

    /// Normalized → whole pixels (top-left origin), at least 1×1, inside the frame.
    static func pixelRect(for rect: EditRect, in size: CGSize) -> CGRect {
        let width = Double(size.width), height = Double(size.height)
        let minX = (rect.x * width).rounded(), minY = (rect.y * height).rounded()
        let maxX = (rect.maxX * width).rounded(), maxY = (rect.maxY * height).rounded()
        let x = min(max(0, minX), max(0, width - 1))
        let y = min(max(0, minY), max(0, height - 1))
        let w = max(1, min(maxX, width) - x)
        let h = max(1, min(maxY, height) - y)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Pixels (top-left origin) → normalized.
    static func normalizedRect(for rect: CGRect, in size: CGSize) -> EditRect {
        guard size.width > 0, size.height > 0 else { return .full }
        return EditRect(
            x: Double(rect.minX / size.width), y: Double(rect.minY / size.height),
            width: Double(rect.width / size.width), height: Double(rect.height / size.height)
        )
    }

    /// Output frame ratio (width / height) after the quarter turns.
    static func frameRatio(sourceSize: CGSize, quarterTurns: Int) -> Double {
        guard sourceSize.width > 0, sourceSize.height > 0 else { return 1 }
        let ratio = Double(sourceSize.width / sourceSize.height)
        return quarterTurns % 2 == 1 ? 1 / ratio : ratio
    }

    /// The output aspect `aspect` asks for, expressed as a crop-space PIXEL ratio.
    static func cropPixelRatio(for aspect: EditAspect, sourceSize: CGSize, quarterTurns: Int) -> Double? {
        let frame = frameRatio(sourceSize: sourceSize, quarterTurns: quarterTurns)
        guard let output = aspect.ratio(originalRatio: frame), output > 0 else { return nil }
        return quarterTurns % 2 == 1 ? 1 / output : output
    }

    // MARK: Validity under straighten

    private static func trig(_ degrees: Double) -> (cos: Double, sin: Double) {
        let radians = degrees * .pi / 180
        return (cos(radians), sin(radians))
    }

    /// True when all four corners of `rect` lie on the image rotated by `angle` degrees.
    static func isValid(_ rect: EditRect, angle: Double, sourceSize: CGSize, tolerance: Double = 1e-6) -> Bool {
        guard rect.x >= -tolerance, rect.y >= -tolerance, rect.maxX <= 1 + tolerance, rect.maxY <= 1 + tolerance,
              rect.width > 0, rect.height > 0 else { return false }
        return scaleToFit(rect, angle: angle, sourceSize: sourceSize) >= 1 - tolerance
    }

    /// The largest factor the rect can be scaled by (about its centre) and stay on the
    /// rotated image. ≥ 1 means it's valid as is; ≤ 0 means its centre is off the image.
    static func scaleToFit(_ rect: EditRect, angle: Double, sourceSize: CGSize) -> Double {
        let W = Double(sourceSize.width), H = Double(sourceSize.height)
        guard W > 0, H > 0 else { return 0 }
        let (c, s) = trig(angle)
        let ac = abs(c), asn = abs(s)
        let dx = (rect.midX - 0.5) * W, dy = (rect.midY - 0.5) * H
        let a = rect.width * W / 2, b = rect.height * H / 2
        // Corner p = q + (±a, ±b); source point = R(-θ)(p - c) must stay within ±W/2, ±H/2.
        let roomX = W / 2 - abs(dx * c + dy * s)
        let roomY = H / 2 - abs(-dx * s + dy * c)
        let needX = a * ac + b * asn
        let needY = a * asn + b * ac
        guard roomX > 0, roomY > 0 else { return 0 }
        return min(needX > 0 ? roomX / needX : .infinity, needY > 0 ? roomY / needY : .infinity)
    }

    /// Largest crop of crop-space pixel ratio `ratio` (nil = the frame's own ratio),
    /// centred on the frame, that stays on the image rotated by `angle`.
    static func maxCrop(ratio: Double?, angle: Double, sourceSize: CGSize) -> EditRect {
        let W = Double(sourceSize.width), H = Double(sourceSize.height)
        guard W > 0, H > 0 else { return .full }
        let r = ratio ?? (W / H)
        let (c, s) = trig(angle)
        let ac = abs(c), asn = abs(s)
        // Half sizes a = r·t, b = t.
        let t = min((W / 2) / (r * ac + asn), (H / 2) / (r * asn + ac))
        let width = min(1, 2 * r * t / W), height = min(1, 2 * t / H)
        return EditRect(centerX: 0.5, centerY: 0.5, width: width, height: height)
    }

    /// `rect` shrunk about its centre (and pulled inside the frame) until valid.
    static func fitted(_ rect: EditRect, angle: Double, sourceSize: CGSize) -> EditRect {
        var current = rect.clampedToUnit
        for _ in 0..<4 {
            let scale = scaleToFit(current, angle: angle, sourceSize: sourceSize)
            if scale >= 1 - 1e-9 { return current }
            if scale <= 0 {
                // Centre is off the image: recentre, keeping the size.
                current = EditRect(centerX: 0.5, centerY: 0.5, width: current.width, height: current.height)
                continue
            }
            let factor = scale * (1 - 1e-9)
            current = EditRect(centerX: current.midX, centerY: current.midY, width: current.width * factor, height: current.height * factor)
                .clampedToUnit
        }
        return isValid(current, angle: angle, sourceSize: sourceSize) ? current : maxCrop(ratio: current.width * Double(sourceSize.width) / max(1e-9, current.height * Double(sourceSize.height)), angle: angle, sourceSize: sourceSize)
    }

    /// The closest valid rect on the way from `valid` to `candidate` (drags that would
    /// uncover an empty corner stop at the edge instead of jumping back).
    static func constrained(from valid: EditRect, toward candidate: EditRect, angle: Double, sourceSize: CGSize) -> EditRect {
        let candidate = candidate
        if isValid(candidate, angle: angle, sourceSize: sourceSize) { return candidate }
        guard isValid(valid, angle: angle, sourceSize: sourceSize) else {
            return fitted(candidate, angle: angle, sourceSize: sourceSize)
        }
        var low = 0.0, high = 1.0
        for _ in 0..<24 {
            let mid = (low + high) / 2
            if isValid(valid.lerp(to: candidate, mid), angle: angle, sourceSize: sourceSize) { low = mid } else { high = mid }
        }
        return valid.lerp(to: candidate, low)
    }

    /// Rect of pixel ratio `ratio` with the same centre and area-ish as `rect`, valid.
    static func applyingRatio(_ ratio: Double?, to rect: EditRect, angle: Double, sourceSize: CGSize) -> EditRect {
        guard let ratio else { return fitted(rect, angle: angle, sourceSize: sourceSize) }
        let W = Double(sourceSize.width), H = Double(sourceSize.height)
        guard W > 0, H > 0 else { return rect }
        // Largest rect of that ratio inside the current one, then grown to the max valid
        // size around the same centre.
        let maxAtCentre = maxCrop(ratio: ratio, angle: angle, sourceSize: sourceSize)
        var candidate = EditRect(centerX: rect.midX, centerY: rect.midY, width: maxAtCentre.width, height: maxAtCentre.height)
        candidate = candidate.clampedToUnit
        return fitted(candidate, angle: angle, sourceSize: sourceSize)
    }

    // MARK: Display space (turned + flipped) ↔ crop space

    /// A crop-space normalized point → the output frame's normalized point.
    static func displayPoint(fromCrop point: CGPoint, quarterTurns: Int, flipH: Bool, flipV: Bool) -> CGPoint {
        var p = point
        for _ in 0..<(((quarterTurns % 4) + 4) % 4) {
            p = CGPoint(x: 1 - p.y, y: p.x)   // 90° clockwise
        }
        if flipH { p.x = 1 - p.x }
        if flipV { p.y = 1 - p.y }
        return p
    }

    static func cropPoint(fromDisplay point: CGPoint, quarterTurns: Int, flipH: Bool, flipV: Bool) -> CGPoint {
        var p = point
        if flipV { p.y = 1 - p.y }
        if flipH { p.x = 1 - p.x }
        for _ in 0..<(((quarterTurns % 4) + 4) % 4) {
            p = CGPoint(x: p.y, y: 1 - p.x)   // 90° counter-clockwise
        }
        return p
    }

    static func displayRect(fromCrop rect: EditRect, quarterTurns: Int, flipH: Bool, flipV: Bool) -> EditRect {
        let a = displayPoint(fromCrop: CGPoint(x: rect.x, y: rect.y), quarterTurns: quarterTurns, flipH: flipH, flipV: flipV)
        let b = displayPoint(fromCrop: CGPoint(x: rect.maxX, y: rect.maxY), quarterTurns: quarterTurns, flipH: flipH, flipV: flipV)
        return EditRect(x: Double(min(a.x, b.x)), y: Double(min(a.y, b.y)), width: Double(abs(b.x - a.x)), height: Double(abs(b.y - a.y)))
    }

    static func cropRect(fromDisplay rect: EditRect, quarterTurns: Int, flipH: Bool, flipV: Bool) -> EditRect {
        let a = cropPoint(fromDisplay: CGPoint(x: rect.x, y: rect.y), quarterTurns: quarterTurns, flipH: flipH, flipV: flipV)
        let b = cropPoint(fromDisplay: CGPoint(x: rect.maxX, y: rect.maxY), quarterTurns: quarterTurns, flipH: flipH, flipV: flipV)
        return EditRect(x: Double(min(a.x, b.x)), y: Double(min(a.y, b.y)), width: Double(abs(b.x - a.x)), height: Double(abs(b.y - a.y)))
    }
}

// MARK: - Thread-safe snapshot

/// A lock-protected copy of every recipe, for code that runs off the main actor
/// (thumbnail keys, the viewing loader, exports, Send to Mood / Story). The edit
/// controller keeps it in step with the store.
final class EditRecipeIndex: @unchecked Sendable {
    /// Filled from the store on first use, so code that runs before the controller
    /// exists (launch thumbnails, automation exports) already sees the edits.
    static let shared: EditRecipeIndex = {
        let index = EditRecipeIndex()
        index.replaceAll(EditStore().load().recipes)
        return index
    }()

    private let lock = NSLock()
    private var recipes: [String: EditRecipe] = [:]

    init() {}

    /// The recipe to show `path` with (nil for none, identity, or a non-editable type).
    func recipe(for path: String) -> EditRecipe? {
        lock.lock()
        let recipe = recipes[path]
        lock.unlock()
        guard let recipe, !recipe.isIdentity, EditEligibility.isEditable((path as NSString).lastPathComponent) else { return nil }
        return recipe
    }

    /// Looks the file up by its path as given and standardized.
    func recipe(for url: URL) -> EditRecipe? {
        recipe(for: url.path) ?? recipe(for: url.standardizedFileURL.path)
    }

    func replaceAll(_ next: [String: EditRecipe]) {
        lock.lock()
        recipes = next
        lock.unlock()
    }

    func set(_ recipe: EditRecipe?, for path: String) {
        lock.lock()
        recipes[path] = recipe
        lock.unlock()
    }
}

/// Thumbnail / preview cache signatures for edited files.
enum EditCacheKey {
    /// `base` (path + mtime + size + pixel size) extended with the recipe's digest.
    static func signature(_ base: String, recipe: EditRecipe?) -> String {
        guard let recipe, !recipe.isIdentity else { return base }
        return base + "|edit:" + recipe.hashToken
    }
}
