import CoreGraphics
import Foundation

/// Geometry for the lightbox loupe: where the lightbox draws its image, and
/// which pixels a loupe at the pointer shows. Viewport points, y down.
enum LoupeGeometry {
    /// The lightbox's image rect: aspect-fit inside the viewport minus
    /// `padding`, centred, scaled by `zoomScale` about its centre, then
    /// shifted by `offset` (mirrors LightboxView's modifiers).
    static func lightboxImageRect(imageSize: CGSize, viewport: CGSize, padding: CGFloat, zoomScale: CGFloat, offset: CGSize) -> CGRect {
        lightboxImageRect(imageSize: imageSize, viewport: viewport, horizontalPadding: padding, verticalPadding: padding, zoomScale: zoomScale, offset: offset)
    }

    /// As above, with separate horizontal (arrow gutters) and vertical insets.
    static func lightboxImageRect(imageSize: CGSize, viewport: CGSize, horizontalPadding: CGFloat, verticalPadding: CGFloat, zoomScale: CGFloat, offset: CGSize) -> CGRect {
        let padding = (h: horizontalPadding, v: verticalPadding)
        let available = CGSize(width: max(viewport.width - padding.h * 2, 1), height: max(viewport.height - padding.v * 2, 1))
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let fit = min(available.width / imageSize.width, available.height / imageSize.height)
        let size = CGSize(width: imageSize.width * fit * zoomScale, height: imageSize.height * fit * zoomScale)
        let center = CGPoint(x: viewport.width / 2 + offset.width, y: viewport.height / 2 + offset.height)
        return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }

    /// The image pixel (in an image `pixelSize` large) under `point`, or nil
    /// when the pointer is off the image.
    static func pixel(at point: CGPoint, imageRect: CGRect, pixelSize: CGSize) -> CGPoint? {
        guard imageRect.width > 0, imageRect.height > 0, imageRect.contains(point) else { return nil }
        let u = (point.x - imageRect.minX) / imageRect.width
        let v = (point.y - imageRect.minY) / imageRect.height
        return CGPoint(x: u * pixelSize.width, y: v * pixelSize.height)
    }

    /// Pixels shown by a loupe `diameter` points wide at `magnification`
    /// screen pixels per image pixel, centred on `pixel`.
    static func sourceRect(around pixel: CGPoint, diameter: CGFloat, magnification: CGFloat, backingScale: CGFloat) -> CGRect {
        let side = max(1, diameter * max(backingScale, 0.5) / max(magnification, 0.1))
        return CGRect(x: pixel.x - side / 2, y: pixel.y - side / 2, width: side, height: side)
    }

    /// The part of `source` inside the image (whole pixels), and where it
    /// goes inside the loupe (points, relative to the loupe's top-left).
    static func visiblePart(of source: CGRect, pixelSize: CGSize, diameter: CGFloat) -> (crop: CGRect, placement: CGRect)? {
        let bounds = CGRect(origin: .zero, size: pixelSize)
        let crop = source.intersection(bounds).integral.intersection(bounds)
        guard !crop.isNull, crop.width >= 1, crop.height >= 1, source.width > 0 else { return nil }
        let k = diameter / source.width
        let placement = CGRect(
            x: (crop.minX - source.minX) * k,
            y: (crop.minY - source.minY) * k,
            width: crop.width * k,
            height: crop.height * k
        )
        return (crop, placement)
    }
}
