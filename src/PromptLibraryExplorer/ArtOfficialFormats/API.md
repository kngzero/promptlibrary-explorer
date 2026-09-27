# ArtOfficialFormats — public API

SwiftPM library target `ArtOfficialFormats` (`import ArtOfficialFormats`).
Imports only Foundation, CoreGraphics, ImageIO, UniformTypeIdentifiers, CoreText,
Compression — safe for sandboxed Quick Look / Thumbnail extensions. No AppKit/SwiftUI.
Every public type is a `Sendable` value type; every function is pure (no global
mutable state, no network access ever).

All readers are **lenient**: a malformed element is skipped, never fatal. Readers
throw `ArtOfficialFormatError` only when the container itself is unusable.

---

## Errors

```swift
public enum ArtOfficialFormatError: Error, Sendable, Equatable {
    case unreadable(String)        // I/O failure
    case notJSON                   // bytes are neither JSON nor a supported archive
    case unsupportedFormat(String) // JSON but wrong shape (e.g. no projects/scenes/shots)
    case archive(String)           // ZIP damaged / over limits / meta.json missing
    case writeFailed(String)
}
```

## File kinds

```swift
public enum ArtOfficialFileKind: String, Sendable, CaseIterable {
    case moodboard      // .mlmboard
    case story          // .stry
    case storyLegacy    // .mlseq
    case promptLibrary  // .plib
    case elements       // .aoe

    public static func detect(url: URL) -> ArtOfficialFileKind?   // by extension, case-insensitive
    public static func detect(pathExtension: String) -> ArtOfficialFileKind?
    public var fileExtension: String          // "mlmboard", "stry", ...
    public var typeIdentifier: String         // UTI string, see below
    public var utType: UTType                 // UTType(typeIdentifier) ?? UTType(filenameExtension:) ?? .data
    public var displayName: String            // "Mood Board", "Story Project", ...
}

public enum ArtOfficialTypeIdentifiers {
    public static let moodboard   = "com.artofficial.mood.mlmboard"
    public static let story       = "com.artofficial.story.project"
    public static let storyLegacy = "com.artofficial.story.mlseq"
    public static let plib        = "com.artofficial.plib"
    public static let aoe         = "com.artofficial.aoe"
    public static let all: [String]
}
```

## EmbeddedImage

A reference to an image inside a document. Holds the *raw* encoded string (or a
lazy archive/file reference) — never decoded bytes. Decoding happens on demand.

```swift
public struct EmbeddedImage: Sendable {
    public enum SourceKind: String, Sendable {
        case dataURL              // data:image/...;base64,... (or percent-encoded data: URL)
        case base64               // bare base64 payload (plib/aoe)
        case remoteURL            // http(s)://... — NEVER fetched; data() == nil
        case unresolvedReference  // e.g. Story web "img_*" IndexedDB id; data() == nil
        case file                 // local file path / file:// URL (read on demand)
        case archiveEntry         // entry inside a legacy .mlmboard ZIP (inflated on demand)
        case inlineData           // bytes supplied in memory
    }

    public let sourceKind: SourceKind
    public let mimeType: String?          // from data URL header / extension; nil if unknown
    public var reference: String?         // URL / img_ id / path / entry name (nil for data URLs)
    public var isResolvable: Bool         // false for remoteURL/unresolvedReference
    public var encodedByteCount: Int      // size of the encoded payload (no decoding)

    public static func parse(_ string: String, relativeTo baseURL: URL? = nil) -> EmbeddedImage?
        // classifies any string: data:, http(s):, img_*, file://, absolute path,
        // long bare base64, or (with baseURL) a relative path. nil for empty strings.
    public static func dataURL(_ string: String) -> EmbeddedImage?
    public init(data: Data, mimeType: String?)          // .inlineData
    public init(fileURL: URL, mimeType: String? = nil)  // .file

    public func data() -> Data?                           // decode on demand; nil if malformed/remote
    public func cgImage(maxPixelSize: Int) -> CGImage?     // ImageIO thumbnail, EXIF-orientation applied
    public func pixelSize() -> CGSize?                    // header-only size query
}
```

## Mood boards (`.mlmboard`)

