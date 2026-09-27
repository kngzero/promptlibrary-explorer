import CoreGraphics
import CoreText
import Foundation

// MARK: - Options

struct ContactSheetOptions: Codable, Equatable, Sendable {
    enum PageSize: String, Codable, CaseIterable, Identifiable, Sendable {
        case a4, letter, custom

        var id: String { rawValue }

        var title: String {
            switch self {
            case .a4: return "A4"
            case .letter: return "US Letter"
            case .custom: return "Custom"
            }
        }
    }

    enum Orientation: String, Codable, CaseIterable, Identifiable, Sendable {
        case portrait, landscape

        var id: String { rawValue }
        var title: String { self == .portrait ? "Portrait" : "Landscape" }
    }

    var pageSize: PageSize = .a4
    /// Custom page size in millimetres (portrait dimensions; orientation swaps them).
    var customWidthMM: Double = 210
    var customHeightMM: Double = 297
    var orientation: Orientation = .portrait
    var columns = 4
    var rows = 5
    var marginMM: Double = 12
    var spacingMM: Double = 4
    var showHeader = true
    var title = ""
    var showDate = true
    var showPageNumbers = true
    var captionFilename = true
    var captionPrompt = false
    var captionRatingFlag = false
    /// Lines of prompt text under each image (when `captionPrompt`).
    var promptLines = 2

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ContactSheetOptions()
        pageSize = (try? c.decode(PageSize.self, forKey: .pageSize)) ?? d.pageSize
        customWidthMM = (try? c.decode(Double.self, forKey: .customWidthMM)) ?? d.customWidthMM
        customHeightMM = (try? c.decode(Double.self, forKey: .customHeightMM)) ?? d.customHeightMM
        orientation = (try? c.decode(Orientation.self, forKey: .orientation)) ?? d.orientation
        columns = (try? c.decode(Int.self, forKey: .columns)) ?? d.columns
        rows = (try? c.decode(Int.self, forKey: .rows)) ?? d.rows
        marginMM = (try? c.decode(Double.self, forKey: .marginMM)) ?? d.marginMM
        spacingMM = (try? c.decode(Double.self, forKey: .spacingMM)) ?? d.spacingMM
        showHeader = (try? c.decode(Bool.self, forKey: .showHeader)) ?? d.showHeader
        title = (try? c.decode(String.self, forKey: .title)) ?? d.title
        showDate = (try? c.decode(Bool.self, forKey: .showDate)) ?? d.showDate
        showPageNumbers = (try? c.decode(Bool.self, forKey: .showPageNumbers)) ?? d.showPageNumbers
        captionFilename = (try? c.decode(Bool.self, forKey: .captionFilename)) ?? d.captionFilename
        captionPrompt = (try? c.decode(Bool.self, forKey: .captionPrompt)) ?? d.captionPrompt
        captionRatingFlag = (try? c.decode(Bool.self, forKey: .captionRatingFlag)) ?? d.captionRatingFlag
        promptLines = (try? c.decode(Int.self, forKey: .promptLines)) ?? d.promptLines
    }

    static let pointsPerMM = 72.0 / 25.4
}

/// One image on the sheet, gathered on the main actor before rendering.
struct ContactSheetItem: Sendable {
    var url: URL
    var name: String
    var prompt: String?
    var rating: Int = 0
    var flag: FileFlag = .unflagged
}

// MARK: - Layout

/// Page geometry in PDF points, top-left origin. Pure, for the renderer, the sheet's
/// preview and tests.
struct ContactSheetLayout: Equatable {
    let pageSize: CGSize
    let columns: Int
    let rows: Int
    let itemCount: Int
    let contentRect: CGRect
    let headerRect: CGRect?
    let footerRect: CGRect?
    let gridRect: CGRect
    let cellSize: CGSize
    let spacing: CGFloat
    let captionHeight: CGFloat

    static let headerHeight: CGFloat = 34
    static let footerHeight: CGFloat = 18
    static let captionLineHeight: CGFloat = 10.5

    var cellsPerPage: Int { columns * rows }

    var pageCount: Int {
        guard itemCount > 0 else { return 0 }
        return (itemCount + cellsPerPage - 1) / cellsPerPage
    }

