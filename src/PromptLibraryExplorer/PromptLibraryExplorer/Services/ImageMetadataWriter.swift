import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes prompt metadata into PNG text chunks or JPEG EXIF/TIFF/XMP properties.
///
/// Every write follows the same safety pattern: read the original (memory-mapped), build the
/// complete new file in memory, re-parse and verify it, and only then atomically replace the
/// original. Anything the writer doesn't explicitly edit is carried over byte-for-byte.
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

    /// How the supplied fields combine with metadata already embedded in the file.
    enum WriteMode {
        /// The supplied prompt fields are authoritative: an empty field removes that value.
        /// Parameters the form doesn't know about (Size, VAE, hashes, …) are always preserved.
        case replace
        /// Only non-empty supplied fields are written; everything else is kept as-is.
        case mergeNonEmpty
    }

    // MARK: - Public

    /// Embeds prompt metadata into an image file in-place.
    /// Supports PNG (text chunks) and JPEG (EXIF UserComment / TIFF ImageDescription / XMP dc:description).
    static func write(_ metadata: PromptMetadata, to url: URL, mode: WriteMode = .replace) throws {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "png":
            try writePNG(metadata, to: url, mode: mode)
        case "jpg", "jpeg":
            try writeJPEG(metadata, to: url, mode: mode)
        default:
            throw WriterError.unsupportedFormat(ext)
        }
    }

    /// Reads the prompt fields the writer manages from the file's current metadata, if any.
    static func existingMetadata(at url: URL) -> PromptMetadata? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }

        let block: ParameterBlock?
        switch url.pathExtension.lowercased() {
        case "png":
            guard let layout = try? PNGLayout(parsing: data) else { return nil }
            block = try? existingParameterBlock(in: layout, of: data)
        case "jpg", "jpeg":
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            block = existingParameterBlock(from: source)
        default:
            return nil
        }

        return block?.promptMetadata
    }

    enum WriterError: LocalizedError {
        case unsupportedFormat(String)
        case failedToReadFile
        case failedToCreateImageSource
        case failedToCreateDestination
        case failedToFinalize
        case invalidPNG
        case malformedPNG(String)
        case unreadableExistingMetadata(String)
        case verificationFailed(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let ext): return "Cannot embed metadata in .\(ext) files. Only PNG and JPEG are supported."
            case .failedToReadFile: return "Failed to read the image file."
            case .failedToCreateImageSource: return "Failed to decode the image."
            case .failedToCreateDestination: return "Failed to create the output image."
            case .failedToFinalize: return "Failed to write the output image."
            case .invalidPNG: return "The file is not a valid PNG."
            case .malformedPNG(let detail): return "The PNG's structure couldn't be read safely (\(detail)). The file was not modified."
            case .unreadableExistingMetadata(let key): return "The existing \"\(key)\" metadata couldn't be decoded, so it was left untouched. The file was not modified."
            case .verificationFailed(let detail): return "The rewritten file failed verification (\(detail)). The original file was not modified."
            }
        }
    }

    // MARK: - Parameters String

    /// An A1111-style parameters block: prompt, optional "Negative prompt:" section, and a
    /// "Key: value, Key: value" line. Keys are kept in their original order and spelling.
    struct ParameterBlock {
        var prompt: String = ""
        var negativePrompt: String = ""
        var pairs: [(key: String, value: String)] = []
        /// Lines after the parameter line (written by some extensions); kept verbatim.
        var trailingLines: [String] = []

        init() {}

        init(parsing text: String) {
            let lines = text
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .components(separatedBy: "\n")

            let parameterLineIndex =
                lines.lastIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("Steps:") }
                ?? lines.lastIndex { $0.contains("Steps:") && !Self.parsePairs(from: $0).isEmpty }
                ?? Self.fallbackParameterLineIndex(in: lines)

            let promptSection: ArraySlice<String>
            if let parameterLineIndex {
                promptSection = lines[..<parameterLineIndex]
                pairs = Self.parsePairs(from: lines[parameterLineIndex])
                trailingLines = Array(lines[(parameterLineIndex + 1)...])
                while let last = trailingLines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
                    trailingLines.removeLast()
                }
            } else {
                promptSection = lines[...]
            }

            var positiveLines: [String] = []
            var negativeLines: [String] = []
            var readingNegative = false
            let negativePrefix = "negative prompt:"

            for line in promptSection {
                if !readingNegative, line.lowercased().hasPrefix(negativePrefix) {
                    readingNegative = true
                    let remainder = line.dropFirst(negativePrefix.count).trimmingCharacters(in: .whitespaces)
                    if !remainder.isEmpty { negativeLines.append(remainder) }
                } else if readingNegative {
                    negativeLines.append(line)
                } else {
                    positiveLines.append(line)
                }
            }

            prompt = positiveLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            negativePrompt = negativeLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var serialized: String {
            var lines: [String] = []
            if !prompt.isEmpty { lines.append(prompt) }
            if !negativePrompt.isEmpty { lines.append("Negative prompt: \(negativePrompt)") }
            if !pairs.isEmpty { lines.append(pairs.map { "\($0.key): \($0.value)" }.joined(separator: ", ")) }
            lines.append(contentsOf: trailingLines)
            return lines.joined(separator: "\n")
        }

        var promptMetadata: PromptMetadata {
            func value(_ keys: Set<String>) -> String {
                guard let pair = pairs.first(where: { keys.contains(ImageMetadataWriter.canonicalKey($0.key)) }) else {
                    return ""
                }
                return Self.unquoted(pair.value)
            }

            return PromptMetadata(
                prompt: prompt,
                negativePrompt: negativePrompt,
                model: value(KnownKey.model),
                steps: value(KnownKey.steps),
                sampler: value(KnownKey.sampler),
                cfgScale: value(KnownKey.cfgScale),
                seed: value(KnownKey.seed)
            )
        }

        mutating func apply(_ metadata: PromptMetadata, mode: WriteMode) {
            func resolved(_ new: String, _ old: String) -> String {
                let new = new.trimmingCharacters(in: .whitespacesAndNewlines)
                switch mode {
                case .replace: return new
                case .mergeNonEmpty: return new.isEmpty ? old : new
                }
            }

            prompt = resolved(metadata.prompt, prompt)
            negativePrompt = resolved(metadata.negativePrompt, negativePrompt)

            setParameter(KnownKey.steps, name: "Steps", value: metadata.steps, mode: mode)
            setParameter(KnownKey.sampler, name: "Sampler", value: metadata.sampler, mode: mode)
            setParameter(KnownKey.cfgScale, name: "CFG scale", value: metadata.cfgScale, mode: mode)
            setParameter(KnownKey.seed, name: "Seed", value: metadata.seed, mode: mode)
            setParameter(KnownKey.model, name: "Model", value: metadata.model, mode: mode)
        }

        private mutating func setParameter(_ keys: Set<String>, name: String, value: String, mode: WriteMode) {
            let value = value
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let matches = pairs.indices.filter { keys.contains(ImageMetadataWriter.canonicalKey(pairs[$0].key)) }

            guard !value.isEmpty else {
                if mode == .replace {
                    for index in matches.reversed() { pairs.remove(at: index) }
                }
                return
            }

            guard let first = matches.first else {
                let pair = (key: name, value: Self.quotedIfNeeded(value))
                if name == "Steps" {
                    pairs.insert(pair, at: 0)
                } else {
                    pairs.append(pair)
                }
                return
            }

            // Keep the original spelling of both key and value when the value is unchanged.
            if Self.unquoted(pairs[first].value) != value {
                pairs[first].value = Self.quotedIfNeeded(value)
            }
            for index in matches.dropFirst().reversed() { pairs.remove(at: index) }
        }

        /// A parameter line without "Steps:" (e.g. one this writer produced with only a model set)
        /// is recognized when it is the last non-empty line and starts with a well-known key.
        private static func fallbackParameterLineIndex(in lines: [String]) -> Int? {
            let leadingKeys: Set<String> = ["sampler", "cfgscale", "seed", "model", "modelhash", "size"]
            guard let index = lines.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
                  let firstKey = parsePairs(from: lines[index]).first?.key,
                  leadingKeys.contains(ImageMetadataWriter.canonicalKey(firstKey))
            else {
                return nil
            }
            return index
        }

        /// Splits "Key: value, Key: \"quoted, value\"" at top-level commas.
        static func parsePairs(from line: String) -> [(key: String, value: String)] {
            var segments: [String] = []
            var current = ""
            var inQuotes = false
            var escaped = false

            for character in line {
                if inQuotes {
                    current.append(character)
                    if escaped {
                        escaped = false
                    } else if character == "\\" {
                        escaped = true
                    } else if character == "\"" {
                        inQuotes = false
                    }
                    continue
                }

                if character == "\"" {
                    inQuotes = true
                    current.append(character)
                } else if character == "," {
                    segments.append(current)
                    current = ""
                } else {
                    current.append(character)
                }
            }
            segments.append(current)

            var pairs: [(key: String, value: String)] = []
            for segment in segments {
                if let colon = segment.firstIndex(of: ":"),
                   !segment[..<colon].contains("\"")
                {
                    let key = segment[..<colon].trimmingCharacters(in: .whitespaces)
                    let value = segment[segment.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    if !key.isEmpty {
                        pairs.append((key: key, value: value))
                        continue
                    }
                }

                // A segment without a key belongs to the previous value (e.g. an unquoted comma).
                if !pairs.isEmpty {
                    pairs[pairs.count - 1].value += "," + segment
                } else if !segment.trimmingCharacters(in: .whitespaces).isEmpty {
                    return []
                }
            }

            return pairs
        }

        static func quotedIfNeeded(_ value: String) -> String {
            guard value.contains(",") || value.contains(":") || value.contains("\"") else { return value }
            let escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }

        static func unquoted(_ value: String) -> String {
            guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
            return String(value.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
    }

    private enum KnownKey {
        static let steps: Set<String> = ["steps"]
        static let sampler: Set<String> = ["sampler"]
        static let cfgScale: Set<String> = ["cfgscale", "guidance"]
        static let seed: Set<String> = ["seed"]
        static let model: Set<String> = ["model", "modelname"]
    }

    // MARK: - PNG

    private static let pngSignature = Data([137, 80, 78, 71, 13, 10, 26, 10])

    /// Keywords whose text chunks the writer owns and rewrites.
    private static let ownedPNGKeywords: Set<String> = ["parameters", "prompt", "negative_prompt"]

    /// ComfyUI stores its API graph in `prompt` and its UI graph in `workflow`; those are never touched.
    private static let protectedJSONKeywords: Set<String> = ["prompt", "workflow"]

    private struct PNGChunk {
        let type: String
        /// Whole chunk: length + type + data + CRC.
        let range: Range<Int>
        let dataRange: Range<Int>
    }

    /// A fully walked PNG. Construction fails unless every chunk is well-formed and the walk
    /// ends exactly at an IEND chunk.
    private struct PNGLayout {
        let chunks: [PNGChunk] // excludes IEND
        let iend: PNGChunk
        /// Any bytes after IEND, preserved verbatim.
        let trailing: Range<Int>

        init(parsing data: Data) throws {
            guard data.count >= pngSignature.count, data.prefix(pngSignature.count) == pngSignature else {
                throw WriterError.invalidPNG
            }

            let base = data.startIndex
            var chunks: [PNGChunk] = []
            var iendChunk: PNGChunk?
            var offset = pngSignature.count

            while iendChunk == nil {
                guard offset + 12 <= data.count else {
                    throw WriterError.malformedPNG("missing IEND chunk")
                }

                let length = readUInt32(from: data, at: base + offset)
                let typeBytes = data[(base + offset + 4)..<(base + offset + 8)]
                guard typeBytes.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }),
                      let type = String(data: typeBytes, encoding: .ascii)
                else {
                    throw WriterError.malformedPNG("invalid chunk type at byte \(offset)")
                }

                let total = 12 + length
                guard length <= Int(Int32.max), offset + total <= data.count else {
                    throw WriterError.malformedPNG("\(type) chunk overruns the file")
                }

                let chunk = PNGChunk(
                    type: type,
                    range: offset..<(offset + total),
                    dataRange: (offset + 8)..<(offset + 8 + length)
                )
                offset += total

                if type == "IEND" {
                    iendChunk = chunk
                } else {
                    chunks.append(chunk)
                }
            }

            guard let iendChunk else {
                throw WriterError.malformedPNG("missing IEND chunk")
            }
            guard chunks.first?.type == "IHDR" else {
                throw WriterError.malformedPNG("first chunk is not IHDR")
            }

            self.chunks = chunks
            self.iend = iendChunk
            self.trailing = offset..<data.count
        }
    }

    private struct PNGTextChunk {
        let keyword: String
        /// Nil when the payload couldn't be decoded.
        let text: String?
    }

    private static func textChunk(_ chunk: PNGChunk, in data: Data) -> PNGTextChunk? {
        guard chunk.type == "tEXt" || chunk.type == "zTXt" || chunk.type == "iTXt" else { return nil }

        let payload = slice(data, chunk.dataRange)
        guard let separator = payload.firstIndex(of: 0),
              let keyword = String(data: payload[..<separator], encoding: .isoLatin1)
        else {
            return nil
        }
        var cursor = payload.index(after: separator)

        switch chunk.type {
        case "tEXt":
            let body = payload[cursor...]
            let text = String(data: body, encoding: .utf8) ?? String(data: body, encoding: .isoLatin1)
            return PNGTextChunk(keyword: keyword, text: text)

        case "zTXt":
            guard cursor < payload.endIndex, payload[cursor] == 0 else {
                return PNGTextChunk(keyword: keyword, text: nil)
            }
            cursor = payload.index(after: cursor)
            let text = MetadataZlib.inflate(Data(payload[cursor...])).flatMap {
                String(data: $0, encoding: .utf8) ?? String(data: $0, encoding: .isoLatin1)
            }
            return PNGTextChunk(keyword: keyword, text: text)

        default: // iTXt
            guard payload.distance(from: cursor, to: payload.endIndex) >= 2 else {
                return PNGTextChunk(keyword: keyword, text: nil)
            }
            let compressed = payload[cursor] == 1
            let method = payload[payload.index(after: cursor)]
            cursor = payload.index(cursor, offsetBy: 2)
            guard let languageEnd = payload[cursor...].firstIndex(of: 0) else {
                return PNGTextChunk(keyword: keyword, text: nil)
            }
            cursor = payload.index(after: languageEnd)
            guard let translatedEnd = payload[cursor...].firstIndex(of: 0) else {
                return PNGTextChunk(keyword: keyword, text: nil)
            }
            cursor = payload.index(after: translatedEnd)
            let body = Data(payload[cursor...])
            let textData: Data?
            if compressed {
                textData = method == 0 ? MetadataZlib.inflate(body) : nil
            } else {
                textData = body
            }
            return PNGTextChunk(keyword: keyword, text: textData.flatMap { String(data: $0, encoding: .utf8) })
        }
    }

    private static func looksLikeJSON(_ text: String?) -> Bool {
        guard let text else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
    }

    /// Whether the writer should drop this chunk because it rewrites its content.
    /// Throws if an owned chunk can't be decoded, rather than silently discarding it.
    private static func isOwnedTextChunk(_ chunk: PNGChunk, in data: Data) throws -> Bool {
        guard let text = textChunk(chunk, in: data) else { return false }
        let keyword = text.keyword.lowercased()
        guard ownedPNGKeywords.contains(keyword) else { return false }
        guard text.text != nil else {
            // An undecodable `prompt` might be a ComfyUI graph; never discard what we can't read.
            throw WriterError.unreadableExistingMetadata(text.keyword)
        }
        if protectedJSONKeywords.contains(keyword), looksLikeJSON(text.text) {
            return false
        }
        return true
    }

    private static func existingParameterBlock(in layout: PNGLayout, of data: Data) throws -> ParameterBlock? {
        var parameters: String?
        var plainPrompt: String?
        var negative: String?

        for chunk in layout.chunks {
            guard let text = textChunk(chunk, in: data) else { continue }
            switch text.keyword.lowercased() {
            case "parameters":
                guard let value = text.text else { throw WriterError.unreadableExistingMetadata(text.keyword) }
                if parameters == nil { parameters = value }
            case "prompt":
                if plainPrompt == nil, let value = text.text, !looksLikeJSON(value) { plainPrompt = value }
            case "negative_prompt":
                if negative == nil { negative = text.text }
            default:
                continue
            }
        }

        if let parameters {
            var block = ParameterBlock(parsing: parameters)
            if block.prompt.isEmpty, let plainPrompt { block.prompt = plainPrompt.trimmingCharacters(in: .whitespacesAndNewlines) }
            if block.negativePrompt.isEmpty, let negative { block.negativePrompt = negative.trimmingCharacters(in: .whitespacesAndNewlines) }
            return block
        }

        guard plainPrompt != nil || negative != nil else { return nil }
        var block = ParameterBlock()
        block.prompt = (plainPrompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        block.negativePrompt = (negative ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return block
    }

    private static func writePNG(_ metadata: PromptMetadata, to url: URL, mode: WriteMode) throws {
        let original = try readMapped(url)
        let layout = try PNGLayout(parsing: original)

        var block = try existingParameterBlock(in: layout, of: original) ?? ParameterBlock()
        block.apply(metadata, mode: mode)
        let parametersText = block.serialized

        var keptChunks: [PNGChunk] = []
        var hasProtectedPrompt = false
        for chunk in layout.chunks {
            if try isOwnedTextChunk(chunk, in: original) { continue }
            if let text = textChunk(chunk, in: original), text.keyword.lowercased() == "prompt" {
                hasProtectedPrompt = true
            }
            keptChunks.append(chunk)
        }

        var newChunks: [Data] = [buildTextChunk(keyword: "parameters", text: parametersText)]
        // Don't add a second `prompt` keyword next to a preserved ComfyUI graph.
        if !block.prompt.isEmpty, !hasProtectedPrompt {
            newChunks.append(buildTextChunk(keyword: "prompt", text: block.prompt))
        }
        if !block.negativePrompt.isEmpty {
            newChunks.append(buildTextChunk(keyword: "negative_prompt", text: block.negativePrompt))
        }

        var output = Data()
        output.reserveCapacity(original.count + newChunks.reduce(0) { $0 + $1.count })
        output.append(pngSignature)
        for chunk in keptChunks { output.append(slice(original, chunk.range)) }
        for chunk in newChunks { output.append(chunk) }
        output.append(slice(original, layout.iend.range))
        output.append(slice(original, layout.trailing))

        try verifyPNG(
            output,
            original: original,
            keptChunks: keptChunks,
            newChunkCount: newChunks.count,
            trailing: layout.trailing,
            expectedParameters: parametersText
        )

        try MetadataFileReplacer.replaceContents(of: url, with: output)
    }

    private static func verifyPNG(
        _ output: Data,
        original: Data,
        keptChunks: [PNGChunk],
        newChunkCount: Int,
        trailing: Range<Int>,
        expectedParameters: String
    ) throws {
        let layout: PNGLayout
        do {
            layout = try PNGLayout(parsing: output)
        } catch {
            throw WriterError.verificationFailed("chunk walk did not reach IEND")
        }

        guard layout.chunks.count == keptChunks.count + newChunkCount else {
            throw WriterError.verificationFailed("unexpected chunk count")
        }
        for (kept, written) in zip(keptChunks, layout.chunks) {
            guard slice(original, kept.range) == slice(output, written.range) else {
                throw WriterError.verificationFailed("\(kept.type) chunk changed")
            }
        }
        guard slice(original, trailing) == slice(output, layout.trailing) else {
            throw WriterError.verificationFailed("data after IEND changed")
        }

        let written = layout.chunks[keptChunks.count...].compactMap { textChunk($0, in: output) }
        guard written.first(where: { $0.keyword == "parameters" })?.text == expectedParameters else {
            throw WriterError.verificationFailed("parameters didn't read back")
        }

        try verifyDecodable(output, matching: original)
    }

    /// Emits tEXt for Latin-1 text and uncompressed iTXt (UTF-8) otherwise, per the PNG spec.
    private static func buildTextChunk(keyword: String, text: String) -> Data {
        var payload = Data(keyword.utf8)
        payload.append(0) // null separator

        let type: String
        if let latin1 = text.data(using: .isoLatin1) {
            type = "tEXt"
            payload.append(latin1)
        } else {
            type = "iTXt"
            payload.append(contentsOf: [0, 0]) // uncompressed, method 0
            payload.append(0) // empty language tag
            payload.append(0) // empty translated keyword
            payload.append(Data(text.utf8))
        }

        var chunk = Data()
        chunk.reserveCapacity(payload.count + 12)
        var length = UInt32(payload.count).bigEndian
        chunk.append(Data(bytes: &length, count: 4))

        var crcInput = Data(type.utf8)
        crcInput.append(payload)
        chunk.append(crcInput)

        var crc = crc32(crcInput).bigEndian
        chunk.append(Data(bytes: &crc, count: 4))

        return chunk
    }

    // MARK: - JPEG

    private static func existingParameterBlock(from source: CGImageSource) -> ParameterBlock? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let comment = decodedUserComment(exif[kCGImagePropertyExifUserComment]),
              !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return ParameterBlock(parsing: comment)
    }

    private static func decodedUserComment(_ rawValue: Any?) -> String? {
        switch rawValue {
        case let value as String:
            return value.replacingOccurrences(of: "\0", with: "")
        case let value as Data:
            let unicodeHeader = Data("UNICODE\0".utf8)
            let asciiHeader = Data("ASCII\0\0\0".utf8)
            if value.starts(with: unicodeHeader) {
                let body = value.dropFirst(unicodeHeader.count)
                return String(data: body, encoding: .utf16BigEndian) ?? String(data: body, encoding: .utf16LittleEndian)
            }
            let body = value.starts(with: asciiHeader) ? value.dropFirst(asciiHeader.count) : value[...]
            return (String(data: body, encoding: .utf8) ?? String(data: body, encoding: .isoLatin1))?
                .replacingOccurrences(of: "\0", with: "")
        default:
            return nil
        }
    }

    private static func writeJPEG(_ metadata: PromptMetadata, to url: URL, mode: WriteMode) throws {
        let original = try readMapped(url)
        guard let source = CGImageSourceCreateWithData(original as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else {
            throw WriterError.failedToCreateImageSource
        }

        var block = existingParameterBlock(from: source) ?? ParameterBlock()
        block.apply(metadata, mode: mode)
        let parametersString = block.serialized

        let imageMetadata: CGMutableImageMetadata
        if let existing = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
            imageMetadata = CGImageMetadataCreateMutableCopy(existing) ?? CGImageMetadataCreateMutable()
        } else {
            imageMetadata = CGImageMetadataCreateMutable()
        }

        guard CGImageMetadataSetValueMatchingImageProperty(
            imageMetadata,
            kCGImagePropertyExifDictionary,
            kCGImagePropertyExifUserComment,
            parametersString as CFString
        ) else {
            throw WriterError.failedToCreateDestination
        }

        // ImageIO mirrors TIFF ImageDescription into XMP dc:description.
        if !block.prompt.isEmpty {
            _ = CGImageMetadataSetValueMatchingImageProperty(
                imageMetadata,
                kCGImagePropertyTIFFDictionary,
                kCGImagePropertyTIFFImageDescription,
                block.prompt as CFString
            )
        }

        let uti = CGImageSourceGetType(source) ?? (UTType.jpeg.identifier as CFString)
        let outputData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(outputData, uti, CGImageSourceGetCount(source), nil) else {
            throw WriterError.failedToCreateDestination
        }

        // Lossless: copies the compressed image data and merges in the new metadata (existing XMP kept).
        let options: [CFString: Any] = [
            kCGImageDestinationMetadata: imageMetadata,
            kCGImageDestinationMergeMetadata: true,
        ]
        var copyError: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &copyError) else {
            let detail = copyError?.takeRetainedValue().localizedDescription ?? "unknown error"
            throw WriterError.verificationFailed("lossless copy failed: \(detail)")
        }

        let output = outputData as Data
        try verifyJPEG(output, original: original, expectedUserComment: parametersString)
        try MetadataFileReplacer.replaceContents(of: url, with: output)
    }

    private static func verifyJPEG(_ output: Data, original: Data, expectedUserComment: String) throws {
        guard output.count > 4, output[output.startIndex] == 0xFF, output[output.startIndex + 1] == 0xD8 else {
            throw WriterError.verificationFailed("output is not a JPEG")
        }

        // The compressed scan data must be byte-identical (no re-encode).
        guard let originalScan = jpegScanRange(in: original),
              let outputScan = jpegScanRange(in: output),
              slice(original, originalScan) == slice(output, outputScan)
        else {
            throw WriterError.verificationFailed("image data would be re-encoded")
        }

        guard let source = CGImageSourceCreateWithData(output as CFData, nil),
              let comment = existingParameterBlock(from: source)
        else {
            throw WriterError.verificationFailed("metadata didn't read back")
        }
        let expected = ParameterBlock(parsing: expectedUserComment)
        guard comment.serialized == expected.serialized else {
            throw WriterError.verificationFailed("metadata didn't read back")
        }

        try verifyDecodable(output, matching: original)
    }

    /// Byte range from the first SOS marker through the first EOI marker (primary image scans).
    private static func jpegScanRange(in data: Data) -> Range<Int>? {
        let base = data.startIndex
        var offset = 2

        while offset + 4 <= data.count {
            guard data[base + offset] == 0xFF else { return nil }
            var markerOffset = offset + 1
            while markerOffset < data.count, data[base + markerOffset] == 0xFF { markerOffset += 1 }
            guard markerOffset < data.count else { return nil }
            let marker = data[base + markerOffset]

            if marker == 0xDA {
                var end = markerOffset + 1
                while end + 1 < data.count {
                    if data[base + end] == 0xFF, data[base + end + 1] == 0xD9 {
                        return offset..<(end + 2)
                    }
                    end += 1
                }
                return nil
            }
            if marker == 0x01 || (0xD0...0xD7).contains(marker) {
                offset = markerOffset + 1
                continue
            }
            if marker == 0xD9 { return nil }

            guard markerOffset + 3 <= data.count else { return nil }
            let length = Int(data[base + markerOffset + 1]) << 8 | Int(data[base + markerOffset + 2])
            guard length >= 2 else { return nil }
            offset = markerOffset + 1 + length
        }

        return nil
    }

    // MARK: - Helpers

    private static func readMapped(_ url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url, options: .alwaysMapped)
        } catch {
            throw WriterError.failedToReadFile
        }
    }

    /// Confirms ImageIO can still open the rewritten file with the same image count and size.
    private static func verifyDecodable(_ output: Data, matching original: Data) throws {
        guard let outputSource = CGImageSourceCreateWithData(output as CFData, nil),
              let originalSource = CGImageSourceCreateWithData(original as CFData, nil),
              CGImageSourceGetStatus(outputSource) == .statusComplete,
              CGImageSourceGetCount(outputSource) == CGImageSourceGetCount(originalSource)
        else {
            throw WriterError.verificationFailed("image no longer decodes")
        }

        func dimensions(_ source: CGImageSource) -> (Int, Int)? {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int
            else {
                return nil
            }
            return (width, height)
        }

        guard let outputSize = dimensions(outputSource),
              let originalSize = dimensions(originalSource),
              outputSize == originalSize
        else {
            throw WriterError.verificationFailed("image dimensions changed")
        }
    }

    /// Slices using offsets relative to the start of `data`.
    private static func slice(_ data: Data, _ range: Range<Int>) -> Data {
        data[(data.startIndex + range.lowerBound)..<(data.startIndex + range.upperBound)]
    }

    fileprivate static func canonicalKey(_ value: String) -> String {
        value
            .lowercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    private static func readUInt32(from data: Data, at offset: Int) -> Int {
        let bytes = data[offset..<(offset + 4)]
        return bytes.reduce(0) { ($0 << 8) | Int($1) }
    }

    private static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var crc = UInt32(index)
        for _ in 0..<8 {
            crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1
        }
        return crc
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}
