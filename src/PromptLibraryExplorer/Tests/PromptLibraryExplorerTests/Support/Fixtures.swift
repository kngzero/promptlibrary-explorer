import Compression
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

// MARK: - Temporary directories

/// Base class giving every test its own temporary directory, removed in tearDown.
class TempDirectoryTestCase: XCTestCase {
    private(set) var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PLETests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        try super.tearDownWithError()
    }

    /// Writes `data` to `name` (relative, may contain subfolders) inside the temp dir.
    @discardableResult
    func writeFile(_ name: String, _ data: Data) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }
}

// MARK: - Checksums / zlib

enum Checksum {
    private static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var crc = UInt32(index)
        for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        return crc
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }

    static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return (b << 16) | a
    }
}

enum Zlib {
    /// Raw DEFLATE via Apple's Compression framework.
    static func rawDeflate(_ data: Data) -> Data {
        let capacity = max(64, data.count + data.count / 10 + 1024)
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                compression_encode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        precondition(written > 0, "compression failed")
        return output.prefix(written)
    }

    /// Full RFC 1950 stream: 2-byte header + raw DEFLATE + big-endian Adler-32.
    static func compress(_ data: Data) -> Data {
        var out = Data([0x78, 0x9C])
        out.append(rawDeflate(data))
        out.append(bigEndian(Checksum.adler32(data)))
        return out
    }
}

