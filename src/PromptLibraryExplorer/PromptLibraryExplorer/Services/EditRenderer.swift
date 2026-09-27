import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// Core Image pipeline for edit recipes. One shared GPU-backed context; previews decode a
/// downsampled source (just large enough for the crop at the requested size), exports the
/// full resolution. Pure and synchronous — call off the main actor.
enum EditRenderer {
    /// Shared, GPU-backed (Metal) context. CIContext is thread-safe.
    static let context: CIContext = CIContext(options: [
        .cacheIntermediates: false,
        .name: "PromptLibraryExplorer.EditRenderer",
    ])

    // MARK: Pipeline

    /// Applies `recipe` to `image` (oriented, any size: the recipe is normalized).
    /// `showingFullFrame` skips the crop (the editor's crop tool shows the whole
    /// straightened, turned frame with the crop drawn over it).
    static func apply(_ recipe: EditRecipe, to input: CIImage, showingFullFrame: Bool = false) -> CIImage {
        let recipe = recipe.normalized()
        var image = input.transformed(by: CGAffineTransform(translationX: -input.extent.minX, y: -input.extent.minY))
        let frame = CGRect(origin: .zero, size: image.extent.size)
        let width = frame.width, height = frame.height
        guard width >= 1, height >= 1 else { return input }

        // 1. Straighten about the centre; the frame keeps the source's size. Clamping
        // first keeps crop edges opaque (a valid crop never shows the clamped pixels).
        if recipe.straighten != 0 {
            let radians = CGFloat(-recipe.straighten * .pi / 180)   // CI is y-up: clockwise = negative
            let rotate = CGAffineTransform(translationX: width / 2, y: height / 2)
                .rotated(by: radians)
                .translatedBy(x: -width / 2, y: -height / 2)
            let base = showingFullFrame ? image : image.clampedToExtent()
            image = base.transformed(by: rotate).cropped(to: frame)
        }

        // 2. Crop (normalized, top-left origin → CI's bottom-left origin).
        if !showingFullFrame, let crop = recipe.crop {
            let pixels = EditGeometry.pixelRect(for: crop, in: frame.size)
            let ciRect = CGRect(x: pixels.minX, y: height - pixels.maxY, width: pixels.width, height: pixels.height)
            image = image.cropped(to: ciRect)
                .transformed(by: CGAffineTransform(translationX: -ciRect.minX, y: -ciRect.minY))
        } else {
            image = image.cropped(to: frame)
        }

        // 3. Quarter turns, clockwise.
        for _ in 0..<recipe.quarterTurns {
            image = image.transformed(by: CGAffineTransform(rotationAngle: -.pi / 2))
            let turned = image.extent
            image = image.transformed(by: CGAffineTransform(translationX: -turned.minX, y: -turned.minY))
        }

        // 4. Flips in the output's own space.
        if recipe.flipHorizontal {
            let w = image.extent.width
            image = image.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0))
        }
        if recipe.flipVertical {
            let h = image.extent.height
            image = image.transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h))
        }

        // 5. Colour.
        image = adjusted(image, recipe: recipe)

        // Integral extent at the origin.
        let extent = image.extent
        let integral = CGRect(x: 0, y: 0, width: extent.width.rounded(), height: extent.height.rounded())
        return image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)).cropped(to: integral)
    }

    private static func adjusted(_ input: CIImage, recipe: EditRecipe) -> CIImage {
        guard recipe.hasAdjustments else { return input }
        var image = input
        if recipe.exposure != 0, let filter = CIFilter(name: "CIExposureAdjust") {
            filter.setValue(image, forKey: kCIInputImageKey)
            filter.setValue(recipe.exposure, forKey: kCIInputEVKey)
            image = filter.outputImage ?? image
        }
        if recipe.contrast != 0 || recipe.saturation != 0, let filter = CIFilter(name: "CIColorControls") {
            filter.setValue(image, forKey: kCIInputImageKey)
            filter.setValue(1 + recipe.contrast * 0.5, forKey: kCIInputContrastKey)
            filter.setValue(max(0, 1 + recipe.saturation), forKey: kCIInputSaturationKey)
            filter.setValue(0, forKey: kCIInputBrightnessKey)
            image = filter.outputImage ?? image
        }
        if recipe.temperature != 0, let filter = CIFilter(name: "CITemperatureAndTint") {
            // Warmer (+) moves the target neutral above 6500 K.
            filter.setValue(image, forKey: kCIInputImageKey)
            filter.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
            filter.setValue(CIVector(x: 6500 + recipe.temperature * 3000, y: 0), forKey: "inputTargetNeutral")
            image = filter.outputImage ?? image
        }
        return image.cropped(to: input.extent)
    }

    // MARK: Rendering

    /// Renders `image` to a CGImage (8-bit RGBA) in `colorSpace` (sRGB when nil).
    static func makeCGImage(_ image: CIImage, colorSpace: CGColorSpace? = nil) -> CGImage? {
        let extent = image.extent
        guard extent.width >= 1, extent.height >= 1, extent.width.isFinite, extent.height.isFinite else { return nil }
        let space = colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return context.createCGImage(image, from: extent, format: .RGBA8, colorSpace: space)
    }

    /// `recipe` applied to an already-decoded, upright CGImage (the editor's working
    /// copy, tests). `maxPixelSize` scales the result down to fit.
    static func render(_ cgImage: CGImage, recipe: EditRecipe, maxPixelSize: CGFloat? = nil, showingFullFrame: Bool = false) -> CGImage? {
        var output = apply(recipe, to: CIImage(cgImage: cgImage), showingFullFrame: showingFullFrame)
        if let maxPixelSize { output = scaledToFit(output, maxPixelSize: maxPixelSize) }
        return makeCGImage(output, colorSpace: cgImage.colorSpace)
    }

    /// The edited image of the file at `url`. `maxPixelSize` (long edge of the OUTPUT)
    /// decodes a downsampled source; nil renders at full resolution (exports).
    static func render(url: URL, recipe: EditRecipe, maxPixelSize: CGFloat?) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let size = orientedPixelSize(of: source)
        else { return nil }
        let decoded: CGImage?
        if let maxPixelSize {
            decoded = decodeForPreview(source, sourceSize: size, recipe: recipe, maxPixelSize: maxPixelSize)
        } else {
            decoded = decodeFull(source)
        }
        guard let decoded else { return nil }
        return render(decoded, recipe: recipe, maxPixelSize: maxPixelSize)
    }

    /// The long edge to decode the source at so the crop still has `maxPixelSize` pixels.
    static func previewDecodeLongEdge(sourceSize: CGSize, recipe: EditRecipe, maxPixelSize: CGFloat) -> Int {
        let crop = recipe.crop ?? .full
        let cropLong = max(crop.width * Double(sourceSize.width), crop.height * Double(sourceSize.height))
        let sourceLong = Double(max(sourceSize.width, sourceSize.height))
        guard cropLong > 0, sourceLong > 0 else { return Int(maxPixelSize) }
        let scale = min(1, Double(maxPixelSize) / cropLong)
        return max(1, Int((sourceLong * scale * 1.05).rounded(.up)))
    }

    static func decodeForPreview(_ source: CGImageSource, sourceSize: CGSize, recipe: EditRecipe, maxPixelSize: CGFloat) -> CGImage? {
        let longEdge = min(Int(max(sourceSize.width, sourceSize.height)), previewDecodeLongEdge(sourceSize: sourceSize, recipe: recipe, maxPixelSize: maxPixelSize))
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: max(1, longEdge),
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Full resolution with the EXIF orientation applied.
    static func decodeFull(_ source: CGImageSource) -> CGImage? {
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let raw = (props?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        guard raw != 1, let orientation = CGImagePropertyOrientation(rawValue: raw) else { return image }
        let oriented = CIImage(cgImage: image).oriented(orientation)
        return makeCGImage(oriented, colorSpace: image.colorSpace)
    }

    static func orientedPixelSize(of source: CGImageSource) -> CGSize? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue
        else { return nil }
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return orientation >= 5 && orientation <= 8 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    static func orientedPixelSize(url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return orientedPixelSize(of: source)
    }

    /// Output pixel size of the edited file (for the viewing tools' info).
    static func editedPixelSize(url: URL, recipe: EditRecipe) -> CGSize? {
        orientedPixelSize(url: url).map { EditGeometry.outputSize(for: recipe, sourceSize: $0) }
    }

    static func scaledToFit(_ image: CIImage, maxPixelSize: CGFloat) -> CIImage {
        let extent = image.extent
        let long = max(extent.width, extent.height)
        guard maxPixelSize > 0, long > maxPixelSize else { return image }
        let scale = maxPixelSize / long
        let target = CGSize(width: max(1, (extent.width * scale).rounded()), height: max(1, (extent.height * scale).rounded()))
        let scaled: CIImage
        if let filter = CIFilter(name: "CILanczosScaleTransform") {
            filter.setValue(image, forKey: kCIInputImageKey)
            filter.setValue(scale, forKey: kCIInputScaleKey)
            filter.setValue(1.0, forKey: kCIInputAspectRatioKey)
            scaled = filter.outputImage ?? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        } else {
            scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let e = scaled.extent
        return scaled.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .cropped(to: CGRect(origin: .zero, size: target))
    }
}
