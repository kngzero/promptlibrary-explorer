import CoreSpotlight
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Everything one Spotlight item is built from: the library index row plus the
/// file's curation (tags, rating) and an optional small thumbnail.
struct SpotlightEntry: Sendable, Equatable {
    var path: String
    var name: String
    var prompt: String = ""
    var negative: String = ""
    var model: String?
    var sampler: String?
    var tags: [String] = []
    /// 0 = unrated, 1…5 stars.
    var rating: Int = 0
    var width: Int?
    var height: Int?
    var thumbnailData: Data?
    /// The library root the file belongs to (`SpotlightItemBuilder.domain`).
    var domain: String

    init(row: LibraryIndexSpotlightRow, tags: [String], rating: Int, domain: String, thumbnailData: Data? = nil) {
        path = row.path
        name = row.name
        prompt = row.prompt
        negative = row.negative
        model = row.model
        sampler = row.sampler
        width = row.width
        height = row.height
        self.tags = tags
        self.rating = rating
        self.domain = domain
        self.thumbnailData = thumbnailData
    }

    init(path: String, name: String, domain: String) {
        self.path = path
        self.name = name
        self.domain = domain
    }
}

/// Builds Core Spotlight items for library files. Pure apart from the thumbnail
/// helper, so the attribute mapping is unit-tested.
///
/// - `uniqueIdentifier` and `relatedUniqueIdentifier`: the file's absolute path, so a
///   result hands the path back to the app (`CSSearchableItemActivityIdentifier`),
///   which reveals it in the browser.
/// - `domainIdentifier`: `"root:" + <library root path>`; one domain per library root.
enum SpotlightItemBuilder {
    static let domainPrefix = "root:"
    static let excerptLimit = 300
    /// Keeps the textContent bounded for very long ComfyUI prompts.
    static let textContentLimit = 8_000
    static let thumbnailPixelSize = 160

    static func domain(forRoot root: String) -> String {
        domainPrefix + root
    }

    /// The longest indexed root that contains `path`, else its parent folder.
    static func domain(forPath path: String, roots: [String]) -> String {
        let match = roots
            .filter { root in path == root || path.hasPrefix(root == "/" ? "/" : root + "/") }
            .max(by: { $0.count < $1.count })
        return domain(forRoot: match ?? (path as NSString).deletingLastPathComponent)
    }

    /// The first `limit` characters of the prompt, whitespace collapsed, cut on a
    /// word boundary with an ellipsis.
    static func excerpt(_ text: String, limit: Int = excerptLimit) -> String {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        let cut = collapsed.prefix(limit)
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > limit / 2 {
            return String(cut[..<space]) + "…"
        }
        return String(cut) + "…"
    }

    /// Tags, then model and sampler; de-duplicated case-insensitively, empties and
    /// "N/A" dropped.
    static func keywords(for entry: SpotlightEntry) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in entry.tags + [entry.model, entry.sampler].compactMap({ $0 }) {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.uppercased() != "N/A" else { continue }
            if seen.insert(value.lowercased()).inserted { result.append(value) }
        }
        return result
    }

    static func contentType(forName name: String) -> UTType {
        let ext = (name as NSString).pathExtension.lowercased()
        if FileHelpers.isImageFile(name) { return UTType(filenameExtension: ext) ?? .image }
        if FileHelpers.isVideoFile(name) { return UTType(filenameExtension: ext) ?? .movie }
        if FileHelpers.isAudioFile(name) { return UTType(filenameExtension: ext) ?? .audio }
        if let type = UTType(filenameExtension: ext), type.conforms(to: .data) { return type }
        return .data
    }

    static func attributes(for entry: SpotlightEntry) -> CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: contentType(forName: entry.name))
        let url = URL(fileURLWithPath: entry.path)
        attributes.title = entry.name
        attributes.displayName = entry.name
        let prompt = entry.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty {
            attributes.contentDescription = excerpt(prompt)
            let body = entry.negative.isEmpty ? prompt : prompt + "\n" + entry.negative
            attributes.textContent = String(body.prefix(textContentLimit))
        }
        let keywords = keywords(for: entry)
        if !keywords.isEmpty { attributes.keywords = keywords }
        if (1...5).contains(entry.rating) {
            attributes.rating = NSNumber(value: entry.rating)
            attributes.ratingDescription = String(repeating: "★", count: entry.rating)
        }
        if let width = entry.width, width > 0 { attributes.pixelWidth = NSNumber(value: width) }
        if let height = entry.height, height > 0 { attributes.pixelHeight = NSNumber(value: height) }
        attributes.contentURL = url
        attributes.relatedUniqueIdentifier = entry.path
        attributes.path = entry.path
        attributes.thumbnailData = entry.thumbnailData
        return attributes
    }

    static func item(for entry: SpotlightEntry) -> CSSearchableItem {
        let item = CSSearchableItem(
            uniqueIdentifier: entry.path,
            domainIdentifier: entry.domain,
            attributeSet: attributes(for: entry)
        )
        // Library files stay searchable until they're removed from the index.
        item.expirationDate = .distantFuture
        return item
    }

    /// A small JPEG thumbnail for an image file, or nil (not an image, online-only,
    /// unreadable). Uses the file's embedded thumbnail when there is one.
    static func thumbnailData(forPath path: String, maxPixelSize: Int = thumbnailPixelSize) -> Data? {
        let name = (path as NSString).lastPathComponent
        guard FileHelpers.isImageFile(name), CloudFileStatus.isLocallyAvailable(path: path) else { return nil }
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