```swift
public struct Moodboard: Sendable {
    public enum LayoutMode: String, Sendable { case auto, grid, mosaic }
    public enum BoardMode: String, Sendable { case grid, infinite }       // Mac-only key

    public var title: String                   // default "My Mood Board"
    public var subtitle: String                // default "Project Name"
    public var hideTitle: Bool                 // Mac-only key, default false
    public var hideSubtitle: Bool              // Mac-only key, default false
    public var layoutMode: LayoutMode          // default .auto (legacy default .mosaic, "square" -> .grid)
    public var boardMode: BoardMode?           // Mac-only
    public var columns: Int                    // default 4
    public var gap: Double                     // default 12
    public var padding: Double                 // boardPadding, default 32
    public var rounded: Bool                   // roundedCorners, default true
    public var shadow: Bool                    // softShadow, default true
    public var safeMargin: Double              // default 0
    public var zoom: Double                    // canvas zoom %, default 100
    public var aspectRatio: String             // "auto" | "1:1" | "4:3" | ... default "auto"
    public var imageBorder: Bool               // default false
    public var imageBorderWidth: Double        // default 2
    public var imageBorderHex: String          // default "#FFFFFF"
    public var canvasWidth: Int?               // Mac-only explicit canvas px size
    public var canvasHeight: Int?
    public var backgroundHex: String           // default "#FFFFFF"
    public var textHex: String                 // default "#1F2937"
    public var palette: [String]
    public var customPalette: [String]
    public var font: String                    // CSS class, e.g. "font-inter"
    public var logo: MoodboardLogo?            // (assetId, scale, position "top-left"|...)
    public var background: MoodboardBackground? // (assetId, opacity, blur)
    public var assets: [MoodboardAsset]
    public var tiles: [MoodboardTile]
    public var isLegacyArchive: Bool           // true when read from the ZIP format
    public var sourceByteCount: Int

    public init()                              // all spec defaults
    public func asset(id: String) -> MoodboardAsset?
    public var aspectRatioValue: Double? { get } // canvasWidth/Height or "w:h"; nil for "auto"
    public var logoAsset: MoodboardAsset? { get }
    public var backgroundAsset: MoodboardAsset? { get }
    public var imageTileCount: Int { get }
}

public struct MoodboardAsset: Sendable, Identifiable {
    public enum Kind: String, Sendable { case image, logo }
    public var id: String; public var name: String; public var kind: Kind
    public var image: EmbeddedImage
}

public struct MoodboardTile: Sendable, Identifiable {
    public enum Content: Sendable {
        case image(assetId: String, pan: CGPoint, zoom: Double)   // pan: ratio of tile (0,0 = centred)
        case color(hex: String)
        case text(String, textHex: String?, backgroundHex: String?, fontSize: Int?, alignment: String?, bold: Bool)  // Mac/web text tiles
    }
    public var id: String
    public var colSpan: Int      // >= 1
    public var rowSpan: Int      // >= 1
    public var caption: String?
    public var content: Content
    public var assetId: String? { get }     // convenience for .image
    public init(id:colSpan:rowSpan:caption:content:)
}

public struct MoodboardLogo: Sendable { public var assetId: String; public var scale: Double; public var position: String }
public struct MoodboardBackground: Sendable { public var assetId: String; public var opacity: Double; public var blur: Double }

public enum MoodboardReader {
    public static func read(from url: URL) throws -> Moodboard   // memory-mapped read
    public static func read(data: Data) throws -> Moodboard      // JSON (current, Mac-native) or legacy ZIP
}

public struct MoodboardDraft: Sendable {
    public struct Image: Sendable { public var name: String; public var data: Data; public var mimeType: String
                                    public init(name:data:mimeType:) }
    public var title: String = "My Mood Board"
    public var subtitle: String = "Project Name"
    public var images: [Image] = []
    public var palette: [String]? = nil          // nil -> default palette
    public var layoutMode: Moodboard.LayoutMode = .auto
    public var columns: Int = 4
    public var backgroundHex: String? = nil      // nil -> palette.first ?? "#FFFFFF"
    public var textHex: String? = nil            // nil -> palette.last ?? "#1F2937"
    public init(title:subtitle:images:palette:layoutMode:columns:backgroundHex:textHex:)  // all defaulted
}

public enum MoodboardWriter {
    public static func encode(_ draft: MoodboardDraft) throws -> Data  // current JSON format
    public static func write(_ draft: MoodboardDraft, to url: URL) throws  // atomic
}

public enum MoodboardPalette {
    public static let defaultPalette: [String]        // web "Default" preset
    public static func extract(from images: [CGImage], count: Int) -> [String]  // "#RRGGBB", light -> dark
}
```

