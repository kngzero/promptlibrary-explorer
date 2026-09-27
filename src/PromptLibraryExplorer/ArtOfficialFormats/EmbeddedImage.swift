import CoreGraphics
import Foundation
import ImageIO

/// A reference to an image embedded in (or referenced by) a document.
///
/// Holds the raw encoded form only — a data-URL string plus the offset of its
/// payload, a lazy archive entry, or a path — and decodes on demand. Remote URLs
/// and unresolved references are never fetched.
public struct EmbeddedImage: Sendable {
    public enum SourceKind: String, Sendable, Hashable {
        case dataURL
        case base64
        case remoteURL
        case unresolvedReference
        case file
        case archiveEntry
        case inlineData
    }

    enum Storage: Sendable {
        /// `string[payloadStart...]` is the payload; `isBase64` false means percent-encoded.
        case encoded(String, payloadStart: String.Index, isBase64: Bool)
        case remote(String)
        case unresolved(String)
        case file(URL)
        case archive(ZipArchive, ZipArchive.Entry)
        case bytes(Data)
    }

    public let sourceKind: SourceKind
    public let mimeType: String?
    let storage: Storage

    init(kind: SourceKind, mimeType: String?, storage: Storage) {
        self.sourceKind = kind
        self.mimeType = mimeType
        self.storage = storage
    }

    public init(data: Data, mimeType: String?) {
        self.init(kind: .inlineData, mimeType: mimeType ?? MIME.sniff(data), storage: .bytes(data))
    }

    public init(fileURL: URL, mimeType: String? = nil) {
        self.init(kind: .file, mimeType: mimeType ?? MIME.fromExtension(fileURL.pathExtension), storage: .file(fileURL))
    }

    static func archiveEntry(_ archive: ZipArchive, _ entry: ZipArchive.Entry) -> EmbeddedImage {
        let ext = (entry.name as NSString).pathExtension
        return EmbeddedImage(kind: .archiveEntry, mimeType: MIME.fromExtension(ext), storage: .archive(archive, entry))
    }

    /// URL / reference / path / entry name. nil for data URLs, base64 and inline data.
    public var reference: String? {
        switch storage {
        case .remote(let s), .unresolved(let s): return s
        case .file(let url): return url.path
        case .archive(_, let entry): return entry.name
        case .encoded, .bytes: return nil
        }
    }

    /// false for remote URLs and unresolved references (their bytes are not available offline).
    public var isResolvable: Bool {
        sourceKind != .remoteURL && sourceKind != .unresolvedReference
    }

    /// Length of the encoded payload in bytes (base64 characters for data URLs).
    public var encodedByteCount: Int {
        switch storage {
        case .encoded(let s, let start, _): return s.utf8.distance(from: start, to: s.endIndex)
        case .archive(_, let e): return e.compressedSize
        case .bytes(let d): return d.count
        case .remote, .unresolved, .file: return 0
        }
    }

    // MARK: Parsing

    /// Classifies any image string found in a document:
    /// `data:` URL, `http(s)://` (remote), `img_*` (unresolved), `file://`, absolute path,
    /// long bare base64, or — when `baseURL` is given — a path relative to it.
    public static func parse(_ string: String, relativeTo baseURL: URL? = nil) -> EmbeddedImage? {
        let trimmed = cheapTrim(string)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.prefix(8).lowercased()
        if lower.hasPrefix("data:") { return dataURL(trimmed) }
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("blob:") {
            return EmbeddedImage(kind: .remoteURL, mimeType: nil, storage: .remote(trimmed))
        }
        if trimmed.hasPrefix("img_") && trimmed.count < 200 {
            return EmbeddedImage(kind: .unresolvedReference, mimeType: nil, storage: .unresolved(trimmed))
        }
        if lower.hasPrefix("file://"), let url = URL(string: trimmed), url.isFileURL {
            return EmbeddedImage(fileURL: url)
        }
        if trimmed.hasPrefix("/") && trimmed.count < 4096 && !trimmed.contains("\n") {
            return EmbeddedImage(fileURL: URL(fileURLWithPath: trimmed))
        }
        if looksLikeBase64(trimmed) {
            return EmbeddedImage(kind: .base64, mimeType: nil,
                                 storage: .encoded(trimmed, payloadStart: trimmed.startIndex, isBase64: true))
        }
        if let baseURL, trimmed.count < 4096, !trimmed.contains("\n"),
           !trimmed.split(separator: "/").contains("..") {
            return EmbeddedImage(fileURL: baseURL.appendingPathComponent(trimmed))
        }
        if trimmed.count < 200, trimmed.range(of: "^[A-Za-z0-9_\\-]+$", options: .regularExpression) != nil {
            return EmbeddedImage(kind: .unresolvedReference, mimeType: nil, storage: .unresolved(trimmed))
        }
        return nil
    }

