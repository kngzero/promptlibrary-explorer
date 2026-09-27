import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Metadata filtering for exports. Never touches originals: everything here takes bytes
/// or metadata objects and returns new ones.
///
/// C2PA / Content Credentials: a PNG's `caBX` chunk is carried over untouched by every
/// policy. ImageIO's lossless JPEG rewrite doesn't carry APP11 (JUMBF) segments, so a
/// JPEG loses its manifest whenever its metadata is changed; either way a changed file
/// no longer matches its manifest's hash, so the credentials wouldn't validate.
enum ExportMetadata {
    enum Failure: LocalizedError {
        case unreadable
        case malformedPNG(String)
        case losslessCopyFailed(String)
        case pixelsChanged
        case leaked([String])

        var errorDescription: String? {
            switch self {
            case .unreadable: return "The image couldn't be read."
            case .malformedPNG(let detail): return "The PNG's structure couldn't be read (\(detail))."
            case .losslessCopyFailed(let detail): return "The metadata couldn't be rewritten without re-encoding (\(detail))."
            case .pixelsChanged: return "Rewriting the metadata would have changed the image data."
            case .leaked(let what): return "The exported file still contained \(what.joined(separator: ", ")), so it wasn't saved."
            }
        }
    }

    // MARK: - XMP / EXIF filtering

    /// Namespace prefixes whose tags `stripAI` keeps (minus the AI / GPS tags below).
    /// Anything else (custom generator namespaces) is removed.
    private static let knownPrefixes: Set<String> = [
        "tiff", "exif", "exifEX", "aux", "xmp", "dc", "photoshop", "xmpRights", "Iptc4xmpCore",
        "Iptc4xmpExt", "xmpMM", "lr", "MicrosoftPhoto", "crs", "xmpDM", "plus",
    ]

    /// Tags that hold prompts or descriptions generators write.
    private static let descriptionTags: Set<String> = [
        "exif:UserComment", "tiff:ImageDescription", "dc:description", "photoshop:Instructions",
        "photoshop:Headline", "xmp:Description",
    ]

    private static let ratingKeywordTags: Set<String> = [
        "xmp:Rating", "xmp:Label", "dc:subject", "lr:hierarchicalSubject", "MicrosoftPhoto:Rating",
    ]

    /// Structural tags every policy keeps.
    private static let structuralTags: Set<String> = [
        "tiff:Orientation", "exif:ColorSpace", "tiff:XResolution", "tiff:YResolution", "tiff:ResolutionUnit",
    ]

    enum TagCategory: Equatable {
        case structural
        case description
        case aiDeclared
        case gps
        case camera
        case ratingKeywords
        case other
        case unknownNamespace
        case imageIOInternal
    }

    static func category(prefix: String, name: String) -> TagCategory {
        let path = "\(prefix):\(name)"
        if prefix == "iio" { return .imageIOInternal }
        if structuralTags.contains(path) { return .structural }
        if descriptionTags.contains(path) { return .description }
        if ratingKeywordTags.contains(path) { return .ratingKeywords }
        // IPTC 2023 generative-AI fields (AIPromptInformation, AISystemUsed, …).
        if prefix == "Iptc4xmpExt", name.hasPrefix("AI") { return .aiDeclared }
        if prefix == "exif", name.hasPrefix("GPS") { return .gps }
        if prefix == "exifEX" || prefix == "aux" { return .camera }
        if prefix == "tiff", name == "Make" || name == "Model" { return .camera }
        if prefix == "exif" {
            switch name {
            case "DateTimeOriginal", "DateTimeDigitized", "SubsecTimeOriginal", "SubsecTimeDigitized",
                 "PixelXDimension", "PixelYDimension":
                return .other
            default:
                return .camera
            }
        }
        if !knownPrefixes.contains(prefix) { return .unknownNamespace }
        return .other
    }

    static func keeps(_ category: TagCategory, policy: ExportMetadataPolicy) -> Bool {
        switch policy.mode {
        case .keepAll:
            return true
        case .stripAI:
            switch category {
            case .structural, .camera, .ratingKeywords, .other: return true
            case .description, .aiDeclared, .gps, .unknownNamespace, .imageIOInternal: return false
            }
        case .stripAll:
            return category == .structural
        case .keepOnly:
            switch category {
            case .structural: return true
            case .camera: return policy.keptFields.contains(.camera)
            case .gps: return policy.keptFields.contains(.gps)
            case .ratingKeywords: return policy.keptFields.contains(.ratingKeywords)
            // Prompt fields are re-synthesised from the parsed values, never copied raw.
            case .description, .aiDeclared, .other, .unknownNamespace, .imageIOInternal: return false
            }
        }
    }

