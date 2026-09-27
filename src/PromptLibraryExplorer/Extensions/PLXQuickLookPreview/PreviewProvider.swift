import Foundation
import PLXQuickLookSupport
import QuickLookUI
import UniformTypeIdentifiers

/// Data-based (QLIsDataBasedPreview) Quick Look preview: returns self-contained HTML
/// with the rendered images embedded as data: URIs.
/// The @objc name must match NSExtensionPrincipalClass in Info.plist.
@objc(PLXPreviewProvider)
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest,
                        completionHandler handler: @escaping (QLPreviewReply?, Error?) -> Void) {
        let url = request.fileURL
        let reply = QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 960, height: 1100)) { reply in
            reply.stringEncoding = .utf8
            let output: PreviewContentFactory.Output
            do {
                output = try PreviewContentFactory.make(for: url)
            } catch {
                let title = url.deletingPathExtension().lastPathComponent
                output = .init(title: title, html: PreviewHTML.message(
                    title: title, detail: "This file couldn't be previewed (\(error))."))
            }
            reply.title = output.title
            return Data(output.html.utf8)
        }
        handler(reply, nil)
    }
}
