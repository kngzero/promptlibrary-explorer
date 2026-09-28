import AppKit
import SwiftUI

/// What the lightbox tells its viewing overlays about the image on screen.
struct LightboxViewingContext {
    /// The file behind the image when it *is* the file (a plain image, not a
    /// Mood / Story render or a .plib's embedded image): the loupe decodes
    /// its native pixels and the histogram is cached per path + mtime.
    var filePath: String?
    /// The image as displayed (fallback source, and its aspect ratio).
    var image: NSImage
    /// Identifies `image` when there's no file path (item + image index / step).
    var imageKey: String
    var viewport: CGSize
    var padding: CGFloat
    var zoomScale: CGFloat
    var offset: CGSize
    /// Room left at the top for the culling bar / document step bar.
    var topInset: CGFloat
}

/// The loupe over the lightbox image (View ▸ Loupe, or the lightbox header
/// button). It never takes clicks. The histogram lives at the top of the
/// details panel (`DetailsHistogramCard`) so it never covers the image.
struct LightboxViewingOverlays: View {
    let context: LightboxViewingContext
    private var viewing: ViewingController { .shared }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if viewing.loupeEnabled {
                LightboxLoupe(context: context)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Loupe

private struct LightboxLoupe: View {
    let context: LightboxViewingContext
    @Environment(\.displayScale) private var displayScale
    @State private var native: CGImage?
    @State private var nativeKey = ""

    private var viewing: ViewingController { .shared }
    private static let diameter: CGFloat = 180

    /// The best source: the file's native pixels once decoded, else the displayed image.
    private var source: CGImage? {
        if let native, nativeKey == context.filePath { return native }
        return context.image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    var body: some View {
        ZStack {
            if let pointer = viewing.lightboxPointer, let source {
                loupe(at: pointer, source: source)
            }
        }
        .frame(width: context.viewport.width, height: context.viewport.height)
        .task(id: context.filePath ?? "") {
            guard let path = context.filePath else {
                native = nil
                nativeKey = ""
                return
            }
            guard nativeKey != path else { return }
            let info = await ViewingImageLoader.info(forPath: path)
            guard let size = info.pixelSize else { return }
            let decoded = await ViewingImageLoader.decode(path: path, maxPixelSize: max(size.width, size.height))
            guard !Task.isCancelled else { return }
            native = decoded
            nativeKey = decoded == nil ? "" : path
        }
    }

    @ViewBuilder
    private func loupe(at pointer: CGPoint, source: CGImage) -> some View {
        let rect = LoupeGeometry.lightboxImageRect(
            imageSize: context.image.size,
            viewport: context.viewport,
            padding: context.padding,
            zoomScale: context.zoomScale,
            offset: context.offset
        )
        let pixelSize = CGSize(width: source.width, height: source.height)
        if let pixel = LoupeGeometry.pixel(at: pointer, imageRect: rect, pixelSize: pixelSize) {
            let sourceRect = LoupeGeometry.sourceRect(
                around: pixel,
                diameter: Self.diameter,
                magnification: CGFloat(viewing.loupeMagnification),
                backingScale: displayScale
            )
            let diameter = Self.diameter
            VStack(spacing: AppSpacing.xs) {
                ZStack(alignment: .topLeading) {
                    Color.appCanvasBackground
                    if let part = LoupeGeometry.visiblePart(of: sourceRect, pixelSize: pixelSize, diameter: diameter),
                       let crop = source.cropping(to: part.crop)
                    {
                        Image(decorative: crop, scale: 1)
                            .resizable()
                            .interpolation(viewing.loupeNearestNeighbour ? .none : .high)
                            .frame(width: part.placement.width, height: part.placement.height)
                            .offset(x: part.placement.minX, y: part.placement.minY)
                    }
                    crosshair(diameter: diameter)
                }
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Color.appPrimaryText.opacity(0.9), lineWidth: 2))
                .shadow(color: Color.appShadowColor, radius: 10, y: 4)

                pixelReadout(pixel: pixel, source: source)
            }
            .position(x: pointer.x, y: pointer.y + 14)
            .accessibilityHidden(true)
        }
    }

    private func crosshair(diameter: CGFloat) -> some View {
        ZStack {
            Rectangle().fill(Color.appPrimaryText.opacity(0.6)).frame(width: 1, height: 14)
            Rectangle().fill(Color.appPrimaryText.opacity(0.6)).frame(width: 14, height: 1)
        }
        .frame(width: diameter, height: diameter)
    }

    private func pixelReadout(pixel: CGPoint, source: CGImage) -> some View {
        let x = min(max(Int(pixel.x), 0), source.width - 1)
        let y = min(max(Int(pixel.y), 0), source.height - 1)
        let rgb = Self.sample(source, x: x, y: y)
        let text = rgb.map { "\(x), \(y) · R \($0.0) G \($0.1) B \($0.2)" } ?? "\(x), \(y)"
        return Text(text)
            .font(.appMicro)
            .monospacedDigit()
            .foregroundStyle(Color.appPrimaryText)
            .padding(.horizontal, AppSpacing.sm)
            .padding(.vertical, AppSpacing.xxs)
            .background(Capsule().fill(Color.appOverlaySurface))
    }

    /// One pixel's sRGB value (draws a 1 × 1 crop; cheap).
    static func sample(_ image: CGImage, x: Int, y: Int) -> (Int, Int, Int)? {
        guard let pixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }
        var data = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let drawn: Bool = data.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { return nil }
        return (Int(data[0]), Int(data[1]), Int(data[2]))
    }
}

// MARK: - Histogram

