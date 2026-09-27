import CoreGraphics
import Foundation
import PLXQuickLookSupport
import QuickLookThumbnailing

/// Finder / Quick Look thumbnails for Mood boards, Story projects, .plib and .aoe.
/// The @objc name must match NSExtensionPrincipalClass in Info.plist.
@objc(PLXThumbnailProvider)
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let maxSize = request.maximumSize
        let scale = max(1, request.scale)
        let pixels = Int((max(maxSize.width, maxSize.height) * scale).rounded(.up))
        guard let image = ThumbnailRenderer.image(for: request.fileURL, maxPixelSize: pixels) else {
            handler(nil, NSError(domain: "com.artofficial.promptlibrary-explorer.quicklook-thumbnail", code: 1,
                                 userInfo: [NSLocalizedDescriptionKey: "No thumbnail available"]))
            return
        }
        let size = ThumbnailRenderer.fittedSize(CGSize(width: image.width, height: image.height), in: maxSize)
        // The context is in points and pre-scaled by request.scale, so drawing the
        // (pixel-sized) image into the point rect keeps full resolution.
        let reply = QLThumbnailReply(contextSize: size) { context -> Bool in
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(origin: .zero, size: size))
            return true
        }
        handler(reply, nil)
    }
}
