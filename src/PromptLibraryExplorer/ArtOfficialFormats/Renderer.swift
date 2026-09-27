import CoreGraphics
import CoreText
import Foundation

/// Thumbnail / preview renderers (CoreGraphics + CoreText only, sRGB, deterministic).
/// Each returns an image whose longest side equals `maxPixelSize`.
public enum ArtOfficialRenderer {
    public static let maxDecodedImagesPerRender = 12
    static let maxTilesPerRender = 30

    // MARK: - Mood board

    public static func renderMoodboard(_ board: Moodboard, maxPixelSize: Int) -> CGImage? {
        guard maxPixelSize > 0 else { return nil }
        let W: CGFloat = 1200
        let bg = RGB(hex: board.backgroundHex, fallback: RGB(r: 1, g: 1, b: 1))
        let fg = RGB(hex: board.textHex, fallback: bg.luminance > 0.5 ? RGB(r: 0.12, g: 0.16, b: 0.22) : RGB(r: 1, g: 1, b: 1))
        let pad = CGFloat(min(max(board.padding, 16), 120))
        let gap = CGFloat(min(max(board.gap, 0), 60))
        let columns = max(1, min(board.columns, 12))
        let radius: CGFloat = board.rounded ? 12 : 0
        let showTitle = !board.hideTitle && !board.title.trimmingCharacters(in: .whitespaces).isEmpty
        let showSubtitle = !board.hideSubtitle && !board.subtitle.trimmingCharacters(in: .whitespaces).isEmpty
        let headerH: CGFloat = (showTitle || showSubtitle) ? (showTitle && showSubtitle ? 84 : 56) : 0
        let headerGap: CGFloat = headerH > 0 ? 28 : 0
        let palette = Array(board.palette.prefix(12))
        let paletteH: CGFloat = palette.isEmpty ? 0 : 44
        let paletteGap: CGFloat = palette.isEmpty ? 0 : 24
        let contentW = W - pad * 2
        let colW = (contentW - CGFloat(columns - 1) * gap) / CGFloat(columns)

        // Pick tiles and decode images (budgeted). Logo/background count toward the budget.
        var budget = DecodeBudget(maxDecodedImagesPerRender)
        let tiles = Array(board.tiles.prefix(maxTilesPerRender))
        let perTilePx = min(1024, max(128, Int(CGFloat(maxPixelSize) / CGFloat(columns) * 2)))
        var decoded: [String: CGImage] = [:]
        for tile in tiles {
            guard let assetID = tile.assetId, decoded[tile.id] == nil else { continue }
            let span = CGFloat(board.layoutMode == .mosaic ? min(tile.colSpan, columns) : 1)
            if let img = budget.decode(board.asset(id: assetID)?.image, maxPixelSize: Int(CGFloat(perTilePx) * span)) {
                decoded[tile.id] = img
            }
        }

        // Layout (logical, relative to content origin).
        var frames: [(MoodboardTile, CGRect)] = []
        let maxContentH = W * 3
        switch board.layoutMode {
        case .auto:
            var heights = [CGFloat](repeating: 0, count: columns)
            for tile in tiles {
                let h: CGFloat
                switch tile.content {
                case .image:
                    if let img = decoded[tile.id], img.width > 0 {
                        h = colW * CGFloat(img.height) / CGFloat(img.width)
                    } else { h = colW }
                case .color: h = 150
                case .text: h = 100
                }
                let c = heights.indices.min { heights[$0] < heights[$1] }!
                if heights[c] > maxContentH { break }
                frames.append((tile, CGRect(x: CGFloat(c) * (colW + gap), y: heights[c], width: colW, height: min(h, colW * 3))))
                heights[c] += min(h, colW * 3) + gap
            }
        case .grid, .mosaic:
            var occupied: [[Bool]] = []
            func free(_ r: Int, _ c: Int, _ cs: Int, _ rs: Int) -> Bool {
                guard c + cs <= columns else { return false }
                for rr in r..<(r + rs) where rr < occupied.count {
                    for cc in c..<(c + cs) where occupied[rr][cc] { return false }
                }
                return true
            }
            for tile in tiles {
                let cs = board.layoutMode == .mosaic ? min(tile.colSpan, columns) : 1
                let rs = board.layoutMode == .mosaic ? min(tile.rowSpan, 6) : 1
                var placed = false
                var row = 0
                while !placed && row < 400 {
                    for col in 0..<columns where free(row, col, cs, rs) {
                        while occupied.count < row + rs { occupied.append([Bool](repeating: false, count: columns)) }
                        for rr in row..<(row + rs) { for cc in col..<(col + cs) { occupied[rr][cc] = true } }
                        let rect = CGRect(x: CGFloat(col) * (colW + gap), y: CGFloat(row) * (colW + gap),
                                          width: CGFloat(cs) * colW + CGFloat(cs - 1) * gap,
                                          height: CGFloat(rs) * colW + CGFloat(rs - 1) * gap)
                        frames.append((tile, rect))
                        placed = true
                        break
                    }
                    row += 1
                }
                if CGFloat(occupied.count) * (colW + gap) > maxContentH { break }
            }
        }
        let naturalH = max(frames.map { $0.1.maxY }.max() ?? colW, colW * 0.75)

        // Canvas size: explicit aspect ratio wins, otherwise grow with content.
        let chromeH = pad * 2 + headerH + headerGap + paletteGap + paletteH
        let H: CGFloat
        if let ratio = board.aspectRatioValue, ratio > 0.2, ratio < 5 {
            H = W / CGFloat(ratio)
        } else {
            H = min(max(chromeH + naturalH, W * 0.5), W * 4)
        }
        let availableH = max(40, H - chromeH)
        let fit = min(1, availableH / naturalH)
        let originX = pad + (contentW - contentW * fit) / 2
        let originY = pad + headerH + headerGap

        guard let canvas = Canvas.make(logicalWidth: W, logicalHeight: H, maxPixelSize: maxPixelSize) else { return nil }
        canvas.fill(CGRect(x: 0, y: 0, width: W, height: H), bg.cg)

        if let bgAsset = board.backgroundAsset, let img = budget.decode(bgAsset.image, maxPixelSize: board.background!.blur > 0 ? 96 : 800) {
            canvas.drawFill(img, in: CGRect(x: 0, y: 0, width: W, height: H), alpha: CGFloat(min(max(board.background!.opacity, 0), 1)))
        }

        // Header
        if headerH > 0 {
            var y = pad
            if showTitle {
                canvas.text(board.title, in: CGRect(x: pad, y: y, width: contentW, height: 48),
                            font: Fonts.moodTitle(board.font, 38), color: fg.cg)
                y += 50
            }
            if showSubtitle {
                canvas.text(board.subtitle, in: CGRect(x: pad, y: y, width: contentW, height: 28),
                            font: Fonts.moodBody(board.font, 20), color: fg.cg(alpha: 0.7))
            }
        }

        // Tiles
        for (tile, local) in frames {
            let r = CGRect(x: originX + local.minX * fit, y: originY + local.minY * fit,
                           width: local.width * fit, height: local.height * fit)
            guard r.maxY <= H - pad + 1 else { continue }
            let tr = radius * fit
            switch tile.content {
            case .image(_, let pan, let zoom):
                if board.shadow { canvas.shadow(r, radius: tr, color: bg.cg) }
                if let img = decoded[tile.id] {
                    canvas.drawFill(img, in: r, radius: tr, pan: board.layoutMode == .mosaic ? pan : .zero,
                                    zoom: board.layoutMode == .mosaic ? zoom : 1)
                } else {
                    canvas.placeholder(r, radius: tr, base: bg, seed: tile.id)
                }
                if board.imageBorder, board.imageBorderWidth > 0 {
                    canvas.stroke(r, RGB(hex: board.imageBorderHex, fallback: RGB(r: 1, g: 1, b: 1)).cg,
                                  width: CGFloat(board.imageBorderWidth) * fit, radius: tr)
                }
            case .color(let hex):
                if board.shadow { canvas.shadow(r, radius: tr, color: bg.cg) }
                let c = RGB(hex: hex, fallback: RGB(r: 0.8, g: 0.8, b: 0.8))
                canvas.fill(r, c.cg, radius: tr)
                let label = c.luminance > 0.55 ? RGB(r: 0, g: 0, b: 0) : RGB(r: 1, g: 1, b: 1)
                if r.height > 40 {
                    canvas.text(hex.uppercased(), in: CGRect(x: r.minX + 10 * fit, y: r.maxY - 26 * fit, width: r.width - 20 * fit, height: 20 * fit),
                                font: Fonts.mono(max(6, 13 * fit)), color: label.cg(alpha: 0.75))
                }
            case .text(let text, let textHex, let bgHex, let size, let align, let bold):
                if let bgHex { canvas.fill(r, RGB(hex: bgHex, fallback: bg).cg, radius: tr) }
                let color = RGB(hex: textHex, fallback: fg)
                let fs = CGFloat(min(max(size ?? 18, 8), 72)) * fit
                let font = bold ? Fonts.moodTitle(board.font, fs) : Fonts.moodBody(board.font, fs)
                let alignment: CTTextAlignment = align == "center" ? .center : (align == "right" ? .right : .left)
                canvas.text(text, in: r.insetBy(dx: 12 * fit, dy: 12 * fit), font: font, color: color.cg,
                            alignment: alignment, maxLines: 8)
            }
        }

        // Logo
        if let logo = board.logo, let asset = board.logoAsset, let img = budget.decode(asset.image, maxPixelSize: 400) {
            let lw = max(24, W * CGFloat(min(max(logo.scale, 0.03), 0.5)))
            let lh = lw * CGFloat(img.height) / CGFloat(max(1, img.width))
            let x = logo.position.hasSuffix("left") ? pad : W - pad - lw
            let y = logo.position.hasPrefix("top") ? pad * 0.5 : H - pad * 0.5 - lh
            canvas.drawFit(img, in: CGRect(x: x, y: y, width: lw, height: lh))
        }

        // Palette strip
        if !palette.isEmpty {
            let y = H - pad - paletteH
            let sw = min(paletteH * 2.2, (contentW - CGFloat(palette.count - 1) * 8) / CGFloat(palette.count))
            for (i, hex) in palette.enumerated() {
                let r = CGRect(x: pad + CGFloat(i) * (sw + 8), y: y, width: sw, height: paletteH)
                let c = RGB(hex: hex, fallback: bg)
                canvas.fill(r, c.cg, radius: min(8, paletteH / 2))
                if abs(c.luminance - bg.luminance) < 0.06 {
                    canvas.stroke(r, fg.cg(alpha: 0.15), width: 1, radius: min(8, paletteH / 2))
                }
            }
        }
        return canvas.ctx.makeImage()
    }