/// Histogram card at the top of the details panel (View ▸ Histogram): RGB +
/// luminance for the selected image, with shadow / highlight clipping.
struct DetailsHistogramCard: View {
    let path: String
    @State private var data: HistogramData?
    @State private var dataKey = ""

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            HStack(spacing: AppSpacing.sm) {
                Text("Histogram")
                    .font(.appCaptionEmphasis)
                    .foregroundStyle(Color.appPrimaryText)
                Spacer(minLength: 0)
                if let data, dataKey == path {
                    clipLamp("Shadows", on: data.isShadowClipped, fraction: data.shadowClippedFraction)
                    clipLamp("Highlights", on: data.isHighlightClipped, fraction: data.highlightClippedFraction)
                }
                Button {
                    ViewingController.shared.histogramEnabled = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.appIcon(9, weight: .semibold))
                }
                .buttonStyle(AppIconButtonStyle(width: 18, height: 18, cornerRadius: AppRadius.xs, showsRestingChrome: false))
                .help("Hide Histogram (View ▸ Histogram)")
                .accessibilityLabel("Hide Histogram")
            }
            ZStack {
                if let data, dataKey == path {
                    HistogramPlot(data: data)
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 72)
            .background(RoundedRectangle(cornerRadius: AppRadius.sm).fill(Color.appCanvasBackground.opacity(0.6)))
            HStack(spacing: AppSpacing.md) {
                legend("R", color: .labelRed)
                legend("G", color: .labelGreen)
                legend("B", color: .labelBlue)
                legend("Luminance", color: .appPrimaryText)
            }
        }
        .task(id: path) { await load() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private func load() async {
        let requested = path
        let result = await HistogramService.shared.histogram(forFileAt: URL(fileURLWithPath: requested))
        guard !Task.isCancelled, requested == path else { return }
        data = result
        dataKey = requested
    }

    private func clipLamp(_ title: String, on: Bool, fraction: Double) -> some View {
        HStack(spacing: AppSpacing.xxs) {
            Image(systemName: title == "Shadows" ? "arrowtriangle.left.fill" : "arrowtriangle.right.fill")
                .font(.appMicro)
                .foregroundStyle(on ? Color.appError : Color.appMuted.opacity(0.5))
            Text(on ? String(format: "%.1f%%", fraction * 100) : title)
                .font(.appMicro)
                .foregroundStyle(on ? Color.appPrimaryText : Color.appMuted)
                .monospacedDigit()
        }
        .help(on ? "\(title) clipped: \(String(format: "%.2f", fraction * 100)) % of pixels" : "No \(title.lowercased()) clipping")
    }

    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: AppSpacing.xxs) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title)
                .font(.appMicro)
                .foregroundStyle(Color.appMuted)
        }
    }

    private var accessibilitySummary: String {
        guard let data, dataKey == path else { return "Histogram loading" }
        return "Histogram. Shadow clipping \(String(format: "%.1f", data.shadowClippedFraction * 100)) percent, highlight clipping \(String(format: "%.1f", data.highlightClippedFraction * 100)) percent."
    }
}

/// RGB channels as translucent fills, luminance as a line.
struct HistogramPlot: View {
    let data: HistogramData

    var body: some View {
        Canvas { context, size in
            let peak = Double(data.displayPeak)
            func path(_ bins: [Int], closed: Bool) -> Path {
                var path = Path()
                let step = size.width / CGFloat(max(bins.count - 1, 1))
                if closed { path.move(to: CGPoint(x: 0, y: size.height)) }
                for (index, value) in bins.enumerated() {
                    let height = CGFloat(min(Double(value) / peak, 1)) * size.height
                    let point = CGPoint(x: CGFloat(index) * step, y: size.height - height)
                    if index == 0, !closed { path.move(to: point) } else { path.addLine(to: point) }
                }
                if closed {
                    path.addLine(to: CGPoint(x: size.width, y: size.height))
                    path.closeSubpath()
                }
                return path
            }
            context.fill(path(data.red, closed: true), with: .color(Color.labelRed.opacity(0.45)))
            context.fill(path(data.green, closed: true), with: .color(Color.labelGreen.opacity(0.45)))
            context.fill(path(data.blue, closed: true), with: .color(Color.labelBlue.opacity(0.45)))
            context.stroke(path(data.luminance, closed: false), with: .color(Color.appPrimaryText.opacity(0.9)), lineWidth: 1)
        }
    }
}

// MARK: - Header buttons

/// Loupe and Histogram toggles for the lightbox's header (also View menu items).
struct LightboxViewingChromeButtons: View {
    @Bindable private var viewing = ViewingController.shared

    var body: some View {
        Menu {
            Toggle("Loupe", isOn: $viewing.loupeEnabled)
            Picker("Magnification", selection: $viewing.loupeMagnification) {
                ForEach(ViewingController.loupeMagnifications, id: \.self) { Text("\($0)×").tag($0) }
            }
            Toggle("Crisp Pixels (Nearest Neighbour)", isOn: $viewing.loupeNearestNeighbour)
        } label: {
            Image(systemName: viewing.loupeEnabled ? "plus.magnifyingglass" : "magnifyingglass")
                .font(.appIcon(13, weight: .medium))
                .foregroundStyle(viewing.loupeEnabled ? Color.appAccent : Color.appMuted)
                .frame(width: 30, height: 30)
        } primaryAction: {
            viewing.loupeEnabled.toggle()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(viewing.loupeEnabled ? "Loupe On (\(viewing.loupeMagnification)×) — click to turn off, hold for options" : "Loupe — click to turn on, hold for options")
        .accessibilityLabel("Loupe")
        .accessibilityValue(viewing.loupeEnabled ? "On, \(viewing.loupeMagnification)×" : "Off")
    }
}