## Story (`.stry`, legacy `.mlseq`)

```swift
public struct StoryDocument: Sendable {
    public var projects: [StoryProject]      // sorted by index
    public var sourceByteCount: Int
}

public struct StoryProject: Sendable, Identifiable {
    public var id: String; public var index: Int
    public var title, code, status: String   // defaults "Untitled", "", "Planning"
    public var logline, director, producer, productionNotes: String?
    public var aspectRatio: String            // default "16:9"
    public var aspectRatioValue: Double       // w/h, 16/9 fallback
    public var dateStart, dateEnd: String?    // "yyyy-MM-dd" as written
    public var coverImage: EmbeddedImage?
    public var scenes: [StoryScene]           // ordered by index; "Unassigned" scene last if any
    public var scripts: [StoryScript]
    public var assetLists: [StoryAssetList]   // Mac/web asset library
    public var isUnassigned: Bool             // synthetic orphan-collector project
    public var estimatedDurationSec: Int      // sum of shot durations (scene est. if scene has no shots)
    public var allShots: [StoryShot] { get }
    public var shotCount: Int { get }
}

public struct StoryScene: Sendable, Identifiable {
    public var id: String; public var index: Int; public var name: String
    public var number: Int
    public var location: String
    public var intExt: String        // "INT" / "EXT"
    public var dayNight: String      // "DAY" / "NIGHT"
    public var estDurationSec: Int
    public var notes: String
    public var isUnassigned: Bool
    public var shots: [StoryShot]    // ordered by index
    public var slugline: String { get }   // "INT. LOCATION - DAY"
}

public struct StoryShot: Sendable, Identifiable {
    public var id: String; public var index: Int; public var name: String
    public var types: [String]       // JSON "type"
    public var description, detailedNotes: String
    public var tags: [String]
    public var estDurationSec: Int   // default 5
    public var status: String        // default "Planned"
    public var thumb: EmbeddedImage?
    public var videoRef: String?
    public var takes: [StoryTake]
}
public struct StoryTake: Sendable { public var id: String; public var label: String?; public var image: EmbeddedImage? }
public struct StoryScript: Sendable { public var id, name, filename, content: String }
public struct StoryAssetList: Sendable { public var id, name: String; public var assets: [StoryAsset] }
public struct StoryAsset: Sendable { public var id, name, description: String; public var sceneIds: [String]; public var thumb: EmbeddedImage? }

// StoryProject / StoryScene / StoryShot have memberwise-style public inits with defaults
// (useful for tests and for building previews in code).

/// Orphans: with exactly one project, orphan scenes attach to it and orphan shots go into a
/// trailing "Unassigned" scene (isUnassigned). With 0 or 2+ projects they go into a synthetic
/// project titled "Unassigned" (id "unassigned", isUnassigned), appended last.
public enum StoryReader {
    public static let unassignedName = "Unassigned"
    public static func read(from url: URL) throws -> StoryDocument
    public static func read(data: Data) throws -> StoryDocument
}

public struct StoryDraft: Sendable {
    public struct Shot: Sendable {
        public var name: String            // usually the filename
        public var imageData: Data?        // any ImageIO format; re-encoded to JPEG <= 1024 px
        public var description: String     // prompt text
        public var tags: [String]
        public var types: [String]
        public var estDurationSec: Int     // default 5
        public init(name:imageData:description:tags:types:estDurationSec:)
    }
    public var title: String
    public var code: String?              // default derived from title
    public var logline: String?
    public var aspectRatio: String        // default "16:9"
    public var sceneName: String          // default "Scene 1"
    public var sceneLocation: String      // default ""
    public var shots: [Shot]
    public init(title:code:logline:aspectRatio:sceneName:sceneLocation:shots:)  // all but title defaulted
}

public enum StoryWriter {
    public static let maxThumbPixelSize = 1024
    public static func encode(_ draft: StoryDraft, now: Date = Date()) throws -> Data
    public static func write(_ draft: StoryDraft, to url: URL) throws   // atomic
}
```

## Rendering (CoreGraphics + CoreText, sRGB, deterministic)