    init(options: ContactSheetOptions, itemCount: Int) {
        var size: CGSize
        switch options.pageSize {
        case .a4: size = CGSize(width: 595.28, height: 841.89)
        case .letter: size = CGSize(width: 612, height: 792)
        case .custom:
            size = CGSize(
                width: max(50, min(5000, options.customWidthMM)) * ContactSheetOptions.pointsPerMM,
                height: max(50, min(5000, options.customHeightMM)) * ContactSheetOptions.pointsPerMM
            )
        }
        let isLandscape = options.orientation == .landscape
        if (size.width > size.height) != isLandscape, size.width != size.height {
            size = CGSize(width: size.height, height: size.width)
        }
        pageSize = size
        columns = max(1, min(20, options.columns))
        rows = max(1, min(30, options.rows))
        self.itemCount = max(0, itemCount)

        let margin = max(0, options.marginMM) * ContactSheetOptions.pointsPerMM
        let content = CGRect(x: margin, y: margin, width: max(1, size.width - 2 * margin), height: max(1, size.height - 2 * margin))
        contentRect = content

        var top = content.minY
        var bottom = content.maxY
        if options.showHeader {
            headerRect = CGRect(x: content.minX, y: top, width: content.width, height: Self.headerHeight)
            top += Self.headerHeight + 8
        } else {
            headerRect = nil
        }
        if options.showPageNumbers {
            footerRect = CGRect(x: content.minX, y: bottom - Self.footerHeight, width: content.width, height: Self.footerHeight)
            bottom -= Self.footerHeight + 4
        } else {
            footerRect = nil
        }
        gridRect = CGRect(x: content.minX, y: top, width: content.width, height: max(1, bottom - top))

        spacing = max(0, options.spacingMM) * ContactSheetOptions.pointsPerMM
        let cellWidth = max(1, (gridRect.width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        let cellHeight = max(1, (gridRect.height - spacing * CGFloat(rows - 1)) / CGFloat(rows))
        cellSize = CGSize(width: cellWidth, height: cellHeight)

        var lines = 0
        if options.captionFilename { lines += 1 }
        if options.captionRatingFlag { lines += 1 }
        if options.captionPrompt { lines += max(1, min(6, options.promptLines)) }
        // Captions never take more than half the cell.
        captionHeight = lines == 0 ? 0 : min(cellHeight * 0.5, CGFloat(lines) * Self.captionLineHeight + 3)
    }

    /// Page (0-based) and slot on that page for item `index`.
    func position(of index: Int) -> (page: Int, slot: Int) {
        (index / cellsPerPage, index % cellsPerPage)
    }

    /// Items on `page`.
    func itemRange(onPage page: Int) -> Range<Int> {
        let start = page * cellsPerPage
        return start..<min(itemCount, start + cellsPerPage)
    }

    func cellRect(slot: Int) -> CGRect {
        let column = slot % columns
        let row = slot / columns
        return CGRect(
            x: gridRect.minX + CGFloat(column) * (cellSize.width + spacing),
            y: gridRect.minY + CGFloat(row) * (cellSize.height + spacing),
            width: cellSize.width,
            height: cellSize.height
        )
    }

    /// Area for the picture in a cell (above the caption).
    func imageArea(inCell cell: CGRect) -> CGRect {
        CGRect(x: cell.minX, y: cell.minY, width: cell.width, height: max(1, cell.height - captionHeight))
    }

    func captionRect(inCell cell: CGRect) -> CGRect {
        CGRect(x: cell.minX, y: cell.maxY - captionHeight, width: cell.width, height: captionHeight)
    }

    /// Aspect-fit rect for an image of `size` inside `area`.
    static func fit(_ size: CGSize, in area: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return area }
        let scale = min(area.width / size.width, area.height / size.height)
        let w = size.width * scale
        let h = size.height * scale
        return CGRect(x: area.midX - w / 2, y: area.minY + (area.height - h) / 2, width: w, height: h)
    }

    /// Pixel size to decode images at: 300 dpi for the cell, capped.
    var thumbnailPixelSize: Int {
        let points = max(cellSize.width, cellSize.height - captionHeight)
        return max(64, min(2000, Int((points * 300 / 72).rounded())))
    }
}

// MARK: - Renderer

enum ContactSheetRenderer {
    enum Failure: LocalizedError {
        case noItems
        case cannotCreatePDF

        var errorDescription: String? {
            switch self {
            case .noItems: return "There's nothing to put on the contact sheet."
            case .cannotCreatePDF: return "The PDF couldn't be created."
            }
        }
    }