    /// A mutable copy of `source` with every top-level tag the policy drops removed.
    static func filteredXMP(_ source: CGImageMetadata?, policy: ExportMetadataPolicy) -> CGMutableImageMetadata {
        guard let source, let copy = CGImageMetadataCreateMutableCopy(source) else {
            return CGImageMetadataCreateMutable()
        }
        guard policy.mode != .keepAll else { return copy }
        var removals: [String] = []
        CGImageMetadataEnumerateTagsUsingBlock(source, nil, nil) { path, tag in
            let prefix = (CGImageMetadataTagCopyPrefix(tag) as String?) ?? ""
            let name = (CGImageMetadataTagCopyName(tag) as String?) ?? (path as String)
            if !keeps(category(prefix: prefix, name: name), policy: policy) {
                removals.append(path as String)
            }
            return true
        }
        for path in removals {
            CGImageMetadataRemoveTagWithPath(copy, nil, path as CFString)
        }
        return copy
    }

    /// True when `metadata` has any tag worth writing (ImageIO's own markers don't count).
    static func hasContent(_ metadata: CGImageMetadata) -> Bool {
        var found = false
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { _, tag in
            let prefix = (CGImageMetadataTagCopyPrefix(tag) as String?) ?? ""
            if prefix != "iio" { found = true }
            return !found
        }
        return found
    }

    // MARK: - Synthesised parameters (keep only)

