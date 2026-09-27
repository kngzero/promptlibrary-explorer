import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// Pixel work for exports: decode (downsampled when the output is smaller), crop/scale,
/// colour conversion and watermarking. Pure and synchronous — call off the main actor.
enum ExportImageRenderer {
    /// Pixel size of the source after its EXIF orientation is applied.
    static func orientedSize(of source: CGImageSource) -> (width: Int, height: Int)? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 && orientation <= 8 ? (height, width) : (width, height)
    }

    /// Decodes the source with its orientation applied. `maxPixelSize` (long edge) lets
    /// ImageIO decode at reduced size when the output is smaller than the original.
    static func orientedImage(from source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Decodes `source` just large enough for `plan` (never below the crop's needs).
    static func decodeForPlan(_ source: CGImageSource, orientedWidth: Int, orientedHeight: Int, plan: ExportResizePlan) -> CGImage? {
        let longSource = max(orientedWidth, orientedHeight)
        let scaleX = Double(plan.outputWidth) / max(1, Double(plan.sourceCrop.width))
        let scaleY = Double(plan.outputHeight) / max(1, Double(plan.sourceCrop.height))
        let factor = min(1, max(scaleX, scaleY))
        // A little headroom so the final resample is a downscale.
        let target = min(longSource, Int((Double(longSource) * factor * 1.05).rounded(.up)))
        return orientedImage(from: source, maxPixelSize: max(1, target))
    }

    /// Crops `plan.sourceCrop` (in oriented source pixels; `image` may be a downsampled
    /// decode of that source) and draws it at the output size in `colorSpace`, then adds the
    /// watermark. `opaque` flattens onto white (JPEG).
    static func render(
        _ image: CGImage,
        orientedSourceWidth: Int,
        plan: ExportResizePlan,
        colorSpace: CGColorSpace,
        opaque: Bool,
        watermark: ExportWatermark,
        watermarkImage: CGImage?
    ) -> CGImage? {
        let width = plan.outputWidth
        let height = plan.outputHeight
        let bitmapInfo = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: bitmapInfo
        ) else { return nil }
        context.interpolationQuality = .high
        if opaque {
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }

        // Map the crop (top-left origin, source pixels) into the decoded image's pixels.
        let ratio = Double(image.width) / Double(max(1, orientedSourceWidth))
        let crop = CGRect(
            x: plan.sourceCrop.minX * ratio,
            y: plan.sourceCrop.minY * ratio,
            width: plan.sourceCrop.width * ratio,
            height: plan.sourceCrop.height * ratio
        )
        // Draw the whole decoded image scaled so the crop fills the canvas.
        let sx = Double(width) / max(0.0001, crop.width)
        let sy = Double(height) / max(0.0001, crop.height)
        let drawRect = CGRect(
            x: -crop.minX * sx,
            y: -(Double(image.height) - crop.maxY) * sy,
            width: Double(image.width) * sx,
            height: Double(image.height) * sy
        )
        context.draw(image, in: drawRect)

        if watermark.isActive {
            drawWatermark(watermark, image: watermarkImage, in: context, canvas: CGSize(width: width, height: height))
        }
        return context.makeImage()
    }

    // MARK: - Watermark

    /// Where a watermark of `natural` size lands on `canvas`, top-left origin.
    static func watermarkRect(natural: CGSize, canvas: CGSize, watermark: ExportWatermark) -> CGRect {
        guard natural.width > 0, natural.height > 0, canvas.width > 0, canvas.height > 0 else { return .zero }
        let margin = max(0, watermark.margin) * min(canvas.width, canvas.height)
        var width = max(1, min(1, max(0.01, watermark.scale)) * canvas.width)
        var height = width * natural.height / natural.width
        let maxHeight = max(1, canvas.height - 2 * margin)
        if height > maxHeight {
            height = maxHeight
            width = height * natural.width / natural.height
        }
        let anchor = watermark.position.anchor
        let x = margin + anchor.x * max(0, canvas.width - 2 * margin - width)
        let y = margin + anchor.y * max(0, canvas.height - 2 * margin - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func drawWatermark(_ watermark: ExportWatermark, image: CGImage?, in context: CGContext, canvas: CGSize) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setAlpha(min(1, max(0, watermark.opacity)))

        switch watermark.kind {
        case .image:
            guard let image else { return }
            let rect = watermarkRect(natural: CGSize(width: image.width, height: image.height), canvas: canvas, watermark: watermark)
            if watermark.shadow { applyShadow(context, height: rect.height) }
            context.draw(image, in: flipped(rect, canvasHeight: canvas.height))

        case .text:
            let text = watermark.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            // The system font has optical sizes, so widths don't scale linearly: refine the
            // size until the line is the requested width, then place it by its real bounds.
            func measure(_ size: CGFloat) -> (line: CTLine, width: CGFloat, ascent: CGFloat, descent: CGFloat) {
                let line = textLine(text, size: size, watermark: watermark)
                var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
                let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
                return (line, max(1, width), ascent, descent)
            }
            let reference = measure(100)
            let target = watermarkRect(
                natural: CGSize(width: reference.width, height: max(1, reference.ascent + reference.descent)),
                canvas: canvas, watermark: watermark
            )
            var fontSize = max(1, 100 * target.width / reference.width)
            var measured = measure(fontSize)
            for _ in 0..<3 where abs(measured.width - target.width) > 0.5 {
                fontSize = max(1, fontSize * target.width / measured.width)
                measured = measure(fontSize)
            }
            let rect = watermarkRect(
                natural: CGSize(width: measured.width, height: max(1, measured.ascent + measured.descent)),
                canvas: canvas, watermark: watermark
            )
            let line = measured.line
            let lineDescent = measured.descent
            if watermark.shadow { applyShadow(context, height: rect.height) }
            let placed = flipped(rect, canvasHeight: canvas.height)
            context.textPosition = CGPoint(x: placed.minX, y: placed.minY + lineDescent)
            CTLineDraw(line, context)
        }
    }

    private static func applyShadow(_ context: CGContext, height: CGFloat) {
        context.setShadow(
            offset: CGSize(width: 0, height: -max(1, height * 0.04)),
            blur: max(2, height * 0.15),
            color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.55)
        )
    }

    private static func textLine(_ text: String, size: CGFloat, watermark: ExportWatermark) -> CTLine {
        let font = CTFontCreateUIFontForLanguage(watermark.bold ? .emphasizedSystem : .system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: cgColor(hex: watermark.textColorHex),
        ]
        let string = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)!
        return CTLineCreateWithAttributedString(string)
    }

    /// Top-left-origin rect → Core Graphics' bottom-left origin.
    static func flipped(_ rect: CGRect, canvasHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: canvasHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// "#RRGGBB" / "RRGGBB" (/ "#RRGGBBAA"); white when unreadable.
    static func cgColor(hex: String) -> CGColor {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6 || value.count == 8, let number = UInt64(value, radix: 16) else {
            return CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        }
        let hasAlpha = value.count == 8
        let r = CGFloat((number >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = CGFloat((number >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = CGFloat((number >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? CGFloat(number & 0xFF) / 255 : 1
        return CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    /// Loads a watermark image (PNG with alpha, or anything ImageIO reads), capped in size.
    static func loadWatermarkImage(path: String?) -> CGImage? {
        guard let path, !path.isEmpty,
              let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)
        else { return nil }
        return orientedImage(from: source, maxPixelSize: 4096)
    }

    // MARK: - Colour

    /// The colour space an export renders into.
    static func colorSpace(for profile: ExportColorProfile, sourceImage: CGImage?) -> CGColorSpace {
        if let name = profile.colorSpaceName, let space = CGColorSpace(name: name) { return space }
        if let space = sourceImage?.colorSpace, space.model == .rgb { return space }
        return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }

    /// True when converting to `profile` changes anything for this source.
    static func needsColorConversion(_ profile: ExportColorProfile, source: CGImageSource) -> Bool {
        guard let wanted = profile.colorSpaceName else { return false }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil), let space = image.colorSpace else { return true }
        return (space.name as String?) != (wanted as String)
    }

    // MARK: - Encoding

    /// Encodes `image` as `format` with `metadata` (already filtered) and quality.
    static func encode(_ image: CGImage, format: ExportFormat, quality: Double, metadata: CGImageMetadata?) -> Data? {
        guard let type = format.utType?.identifier else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { return nil }
        var options: [CFString: Any] = [:]
        if format.usesQuality { options[kCGImageDestinationLossyCompressionQuality] = min(1, max(0, quality)) }
        if let metadata {
            CGImageDestinationAddImageAndMetadata(destination, image, metadata, options as CFDictionary)
        } else {
            CGImageDestinationAddImage(destination, image, options as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
