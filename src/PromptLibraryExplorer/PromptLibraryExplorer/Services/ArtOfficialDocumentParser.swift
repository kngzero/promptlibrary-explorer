import ArtOfficialFormats
import Foundation

/// Parses Mood boards (`.mlmboard`) and Story projects (`.stry`, `.mlseq`) and caches the
/// results, mirroring `PlibParser`: a bounded LRU keyed by path, validated against the
/// file's modification date and size.
///
/// Embedded images stay encoded (`EmbeddedImage` is lazy), so a cached board holds its
/// base64 text but never decoded bitmaps.
actor ArtOfficialDocumentParser {
    static let shared = ArtOfficialDocumentParser()

    /// Boards can be tens of MB of base64 text, so keep only a handful.
    private var cache = LRUCache<ParsedFileCacheEntry<ArtOfficialDocument>>(capacity: 12)

    func parse(at url: URL) async -> ArtOfficialDocument? {
        let path = url.path
        // URL instances cache resource values; read a fresh signature every time.
        var freshURL = url
        freshURL.removeAllCachedResourceValues()
        let signature = ParsedFileCacheEntry<ArtOfficialDocument>.signature(of: freshURL)
        if let cached = cache.value(forKey: path) {
            if cached.matches(signature) { return cached.value }
            cache.removeValue(forKey: path)
        }

        // Decode off the actor so several files can parse at once (the actor only
        // guards the cache). A duplicate parse of the same file is harmless.
        let document = await Task.detached(priority: .userInitiated) {
            ArtOfficialDocument.read(from: url)
        }.value
        guard let document else { return nil }

        cache.setValue(
            ParsedFileCacheEntry(value: document, modificationDate: signature.0, fileSize: signature.1),
            forKey: path
        )
        return document
    }

    func clearCache() {
        cache.removeAll()
    }

    /// Drops the cached parse for a single file (edited, moved or deleted).
    func invalidate(path: String) {
        cache.removeValue(forKey: path)
        cache.removeValue(forKey: URL(fileURLWithPath: path).standardizedFileURL.path)
    }

    var cachedCount: Int {
        cache.count
    }
}