    // MARK: - Story

    static let storyBG = RGB(r: 0.07, g: 0.07, b: 0.08)
    static let storyPanel = RGB(r: 0.12, g: 0.12, b: 0.14)
    static let storyText = RGB(r: 0.96, g: 0.96, b: 0.97)
    static let storyAccent = RGB(r: 0.91, g: 0.47, b: 0.98)   // Story's fuchsia

    /// Cover image if present, else a 1/2x2/3x3 grid of the first shot thumbnails with names.
    public static func renderStoryContactSheet(_ project: StoryProject, maxPixelSize: Int) -> CGImage? {
        let W: CGFloat = 1200, H: CGFloat = 900
        guard let canvas = Canvas.make(logicalWidth: W, logicalHeight: H, maxPixelSize: maxPixelSize) else { return nil }
        var budget = DecodeBudget(maxDecodedImagesPerRender)
        canvas.fill(CGRect(x: 0, y: 0, width: W, height: H), storyBG.cg)

        // Title band
        let pad: CGFloat = 40
        let bandH: CGFloat = 120
        canvas.fill(CGRect(x: 0, y: 0, width: W, height: bandH), storyPanel.cg)
        canvas.fill(CGRect(x: 0, y: bandH - 3, width: W, height: 3), storyAccent.cg)
        canvas.text(project.title, in: CGRect(x: pad, y: 22, width: W - pad * 2, height: 50),
                    font: Fonts.bold(40), color: storyText.cg)
        var meta: [String] = []
        if !project.code.isEmpty { meta.append(project.code) }
        meta.append("\(project.scenes.count) scene\(project.scenes.count == 1 ? "" : "s")")
        meta.append("\(project.shotCount) shot\(project.shotCount == 1 ? "" : "s")")
        if project.estimatedDurationSec > 0 { meta.append(formatDuration(project.estimatedDurationSec)) }
        meta.append(project.aspectRatio)
        canvas.text(meta.joined(separator: "  ·  "), in: CGRect(x: pad, y: 76, width: W - pad * 2, height: 28),
                    font: Fonts.regular(20), color: storyText.cg(alpha: 0.6))

        let body = CGRect(x: pad, y: bandH + pad * 0.75, width: W - pad * 2, height: H - bandH - pad * 1.75)
        if let cover = budget.decode(project.coverImage, maxPixelSize: maxPixelSize) {
            canvas.drawFill(cover, in: body, radius: 14)
            if let logline = project.logline {
                let r = CGRect(x: body.minX, y: body.maxY - 90, width: body.width, height: 90)
                canvas.ctx.saveGState()
                canvas.ctx.addPath(Canvas.roundedPath(canvas.cg(body), 14)); canvas.ctx.clip()
                canvas.fill(r, RGB(r: 0, g: 0, b: 0).cg(alpha: 0.55))
                canvas.ctx.restoreGState()
                canvas.text(logline, in: r.insetBy(dx: 24, dy: 18), font: Fonts.regular(22), color: storyText.cg, maxLines: 2)
            }
            return canvas.ctx.makeImage()
        }

        let shots = Array(project.allShots.prefix(9))
        guard !shots.isEmpty else {
            canvas.placeholder(body, radius: 14, base: storyBG, seed: project.id, label: "No shots yet")
            if let logline = project.logline {
                canvas.text(logline, in: CGRect(x: body.minX + 40, y: body.maxY - 110, width: body.width - 80, height: 70),
                            font: Fonts.regular(22), color: storyText.cg(alpha: 0.7), alignment: .center, maxLines: 2)
            }
            return canvas.ctx.makeImage()
        }
        let n = shots.count <= 1 ? 1 : (shots.count <= 4 ? 2 : 3)
        let rows = Int(ceil(Double(shots.count) / Double(n)))
        let gap: CGFloat = 20
        let captionH: CGFloat = n == 1 ? 40 : (n == 2 ? 34 : 28)
        let cellW = (body.width - CGFloat(n - 1) * gap) / CGFloat(n)
        let cellH = (body.height - CGFloat(max(n, rows) - 1) * gap) / CGFloat(max(n, rows))
        let aspect = CGFloat(project.aspectRatioValue)
        var frameW = cellW
        var frameH = frameW / aspect
        if frameH > cellH - captionH { frameH = cellH - captionH; frameW = frameH * aspect }
        let px = min(1024, Int(CGFloat(maxPixelSize) / CGFloat(n) * 1.5))
        let gridH = CGFloat(max(n, rows)) * cellH + CGFloat(max(n, rows) - 1) * gap
        let top = body.minY + (body.height - gridH) / 2

        for (i, shot) in shots.enumerated() {
            let col = i % n, row = i / n
            let cell = CGRect(x: body.minX + CGFloat(col) * (cellW + gap), y: top + CGFloat(row) * (cellH + gap), width: cellW, height: cellH)
            let block = frameH + captionH
            let frame = CGRect(x: cell.midX - frameW / 2, y: cell.minY + (cellH - block) / 2, width: frameW, height: frameH)
            if let img = budget.decode(shot.thumb, maxPixelSize: px) {
                canvas.drawFill(img, in: frame, radius: 8)
            } else {
                canvas.placeholder(frame, radius: 8, base: storyPanel, seed: shot.id,
                                   label: shot.thumb?.isResolvable == false ? "Image not embedded" : nil)
            }
            let fs: CGFloat = n == 1 ? 24 : (n == 2 ? 20 : 17)
            let number = "\(i + 1)"
            canvas.text(number, in: CGRect(x: frame.minX, y: frame.maxY + 8, width: 40, height: fs * 1.4),
                        font: Fonts.bold(fs), color: storyAccent.cg)
            let label = shot.name.isEmpty ? (shot.description.isEmpty ? "Shot \(i + 1)" : shot.description) : shot.name
            canvas.text(label, in: CGRect(x: frame.minX + fs * 1.6, y: frame.maxY + 8, width: frameW - fs * 1.6, height: fs * 1.4),
                        font: Fonts.regular(fs), color: storyText.cg(alpha: 0.85))
        }
        if project.shotCount > shots.count {
            let more = "+\(project.shotCount - shots.count) more"
            canvas.text(more, in: CGRect(x: W - pad - 300, y: H - pad * 0.95, width: 300, height: 26),
                        font: Fonts.regular(18), color: storyText.cg(alpha: 0.5), alignment: .right)
        }
        return canvas.ctx.makeImage()
    }

