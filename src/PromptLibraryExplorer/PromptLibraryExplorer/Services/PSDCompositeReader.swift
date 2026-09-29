import Foundation

/// Reads a PSD's stored composite (the flattened image Photoshop saves with
/// Maximize Compatibility) when ImageIO would misread it.
///
/// ImageIO takes the fourth channel of any RGB (or second of any grayscale)
/// PSD as transparency. In Photoshop that channel is the composite's
/// transparency only when the file says so (a negative layer count); otherwise
/// it is a saved selection or a spot channel, and ImageIO hides or fades the
/// pixels it doesn't cover: a file with an empty selection saved reads as fully
/// transparent. This reader keeps the colour channels and drops the rest.
///
/// Values are the document's own (no colour-profile conversion), as in
/// Photoshop's Histogram panel. Only PSD version 1, RGB or grayscale, 8 or 16
/// bit, raw or RLE composites are read; `nil` otherwise.
enum PSDCompositeReader {
    struct Header: Equatable {
        var channels: Int
        var width: Int
        var height: Int
        var depth: Int
        var mode: Int
        /// The first extra channel is the composite's transparency.
        var hasMergedTransparency: Bool
        /// Offset of the image data section (compression word).
        var imageDataOffset: Int

        var colorChannels: Int? {
            switch mode {
            case 1: return 1   // grayscale
            case 3: return 3   // RGB
            default: return nil
            }
        }

        /// True when ImageIO would take a saved selection or spot channel for
        /// transparency.
        var imageIOMisreadsExtraChannel: Bool {
            guard let colorChannels else { return false }
            return channels > colorChannels && !hasMergedTransparency
        }
    }

    static func header(of data: Data) -> Header? {
        var reader = ByteReader(data: data)
        guard reader.bytes(4) == Array("8BPS".utf8), reader.uint16() == 1 else { return nil }
        reader.skip(6)
        guard let channels = reader.uint16(), let height = reader.uint32(), let width = reader.uint32(),
              let depth = reader.uint16(), let mode = reader.uint16(),
              let colorModeLength = reader.uint32() else { return nil }
        reader.skip(Int(colorModeLength))
        guard let resourcesLength = reader.uint32() else { return nil }
        reader.skip(Int(resourcesLength))
        guard let layerMaskLength = reader.uint32() else { return nil }
        let layerMaskStart = reader.offset
        var mergedTransparency = false
        if layerMaskLength >= 6, let layerInfoLength = reader.uint32(), layerInfoLength >= 2,
           let count = reader.uint16() {
            mergedTransparency = Int16(bitPattern: UInt16(count)) < 0
        }
        let imageDataOffset = layerMaskStart + Int(layerMaskLength)
        guard channels > 0, width > 0, height > 0, imageDataOffset + 2 <= data.count else { return nil }
        return Header(
            channels: channels, width: Int(width), height: Int(height), depth: depth, mode: mode,
            hasMergedTransparency: mergedTransparency, imageDataOffset: imageDataOffset
        )
    }

    /// The composite sampled to about `maxDimension` px on its long edge, as
    /// opaque 8-bit RGBA (nearest pixel; only the sampled rows are decoded).
    static func sampledRGBA(of data: Data, header: Header, maxDimension: Int) -> (pixels: [UInt8], width: Int, height: Int)? {
        guard let colorChannels = header.colorChannels, header.depth == 8 || header.depth == 16 else { return nil }
        let bytesPerSample = header.depth / 8
        let rowBytes = header.width * bytesPerSample
        let step = max(1, Int((Double(max(header.width, header.height)) / Double(max(maxDimension, 1))).rounded(.up)))
        let outWidth = (header.width + step - 1) / step
        let outHeight = (header.height + step - 1) / step

        var reader = ByteReader(data: data, offset: header.imageDataOffset)
        guard let compression = reader.uint16() else { return nil }
        let planeCount = header.channels * header.height

        // Where each (channel, row) starts, and how long it is.
        var rowStart = [Int](repeating: 0, count: planeCount)
        var rowLength = [Int](repeating: rowBytes, count: planeCount)
        switch compression {
        case 0:
            let base = reader.offset
            for index in 0..<planeCount { rowStart[index] = base + index * rowBytes }
            guard base + planeCount * rowBytes <= data.count else { return nil }
        case 1:
            var offset = reader.offset + planeCount * 2
            for index in 0..<planeCount {
                guard let count = reader.uint16() else { return nil }
                rowStart[index] = offset
                rowLength[index] = count
                offset += count
            }
            guard offset <= data.count else { return nil }
        default:
            return nil
        }

        var pixels = [UInt8](repeating: 255, count: outWidth * outHeight * 4)
        var scratch = [UInt8](repeating: 0, count: rowBytes)
        let ok: Bool = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            for outY in 0..<outHeight {
                let y = outY * step
                for channel in 0..<colorChannels {
                    let plane = channel * header.height + y
                    let start = rowStart[plane], length = rowLength[plane]
                    let row = UnsafeRawBufferPointer(rebasing: raw[start..<(start + length)])
                    if compression == 1 {
                        guard unpackBits(row, into: &scratch) else { return false }
                    } else {
                        scratch.withUnsafeMutableBytes { $0.copyMemory(from: row) }
                    }
                    for outX in 0..<outWidth {
                        // 16-bit samples are big-endian: the high byte is the 8-bit value.
                        let value = scratch[outX * step * bytesPerSample]
                        let base = (outY * outWidth + outX) * 4
                        if colorChannels == 1 {
                            pixels[base] = value; pixels[base + 1] = value; pixels[base + 2] = value
                        } else {
                            pixels[base + channel] = value
                        }
                    }
                }
            }
            return true
        }
        return ok ? (pixels, outWidth, outHeight) : nil
    }

    /// PackBits (Photoshop RLE) into `output`, which must be filled exactly.
    static func unpackBits(_ input: UnsafeRawBufferPointer, into output: inout [UInt8]) -> Bool {
        var i = 0, o = 0
        while i < input.count, o < output.count {
            let n = Int(Int8(bitPattern: input[i]))
            i += 1
            if n >= 0 {
                let count = n + 1
                guard i + count <= input.count, o + count <= output.count else { return false }
                for k in 0..<count { output[o + k] = input[i + k] }
                i += count; o += count
            } else if n != -128 {
                let count = 1 - n
                guard i < input.count, o + count <= output.count else { return false }
                let value = input[i]
                for k in 0..<count { output[o + k] = value }
                i += 1; o += count
            }
        }
        return o == output.count
    }

    private struct ByteReader {
        let data: Data
        var offset: Int

        init(data: Data, offset: Int = 0) {
            self.data = data
            self.offset = offset
        }

        mutating func skip(_ count: Int) { offset += count }

        mutating func bytes(_ count: Int) -> [UInt8]? {
            guard offset >= 0, offset + count <= data.count else { return nil }
            defer { offset += count }
            let start = data.startIndex + offset
            return Array(data[start..<(start + count)])
        }

        mutating func uint16() -> Int? {
            guard let b = bytes(2) else { return nil }
            return Int(b[0]) << 8 | Int(b[1])
        }

        mutating func uint32() -> Int? {
            guard let b = bytes(4) else { return nil }
            return Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
        }
    }
}
