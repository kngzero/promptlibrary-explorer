import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Encodes CGImages for embedding in preview HTML (`data:` URIs).
public enum PreviewImageEncoder {
    /// JPEG for opaque images (or when `forceOpaque`), PNG when the image carries alpha.
    public static func encode(_ image: CGImage, quality: Double = 0.82, forceOpaque: Bool = false) -> (data: Data, mime: String)? {
        let opaque = forceOpaque || !hasAlpha(image)
        let type = opaque ? UTType.jpeg : UTType.png
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, type.identifier as CFString, 1, nil) else {
            return nil
        }
        let props: [CFString: Any] = opaque ? [kCGImageDestinationLossyCompressionQuality: quality] : [:]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (out as Data, opaque ? "image/jpeg" : "image/png")
    }

    public static func dataURI(_ image: CGImage, quality: Double = 0.82, forceOpaque: Bool = false) -> String? {
        guard let (data, mime) = encode(image, quality: quality, forceOpaque: forceOpaque) else { return nil }
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }
}