    /// An A1111-style parameters block holding only the fields `policy` keeps, or nil when
    /// nothing is left. Used by "Keep Only" so no unselected value is ever copied raw.
    static func synthesizedParameters(from parsed: ImageMetadataParser.Metadata, policy: ExportMetadataPolicy) -> String? {
        let params = parsed.generationParameters
        var lines: [String] = []
        let prompt = parsed.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if policy.keeps(.prompt), !prompt.isEmpty { lines.append(prompt) }
        if policy.keeps(.negativePrompt), let negative = parsed.negativePrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !negative.isEmpty {
            lines.append("Negative prompt: \(negative)")
        }
        var pairs: [String] = []
        if policy.keeps(.parameters) {
            if let steps = params.steps, !steps.isEmpty { pairs.append("Steps: \(steps)") }
            if let sampler = params.sampler, !sampler.isEmpty { pairs.append("Sampler: \(sampler)") }
            if let cfg = params.cfg, !cfg.isEmpty { pairs.append("CFG scale: \(cfg)") }
        }
        if policy.keeps(.seed), let seed = params.seed, !seed.isEmpty { pairs.append("Seed: \(seed)") }
        if policy.keeps(.parameters), let width = params.width, let height = params.height {
            pairs.append("Size: \(width)x\(height)")
        }
        if policy.keeps(.model), let model = params.model?.trimmingCharacters(in: .whitespacesAndNewlines),
           !model.isEmpty, model != "N/A"
        {
            pairs.append("Model: \(model.contains(",") ? "\"\(model)\"" : model)")
        }
        if !pairs.isEmpty { lines.append(pairs.joined(separator: ", ")) }
        let text = lines.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    /// The prompt line of a synthesised block (mirrored into ImageDescription for JPEG).
    static func keptPrompt(from parsed: ImageMetadataParser.Metadata, policy: ExportMetadataPolicy) -> String? {
        guard policy.keeps(.prompt) else { return nil }
        let prompt = parsed.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return prompt.isEmpty ? nil : prompt
    }

    /// Adds the synthesised block to JPEG/HEIC/TIFF-style metadata.
    static func applySynthesized(_ text: String?, prompt: String?, to metadata: CGMutableImageMetadata) {
        if let text {
            CGImageMetadataRemoveTagWithPath(metadata, nil, "exif:UserComment" as CFString)
            _ = CGImageMetadataSetValueMatchingImageProperty(
                metadata, kCGImagePropertyExifDictionary, kCGImagePropertyExifUserComment, text as CFString
            )
        }
        if let prompt {
            // Replace rather than mutate: editing a copied dc:description alt-array in
            // place crashes inside ImageIO.
            CGImageMetadataRemoveTagWithPath(metadata, nil, "dc:description" as CFString)
            CGImageMetadataRemoveTagWithPath(metadata, nil, "tiff:ImageDescription" as CFString)
            _ = CGImageMetadataSetValueMatchingImageProperty(
                metadata, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFImageDescription, prompt as CFString
            )
        }
    }

    // MARK: - PNG chunks

    struct PNGChunk {
        let type: String
        /// Whole chunk (length + type + data + CRC), relative to the start of the data.
        let range: Range<Int>
        let dataRange: Range<Int>

        var isText: Bool { type == "tEXt" || type == "zTXt" || type == "iTXt" }
    }

    static let pngSignature = Data([137, 80, 78, 71, 13, 10, 26, 10])

    /// Walks every chunk through IEND. Throws on anything malformed.
    static func pngChunks(_ data: Data) throws -> [PNGChunk] {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, Data(bytes[0..<8]) == pngSignature else { throw Failure.malformedPNG("not a PNG") }
        var chunks: [PNGChunk] = []
        var offset = 8
        while true {
            guard offset + 12 <= bytes.count else { throw Failure.malformedPNG("missing IEND") }
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            let typeBytes = bytes[(offset + 4)..<(offset + 8)]
            guard typeBytes.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }),
                  let type = String(bytes: typeBytes, encoding: .ascii)
            else { throw Failure.malformedPNG("bad chunk type at \(offset)") }
            let end = offset + 12 + length
            guard length >= 0, end <= bytes.count else { throw Failure.malformedPNG("\(type) overruns the file") }
            chunks.append(PNGChunk(type: type, range: offset..<end, dataRange: (offset + 8)..<(offset + 8 + length)))
            offset = end
            if type == "IEND" { break }
        }
        guard chunks.first?.type == "IHDR" else { throw Failure.malformedPNG("first chunk isn't IHDR") }
        return chunks
    }

    static func keyword(of chunk: PNGChunk, in data: Data) -> String? {
        guard chunk.isText else { return nil }
        let payload = data.subdata(in: (data.startIndex + chunk.dataRange.lowerBound)..<(data.startIndex + chunk.dataRange.upperBound))
        guard let nul = payload.firstIndex(of: 0) else { return nil }
        return String(data: payload[payload.startIndex..<nul], encoding: .isoLatin1)
    }

    /// PNG text keywords `stripAI` keeps: credits, not generation data.
    static let safePNGKeywords: Set<String> = ["title", "author", "copyright", "creation time", "disclaimer", "warning", "legal"]
    /// ComfyUI's API graph and UI workflow chunks (kept by Keep Only ▸ workflow).
    static let workflowPNGKeywords: Set<String> = ["prompt", "workflow"]

    static func keepsPNGTextChunk(keyword: String?, policy: ExportMetadataPolicy) -> Bool {
        let key = keyword?.lowercased() ?? ""
        switch policy.mode {
        case .keepAll: return true
        case .stripAI: return safePNGKeywords.contains(key)
        case .stripAll: return false
        case .keepOnly: return policy.keptFields.contains(.workflow) && workflowPNGKeywords.contains(key)
        }
    }

    /// Chunks the policy removes outright (besides text): EXIF (re-expressed as filtered XMP)
    /// and, for Strip All, the modification time.
    static func dropsPNGChunk(_ type: String, policy: ExportMetadataPolicy) -> Bool {
        switch policy.mode {
        case .keepAll: return false
        case .stripAI, .keepOnly: return type == "eXIf"
        case .stripAll: return type == "eXIf" || type == "tIME"
        }
    }

    static func pngChunk(type: String, payload: Data) -> Data {
        var out = Data()
        let length = UInt32(payload.count)
        out.append(contentsOf: [UInt8(length >> 24 & 0xFF), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)])
        var crcInput = Data(type.utf8)
        crcInput.append(payload)
        out.append(crcInput)
        let crc = crc32(crcInput)
        out.append(contentsOf: [UInt8(crc >> 24 & 0xFF), UInt8(crc >> 16 & 0xFF), UInt8(crc >> 8 & 0xFF), UInt8(crc & 0xFF)])
        return out
    }

    /// tEXt when the text is Latin-1, else an uncompressed UTF-8 iTXt.
    static func pngTextChunk(keyword: String, text: String) -> Data {
        if let latin1 = text.data(using: .isoLatin1), text.unicodeScalars.allSatisfy({ $0.value < 256 }) {
            var payload = Data(keyword.utf8)
            payload.append(0)
            payload.append(latin1)
            return pngChunk(type: "tEXt", payload: payload)
        }
        var payload = Data(keyword.utf8)
        payload.append(contentsOf: [0, 0, 0, 0, 0])
        payload.append(Data(text.utf8))
        return pngChunk(type: "iTXt", payload: payload)
    }

    static func pngXMPChunk(_ xmp: Data) -> Data {
        var payload = Data("XML:com.adobe.xmp".utf8)
        payload.append(contentsOf: [0, 0, 0, 0, 0])
        payload.append(xmp)
        return pngChunk(type: "iTXt", payload: payload)
    }

    /// Rebuilds a PNG without the chunks `policy` drops, inserting `extraChunks` (already
    /// encoded) before the first IDAT. Image data chunks are copied byte for byte, so
    /// the decoded pixels are identical.
    static func rewritePNG(_ data: Data, policy: ExportMetadataPolicy, extraChunks: [Data]) throws -> Data {
        let chunks = try pngChunks(data)
        var out = Data(pngSignature)
        var inserted = false
        func bytes(_ range: Range<Int>) -> Data {
            data.subdata(in: (data.startIndex + range.lowerBound)..<(data.startIndex + range.upperBound))
        }
        for chunk in chunks {
            if chunk.type == "IDAT", !inserted {
                extraChunks.forEach { out.append($0) }
                inserted = true
            }
            if chunk.isText, !keepsPNGTextChunk(keyword: keyword(of: chunk, in: data), policy: policy) { continue }
            if dropsPNGChunk(chunk.type, policy: policy) { continue }
            out.append(bytes(chunk.range))
        }
        if !inserted { throw Failure.malformedPNG("no image data") }
        return out
    }

    /// The source's text chunks the policy keeps, as raw bytes (verbatim).
    static func keptPNGTextChunks(_ data: Data, policy: ExportMetadataPolicy, excludingXMP: Bool) -> [Data] {
        guard let chunks = try? pngChunks(data) else { return [] }
        return chunks.compactMap { chunk in
            guard chunk.isText else { return nil }
            let key = keyword(of: chunk, in: data)
            if excludingXMP, key == "XML:com.adobe.xmp" { return nil }
            guard keepsPNGTextChunk(keyword: key, policy: policy) else { return nil }
            return data.subdata(in: (data.startIndex + chunk.range.lowerBound)..<(data.startIndex + chunk.range.upperBound))
        }
    }

    /// Inserts encoded chunks before the first IDAT of an ImageIO-written PNG.
    static func splice(_ extraChunks: [Data], into png: Data) throws -> Data {
        guard !extraChunks.isEmpty else { return png }
        return try rewritePNG(png, policy: .keepAll, extraChunks: extraChunks)
    }

    /// PNG lossless path: drop, then re-add filtered XMP and any synthesised parameters.
    static func strippedPNG(_ data: Data, policy: ExportMetadataPolicy, parsed: ImageMetadataParser.Metadata?) throws -> Data {
        var extra: [Data] = []
        if policy.mode != .keepAll {
            let source = CGImageSourceCreateWithData(data as CFData, nil)
            let xmp = filteredXMP(source.flatMap { CGImageSourceCopyMetadataAtIndex($0, 0, nil) }, policy: policy)
            if hasContent(xmp), let xmpData = CGImageMetadataCreateXMPData(xmp, nil) as Data? {
                extra.append(pngXMPChunk(xmpData))
            }
            if policy.mode == .keepOnly, let parsed, let text = synthesizedParameters(from: parsed, policy: policy) {
                extra.append(pngTextChunk(keyword: "parameters", text: text))
            }
        }
        let output = try rewritePNG(data, policy: policy, extraChunks: extra)
        try verifySamePNGImageData(original: data, output: output)
        return output
    }

    private static func verifySamePNGImageData(original: Data, output: Data) throws {
        func imageData(_ data: Data) throws -> Data {
            var result = Data()
            for chunk in try pngChunks(data) where ["IHDR", "PLTE", "IDAT"].contains(chunk.type) {
                result.append(data.subdata(in: (data.startIndex + chunk.range.lowerBound)..<(data.startIndex + chunk.range.upperBound)))
            }
            return result
        }
        guard try imageData(original) == imageData(output) else { throw Failure.pixelsChanged }
    }

    // MARK: - Lossless rewrite through ImageIO (JPEG, and TIFF/HEIC where supported)

    static func losslessRewrite(_ data: Data, policy: ExportMetadataPolicy, parsed: ImageMetadataParser.Metadata?) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source)
        else { throw Failure.unreadable }

        let metadata = filteredXMP(CGImageSourceCopyMetadataAtIndex(source, 0, nil), policy: policy)
        if policy.mode == .keepOnly, let parsed {
            applySynthesized(
                synthesizedParameters(from: parsed, policy: policy),
                prompt: keptPrompt(from: parsed, policy: policy),
                to: metadata
            )
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type, CGImageSourceGetCount(source), nil) else {
            throw Failure.losslessCopyFailed("no destination for \(type)")
        }
        var options: [CFString: Any] = [
            kCGImageDestinationMetadata: metadata,
            kCGImageDestinationMergeMetadata: false,
        ]
        if !policy.keeps(ExportMetadataField.gps) {
            options[kCGImagePropertyGPSDictionary] = kCFNull
        }
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error) else {
            let detail = error?.takeRetainedValue().localizedDescription ?? "unsupported format"
            throw Failure.losslessCopyFailed(detail)
        }
        let result = output as Data
        if UTType(type as String)?.conforms(to: .jpeg) == true {
            guard let a = jpegScanData(data), let b = jpegScanData(result), a == b else { throw Failure.pixelsChanged }
        }
        return result
    }

    /// Bytes from the first SOS marker through the following EOI.
    static func jpegScanData(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        var offset = 2
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
        while offset + 4 <= bytes.count {
            guard bytes[offset] == 0xFF else { return nil }
            var markerOffset = offset + 1
            while markerOffset < bytes.count, bytes[markerOffset] == 0xFF { markerOffset += 1 }
            guard markerOffset + 2 < bytes.count else { return nil }
            let marker = bytes[markerOffset]
            if marker == 0xDA {
                var end = markerOffset + 1
                while end + 1 < bytes.count {
                    if bytes[end] == 0xFF, bytes[end + 1] == 0xD9 { return Data(bytes[offset..<(end + 2)]) }
                    end += 1
                }
                return nil
            }
            if marker == 0x01 || (0xD0...0xD7).contains(marker) {
                offset = markerOffset + 1
                continue
            }
            let length = Int(bytes[markerOffset + 1]) << 8 | Int(bytes[markerOffset + 2])
            guard length >= 2 else { return nil }
            offset = markerOffset + 1 + length
        }
        return nil
    }

    // MARK: - Verification

    private static let aiTextKeywords: Set<String> = [
        "parameters", "prompt", "workflow", "negative_prompt", "negativeprompt", "comment", "description",
        "dream", "sd-metadata", "invokeai_metadata", "invokeai_graph", "generation_data", "source", "software",
    ]

    /// What of the AI metadata the policy removes is still in the file at `url`
    /// (empty = clean). Re-parses with `ImageMetadataParser`, then checks raw PNG chunks.
    static func leakedAIMetadata(at url: URL, policy: ExportMetadataPolicy) -> [String] {
        guard policy.mode != .keepAll else { return [] }
        var leaks: [String] = []
        let parsed = ImageMetadataParser.readMetadataUncached(at: url)
        let params = parsed.generationParameters
        if !policy.keeps(.prompt), !parsed.prompt.isEmpty { leaks.append("a prompt") }
        if !policy.keeps(.negativePrompt), parsed.negativePrompt?.isEmpty == false { leaks.append("a negative prompt") }
        if !policy.keeps(.seed), params.seed?.isEmpty == false { leaks.append("a seed") }
        if !policy.keeps(.parameters),
           params.steps?.isEmpty == false || params.sampler?.isEmpty == false || params.cfg?.isEmpty == false
        {
            leaks.append("generation parameters")
        }
        if !policy.keeps(.workflow), parsed.comfyPromptJSON != nil || parsed.comfyWorkflowJSON != nil {
            leaks.append("a ComfyUI graph")
        }
        if url.pathExtension.lowercased() == "png", let data = try? Data(contentsOf: url, options: .mappedIfSafe),
           let chunks = try? pngChunks(data)
        {
            for chunk in chunks where chunk.isText {
                let key = keyword(of: chunk, in: data)?.lowercased() ?? ""
                if keepsPNGTextChunk(keyword: key, policy: policy) { continue }
                if policy.mode == .keepOnly, key == "parameters" || key == "xml:com.adobe.xmp" { continue }
                if policy.mode != .keepOnly, key == "xml:com.adobe.xmp" { continue }
                if aiTextKeywords.contains(key) || policy.mode == .stripAll {
                    leaks.append("a \"\(key)\" text chunk")
                }
            }
        }
        if !policy.keeps(.gps), let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           gps[kCGImagePropertyGPSLatitude] != nil || gps[kCGImagePropertyGPSLongitude] != nil
        {
            leaks.append("a GPS location")
        }
        var seen = Set<String>()
        return leaks.filter { seen.insert($0).inserted }
    }

    // MARK: - CRC

    private static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var c = UInt32(index)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}
