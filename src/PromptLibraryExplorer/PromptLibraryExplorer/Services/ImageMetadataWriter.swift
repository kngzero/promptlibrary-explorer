import Compression
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes prompt metadata into PNG tEXt chunks or JPEG EXIF/TIFF properties.
enum ImageMetadataWriter {
    struct PromptMetadata {
        var prompt: String
        var negativePrompt: String
        var model: String
        var steps: String
        var sampler: String
        var cfgScale: String
        var seed: String
    }

    // MARK: - Public

    /// Embeds prompt metadata into an image file in-place.
    /// Supports PNG (tEXt chunks) and JPEG (EXIF UserComment / TIFF ImageDescription).
    static func write(_ metadata: PromptMetadata, to url: URL) throws {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "png":
            try writePNG(metadata, to: url)
        case "jpg", "jpeg":
            try writeJPEG(metadata, to: url)
        default:
            throw WriterError.unsupportedFormat(ext)
        }
    }

    enum WriterError: LocalizedError {
        case unsupportedFormat(String)
        case failedToReadFile
        case failedToCreateImageSource
        case failedToCreateDestination
        case failedToFinalize
        case invalidPNG

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let ext): return "Cannot embed metadata in .\(ext) files. Only PNG and JPEG are supported."
            case .failedToReadFile: return "Failed to read the image file."
            case .failedToCreateImageSource: return "Failed to decode the image."
            case .failedToCreateDestination: return "Failed to create the output image."
            case .failedToFinalize: return "Failed to write the output image."
            case .invalidPNG: return "The file is not a valid PNG."
            }
        }
    }

    // MARK: - PNG

    /// Builds the Stable Diffusion-style parameters string that most tools recognize.
    private static func parameterString(from metadata: PromptMetadata) -> String {
        var lines: [String] = []
        lines.append(metadata.prompt)
        if !metadata.negativePrompt.isEmpty {
            lines.append("Negative prompt: \(metadata.negativePrompt)")
        }

        var params: [(String, String)] = []
        if !metadata.steps.isEmpty { params.append(("Steps", metadata.steps)) }
        if !metadata.sampler.isEmpty { params.append(("Sampler", metadata.sampler)) }
        if !metadata.cfgScale.isEmpty { params.append(("CFG scale", metadata.cfgScale)) }
        if !metadata.seed.isEmpty { params.append(("Seed", metadata.seed)) }
        if !metadata.model.isEmpty { params.append(("Model", metadata.model)) }

        if !params.isEmpty {
            lines.append(params.map { "\($0.0): \($0.1)" }.joined(separator: ", "))
        }

        return lines.joined(separator: "\n")
    }

    private static func writePNG(_ metadata: PromptMetadata, to url: URL) throws {
        var data = try Data(contentsOf: url)

        let pngSignature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        guard data.count >= pngSignature.count,
              Array(data.prefix(pngSignature.count)) == pngSignature
        else {
            throw WriterError.invalidPNG
        }

        // Remove existing prompt-related tEXt/zTXt chunks to avoid duplication
        data = removeExistingPromptChunks(from: data)

        // Build tEXt chunks
        let parametersValue = parameterString(from: metadata)
        var newChunks = Data()
        newChunks.append(buildTEXtChunk(keyword: "parameters", text: parametersValue))

        if !metadata.prompt.isEmpty {
            newChunks.append(buildTEXtChunk(keyword: "prompt", text: metadata.prompt))
        }
        if !metadata.negativePrompt.isEmpty {
            newChunks.append(buildTEXtChunk(keyword: "negative_prompt", text: metadata.negativePrompt))
        }

        // Insert chunks right before IEND
        let iendOffset = findIENDOffset(in: data)
        data.insert(contentsOf: newChunks, at: iendOffset)

        try data.write(to: url, options: .atomic)
    }

    private static func buildTEXtChunk(keyword: String, text: String) -> Data {
        var payload = Data(keyword.utf8)
        payload.append(0) // null separator
        payload.append(Data(text.utf8))

        var chunk = Data()
        // Length (4 bytes big-endian)
        var length = UInt32(payload.count).bigEndian
        chunk.append(Data(bytes: &length, count: 4))
        // Type
        chunk.append(Data("tEXt".utf8))
        // Data
        chunk.append(payload)
        // CRC over type + data
        var crcInput = Data("tEXt".utf8)
        crcInput.append(payload)
        var crc = crc32(crcInput).bigEndian
        chunk.append(Data(bytes: &crc, count: 4))

        return chunk
    }

    private static func findIENDOffset(in data: Data) -> Int {
        let iendType = Data("IEND".utf8)
        // IEND chunk: 4-byte length (0) + "IEND" + CRC = 12 bytes from end
        // Search backwards for "IEND"
        for i in stride(from: data.count - 8, through: 8, by: -1) {
            if data[i..<(i + 4)] == iendType {
                // The chunk starts 4 bytes before the type (length field)
                return i - 4
            }
        }
        // Fallback: append before end
        return data.count
    }

    private static func removeExistingPromptChunks(from data: Data) -> Data {
        let pngSignature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        let promptKeywords: Set<String> = ["parameters", "prompt", "negative_prompt"]

        var result = Data(pngSignature)
        var offset = pngSignature.count

        while offset + 12 <= data.count {
            let length = readUInt32(from: data, at: offset)
            let typeRange = (offset + 4)..<(offset + 8)
            guard let chunkType = String(data: data.subdata(in: typeRange), encoding: .ascii) else { break }

            let totalChunkSize = 4 + 4 + length + 4 // length + type + data + crc
            guard offset + totalChunkSize <= data.count else { break }

            var shouldRemove = false
            if chunkType == "tEXt" || chunkType == "zTXt" || chunkType == "iTXt" {
                let chunkData = data.subdata(in: (offset + 8)..<(offset + 8 + length))
                if let separator = chunkData.firstIndex(of: 0) {
                    let keyData = chunkData[chunkData.startIndex..<separator]
                    if let key = String(data: keyData, encoding: .utf8)?.lowercased(),
                       promptKeywords.contains(key)
                    {
                        shouldRemove = true
                    }
                }
            }

            if !shouldRemove {
                result.append(data.subdata(in: offset..<(offset + totalChunkSize)))
            }

            offset += totalChunkSize
            if chunkType == "IEND" { break }
        }

        return result
    }

    // MARK: - JPEG

    private static func writeJPEG(_ metadata: PromptMetadata, to url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw WriterError.failedToCreateImageSource
        }

        let parametersString = parameterString(from: metadata)

        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifUserComment: parametersString
            ] as [CFString: Any],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFImageDescription: metadata.prompt
            ] as [CFString: Any],
        ]

        let uti = CGImageSourceGetType(source) ?? (UTType.jpeg.identifier as CFString)
        let outputData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(outputData, uti, 1, nil) else {
            throw WriterError.failedToCreateDestination
        }

        // Merge existing properties with new ones
        let existingProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        var merged = existingProperties
        for (key, value) in properties {
            if let existingDict = merged[key] as? [CFString: Any],
               let newDict = value as? [CFString: Any]
            {
                var mergedDict = existingDict
                for (k, v) in newDict { mergedDict[k] = v }
                merged[key] = mergedDict
            } else {
                merged[key] = value
            }
        }

        CGImageDestinationAddImageFromSource(destination, source, 0, merged as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw WriterError.failedToFinalize
        }

        try (outputData as Data).write(to: url, options: .atomic)
    }

    // MARK: - Helpers

    private static func readUInt32(from data: Data, at offset: Int) -> Int {
        let bytes = data[offset..<(offset + 4)]
        return bytes.reduce(0) { ($0 << 8) | Int($1) }
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                if crc & 1 == 1 {
                    crc = (crc >> 1) ^ 0xEDB88320
                } else {
                    crc >>= 1
                }
            }
        }
        return crc ^ 0xFFFFFFFF
    }
}
