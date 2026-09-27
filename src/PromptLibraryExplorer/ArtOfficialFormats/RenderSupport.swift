import CoreGraphics
import CoreText
import Foundation

/// Drawing primitives shared by the renderers. All geometry is expressed in a
/// top-left-origin logical space; `Canvas` converts to CoreGraphics' bottom-left space.
struct Canvas {
    let ctx: CGContext
    let width: CGFloat    // logical
    let height: CGFloat   // logical

    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Creates a bitmap whose longest side is `maxPixelSize`, scaled from the logical size.
    static func make(logicalWidth w: CGFloat, logicalHeight h: CGFloat, maxPixelSize: Int) -> Canvas? {
        guard maxPixelSize > 0, w > 0, h > 0, w.isFinite, h.isFinite else { return nil }
        let maxPx = CGFloat(min(maxPixelSize, 8192))
        let scale = maxPx / max(w, h)
        let pw = max(1, Int((w * scale).rounded()))
        let ph = max(1, Int((h * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.setShouldAntialias(true)
        ctx.setAllowsFontSmoothing(true)
        ctx.scaleBy(x: CGFloat(pw) / w, y: CGFloat(ph) / h)
        return Canvas(ctx: ctx, width: w, height: h)
    }

    var pixelScale: CGFloat { CGFloat(ctx.width) / width }

    /// Top-left logical rect -> CoreGraphics rect.
    func cg(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height)
    }

    func fill(_ r: CGRect, _ color: CGColor, radius: CGFloat = 0) {
        ctx.saveGState()
        ctx.setFillColor(color)
        ctx.addPath(Self.roundedPath(cg(r), radius))
        ctx.fillPath()
        ctx.restoreGState()
    }

    func stroke(_ r: CGRect, _ color: CGColor, width: CGFloat, radius: CGFloat = 0) {
        ctx.saveGState()
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.addPath(Self.roundedPath(cg(r).insetBy(dx: width / 2, dy: width / 2), max(0, radius - width / 2)))
        ctx.strokePath()
        ctx.restoreGState()
    }

    static func roundedPath(_ r: CGRect, _ radius: CGFloat) -> CGPath {
        let rad = max(0, min(radius, min(r.width, r.height) / 2))
        return rad > 0 ? CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil) : CGPath(rect: r, transform: nil)
    }

    /// Draws with a soft drop shadow behind a rounded rect (shadow only; content drawn separately).
    func shadow(_ r: CGRect, radius: CGFloat, color: CGColor) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 14, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.18))
        fill(r, color, radius: radius)
        ctx.restoreGState()
    }

    /// Aspect-fill `image` into `r` with CSS-like pan (ratio of the frame, +y = down) and zoom.
    func drawFill(_ image: CGImage, in r: CGRect, radius: CGFloat = 0, pan: CGPoint = .zero, zoom: Double = 1, alpha: CGFloat = 1) {
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        guard iw > 0, ih > 0, r.width > 0, r.height > 0 else { return }
        let scale = max(r.width / iw, r.height / ih) * CGFloat(max(1, zoom))
        let dw = iw * scale, dh = ih * scale
        // Clamp the pan so the image always covers the frame.
        let maxX = max(0, (dw - r.width) / 2), maxY = max(0, (dh - r.height) / 2)
        let ox = min(max(pan.x * r.width, -maxX), maxX)
        let oy = min(max(pan.y * r.height, -maxY), maxY)
        let dest = CGRect(x: r.midX - dw / 2 + ox, y: r.midY - dh / 2 + oy, width: dw, height: dh)
        ctx.saveGState()
        ctx.addPath(Self.roundedPath(cg(r), radius))
        ctx.clip()
        ctx.setAlpha(alpha)
        ctx.draw(image, in: cg(dest))
        ctx.restoreGState()
    }

    /// Aspect-fit (letterboxed) draw.
    func drawFit(_ image: CGImage, in r: CGRect, radius: CGFloat = 0) {
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        guard iw > 0, ih > 0 else { return }
        let scale = min(r.width / iw, r.height / ih)
        let dest = CGRect(x: r.midX - iw * scale / 2, y: r.midY - ih * scale / 2, width: iw * scale, height: ih * scale)
        ctx.saveGState()
        ctx.addPath(Self.roundedPath(cg(dest), radius))
        ctx.clip()
        ctx.draw(image, in: cg(dest))
        ctx.restoreGState()
    }

    /// Tasteful "missing image" tile: tinted fill + a simple landscape glyph.
    func placeholder(_ r: CGRect, radius: CGFloat, base: RGB, seed: String, label: String? = nil) {
        let tint = Double(Self.stableHash(seed) % 1000) / 1000
        let dark = base.luminance < 0.5
        let bg = dark ? base.mixed(with: RGB(r: 1, g: 1, b: 1), 0.08 + tint * 0.05)
                      : base.mixed(with: RGB(r: 0, g: 0, b: 0), 0.06 + tint * 0.05)
        fill(r, bg.cg, radius: radius)
        let fg = (dark ? RGB(r: 1, g: 1, b: 1) : RGB(r: 0, g: 0, b: 0)).cg(alpha: 0.22)
        let side = min(r.width, r.height) * 0.28
        guard side > 4 else { return }
        let g = CGRect(x: r.midX - side / 2, y: r.midY - side * 0.4, width: side, height: side * 0.8)
        ctx.saveGState()
        ctx.setStrokeColor(fg)
        ctx.setFillColor(fg)
        ctx.setLineWidth(max(1, side * 0.06))
        ctx.addPath(Self.roundedPath(cg(g), side * 0.1))
        ctx.strokePath()
        // Mountains
        let m = cg(g.insetBy(dx: side * 0.12, dy: side * 0.14))
        ctx.move(to: CGPoint(x: m.minX, y: m.minY))
        ctx.addLine(to: CGPoint(x: m.minX + m.width * 0.38, y: m.minY + m.height * 0.62))
        ctx.addLine(to: CGPoint(x: m.minX + m.width * 0.6, y: m.minY + m.height * 0.3))
        ctx.addLine(to: CGPoint(x: m.minX + m.width * 0.75, y: m.minY + m.height * 0.45))
        ctx.addLine(to: CGPoint(x: m.maxX, y: m.minY))
        ctx.closePath()
        ctx.fillPath()
        let sun = side * 0.1
        ctx.fillEllipse(in: CGRect(x: m.maxX - sun * 2.2, y: m.maxY - sun * 2.2, width: sun * 1.6, height: sun * 1.6))
        ctx.restoreGState()
        if let label, !label.isEmpty, r.height > side * 2.2 {
            text(label, in: CGRect(x: r.minX + 8, y: g.maxY + side * 0.2, width: r.width - 16, height: side * 0.6),
                 font: Fonts.regular(max(8, side * 0.2)), color: fg, alignment: .center, maxLines: 1)
        }
    }

    // MARK: Text

    /// Lays out `string` in `r` (top-left logical), wrapping to `maxLines`, truncating the last.
    @discardableResult
    func text(_ string: String, in r: CGRect, font: CTFont, color: CGColor, alignment: CTTextAlignment = .left,
              maxLines: Int = 1, lineSpacing: CGFloat = 1.15) -> CGFloat {
        let clean = string.replacingOccurrences(of: "\r", with: "")
            .split(whereSeparator: \.isNewline).joined(separator: maxLines == 1 ? " " : "\n")
        guard !clean.isEmpty, r.width > 4, r.height > 1, maxLines > 0 else { return 0 }
        let attrs: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color]
        let attributed = CFAttributedStringCreate(nil, clean as CFString, attrs as CFDictionary)!
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let length = CFAttributedStringGetLength(attributed)
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font), leading = CTFontGetLeading(font)
        let lineHeight = (ascent + descent + leading) * lineSpacing
        let fitLines = max(1, min(maxLines, Int(floor((r.height + (lineHeight - ascent - descent)) / lineHeight))))

        var lines: [CTLine] = []
        var start = 0
        while start < length && lines.count < fitLines {
            let count = CTTypesetterSuggestLineBreak(typesetter, start, Double(r.width))
            guard count > 0 else { break }
            let isLast = lines.count == fitLines - 1
            if isLast && start + count < length {
                let rest = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: length - start))
                let token = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, "…" as CFString, attrs as CFDictionary)!)
                lines.append(CTLineCreateTruncatedLine(rest, Double(r.width), .end, token) ?? rest)
            } else {
                lines.append(CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count)))
            }
            start += count
        }

        ctx.saveGState()
        ctx.textMatrix = .identity
        var y = r.minY + ascent
        for line in lines {
            let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line))
            let x: CGFloat
            switch alignment {
            case .center: x = r.minX + (r.width - w) / 2
            case .right: x = r.maxX - w
            default: x = r.minX
            }
            ctx.textPosition = CGPoint(x: x, y: height - y)
            CTLineDraw(line, ctx)
            y += lineHeight
        }
        ctx.restoreGState()
        return CGFloat(lines.count) * lineHeight
    }

    /// Deterministic FNV-1a (Swift's hashValue is randomised per process).
    static func stableHash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01B3 }
        return h
    }
}

