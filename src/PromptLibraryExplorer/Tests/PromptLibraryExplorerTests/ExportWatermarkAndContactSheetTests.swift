import CoreGraphics
import ImageIO
import PDFKit
import XCTest
@testable import PromptLibraryExplorer

final class ExportWatermarkTests: XCTestCase {
    private func solidImage(width: Int, height: Int, red: CGFloat, alpha: CGFloat) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        if alpha > 0 {
            context.setFillColor(CGColor(srgbRed: red, green: 0, blue: 0, alpha: alpha))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return context.makeImage()!
    }

    /// RGBA at (x, y), top-left origin.
    private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(
            data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let i = (y * image.width + x) * 4
        return (bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3])
    }

    private var watermark: ExportWatermark {
        var wm = ExportWatermark()
        wm.isEnabled = true
        wm.kind = .image
        wm.imagePath = "/unused"
        wm.position = .bottomRight
        wm.margin = 0.03
        wm.scale = 0.2
        wm.opacity = 0.5
        wm.shadow = false
        return wm
    }

    func testRectFollowsTheNineGrid() {
        let canvas = CGSize(width: 100, height: 100)
        var wm = watermark
        XCTAssertEqual(ExportImageRenderer.watermarkRect(natural: CGSize(width: 10, height: 10), canvas: canvas, watermark: wm),
                       CGRect(x: 77, y: 77, width: 20, height: 20))
        wm.position = .topLeft
        XCTAssertEqual(ExportImageRenderer.watermarkRect(natural: CGSize(width: 10, height: 5), canvas: canvas, watermark: wm),
                       CGRect(x: 3, y: 3, width: 20, height: 10))
        wm.position = .center
        XCTAssertEqual(ExportImageRenderer.watermarkRect(natural: CGSize(width: 10, height: 10), canvas: canvas, watermark: wm),
                       CGRect(x: 40, y: 40, width: 20, height: 20))
    }

    func testImageWatermarkCompositesAtItsOpacity() throws {
        let base = solidImage(width: 100, height: 100, red: 0, alpha: 0) // fully transparent
        let mark = solidImage(width: 10, height: 10, red: 1, alpha: 1)   // opaque red
        let plan = ExportGeometry.plan(sourceWidth: 100, sourceHeight: 100, sizing: .original)
        let output = try XCTUnwrap(ExportImageRenderer.render(
            base, orientedSourceWidth: 100, plan: plan,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, opaque: false,
            watermark: watermark, watermarkImage: mark
        ))

        let inside = pixel(output, x: 87, y: 87)
        XCTAssertEqual(Int(inside.a), 128, accuracy: 2, "50% opacity over transparency")
        XCTAssertEqual(Int(inside.r), 128, accuracy: 2, "premultiplied red")
        XCTAssertEqual(pixel(output, x: 10, y: 10).a, 0, "outside the watermark stays transparent")
        XCTAssertEqual(pixel(output, x: 75, y: 87).a, 0, "left of the watermark rect")
    }

    func testTextWatermarkDrawsSomethingInItsCorner() throws {
        let base = solidImage(width: 200, height: 100, red: 0, alpha: 0)
        var wm = ExportWatermark()
        wm.isEnabled = true
        wm.text = "WWWW"
        wm.textColorHex = "#FFFFFF"
        wm.position = .topLeft
        wm.scale = 0.5
        wm.opacity = 1
        wm.shadow = false
        let plan = ExportGeometry.plan(sourceWidth: 200, sourceHeight: 100, sizing: .original)
        let output = try XCTUnwrap(ExportImageRenderer.render(
            base, orientedSourceWidth: 200, plan: plan, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            opaque: false, watermark: wm, watermarkImage: nil
        ))
        var bytes = [UInt8](repeating: 0, count: 200 * 100 * 4)
        let context = CGContext(
            data: &bytes, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 800,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(output, in: CGRect(x: 0, y: 0, width: 200, height: 100))
        var topLeftInk = 0
        var bottomRightInk = 0
        for y in 0..<100 {
            for x in 0..<200 where bytes[(y * 200 + x) * 4 + 3] > 0 {
                if x < 110, y < 50 { topLeftInk += 1 } else if x > 120, y > 60 { bottomRightInk += 1 }
            }
        }
        XCTAssertGreaterThan(topLeftInk, 50)
        XCTAssertEqual(bottomRightInk, 0)
    }

    func testSmallTextWatermarkStaysInsideItsMargin() throws {
        let base = solidImage(width: 300, height: 300, red: 0, alpha: 0)
        var wm = ExportWatermark()
        wm.isEnabled = true
        wm.text = "© Art Official"
        wm.position = .bottomRight
        wm.scale = 0.2
        wm.margin = 0.03
        wm.opacity = 1
        wm.shadow = false
        let plan = ExportGeometry.plan(sourceWidth: 300, sourceHeight: 300, sizing: .original)
        let output = try XCTUnwrap(ExportImageRenderer.render(
            base, orientedSourceWidth: 300, plan: plan, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            opaque: false, watermark: wm, watermarkImage: nil
        ))
        var bytes = [UInt8](repeating: 0, count: 300 * 300 * 4)
        let context = CGContext(
            data: &bytes, width: 300, height: 300, bitsPerComponent: 8, bytesPerRow: 1200,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(output, in: CGRect(x: 0, y: 0, width: 300, height: 300))
        var maxInkX = 0
        var minInkX = 300
        for y in 0..<300 {
            for x in 0..<300 where bytes[(y * 300 + x) * 4 + 3] > 40 {
                maxInkX = max(maxInkX, x)
                minInkX = min(minInkX, x)
            }
        }
        XCTAssertLessThanOrEqual(maxInkX, 298, "text overran the right margin")
        XCTAssertGreaterThanOrEqual(minInkX, 230, "text is about 20% of the width")
    }

    func testHexColours() {
        let red = ExportImageRenderer.cgColor(hex: "#FF0000").components ?? []
        XCTAssertEqual(red.first ?? 0, 1, accuracy: 0.001)
        let fallback = ExportImageRenderer.cgColor(hex: "nope").components ?? []
        XCTAssertEqual(fallback.first ?? 0, 1, accuracy: 0.001)
    }
}

final class ContactSheetTests: TempDirectoryTestCase {
    func testPageCountAndGridMath() {
        var options = ContactSheetOptions()
        options.columns = 4
        options.rows = 5
        let layout = ContactSheetLayout(options: options, itemCount: 41)
        XCTAssertEqual(layout.cellsPerPage, 20)
        XCTAssertEqual(layout.pageCount, 3)
        XCTAssertEqual(layout.itemRange(onPage: 2), 40..<41)
        XCTAssertEqual(layout.position(of: 21).page, 1)
        XCTAssertEqual(layout.position(of: 21).slot, 1)
        XCTAssertEqual(ContactSheetLayout(options: options, itemCount: 0).pageCount, 0)
        XCTAssertEqual(ContactSheetLayout(options: options, itemCount: 20).pageCount, 1)

        // A4 portrait, cells tile the grid exactly.
        XCTAssertEqual(layout.pageSize.width, 595.28, accuracy: 0.01)
        let first = layout.cellRect(slot: 0)
        let last = layout.cellRect(slot: 19)
        XCTAssertEqual(first.minX, layout.gridRect.minX, accuracy: 0.001)
        XCTAssertEqual(first.minY, layout.gridRect.minY, accuracy: 0.001)
        XCTAssertEqual(last.maxX, layout.gridRect.maxX, accuracy: 0.001)
        XCTAssertEqual(last.maxY, layout.gridRect.maxY, accuracy: 0.001)
        XCTAssertLessThan(layout.headerRect?.maxY ?? 0, layout.gridRect.minY)
        XCTAssertGreaterThan(layout.footerRect?.minY ?? 0, layout.gridRect.maxY)
    }

    func testOrientationAndCustomSize() {
        var options = ContactSheetOptions()
        options.pageSize = .letter
        options.orientation = .landscape
        let letter = ContactSheetLayout(options: options, itemCount: 1)
        XCTAssertEqual(letter.pageSize, CGSize(width: 792, height: 612))

        options.pageSize = .custom
        options.customWidthMM = 100
        options.customHeightMM = 150
        options.orientation = .portrait
        let custom = ContactSheetLayout(options: options, itemCount: 1)
        XCTAssertEqual(custom.pageSize.width, 100 * 72 / 25.4, accuracy: 0.01)
        XCTAssertEqual(custom.pageSize.height, 150 * 72 / 25.4, accuracy: 0.01)
    }

    func testCaptionsReserveSpaceAndFitKeepsAspect() {
        var options = ContactSheetOptions()
        options.captionFilename = true
        options.captionPrompt = true
        options.promptLines = 2
        options.captionRatingFlag = true
        let layout = ContactSheetLayout(options: options, itemCount: 1)
        XCTAssertEqual(layout.captionHeight, 4 * ContactSheetLayout.captionLineHeight + 3, accuracy: 0.001)
        let cell = layout.cellRect(slot: 0)
        XCTAssertEqual(layout.imageArea(inCell: cell).height + layout.captionHeight, cell.height, accuracy: 0.001)

        let fit = ContactSheetLayout.fit(CGSize(width: 200, height: 100), in: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(fit, CGRect(x: 0, y: 25, width: 100, height: 50))
    }

    func testRendersAMultiPagePDF() async throws {
        var items: [ContactSheetItem] = []
        for i in 0..<7 {
            let url = try writeFile("img\(i).png", PNGFixture.basePNG(width: 40, height: 30))
            items.append(ContactSheetItem(url: url, name: url.lastPathComponent, prompt: "prompt \(i)", rating: i % 6, flag: i == 0 ? .pick : .unflagged))
        }
        items.append(ContactSheetItem(url: tempDir.appendingPathComponent("missing.wav"), name: "missing.wav"))
        var options = ContactSheetOptions()
        options.columns = 2
        options.rows = 2
        options.captionPrompt = true
        options.captionRatingFlag = true
        options.title = "Test Sheet"
        let output = tempDir.appendingPathComponent("sheet.pdf")
        try await ContactSheetRenderer.renderPDF(items: items, options: options, to: output)

        let data = try Data(contentsOf: output)
        XCTAssertGreaterThan(data.count, 1_000)
        let document = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(document.pageCount, 2)
        let text = document.page(at: 0)?.string ?? ""
        XCTAssertTrue(text.contains("Test Sheet"), text)
        XCTAssertTrue(text.contains("img0.png"), text)
        XCTAssertTrue(document.page(at: 1)?.string?.contains("Page 2 of 2") ?? false)
    }

    func testEmptySelectionThrows() async {
        do {
            try await ContactSheetRenderer.renderPDF(items: [], options: ContactSheetOptions(), to: tempDir.appendingPathComponent("x.pdf"))
            XCTFail("expected an error")
        } catch {}
    }
}