    /// Renders a multi-page PDF with a Core Graphics PDF context. Images are decoded
    /// downsampled to the cell size. Cancellable between images.
    static func renderPDF(
        items: [ContactSheetItem],
        options: ContactSheetOptions,
        date: Date = Date(),
        to url: URL,
        progress: @Sendable (Int, Int) -> Void = { _, _ in },
        image: (URL, Int) async -> CGImage? = { url, size in await ExportSourceImages.previewImage(for: url, maxPixelSize: size) }
    ) async throws {
        guard !items.isEmpty else { throw Failure.noItems }
        let layout = ContactSheetLayout(options: options, itemCount: items.count)
        var mediaBox = CGRect(origin: .zero, size: layout.pageSize)
        let title = options.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let info: [CFString: Any] = [
            kCGPDFContextTitle: title.isEmpty ? "Contact Sheet" : title,
            kCGPDFContextCreator: "PromptLibrary Explorer",
        ]
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, info as CFDictionary) else {
            throw Failure.cannotCreatePDF
        }
        let pageHeight = layout.pageSize.height
        func flip(_ rect: CGRect) -> CGRect { ExportImageRenderer.flipped(rect, canvasHeight: pageHeight) }

        let dateText = DateFormatter.localizedString(from: date, dateStyle: .long, timeStyle: .none)
        var done = 0
        do {
            for page in 0..<layout.pageCount {
                context.beginPDFPage(nil)
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fill(mediaBox)

                if let header = layout.headerRect {
                    let headerTitle = title.isEmpty ? "Contact Sheet" : title
                    drawText(headerTitle, in: flip(header), size: 15, bold: true, gray: 0.08, context: context)
                    let subtitle = [options.showDate ? dateText : nil, "\(items.count) item\(items.count == 1 ? "" : "s")"]
                        .compactMap { $0 }.joined(separator: " · ")
                    drawText(subtitle, in: flip(header), size: 9, bold: false, gray: 0.4, context: context, alignRight: true, baselineFromTop: 12)
                    context.setStrokeColor(CGColor(gray: 0.8, alpha: 1))
                    context.setLineWidth(0.5)
                    let lineY = pageHeight - header.maxY
                    context.strokeLineSegments(between: [CGPoint(x: header.minX, y: lineY), CGPoint(x: header.maxX, y: lineY)])
                }

                for index in layout.itemRange(onPage: page) {
                    try Task.checkCancellation()
                    let item = items[index]
                    let cell = layout.cellRect(slot: index - page * layout.cellsPerPage)
                    let area = layout.imageArea(inCell: cell)
                    if let picture = await image(item.url, layout.thumbnailPixelSize) {
                        let rect = ContactSheetLayout.fit(CGSize(width: picture.width, height: picture.height), in: area)
                        context.interpolationQuality = .high
                        context.draw(picture, in: flip(rect))
                        context.setStrokeColor(CGColor(gray: 0.85, alpha: 1))
                        context.setLineWidth(0.4)
                        context.stroke(flip(rect))
                    } else {
                        context.setFillColor(CGColor(gray: 0.93, alpha: 1))
                        context.fill(flip(area.insetBy(dx: 2, dy: 2)))
                        drawText(item.url.pathExtension.uppercased(), in: flip(area), size: 10, bold: true, gray: 0.5, context: context, centered: true)
                    }
                    drawCaption(for: item, in: layout.captionRect(inCell: cell), options: options, pageHeight: pageHeight, context: context)
                    done += 1
                    progress(done, items.count)
                }

                if let footer = layout.footerRect {
                    drawText("Page \(page + 1) of \(layout.pageCount)", in: flip(footer), size: 8, bold: false, gray: 0.45, context: context, centered: true)
                }
                context.endPDFPage()
            }
        } catch {
            context.endPDFPage()
            context.closePDF()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        context.closePDF()
    }