struct RGB: Sendable {
    var r: Double, g: Double, b: Double

    init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }

    init(hex: String?, fallback: RGB) {
        if let c = Hex.rgb(hex) { self.init(r: c.r, g: c.g, b: c.b) } else { self = fallback }
    }

    var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
    var cg: CGColor { cg(alpha: 1) }
    func cg(alpha: Double) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: alpha) }
    func mixed(with o: RGB, _ t: Double) -> RGB { RGB(r: r + (o.r - r) * t, g: g + (o.g - g) * t, b: b + (o.b - b) * t) }
}

enum Fonts {
    static func regular(_ size: CGFloat) -> CTFont {
        CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    static func bold(_ size: CGFloat) -> CTFont {
        CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil) ?? CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
    }

    static func mono(_ size: CGFloat) -> CTFont {
        CTFontCreateUIFontForLanguage(.userFixedPitch, size, nil) ?? CTFontCreateWithName("Menlo-Regular" as CFString, size, nil)
    }

    /// Maps the Mood CSS font class to a CoreText face.
    static func moodTitle(_ cssClass: String, _ size: CGFloat) -> CTFont {
        if cssClass.contains("playfair") { return CTFontCreateWithName("Georgia-Bold" as CFString, size, nil) }
        if cssClass.contains("mono") {
            let base = mono(size)
            return CTFontCreateCopyWithSymbolicTraits(base, size, nil, .traitBold, .traitBold) ?? base
        }
        return bold(size)
    }

    static func moodBody(_ cssClass: String, _ size: CGFloat) -> CTFont {
        if cssClass.contains("playfair") { return CTFontCreateWithName("Georgia" as CFString, size, nil) }
        if cssClass.contains("mono") { return mono(size) }
        return regular(size)
    }
}

/// Enforces the per-render cap on decoded images.
struct DecodeBudget {
    private(set) var remaining: Int

    init(_ limit: Int) { remaining = limit }

    mutating func decode(_ image: EmbeddedImage?, maxPixelSize: Int) -> CGImage? {
        guard let image, image.isResolvable, remaining > 0 else { return nil }
        remaining -= 1
        return image.cgImage(maxPixelSize: max(16, maxPixelSize))
    }
}

func formatDuration(_ seconds: Int) -> String {
    let s = max(0, seconds)
    if s >= 3600 { return String(format: "%dh %02dm", s / 3600, (s % 3600) / 60) }
    if s >= 60 { return s % 60 == 0 ? "\(s / 60)m" : "\(s / 60)m \(s % 60)s" }
    return "\(s)s"
}
