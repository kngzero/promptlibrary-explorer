import AppKit
import Foundation

// Pure models behind visual search (Find Similar Images, More Like This,
// colour search). The engine (VisualIndexService / VisualIndexController)
// computes signatures and matches; these types shape what the UI does with them.
//
// HARD RULE: similar / duplicate results are for inspection only. Nothing here
// marks, pre-selects, ranks for removal or offers to delete any file.

// MARK: - Hex colours

/// An sRGB colour parsed from "#RRGGBB" / "RRGGBB" / "#RGB".
struct PaletteColor: Hashable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    init?(hex: String) {
        guard let normalized = Self.normalizedHex(hex) else { return nil }
        let value = UInt32(normalized.dropFirst(), radix: 16) ?? 0
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    init?(nsColor: NSColor) {
        guard let rgb = nsColor.usingColorSpace(.sRGB) else { return nil }
        self.init(red: Double(rgb.redComponent), green: Double(rgb.greenComponent), blue: Double(rgb.blueComponent))
    }

    /// "#RRGGBB" (uppercase), or nil when `value` isn't a 3- or 6-digit hex colour.
    static func normalizedHex(_ value: String) -> String? {
        var hex = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, hex.allSatisfy(\.isHexDigit) else { return nil }
        return "#" + hex.uppercased()
    }