    /// Trims only when needed, so a multi-megabyte payload is not copied.
    static func cheapTrim(_ s: String) -> String {
        guard let first = s.unicodeScalars.first, let last = s.unicodeScalars.last else { return s }
        let ws = CharacterSet.whitespacesAndNewlines
        return (ws.contains(first) || ws.contains(last)) ? s.trimmingCharacters(in: ws) : s
    }

    /// Parses `data:[<mime>][;params][;base64],<payload>`. The payload is NOT decoded.
    public static func dataURL(_ string: String) -> EmbeddedImage? {
        guard string.utf8.count > 5, string.prefix(5).lowercased() == "data:",
              let comma = string.firstIndex(of: ",") else { return nil }
        let header = string[string.index(string.startIndex, offsetBy: 5)..<comma]
        let params = header.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        let mime = params.first.flatMap { $0.contains("/") ? $0.lowercased() : nil }
        let isBase64 = params.dropFirst().contains { $0.lowercased() == "base64" }
            || (params.first?.lowercased() == "base64")
        return EmbeddedImage(kind: .dataURL, mimeType: mime,
                             storage: .encoded(string, payloadStart: string.index(after: comma), isBase64: isBase64))
    }

    static func looksLikeBase64(_ s: String) -> Bool {
        guard s.utf8.count > 100 else { return false }
        // Sample the head so huge payloads are not scanned in full.
        for byte in s.utf8.prefix(512) {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "+"), UInt8(ascii: "/"),
                 UInt8(ascii: "="), UInt8(ascii: "-"), UInt8(ascii: "_"), 10, 13, 32:
                continue
            default:
                return false
            }
        }
        return true
    }

    // MARK: Decoding

    /// Decoded image bytes, or nil (malformed payload, remote/unresolved source, missing file).
    public func data() -> Data? {
        switch storage {
        case .encoded(let s, let start, let isBase64):
            let payload = s[start...]
            if isBase64 {
                return Self.decodeBase64(payload)
            }
            let text = String(payload)
            return (text.removingPercentEncoding ?? text).data(using: .utf8)
        case .remote, .unresolved:
            return nil
        case .file(let url):
            return try? Data(contentsOf: url, options: [.mappedIfSafe])
        case .archive(let archive, let entry):
            return archive.extract(entry)
        case .bytes(let d):
            return d
        }
    }

    static func decodeBase64(_ payload: Substring) -> Data? {
        // Fast path: canonical base64.
        if let d = Data(base64Encoded: String(payload)), !d.isEmpty { return d }
        // Lenient path: strip whitespace / percent-encoded padding, map URL-safe alphabet, re-pad.
        var cleaned = String(payload)
        if cleaned.contains("%") { cleaned = cleaned.removingPercentEncoding ?? cleaned }
        var bytes = [UInt8]()
        bytes.reserveCapacity(cleaned.utf8.count)
        for b in cleaned.utf8 {
            switch b {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "+"), UInt8(ascii: "/"):
                bytes.append(b)
            case UInt8(ascii: "-"): bytes.append(UInt8(ascii: "+"))
            case UInt8(ascii: "_"): bytes.append(UInt8(ascii: "/"))
            case UInt8(ascii: "="), 9, 10, 13, 32: continue
            default: return nil   // genuinely malformed
            }
        }
        guard !bytes.isEmpty, bytes.count % 4 != 1 else { return nil }
        while bytes.count % 4 != 0 { bytes.append(UInt8(ascii: "=")) }
        guard let d = Data(base64Encoded: Data(bytes)), !d.isEmpty else { return nil }
        return d
    }

    /// Decodes a downsampled image whose longest side is at most `maxPixelSize`
    /// (EXIF orientation applied). nil when the bytes are unavailable or undecodable.
    public func cgImage(maxPixelSize: Int) -> CGImage? {
        guard let data = data(), !data.isEmpty else { return nil }
        return ImageCodec.thumbnail(data: data, maxPixelSize: maxPixelSize)
    }

    /// Pixel size read from the image header only (orientation-corrected).
    public func pixelSize() -> CGSize? {
        guard let data = data() else { return nil }
        return ImageCodec.pixelSize(data: data)
    }
}

enum ImageCodec {
    static func thumbnail(data: Data, maxPixelSize: Int) -> CGImage? {
        guard maxPixelSize > 0,
              let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0 else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    static func pixelSize(data: Data) -> CGSize? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              w > 0, h > 0 else { return nil }
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    /// Re-encodes any ImageIO-readable bytes as JPEG with longest side <= maxPixelSize.
    static func jpeg(from data: Data, maxPixelSize: Int, quality: Double = 0.85) -> Data? {
        guard let image = thumbnail(data: data, maxPixelSize: maxPixelSize) else { return nil }
        // Flatten onto white in sRGB so transparent PNGs don't turn black in JPEG.
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            return encode(image, type: "public.jpeg", quality: quality)
        }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return encode(ctx.makeImage() ?? image, type: "public.jpeg", quality: quality)
    }

    static func encode(_ image: CGImage, type: String, quality: Double = 0.85) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, type as CFString, 1, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, image, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