    /// A single storyboard frame (project aspect ratio) with a caption band.
    public static func renderStoryShot(_ shot: StoryShot, project: StoryProject?, maxPixelSize: Int) -> CGImage? {
        let W: CGFloat = 1200
        let aspect = CGFloat(project?.aspectRatioValue ?? 16.0 / 9.0)
        let frameH = W / min(max(aspect, 0.3), 4)
        let captionH: CGFloat = 170
        let H = frameH + captionH
        guard let canvas = Canvas.make(logicalWidth: W, logicalHeight: H, maxPixelSize: maxPixelSize) else { return nil }
        var budget = DecodeBudget(maxDecodedImagesPerRender)
        canvas.fill(CGRect(x: 0, y: 0, width: W, height: H), storyBG.cg)
        let frame = CGRect(x: 0, y: 0, width: W, height: frameH)
        if let img = budget.decode(shot.thumb, maxPixelSize: maxPixelSize) {
            canvas.drawFill(img, in: frame)
        } else {
            canvas.placeholder(frame, radius: 0, base: storyPanel, seed: shot.id,
                               label: shot.thumb?.isResolvable == false ? "Image not embedded" : "No frame")
        }
        canvas.fill(CGRect(x: 0, y: frameH, width: W, height: 3), storyAccent.cg)

        let pad: CGFloat = 36
        var heading: [String] = []
        if let project, let (sIndex, scene) = project.scenes.enumerated().first(where: { $0.element.shots.contains { $0.id == shot.id } }) {
            let shotNo = (scene.shots.firstIndex { $0.id == shot.id } ?? 0) + 1
            heading.append(scene.isUnassigned ? "Unassigned" : "Scene \(scene.number > 0 ? scene.number : sIndex + 1)")
            heading.append("Shot \(shotNo)")
        }
        let title = shot.name.isEmpty ? "Untitled shot" : shot.name
        let headingText = heading.isEmpty ? "" : heading.joined(separator: " · ") + "  "
        canvas.text(headingText.uppercased(), in: CGRect(x: pad, y: frameH + 24, width: 360, height: 26),
                    font: Fonts.bold(18), color: storyAccent.cg)
        var right: [String] = shot.types
        right.append(formatDuration(shot.estDurationSec))
        canvas.text(right.joined(separator: " · "), in: CGRect(x: W - pad - 420, y: frameH + 24, width: 420, height: 26),
                    font: Fonts.regular(18), color: storyText.cg(alpha: 0.6), alignment: .right)
        canvas.text(title, in: CGRect(x: pad, y: frameH + 54, width: W - pad * 2, height: 40),
                    font: Fonts.bold(30), color: storyText.cg)
        let desc = shot.description.isEmpty ? shot.detailedNotes : shot.description
        canvas.text(desc, in: CGRect(x: pad, y: frameH + 100, width: W - pad * 2, height: 56),
                    font: Fonts.regular(19), color: storyText.cg(alpha: 0.75), maxLines: 2)
        return canvas.ctx.makeImage()
    }
}