    var hex: String {
        func byte(_ component: Double) -> Int { Int((component * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    /// Hue in degrees (0..<360), saturation and brightness (0…1), HSB/HSV model.
    var hsb: (hue: Double, saturation: Double, brightness: Double) {
        let maxValue = max(red, green, blue)
        let minValue = min(red, green, blue)
        let delta = maxValue - minValue
        var hue = 0.0
        if delta > 0 {
            if maxValue == red {
                hue = 60 * ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxValue == green {
                hue = 60 * ((blue - red) / delta + 2)
            } else {
                hue = 60 * ((red - green) / delta + 4)
            }
        }
        if hue < 0 { hue += 360 }
        let saturation = maxValue == 0 ? 0 : delta / maxValue
        return (hue, saturation, maxValue)
    }

    /// CIE L*a*b* (D65).
    var lab: (l: Double, a: Double, b: Double) {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let r = linear(red), g = linear(green), b = linear(blue)
        let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
        let y = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 1.0
        let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : (7.787 * t) + 16.0 / 116.0 }
        let fx = f(x), fy = f(y), fz = f(z)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    /// CIE76 ΔE between two colours (0 = identical, ~100 = black vs white).
    func distance(to other: PaletteColor) -> Double {
        let a = lab, b = other.lab
        return sqrt(pow(a.l - b.l, 2) + pow(a.a - b.a, 2) + pow(a.b - b.b, 2))
    }
}

// MARK: - Colour families (Group By ▸ Colour Family)

/// Hue bucket of a file's first dominant colour, plus neutrals.
enum ColorFamily: String, CaseIterable, Identifiable, Sendable {
    case red, orange, yellow, green, cyan, blue, purple, pink
    case neutral, dark, light

    var id: String { rawValue }

    var title: String {
        switch self {
        case .red: return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .cyan: return "Cyan"
        case .blue: return "Blue"
        case .purple: return "Purple"
        case .pink: return "Pink"
        case .neutral: return "Neutral"
        case .dark: return "Dark"
        case .light: return "Light"
        }
    }

    /// Order the families appear in when listed (rainbow, then neutrals).
    var sortRank: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    init(color: PaletteColor) {
        let (hue, saturation, brightness) = color.hsb
        if brightness < 0.2 {
            self = .dark
            return
        }
        if saturation < 0.12 || (saturation < 0.2 && brightness > 0.9) {
            self = brightness > 0.82 ? .light : .neutral
            return
        }
        switch hue {
        case ..<15: self = .red
        case ..<45: self = .orange
        case ..<70: self = .yellow
        case ..<160: self = .green
        case ..<200: self = .cyan
        case ..<255: self = .blue
        case ..<290: self = .purple
        case ..<345: self = .pink
        default: self = .red
        }
    }

    init?(hex: String) {
        guard let color = PaletteColor(hex: hex) else { return nil }
        self.init(color: color)
    }

    /// Family of the first (heaviest) dominant colour; nil when there are none.
    static func of(_ colors: [DominantColor]) -> ColorFamily? {
        guard let first = colors.first else { return nil }
        return ColorFamily(hex: first.hex)
    }
}

// MARK: - Colour filter / smart-folder rule

/// A palette of 1–3 colours plus a tolerance (0 = exact, 1 = loose). Used by
/// the Filter menu's colour filter and the smart-folder `dominantColor` rule.
struct ColorFilter: Codable, Hashable, Sendable {
    static let maxColors = 3
    static let defaultTolerance = 0.3

    private(set) var palette: [String]
    private(set) var tolerance: Double

    /// Nil when no valid colour remains after normalising.
    init?(palette: [String], tolerance: Double = ColorFilter.defaultTolerance) {
        var seen = Set<String>()
        let normalized = palette
            .compactMap(PaletteColor.normalizedHex)
            .filter { seen.insert($0).inserted }
        guard !normalized.isEmpty else { return nil }
        self.palette = Array(normalized.prefix(Self.maxColors))
        self.tolerance = tolerance.isFinite ? min(max(tolerance, 0), 1) : Self.defaultTolerance
    }

    enum CodingKeys: String, CodingKey { case palette, tolerance }

    /// Lenient: bad hex values are dropped, a missing tolerance uses the default;
    /// throws only when no valid colour is left.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = (try? c.decodeIfPresent([String].self, forKey: .palette)) ?? []
        let tolerance = (try? c.decodeIfPresent(Double.self, forKey: .tolerance)) ?? Self.defaultTolerance
        guard let value = ColorFilter(palette: raw, tolerance: tolerance) else {
            throw DecodingError.dataCorruptedError(forKey: .palette, in: c, debugDescription: "No valid colours")
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(palette, forKey: .palette)
        try c.encode(tolerance, forKey: .tolerance)
    }

    // Persistence as a JSON string (AppStorage).

    var storageString: String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Nil for "", garbage or a palette with no valid colour.
    init?(storageString: String) {
        guard !storageString.isEmpty, let data = storageString.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ColorFilter.self, from: data)
        else { return nil }
        self = decoded
    }

    /// Largest ΔE a dominant colour may be from a palette colour and still count.
    var maxDistance: Double { 8 + tolerance * 52 }

    var summary: String { palette.joined(separator: " ") }
}

enum PaletteMatcher {
    /// Colours lighter than this share of the image are ignored.
    static let minimumWeight = 0.03

    /// True when every palette colour is close to one of the file's dominant colours.
    static func matches(_ colors: [DominantColor], filter: ColorFilter) -> Bool {
        guard let distance = distance(colors, filter: filter) else { return false }
        return distance.worst <= filter.maxDistance
    }

    /// Worst and mean (over the palette) of each palette colour's nearest
    /// dominant-colour distance; nil when the file has no usable colours.
    static func distance(_ colors: [DominantColor], filter: ColorFilter) -> (worst: Double, mean: Double)? {
        let candidates = colors
            .filter { $0.weight >= minimumWeight }
            .compactMap { PaletteColor(hex: $0.hex) }
        guard !candidates.isEmpty else { return nil }
        let wanted = filter.palette.compactMap(PaletteColor.init(hex:))
        guard !wanted.isEmpty else { return nil }
        let nearest = wanted.map { target in candidates.map { target.distance(to: $0) }.min() ?? .infinity }
        return (nearest.max() ?? .infinity, nearest.reduce(0, +) / Double(nearest.count))
    }
}

// MARK: - Scope

/// Folder (direct children of the folder on screen) or the whole library
/// (everything under the root). Shared by Find Similar Images, More Like This
/// and palette search; persisted.
enum VisualSearchScopeChoice: String, CaseIterable, Identifiable, Sendable {
    case folder
    case library

    var id: String { rawValue }

    var title: String {
        switch self {
        case .folder: return "This Folder"
        case .library: return "Whole Library"
        }
    }
}

// MARK: - Virtual listings

/// A temporary, ranked listing shown in place of a folder: "Similar to …",
/// "Matching palette …" or one similar-images group. Like a collection it
/// replaces the folder's contents until closed; unlike one it isn't saved.
struct VirtualListing: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// More Like This: `path` is the reference image (listed first).
        case similarTo(path: String)
        /// Files ranked by how well their dominant colours match the palette.
        case palette(colors: [String])
        /// One group from Find Similar Images, in the group's own order.
        case similarGroup(exact: Bool)
    }

    /// What closing the listing returns to.
    enum Origin: Equatable, Sendable {
        case folder
        case collection(UUID)
    }

    let id: UUID
    var kind: Kind
    var title: String
    /// Ranked: most similar first (never "keeper first" — see the HARD RULE).
    var paths: [String]
    var origin: Origin

    init(id: UUID = UUID(), kind: Kind, title: String, paths: [String], origin: Origin = .folder) {
        self.id = id
        self.kind = kind
        self.title = title
        self.paths = paths
        self.origin = origin
    }

    var systemImage: String {
        switch kind {
        case .similarTo: return "sparkle.magnifyingglass"
        case .palette: return "paintpalette"
        case .similarGroup: return "square.on.square"
        }
    }

    /// The reference file to reselect when the listing closes.
    var sourcePath: String? {
        if case let .similarTo(path) = kind { return path }
        return nil
    }

    /// Rewrites `paths` after a rename / move (file or folder).
    mutating func migratePaths(from oldPath: String, to newPath: String) -> Bool {
        var changed = false
        paths = paths.map { path in
            if let rewritten = MetadataPathKeys.rewrite(path, from: oldPath, to: newPath), rewritten != path {
                changed = true
                return rewritten
            }
            return path
        }
        if case let .similarTo(source) = kind,
           let rewritten = MetadataPathKeys.rewrite(source, from: oldPath, to: newPath), rewritten != source
        {
            kind = .similarTo(path: rewritten)
            changed = true
        }
        return changed
    }
}

/// Which listing the browser shows: the folder, a collection, or a virtual
/// listing. Pure state machine behind `ExplorerViewModel`'s listing switches.
struct ListingModeState: Equatable {
    enum Mode: Equatable {
        case folder
        case collection(UUID)
        case virtual(VirtualListing)
    }

    var collectionID: UUID?
    var virtualListing: VirtualListing?

    var mode: Mode {
        if let virtualListing { return .virtual(virtualListing) }
        if let collectionID { return .collection(collectionID) }
        return .folder
    }

    /// Opens `listing`, remembering where to return: the open collection, or
    /// the origin of a virtual listing it replaces (so chains close back to
    /// where they started).
    mutating func openVirtual(_ listing: VirtualListing) {
        var next = listing
        if let collectionID {
            next.origin = .collection(collectionID)
        } else if let current = virtualListing {
            next.origin = current.origin
        } else {
            next.origin = .folder
        }
        collectionID = nil
        virtualListing = next
    }

    /// Closes the virtual listing, returning to its origin.
    mutating func closeVirtual() {
        guard let listing = virtualListing else { return }
        virtualListing = nil
        if case let .collection(id) = listing.origin {
            collectionID = id
        } else {
            collectionID = nil
        }
    }

    /// Opening (or, with nil, closing) a collection always leaves any virtual listing.
    mutating func openCollection(_ id: UUID?) {
        virtualListing = nil
        collectionID = id
    }

    /// Navigating to a folder leaves collections and virtual listings.
    mutating func selectFolder() {
        virtualListing = nil
        collectionID = nil
    }
}

// MARK: - Similar Images actions

/// Everything a Find Similar Images group (or a file in it) offers. There is
/// deliberately no removal / trash / "keep best" action: every file is kept.
enum SimilarGroupAction: String, CaseIterable, Identifiable, Sendable {
    case compare
    case selectInGrid
    case addToCollection
    case revealInFinder
    case openInLightbox

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compare: return "Compare"
        case .selectInGrid: return "Select in Grid"
        case .addToCollection: return "Add to Collection"
        case .revealInFinder: return "Reveal in Finder"
        case .openInLightbox: return "Open in Lightbox"
        }
    }

