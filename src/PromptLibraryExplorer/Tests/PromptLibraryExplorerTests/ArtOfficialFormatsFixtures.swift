import Compression
import CoreGraphics
import Foundation
import ImageIO

/// In-code fixtures for ArtOfficialFormatsTests (images, ZIP archives, temp dirs).
enum AOFixtures {
    // MARK: Temp dirs

    static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aoformats-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Images

    /// Solid-colour image; if `split` is given, the right half uses that colour.
    static func image(width: Int, height: Int, rgb: (UInt8, UInt8, UInt8), split: (UInt8, UInt8, UInt8)? = nil) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        func color(_ c: (UInt8, UInt8, UInt8)) -> CGColor {
            CGColor(srgbRed: CGFloat(c.0) / 255, green: CGFloat(c.1) / 255, blue: CGFloat(c.2) / 255, alpha: 1)
        }
        ctx.setFillColor(color(rgb))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let split {
            ctx.setFillColor(color(split))
            ctx.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        }
        return ctx.makeImage()!
    }

    static func png(width: Int = 32, height: Int = 24, rgb: (UInt8, UInt8, UInt8) = (200, 40, 40)) -> Data {
        encode(image(width: width, height: height, rgb: rgb), type: "public.png")
    }

    static func encode(_ image: CGImage, type: String) -> Data {
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out as CFMutableData, type as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        precondition(CGImageDestinationFinalize(dest))
        return out as Data
    }

    static func dataURL(_ data: Data, mime: String = "image/png") -> String {
        "data:\(mime);base64,\(data.base64EncodedString())"
    }

    // MARK: ZIP writer (test-only)

    struct ZipEntrySpec {
        var name: String
        var data: Data
        var deflate: Bool = false
        /// Use a data descriptor (flag bit 3, zero sizes in the local header).
        var dataDescriptor: Bool = false
        /// Overrides the uncompressed size declared in the central directory.
        var declaredUncompressedSize: UInt32?
    }

    static func zip(_ specs: [ZipEntrySpec], declaredEntryCount: UInt16? = nil) -> Data {
        var out = Data()
        var central = Data()
        for spec in specs {
            let crc = crc32(spec.data)
            let payload = spec.deflate ? rawDeflate(spec.data) : spec.data
            let method: UInt16 = spec.deflate ? 8 : 0
            let flags: UInt16 = (spec.dataDescriptor ? 0x0008 : 0) | 0x0800
            let nameBytes = Data(spec.name.utf8)
            let offset = UInt32(out.count)
            let usize = spec.declaredUncompressedSize ?? UInt32(spec.data.count)

            out.le32(0x0403_4B50); out.le16(20); out.le16(flags); out.le16(method)
            out.le16(0); out.le16(0)
            if spec.dataDescriptor {
                out.le32(0); out.le32(0); out.le32(0)
            } else {
                out.le32(crc); out.le32(UInt32(payload.count)); out.le32(usize)
            }
            out.le16(UInt16(nameBytes.count)); out.le16(0)
            out.append(nameBytes)
            out.append(payload)
            if spec.dataDescriptor {
                out.le32(0x0807_4B50); out.le32(crc); out.le32(UInt32(payload.count)); out.le32(usize)
            }

            central.le32(0x0201_4B50); central.le16(20); central.le16(20); central.le16(flags); central.le16(method)
            central.le16(0); central.le16(0)
            central.le32(crc); central.le32(UInt32(payload.count)); central.le32(usize)
            central.le16(UInt16(nameBytes.count)); central.le16(0); central.le16(0)
            central.le16(0); central.le16(0); central.le32(0); central.le32(offset)
            central.append(nameBytes)
        }
        let cdOffset = UInt32(out.count)
        out.append(central)
        let count = declaredEntryCount ?? UInt16(specs.count)
        out.le32(0x0605_4B50); out.le16(0); out.le16(0); out.le16(count); out.le16(count)
        out.le32(UInt32(central.count)); out.le32(cdOffset); out.le16(0)
        return out
    }

    static func rawDeflate(_ data: Data) -> Data {
        let capacity = data.count + 1024
        var out = Data(count: capacity)
        let n = out.withUnsafeMutableBytes { o in
            data.withUnsafeBytes { i in
                compression_encode_buffer(o.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          i.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        precondition(n > 0)
        return out.prefix(n)
    }

    static func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
            table[i] = c
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for b in data { crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }

    static func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

private extension Data {
    mutating func le16(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func le32(_ v: UInt32) { le16(UInt16(v & 0xFFFF)); le16(UInt16(v >> 16)) }
}
