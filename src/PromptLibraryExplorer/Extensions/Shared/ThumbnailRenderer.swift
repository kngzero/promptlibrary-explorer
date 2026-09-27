import ArtOfficialFormats
import CoreGraphics
import CoreText
import Foundation

/// Finder thumbnail images for Art Official documents (CoreGraphics only).
public enum ThumbnailRenderer {
    /// Captions are drawn only when the thumbnail is big enough to read them.
    public static let minCaptionPixelSize = 256

    public static func image(for url: URL, maxPixelSize: Int) -> CGImage? {
        let px = max(16, maxPixelSize)
        switch ArtOfficialFileKind.detect(url: url) {
        case .moodboard:
            guard let board = try? MoodboardReader.read(from: url) else { return nil }
            return ArtOfficialRenderer.renderMoodboard(board, maxPixelSize: px)
        case .story, .storyLegacy:
            guard let doc = try? StoryReader.read(from: url) else { return nil }
            let project = doc.projects.first { !$0.isUnassigned && $0.shotCount > 0 }
                ?? doc.projects.first { !$0.isUnassigned }
                ?? doc.projects.first
            guard let project else { return nil }
            return ArtOfficialRenderer.renderStoryContactSheet(project, maxPixelSize: px)
        case .promptLibrary:
            guard let preview = PlibPreview.read(from: url) else { return nil }
            return promptImage(preview, maxPixelSize: px)
        case .elements:
            guard let preview = AoePreview.read(from: url) else { return nil }
            return promptImage(preview, maxPixelSize: px)
        case nil:
            return nil
        }
    }

    /// The first decodable embedded image with a prompt caption band; a text card when
    /// the file has no usable image.
    public static func promptImage(_ preview: PromptFilePreview, maxPixelSize px: Int) -> CGImage? {
        let caption = captionText(preview.prompt)
        let base = preview.images.lazy.filter(\.isResolvable).compactMap { $0.cgImage(maxPixelSize: px) }.first
        guard let base else { return textCard(caption.isEmpty ? preview.title : caption, maxPixelSize: px) }
        guard !caption.isEmpty, max(base.width, base.height) >= minCaptionPixelSize else { return base }
        let w = base.width, h = base.height
        guard let ctx = makeContext(width: w, height: h) else { return base }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
        let short = CGFloat(min(w, h))
        let fontSize = max(9, (short * 0.045).rounded())
        let pad = (fontSize * 0.8).rounded()
        let bandHeight = min(CGFloat(h) * 0.4, fontSize * 1.25 * 2 + pad * 2)
        // Soft gradient scrim, then text.
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                     colors: [CGColor(gray: 0, alpha: 0.72), CGColor(gray: 0, alpha: 0.0)] as CFArray,
                                     locations: [0, 1]) {
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 0, y: 0, width: CGFloat(w), height: bandHeight * 1.35))
            ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: bandHeight * 1.35), options: [])
            ctx.restoreGState()
        }
        drawText(caption, in: CGRect(x: pad, y: pad * 0.7, width: CGFloat(w) - pad * 2, height: bandHeight - pad),
                 fontSize: fontSize, color: CGColor(gray: 1, alpha: 0.96), maxLines: 2, context: ctx)
        return ctx.makeImage() ?? base
    }

    /// 4:5 card with the prompt text, used when a prompt file has no decodable image.
    public static func textCard(_ text: String, maxPixelSize px: Int) -> CGImage? {
        let h = px, w = max(1, Int((Double(px) * 0.8).rounded()))
        guard let ctx = makeContext(width: w, height: h) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 0.965, green: 0.965, blue: 0.97, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let fontSize = max(8, (CGFloat(w) * 0.07).rounded())
        let pad = CGFloat(w) * 0.1
        drawText(text.isEmpty ? "Prompt" : text,
                 in: CGRect(x: pad, y: pad, width: CGFloat(w) - pad * 2, height: CGFloat(h) - pad * 2),
                 fontSize: fontSize, color: CGColor(srgbRed: 0.15, green: 0.15, blue: 0.17, alpha: 1),
                 maxLines: 12, context: ctx)
        return ctx.makeImage()
    }

    /// Whitespace collapsed, trimmed to ~160 characters (Finder can't show more).
    public static func captionText(_ prompt: String) -> String {
        let collapsed = prompt.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard collapsed.count > 160 else { return collapsed }
        return String(collapsed.prefix(159)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Size (points) of an image of `imageSize` fitted inside `bounds`, preserving aspect.
    public static func fittedSize(_ imageSize: CGSize, in bounds: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let s = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        return CGSize(width: max(1, (imageSize.width * s).rounded()), height: max(1, (imageSize.height * s).rounded()))
    }

    // MARK: Drawing

    static func makeContext(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// Draws up to `maxLines` lines bottom-anchored in `rect`, truncating the last with "…".
    static func drawText(_ text: String, in rect: CGRect, fontSize: CGFloat, color: CGColor, maxLines: Int,
                         context ctx: CGContext) {
        let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let attributed = NSAttributedString(string: text, attributes: attrs)
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let length = attributed.length
        var lines: [CTLine] = []
        var start = 0
        let lineHeight = (CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)) * 1.1
        let fitLines = max(1, min(maxLines, Int(rect.height / lineHeight)))
        while start < length && lines.count < fitLines {
            let count = CTTypesetterSuggestLineBreak(typesetter, start, Double(rect.width))
            guard count > 0 else { break }
            let isLast = lines.count == fitLines - 1 && start + count < length
            if isLast {
                let rest = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: length - start))
                let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attrs))
                lines.append(CTLineCreateTruncatedLine(rest, Double(rect.width), .end, ellipsis) ?? rest)
            } else {
                lines.append(CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count)))
            }
            start += count
        }
        // Bottom-anchored for captions; the text card simply fills from the top.
        let totalHeight = CGFloat(lines.count) * lineHeight
        var y = maxLines > 2 ? rect.maxY - CTFontGetAscent(font) : rect.minY + totalHeight - CTFontGetAscent(font)
        ctx.saveGState()
        ctx.textMatrix = .identity
        for line in lines {
            ctx.textPosition = CGPoint(x: rect.minX, y: y)
            CTLineDraw(line, ctx)
            y -= lineHeight
        }
        ctx.restoreGState()
    }
}