    var systemImage: String {
        switch self {
        case .compare: return "rectangle.split.2x1"
        case .selectInGrid: return "checkmark.circle"
        case .addToCollection: return "rectangle.stack.badge.plus"
        case .revealInFinder: return "folder"
        case .openInLightbox: return "arrow.up.left.and.arrow.down.right"
        }
    }

    /// Group-level buttons, in display order.
    static let groupActions: [SimilarGroupAction] = [.compare, .selectInGrid, .addToCollection, .revealInFinder]
    /// Per-file actions (click / double-click a thumbnail, its context menu).
    static let fileActions: [SimilarGroupAction] = [.openInLightbox, .revealInFinder]
}

// MARK: - Keys & eligibility

enum VisualSearchKeys {
    /// More Like This: bare M (no ⌘ ⌃ ⌥ ⇧), owned by the key monitors
    /// (grid `handleGlobalKey`, lightbox monitor) — never a menu key equivalent.
    static let moreLikeThisCharacter = "m"

    static func isMoreLikeThis(characters: String?, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard modifiers.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
        return characters?.lowercased() == moreLikeThisCharacter
    }

    static func isMoreLikeThis(_ event: NSEvent) -> Bool {
        isMoreLikeThis(characters: event.charactersIgnoringModifiers, modifiers: event.modifierFlags)
    }
}

enum VisualSearchEligibility {
    /// Files the visual index covers: images and videos.
    static func isVisual(_ name: String) -> Bool {
        FileHelpers.isImageFile(name) || FileHelpers.isVideoFile(name)
    }

    /// Files that have a palette to search with: visual files and Mood boards.
    static func hasPalette(_ name: String) -> Bool {
        isVisual(name) || FileHelpers.isMoodboardFile(name)
    }
}