func bigEndian(_ value: UInt32) -> Data {
    Data([UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
}

func littleEndian(_ value: UInt32) -> Data {
    Data([UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24 & 0xFF)])
}

// MARK: - PNG

enum PNGFixture {
    static let signature = Data([137, 80, 78, 71, 13, 10, 26, 10])

    struct Chunk {
        let type: String
        /// Entire chunk: length + type + data + CRC.
        let raw: Data
        let payload: Data
    }

    /// A small real PNG produced by ImageIO.
    static func basePNG(width: Int = 8, height: Int = 6) -> Data {
        let image = makeCGImage(width: width, height: height)
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        precondition(CGImageDestinationFinalize(dest))
        return data as Data
    }

    static func chunk(type: String, payload: Data) -> Data {
        var out = bigEndian(UInt32(payload.count))
        var crcInput = Data(type.utf8)
        crcInput.append(payload)
        out.append(crcInput)
        out.append(bigEndian(Checksum.crc32(crcInput)))
        return out
    }

    static func tEXt(_ keyword: String, _ text: String) -> Data {
        var payload = Data(keyword.utf8)
        payload.append(0)
        payload.append(text.data(using: .isoLatin1) ?? Data(text.utf8))
        return chunk(type: "tEXt", payload: payload)
    }

    static func zTXt(_ keyword: String, _ text: String) -> Data {
        var payload = Data(keyword.utf8)
        payload.append(contentsOf: [0, 0]) // separator + compression method
        payload.append(Zlib.compress(Data(text.utf8)))
        return chunk(type: "zTXt", payload: payload)
    }

    static func iTXt(_ keyword: String, _ text: String, compressed: Bool) -> Data {
        var payload = Data(keyword.utf8)
        payload.append(0)
        payload.append(contentsOf: [compressed ? 1 : 0, 0])
        payload.append(0) // language
        payload.append(0) // translated keyword
        payload.append(compressed ? Zlib.compress(Data(text.utf8)) : Data(text.utf8))
        return chunk(type: "iTXt", payload: payload)
    }

    /// Inserts extra chunks right after IHDR.
    static func png(with extraChunks: [Data], base: Data = basePNG()) -> Data {
        let ihdrEnd = signature.count + 8 + 13 + 4
        var out = base.prefix(ihdrEnd)
        for chunk in extraChunks { out.append(chunk) }
        out.append(base.suffix(from: ihdrEnd))
        return Data(out)
    }

    static func chunks(_ data: Data) -> [Chunk] {
        let data = Data(data)
        var result: [Chunk] = []
        var offset = signature.count
        while offset + 12 <= data.count {
            let length = Int(data[offset]) << 24 | Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
            let type = String(data: data[(offset + 4)..<(offset + 8)], encoding: .ascii) ?? "????"
            let end = offset + 12 + length
            guard end <= data.count else { break }
            result.append(Chunk(type: type, raw: data[offset..<end], payload: data[(offset + 8)..<(offset + 8 + length)]))
            offset = end
            if type == "IEND" { break }
        }
        return result
    }

    /// Keyword of a tEXt/zTXt/iTXt chunk.
    static func keyword(of chunk: Chunk) -> String? {
        guard ["tEXt", "zTXt", "iTXt"].contains(chunk.type), let nul = chunk.payload.firstIndex(of: 0) else { return nil }
        return String(data: chunk.payload[chunk.payload.startIndex..<nul], encoding: .isoLatin1)
    }

    /// Text of an uncompressed tEXt or iTXt chunk.
    static func text(of chunk: Chunk) -> String? {
        guard let nul = chunk.payload.firstIndex(of: 0) else { return nil }
        switch chunk.type {
        case "tEXt":
            return String(data: chunk.payload[(nul + 1)...], encoding: .isoLatin1)
        case "iTXt":
            var cursor = nul + 3
            guard let lang = chunk.payload[cursor...].firstIndex(of: 0) else { return nil }
            cursor = lang + 1
            guard let translated = chunk.payload[cursor...].firstIndex(of: 0) else { return nil }
            return String(data: chunk.payload[(translated + 1)...], encoding: .utf8)
        default:
            return nil
        }
    }

    static func textChunks(_ data: Data, keyword: String) -> [Chunk] {
        chunks(data).filter { self.keyword(of: $0) == keyword }
    }
}

func makeCGImage(width: Int, height: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    for y in 0..<height {
        for x in 0..<width {
            context.setFillColor(red: CGFloat(x) / CGFloat(width), green: CGFloat(y) / CGFloat(height), blue: 0.5, alpha: 1)
            context.fill(CGRect(x: x, y: y, width: 1, height: 1))
        }
    }
    return context.makeImage()!
}

// MARK: - JPEG

enum JPEGFixture {
    static func baseJPEG(width: Int = 16, height: Int = 12) -> Data {
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, makeCGImage(width: width, height: height), [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        precondition(CGImageDestinationFinalize(dest))
        return data as Data
    }

    /// Bytes from the first SOS marker through the following EOI (the compressed scan data).
    static func scanData(_ data: Data) -> Data? {
        let data = Data(data)
        var offset = 2
        while offset + 4 <= data.count {
            guard data[offset] == 0xFF else { return nil }
            let marker = data[offset + 1]
            if marker == 0xDA {
                var end = offset + 2
                while end + 1 < data.count {
                    if data[end] == 0xFF, data[end + 1] == 0xD9 { return data[offset..<(end + 2)] }
                    end += 1
                }
                return nil
            }
            let length = Int(data[offset + 2]) << 8 | Int(data[offset + 3])
            offset += 2 + length
        }
        return nil
    }
}

// MARK: - WAV

enum WAVFixture {
    static func chunk(_ id: String, _ payload: Data, declaredSize: UInt32? = nil) -> Data {
        var out = Data(id.utf8)
        out.append(littleEndian(declaredSize ?? UInt32(payload.count)))
        out.append(payload)
        if payload.count % 2 == 1, declaredSize == nil { out.append(0) }
        return out
    }

    static var fmt: Data {
        var p = Data()
        p.append(contentsOf: [1, 0]) // PCM
        p.append(contentsOf: [1, 0]) // mono
        p.append(littleEndian(8000))
        p.append(littleEndian(8000))
        p.append(contentsOf: [1, 0]) // block align
        p.append(contentsOf: [8, 0]) // bits per sample
        return chunk("fmt ", p)
    }

    static func info(_ items: [(String, String)]) -> Data {
        var payload = Data("INFO".utf8)
        for (id, value) in items {
            var v = Data(value.utf8)
            v.append(0)
            payload.append(chunk(id, v))
        }
        return chunk("LIST", payload)
    }

    static func riff(_ chunks: [Data], declaredSize: UInt32? = nil) -> Data {
        let body = chunks.reduce(Data(), +)
        var out = Data("RIFF".utf8)
        out.append(littleEndian(declaredSize ?? UInt32(body.count + 4)))
        out.append(Data("WAVE".utf8))
        out.append(body)
        return out
    }

    static func audioBytes(_ count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) })
    }

    struct Chunk {
        let id: String
        let payload: Data
    }

    /// Lenient chunk walk (clamps an oversized final chunk).
    static func chunks(_ data: Data) -> [Chunk] {
        let data = Data(data)
        var result: [Chunk] = []
        var offset = 12
        while offset + 8 <= data.count {
            let id = String(data: data[offset..<(offset + 4)], encoding: .ascii) ?? "????"
            let size = Int(data[offset + 4]) | Int(data[offset + 5]) << 8 | Int(data[offset + 6]) << 16 | Int(data[offset + 7]) << 24
            let start = offset + 8
            let end = min(start + size, data.count)
            result.append(Chunk(id: id, payload: data[start..<end]))
            offset = end + (size % 2)
        }
        return result
    }

    static func infoItems(_ list: Chunk) -> [Chunk] {
        var fake = Data("RIFF\0\0\0\0WAVE".utf8)
        fake.append(list.payload.dropFirst(4))
        return chunks(fake)
    }
}