    private static func drawCaption(for item: ContactSheetItem, in rect: CGRect, options: ContactSheetOptions, pageHeight: CGFloat, context: CGContext) {
        guard rect.height > 1 else { return }
        var lines: [(String, Bool, Int)] = [] // text, bold, max lines
        if options.captionFilename { lines.append((item.name, true, 1)) }
        if options.captionRatingFlag {
            var parts: [String] = []
            if item.rating > 0 { parts.append(String(repeating: "★", count: item.rating) + String(repeating: "☆", count: 5 - item.rating)) }
            if item.flag != .unflagged { parts.append(item.flag.title) }
            lines.append((parts.isEmpty ? "–" : parts.joined(separator: "  "), false, 1))
        }
        if options.captionPrompt {
            let prompt = (item.prompt ?? "").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            lines.append((prompt.isEmpty ? "No prompt" : prompt, false, max(1, min(6, options.promptLines))))
        }
        var y = rect.minY + 3
        for (text, bold, maxLines) in lines {
            let height = CGFloat(maxLines) * ContactSheetLayout.captionLineHeight
            guard y + ContactSheetLayout.captionLineHeight <= rect.maxY + 0.5 else { break }
            let lineRect = CGRect(x: rect.minX, y: y, width: rect.width, height: min(height, rect.maxY - y))
            drawWrapped(text, in: ExportImageRenderer.flipped(lineRect, canvasHeight: pageHeight), size: 7.5, bold: bold, maxLines: maxLines, context: context)
            y += height
        }
    }

    // MARK: Text

    private static func attributed(_ text: String, size: CGFloat, bold: Bool, gray: CGFloat, alignment: CTTextAlignment = .left) -> CFAttributedString {
        let font = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        var align = alignment
        var lineBreak = CTLineBreakMode.byWordWrapping
        let style: CTParagraphStyle = withUnsafePointer(to: &align) { alignPointer in
            withUnsafePointer(to: &lineBreak) { breakPointer in
                let settings = [
                    CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: alignPointer),
                    CTParagraphStyleSetting(spec: .lineBreakMode, valueSize: MemoryLayout<CTLineBreakMode>.size, value: breakPointer),
                ]
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(gray: gray, alpha: 1),
            kCTParagraphStyleAttributeName: style,
        ]
        return CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)!
    }

    /// One line of text in `rect` (Core Graphics coordinates), truncated to fit.
    private static func drawText(
        _ text: String, in rect: CGRect, size: CGFloat, bold: Bool, gray: CGFloat, context: CGContext,
        alignRight: Bool = false, centered: Bool = false, baselineFromTop: CGFloat? = nil
    ) {
        let string = attributed(text, size: size, bold: bold, gray: gray)
        let line = CTLineCreateWithAttributedString(string)
        let token = CTLineCreateWithAttributedString(attributed("…", size: size, bold: bold, gray: gray))
        let fitted = CTLineCreateTruncatedLine(line, Double(rect.width), .end, token) ?? line
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(fitted, &ascent, &descent, nil))
        var x = rect.minX
        if alignRight { x = rect.maxX - width }
        if centered { x = rect.midX - width / 2 }
        let y: CGFloat
        if let baselineFromTop {
            y = rect.maxY - baselineFromTop
        } else if centered {
            y = rect.midY - (ascent - descent) / 2
        } else {
            y = rect.maxY - ascent - 2
        }
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(fitted, context)
    }

    /// Wrapped text limited to `maxLines`, last line truncated.
    private static func drawWrapped(_ text: String, in rect: CGRect, size: CGFloat, bold: Bool, maxLines: Int, context: CGContext) {
        let string = attributed(text, size: size, bold: bold, gray: bold ? 0.1 : 0.35)
        let setter = CTFramesetterCreateWithAttributedString(string)
        let path = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
        guard let lines = CTFrameGetLines(frame) as? [CTLine], !lines.isEmpty else { return }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        let count = min(maxLines, lines.count)
        for i in 0..<count {
            var line = lines[i]
            if i == count - 1, lines.count > count || CTLineGetStringRange(line).location + CTLineGetStringRange(line).length < CFAttributedStringGetLength(string) {
                let range = CTLineGetStringRange(line)
                let rest = CFAttributedStringCreateWithSubstring(nil, string, CFRange(location: range.location, length: CFAttributedStringGetLength(string) - range.location))!
                let token = CTLineCreateWithAttributedString(attributed("…", size: size, bold: bold, gray: 0.35))
                line = CTLineCreateTruncatedLine(CTLineCreateWithAttributedString(rest), Double(rect.width), .end, token) ?? line
            }
            context.textPosition = CGPoint(x: rect.minX + origins[i].x, y: rect.minY + origins[i].y)
            CTLineDraw(line, context)
        }
    }
}