```swift
public enum ArtOfficialRenderer {
    public static let maxDecodedImagesPerRender = 12
    /// Longest side == maxPixelSize (the other side follows the board/project aspect).
    public static func renderMoodboard(_ board: Moodboard, maxPixelSize: Int) -> CGImage?
    public static func renderStoryContactSheet(_ project: StoryProject, maxPixelSize: Int) -> CGImage?
    public static func renderStoryShot(_ shot: StoryShot, project: StoryProject?, maxPixelSize: Int) -> CGImage?
}
```

## Search text

```swift
public enum ArtOfficialSearchText {
    public static func moodboard(_ board: Moodboard) -> (title: String, body: String)
    public static func story(_ document: StoryDocument) -> (title: String, body: String)
    public static func story(_ project: StoryProject) -> (title: String, body: String)
}
```

## Existing app formats (independent, lenient previews)

```swift
public struct PromptFilePreview: Sendable {
    public var title: String         // file name without extension
    public var prompt: String
    public var model: String?
    public var images: [EmbeddedImage]
    public var referenceImages: [EmbeddedImage]
}
public enum PlibPreview { public static func read(from url: URL) -> PromptFilePreview?
                          public static func read(data: Data, fileURL: URL?) -> PromptFilePreview? }
public enum AoePreview  { public static func read(from url: URL) -> PromptFilePreview?
                          public static func read(data: Data, fileURL: URL?) -> PromptFilePreview? }
```

## ZIP (exposed for reuse; used by the legacy board reader)

```swift
public struct ZipArchive: Sendable {
    public struct Limits: Sendable { maxEntries, maxTotalUncompressed, maxEntryUncompressed; static let `default` }
    public struct Entry: Sendable, Hashable { name, method, compressedSize, uncompressedSize }
    public let entries: [Entry]              // validated, safe entries only
    public let rejectedEntryNames: [String]  // traversal / absolute / encrypted / over-limit / unsupported
    public static func isZip(_ data: Data) -> Bool
    public init(data: Data, limits: Limits = .default) throws
    public func entry(named: String) -> Entry?
    public func entry(lastPathComponent: String) -> Entry?
    public func extract(_ entry: Entry) -> Data?  // nil if damaged or inflates past declared size
}
```

## Owner-app differences handled

- Mac Mood writes the web JSON plus: `boardMode` ("grid"/"infinite"), `text` canvas items
  (`text`, `fontSize`, `textAlign`, `fontWeight`, `textColor`, `backgroundColor`), `caption`,
  `branding.hideTitle/hideSubtitle`, `layoutOptions.freeformShowGrid/freeformSnap/canvasWidth/canvasHeight`.
  All are read. (Mac freeform x/y positions are never written to files, so infinite boards render as grids.)
- Mac Mood's decoder also accepts its native `ProjectState` Codable JSON (`imageData` base64, `kind`,
  `assetID`, `positionX/Y`, `logoAssetID` …) — also read (with Mac-native defaults).
- Legacy ZIP: web mapping (square->grid, default mosaic, crop->position, bg/description/rounded/shadow,
  showSafeMargin -> 40 fallback, web defaults) + Mac filename fallbacks (`fileName` | `file` | `name` | `id`;
  `assets/<f>`, `<f>`, then any entry with the same last path component).
- Story for Mac writes snake_case everywhere (`aspect_ratio`, `shot_templates`, `asset_lists`, `image_id`,
  …) plus extension keys (`audio_tracks`, `audio_track_count`, `file_path`, `bookmark`, `project_id` on
  audio/comments, `asset_lists`, `project_assets`, `scripts`); the web writes camelCase for a few
  (`aspectRatio`, `shotTypePresets`, `imageId`). Both spellings are read.
- `StoryWriter` writes `aspectRatio` (the one spelling both apps read: Mac's convertFromSnakeCase maps it
  unchanged) and omits `shotTypePresets` so the web app keeps its defaults.

## Limits

- Legacy ZIP: <= 2,000 entries, <= 512 MB total uncompressed, <= 64 MB per entry,
  stored + deflate only, encrypted entries ignored, `..`/absolute/backslash paths ignored,
  data descriptors supported (sizes are taken from the central directory).
- Renderers decode at most 12 images per call, each via ImageIO thumbnailing.
- No network access, ever: remote URLs and `img_*` references stay unresolved.