// MARK: - ID3

enum ID3Fixture {
    struct Frame: Equatable {
        let id: String
        let flags: Data
        let payload: Data
    }

    static func syncsafe(_ value: Int) -> Data {
        Data([UInt8(value >> 21 & 0x7F), UInt8(value >> 14 & 0x7F), UInt8(value >> 7 & 0x7F), UInt8(value & 0x7F)])
    }

    static func frameV23(_ id: String, _ payload: Data, flags: Data = Data([0, 0])) -> Data {
        var out = Data(id.utf8)
        out.append(bigEndian(UInt32(payload.count)))
        out.append(flags)
        out.append(payload)
        return out
    }

    static func frameV22(_ id: String, _ payload: Data) -> Data {
        var out = Data(id.utf8)
        let n = payload.count
        out.append(contentsOf: [UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)])
        out.append(payload)
        return out
    }

    static func latin1Text(_ text: String) -> Data {
        var p = Data([0])
        p.append(text.data(using: .isoLatin1)!)
        return p
    }

    static func tag(version: UInt8, flags: UInt8 = 0, body: Data) -> Data {
        var out = Data("ID3".utf8)
        out.append(contentsOf: [version, 0, flags])
        out.append(syncsafe(body.count))
        out.append(body)
        return out
    }

    /// Fake MPEG audio frames (sync word + arbitrary bytes).
    static func fakeAudio(_ count: Int) -> Data {
        var d = Data([0xFF, 0xFB, 0x90, 0x64])
        d.append(Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ 7) }))
        return d
    }

    /// Parses a v2.3/v2.4 tag without extended header. Returns frames and the tag end offset.
    static func parse(_ data: Data) -> (version: Int, frames: [Frame], tagEnd: Int)? {
        let data = Data(data)
        guard data.count >= 10, data.prefix(3) == Data("ID3".utf8) else { return nil }
        let version = Int(data[3])
        let size = (0..<4).reduce(0) { ($0 << 7) | Int(data[6 + $1] & 0x7F) }
        let end = 10 + size
        var offset = 10
        var frames: [Frame] = []
        while offset + 10 <= end, data[offset] != 0 {
            let id = String(data: data[offset..<(offset + 4)], encoding: .ascii)!
            let len: Int
            if version == 4 {
                len = (0..<4).reduce(0) { ($0 << 7) | Int(data[offset + 4 + $1] & 0x7F) }
            } else {
                len = (0..<4).reduce(0) { ($0 << 8) | Int(data[offset + 4 + $1]) }
            }
            frames.append(Frame(id: id, flags: data[(offset + 8)..<(offset + 10)], payload: data[(offset + 10)..<(offset + 10 + len)]))
            offset += 10 + len
        }
        return (version, frames, end)
    }
}

// MARK: - Misc

extension XCTestCase {
    func assertFileUnchanged(_ url: URL, _ original: Data, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(try? Data(contentsOf: url), original, "file was modified", file: file, line: line)
    }
}
