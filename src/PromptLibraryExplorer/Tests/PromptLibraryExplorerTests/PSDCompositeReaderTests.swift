import XCTest
@testable import PromptLibraryExplorer

// PSD composites whose extra channel is a saved selection, not transparency:
// read directly (raw and RLE, 8 and 16 bit); real merged transparency is left
// to ImageIO. Files are built in memory.

final class PSDCompositeReaderTests: XCTestCase {
    /// A flat PSD: `planes` are the composite's channels, row-major, one byte
    /// (8-bit) or two (16-bit, big-endian) per sample.
    private func makePSD(
        width: Int, height: Int, depth: Int = 8, mode: Int = 3,
        planes: [[UInt16]], layerCount: Int16? = nil, rle: Bool = false
    ) -> Data {
        var d = Data()
        func u16(_ v: Int) { d.append(contentsOf: [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]) }
        func u32(_ v: Int) { d.append(contentsOf: [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]) }
        d.append(contentsOf: Array("8BPS".utf8)); u16(1); d.append(contentsOf: [0, 0, 0, 0, 0, 0])
        u16(planes.count); u32(height); u32(width); u16(depth); u16(mode)
        u32(0)   // colour mode data
        u32(0)   // image resources
        if let layerCount {
            // Layer info holding just the count (the reader stops there).
            u32(8); u32(2); u16(Int(UInt16(bitPattern: layerCount))); u16(0)
        } else {
            u32(0)
        }
        let rows: [[UInt8]] = planes.flatMap { plane in
            (0..<height).map { y in
                plane[(y * width)..<((y + 1) * width)].flatMap { v -> [UInt8] in
                    depth == 16 ? [UInt8(v >> 8), UInt8(v & 0xFF)] : [UInt8(v)]
                }
            }
        }
        if rle {
            // One literal run per row.
            let packed = rows.map { [UInt8($0.count - 1)] + $0 }
            u16(1)
            for row in packed { u16(row.count) }
            for row in packed { d.append(contentsOf: row) }
        } else {
            u16(0)
            for row in rows { d.append(contentsOf: row) }
        }
        return d
    }

    private func histogram(_ data: Data) throws -> HistogramData {
        let header = try XCTUnwrap(PSDCompositeReader.header(of: data))
        let sample = try XCTUnwrap(PSDCompositeReader.sampledRGBA(of: data, header: header, maxDimension: 512))
        return sample.pixels.withUnsafeBufferPointer {
            HistogramComputer.compute(rgba: $0, width: sample.width, height: sample.height, bytesPerRow: sample.width * 4)
        }
    }

    func testSavedSelectionChannelIsNotTreatedAsTransparency() throws {
        // 2×2 red, green, blue; a fourth channel that is an empty saved selection.
        let data = makePSD(width: 2, height: 2, planes: [[200, 200, 200, 200], [100, 100, 100, 100], [50, 50, 50, 50], [0, 0, 0, 0]])
        let header = try XCTUnwrap(PSDCompositeReader.header(of: data))
        XCTAssertTrue(header.imageIOMisreadsExtraChannel)
        let result = try histogram(data)
        XCTAssertEqual(result.pixelCount, 4, "every pixel counts, whatever the selection")
        XCTAssertEqual(result.red[200], 4)
        XCTAssertEqual(result.green[100], 4)
        XCTAssertEqual(result.blue[50], 4)
    }

    func testRLEAnd16BitCompositesDecode() throws {
        let rle = makePSD(width: 3, height: 2, planes: [[10, 20, 30, 40, 50, 60], [1, 1, 1, 1, 1, 1], [2, 2, 2, 2, 2, 2], [255, 0, 255, 0, 255, 0]], rle: true)
        let rleResult = try histogram(rle)
        XCTAssertEqual(rleResult.pixelCount, 6)
        XCTAssertEqual([10, 20, 30, 40, 50, 60].map { rleResult.red[$0] }, [1, 1, 1, 1, 1, 1])

        let sixteen = makePSD(width: 1, height: 1, depth: 16, planes: [[0xFF00], [0x8000], [0x0100], [0]])
        let sixteenResult = try histogram(sixteen)
        XCTAssertEqual(sixteenResult.red[255], 1)
        XCTAssertEqual(sixteenResult.green[128], 1)
        XCTAssertEqual(sixteenResult.blue[1], 1)
    }

    func testGrayscaleWithExtraChannelReadsGrey() throws {
        let data = makePSD(width: 2, height: 1, mode: 1, planes: [[90, 90], [0, 0]])
        let result = try histogram(data)
        XCTAssertEqual(result.pixelCount, 2)
        XCTAssertEqual(result.luminance[90], 2)
    }

    func testMergedTransparencyAndPlainFilesStayWithImageIO() throws {
        let transparent = makePSD(width: 1, height: 1, planes: [[1], [2], [3], [0]], layerCount: -2)
        XCTAssertEqual(PSDCompositeReader.header(of: transparent)?.hasMergedTransparency, true)
        XCTAssertEqual(PSDCompositeReader.header(of: transparent)?.imageIOMisreadsExtraChannel, false)

        let plain = makePSD(width: 1, height: 1, planes: [[1], [2], [3]], layerCount: 2)
        XCTAssertEqual(PSDCompositeReader.header(of: plain)?.imageIOMisreadsExtraChannel, false)

        let cmyk = makePSD(width: 1, height: 1, mode: 4, planes: [[1], [2], [3], [4], [5]])
        XCTAssertEqual(PSDCompositeReader.header(of: cmyk)?.imageIOMisreadsExtraChannel, false)
        XCTAssertNil(PSDCompositeReader.header(of: Data("not a psd".utf8)))
    }

    func testLargeCompositeIsSampledNotFullyDecoded() throws {
        let size = 64
        let plane = [UInt16](repeating: 7, count: size * size)
        let data = makePSD(width: size, height: size, planes: [plane, plane, plane, plane], rle: true)
        let header = try XCTUnwrap(PSDCompositeReader.header(of: data))
        let sample = try XCTUnwrap(PSDCompositeReader.sampledRGBA(of: data, header: header, maxDimension: 16))
        XCTAssertEqual(sample.width, 16)
        XCTAssertEqual(sample.height, 16)
    }

    func testTruncatedFileFailsCleanly() throws {
        let data = makePSD(width: 4, height: 4, planes: Array(repeating: [UInt16](repeating: 1, count: 16), count: 4), rle: true)
        let header = try XCTUnwrap(PSDCompositeReader.header(of: data))
        XCTAssertNil(PSDCompositeReader.sampledRGBA(of: data.prefix(data.count - 10), header: header, maxDimension: 512))
    }
}
