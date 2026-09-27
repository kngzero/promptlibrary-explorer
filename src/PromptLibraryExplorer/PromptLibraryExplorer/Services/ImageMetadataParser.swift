import Compression
import Foundation
import ImageIO

actor ImageMetadataParser {
    struct Metadata {
        let prompt: String
        let negativePrompt: String?
        let model: String?
        let timestamp: String?
        let fields: [PromptMetadataField]
        /// Raw ComfyUI API-graph JSON (`prompt` chunk), when present.
        var comfyPromptJSON: String? = nil
        /// Raw ComfyUI UI workflow JSON (`workflow` chunk), when present.
        var comfyWorkflowJSON: String? = nil

        /// Structured generation parameters (model, sampler, seed, steps, cfg, size).
        var generationParameters: GenerationParameters {
            var params = GenerationParameters(fields: fields)
            if let model, !model.isEmpty { params.model = model }
            return params
        }

        static let empty = Metadata(
            prompt: "",
            negativePrompt: nil,
            model: nil,
            timestamp: nil,
            fields: []
        )
    }

    private struct ParsedParameterBlock {
        let prompt: String
        let negativePrompt: String?
        let parameterFields: [PromptMetadataField]
        let model: String?
    }

    static let shared = ImageMetadataParser()

    private var cache: [String: Metadata] = [:]

    func parse(at url: URL) async -> Metadata {
        let path = url.path
        if let cached = cache[path] {
            return cached
        }

        let parsed = Self.readMetadata(at: url)
        cache[path] = parsed
        return parsed
    }

    func clearCache() {
        cache.removeAll()
    }

    /// Number of parsed files currently held in memory.
    var cachedCount: Int {
        cache.count
    }

    /// Parses a file's embedded metadata without touching the actor's cache. Safe to call from
    /// any thread; used by whole-library indexing.
    static func readMetadataUncached(at url: URL) -> Metadata {
        readMetadata(at: url)
    }

    private static func readMetadata(at url: URL) -> Metadata {
        let ext = url.pathExtension.lowercased()
        guard ext == "png" || ext == "jpg" || ext == "jpeg" else {
            return .empty
        }

        var rawFields: [PromptMetadataField] = []

        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        {
            appendImageIOFields(from: properties, into: &rawFields)
        }

        if let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) {
            switch ext {
            case "png":
                rawFields.append(contentsOf: pngTextFields(from: data))
            case "jpg", "jpeg":
                rawFields.append(contentsOf: jpegSegmentFields(from: data))
            default:
                break
            }
        }

        let dedupedFields = deduplicatedFields(rawFields)
        if dedupedFields.isEmpty {
            return .empty
        }

        var prompt = ""
        var negativePrompt: String?
        var model: String?
        var timestamp: String?
        var displayFields: [PromptMetadataField] = []
        var consumedParameterBlock = false
        var comfyPromptJSON: String?
        var comfyWorkflowJSON: String?

        for field in dedupedFields {
            let canonical = canonicalKey(field.label)

            if !consumedParameterBlock,
               let parameterBlock = parseParameterBlock(from: field.value)
            {
                consumedParameterBlock = true
                if prompt.isEmpty {
                    prompt = parameterBlock.prompt
                }
                if negativePrompt == nil {
                    negativePrompt = parameterBlock.negativePrompt
                }
                if model == nil {
                    model = parameterBlock.model
                }
                if let negativePrompt, !negativePrompt.isEmpty {
                    displayFields.append(PromptMetadataField(label: "Negative Prompt", value: negativePrompt))
                }
                displayFields.append(contentsOf: parameterBlock.parameterFields)
                continue
            }

            if canonical == "prompt", looksLikeJSON(field.value), comfyPromptJSON == nil {
                comfyPromptJSON = field.value
            }
            if canonical == "workflow", looksLikeJSON(field.value), comfyWorkflowJSON == nil {
                comfyWorkflowJSON = field.value
            }

            if prompt.isEmpty,
               canonical == "prompt",
               !looksLikeJSON(field.value)
            {
                prompt = field.value
                continue
            }

            if negativePrompt == nil,
               canonical == "negativeprompt"
            {
                negativePrompt = field.value
            }

            if timestamp == nil,
               isTimestampField(canonical),
               let normalizedTimestamp = normalizedTimestamp(field.value)
            {
                timestamp = normalizedTimestamp
            }

            if model == nil,
               isLikelyAIModelField(canonical)
            {
                model = field.value
            }

            displayFields.append(field)
        }

        if !consumedParameterBlock, comfyPromptJSON != nil || comfyWorkflowJSON != nil {
            let extraction = comfyPromptJSON.flatMap(ComfyUIGraphParser.extract(apiGraphJSON:))
                ?? comfyWorkflowJSON.flatMap(ComfyUIGraphParser.extract(workflowJSON:))
            if let extraction {
                if prompt.isEmpty { prompt = extraction.prompt }
                if negativePrompt == nil, let negative = extraction.negativePrompt, !negative.isEmpty {
                    negativePrompt = negative
                }
                if model == nil { model = extraction.model }
                var comfyFields: [PromptMetadataField] = []
                if let negativePrompt, !negativePrompt.isEmpty {
                    comfyFields.append(PromptMetadataField(label: "Negative Prompt", value: negativePrompt))
                }
                comfyFields.append(contentsOf: extraction.fields)
                displayFields.insert(contentsOf: comfyFields, at: 0)
            }
        }

        var metadata = Metadata(
            prompt: prompt,
            negativePrompt: negativePrompt,
            model: model,
            timestamp: timestamp,
            fields: deduplicatedFields(displayFields)
        )
        metadata.comfyPromptJSON = comfyPromptJSON
        metadata.comfyWorkflowJSON = comfyWorkflowJSON
        return metadata
    }

    private static func appendImageIOFields(from properties: [CFString: Any], into fields: inout [PromptMetadataField]) {
        if let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any] {
            appendField(from: png[kCGImagePropertyPNGComment], label: "Comment", into: &fields)
            appendField(from: png[kCGImagePropertyPNGDescription], label: "Description", into: &fields)
            appendField(from: png[kCGImagePropertyPNGSoftware], label: "Software", into: &fields)
            appendField(from: png[kCGImagePropertyPNGTitle], label: "Title", into: &fields)
            appendField(from: png[kCGImagePropertyPNGCreationTime], label: "Creation Time", into: &fields)
        }

        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            appendField(from: exif[kCGImagePropertyExifUserComment], label: "User Comment", into: &fields)
            appendField(from: exif[kCGImagePropertyExifDateTimeOriginal], label: "Date Time Original", into: &fields)
            appendField(from: exif[kCGImagePropertyExifDateTimeDigitized], label: "Date Time Digitized", into: &fields)
        }

        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            appendField(from: tiff[kCGImagePropertyTIFFImageDescription], label: "Image Description", into: &fields)
            appendField(from: tiff[kCGImagePropertyTIFFSoftware], label: "Software", into: &fields)
            appendField(from: tiff[kCGImagePropertyTIFFDateTime], label: "Date Time", into: &fields)
            appendField(from: tiff[kCGImagePropertyTIFFModel], label: "Camera Model", into: &fields)
        }
    }

    private static func appendField(from rawValue: Any?, label: String, into fields: inout [PromptMetadataField]) {
        guard let value = normalizedString(from: rawValue) else { return }
        fields.append(PromptMetadataField(label: label, value: value))
    }

    private static func normalizedString(from rawValue: Any?) -> String? {
        switch rawValue {
        case let value as String:
            return normalizedText(value)
        case let value as NSString:
            return normalizedText(value as String)
        case let value as Data:
            return decodeTextData(value)
        default:
            return nil
        }
    }

    private static func normalizedText(_ value: String) -> String? {
        let trimmed = value
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func decodeTextData(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }

        let asciiHeader = Data("ASCII\0\0\0".utf8)
        let unicodeHeader = Data("UNICODE\0".utf8)
        let jisHeader = Data("JIS\0\0\0\0\0".utf8)

        if data.starts(with: asciiHeader) {
            return decodeBytes(data.dropFirst(asciiHeader.count), encodings: [.utf8, .ascii, .isoLatin1])
        }

        if data.starts(with: unicodeHeader) {
            return decodeBytes(data.dropFirst(unicodeHeader.count), encodings: [.utf16BigEndian, .utf16LittleEndian, .utf8])
        }

        if data.starts(with: jisHeader) {
            return decodeBytes(data.dropFirst(jisHeader.count), encodings: [.iso2022JP, .utf8, .ascii])
        }

        return decodeBytes(data[...], encodings: [.utf8, .utf16BigEndian, .utf16LittleEndian, .ascii, .isoLatin1])
    }

    private static func decodeBytes<S: DataProtocol>(_ bytes: S, encodings: [String.Encoding]) -> String? {
        let data = Data(bytes)
        for encoding in encodings {
            if let text = String(data: data, encoding: encoding),
               let normalized = normalizedText(text)
            {
                return normalized
            }
        }
        return nil
    }

    private static func pngTextFields(from data: Data) -> [PromptMetadataField] {
        let pngSignature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        guard data.count >= pngSignature.count, Array(data.prefix(pngSignature.count)) == pngSignature else {
            return []
        }

        var fields: [PromptMetadataField] = []
        var offset = pngSignature.count

        while offset + 12 <= data.count {
            let length = readUInt32(from: data, at: offset)
            let typeRange = (offset + 4)..<(offset + 8)
            guard let chunkType = String(data: data.subdata(in: typeRange), encoding: .ascii) else { break }

            let chunkStart = offset + 8
            let chunkEnd = chunkStart + length
            guard chunkEnd + 4 <= data.count else { break }

            let chunkData = data.subdata(in: chunkStart..<chunkEnd)

            switch chunkType {
            case "tEXt":
                if let field = parsePNGTextChunk(chunkData) {
                    fields.append(field)
                }
            case "zTXt":
                if let field = parsePNGCompressedTextChunk(chunkData) {
                    fields.append(field)
                }
            case "iTXt":
                if let field = parsePNGInternationalTextChunk(chunkData) {
                    fields.append(field)
                }
            default:
                break
            }

            offset = chunkEnd + 4
            if chunkType == "IEND" {
                break
            }
        }

        return fields
    }

    private static func parsePNGTextChunk(_ chunkData: Data) -> PromptMetadataField? {
        guard let separator = chunkData.firstIndex(of: 0) else { return nil }
        let keyData = chunkData[..<separator]
        let valueData = chunkData[chunkData.index(after: separator)...]
        guard let key = decodeBytes(keyData, encodings: [.isoLatin1]),
              let value = decodeBytes(valueData, encodings: [.utf8, .isoLatin1])
        else { return nil }

        return PromptMetadataField(label: prettifiedLabel(key), value: value)
    }

    private static func parsePNGCompressedTextChunk(_ chunkData: Data) -> PromptMetadataField? {
        guard let separator = chunkData.firstIndex(of: 0) else { return nil }
        let keyData = chunkData[..<separator]
        let compressionMethodIndex = chunkData.index(after: separator)
        guard compressionMethodIndex < chunkData.endIndex, chunkData[compressionMethodIndex] == 0 else { return nil }
        let compressedStart = chunkData.index(after: compressionMethodIndex)
        let compressedData = Data(chunkData[compressedStart...])

        guard let key = decodeBytes(keyData, encodings: [.isoLatin1]),
              let inflated = inflateZlib(compressedData),
              let value = decodeTextData(inflated)
        else { return nil }

        return PromptMetadataField(label: prettifiedLabel(key), value: value)
    }

    private static func parsePNGInternationalTextChunk(_ chunkData: Data) -> PromptMetadataField? {
        guard let keyEnd = chunkData.firstIndex(of: 0) else { return nil }
        let keyData = chunkData[..<keyEnd]
        var cursor = chunkData.index(after: keyEnd)
        guard cursor < chunkData.endIndex else { return nil }

        let compressionFlag = chunkData[cursor]
        cursor = chunkData.index(after: cursor)
        guard cursor < chunkData.endIndex else { return nil }

        let compressionMethod = chunkData[cursor]
        cursor = chunkData.index(after: cursor)
        guard cursor <= chunkData.endIndex else { return nil }

        guard let languageEnd = chunkData[cursor...].firstIndex(of: 0) else { return nil }
        cursor = chunkData.index(after: languageEnd)
        guard cursor <= chunkData.endIndex else { return nil }

        guard let translatedEnd = chunkData[cursor...].firstIndex(of: 0) else { return nil }
        let translatedKeyData = chunkData[cursor..<translatedEnd]
        cursor = chunkData.index(after: translatedEnd)

        let payload = Data(chunkData[cursor...])
        let valueData: Data
        if compressionFlag == 1 && compressionMethod == 0 {
            guard let inflated = inflateZlib(payload) else { return nil }
            valueData = inflated
        } else {
            valueData = payload
        }

        let key = decodeBytes(translatedKeyData, encodings: [.utf8])
            ?? decodeBytes(keyData, encodings: [.utf8, .isoLatin1])
        guard let key, let value = decodeBytes(valueData, encodings: [.utf8, .isoLatin1]) else { return nil }

        return PromptMetadataField(label: prettifiedLabel(key), value: value)
    }

    private static func jpegSegmentFields(from data: Data) -> [PromptMetadataField] {
        guard data.count > 4, data[0] == 0xFF, data[1] == 0xD8 else { return [] }

        var fields: [PromptMetadataField] = []
        var offset = 2

        while offset + 4 <= data.count {
            guard data[offset] == 0xFF else {
                offset += 1
                continue
            }

            var markerOffset = offset
            while markerOffset < data.count, data[markerOffset] == 0xFF {
                markerOffset += 1
            }
            guard markerOffset < data.count else { break }

            let marker = data[markerOffset]
            offset = markerOffset + 1

            if marker == 0xD9 || marker == 0xDA {
                break
            }

            guard offset + 2 <= data.count else { break }
            let segmentLength = readUInt16(from: data, at: offset)
            offset += 2

            guard segmentLength >= 2, offset + segmentLength - 2 <= data.count else { break }
            let segmentData = data.subdata(in: offset..<(offset + segmentLength - 2))

            if marker == 0xFE,
               let comment = decodeTextData(segmentData)
            {
                fields.append(PromptMetadataField(label: "Comment", value: comment))
            } else if marker == 0xE1,
                      let xmpPacket = xmpPacket(from: segmentData)
            {
                fields.append(contentsOf: xmpFields(from: xmpPacket))
            }

            offset += segmentLength - 2
        }

        return fields
    }

    private static func xmpPacket(from segmentData: Data) -> String? {
        let header = Data("http://ns.adobe.com/xap/1.0/\0".utf8)
        guard segmentData.starts(with: header) else { return nil }
        return decodeBytes(segmentData.dropFirst(header.count), encodings: [.utf8, .utf16BigEndian, .utf16LittleEndian])
    }

    private static func xmpFields(from packet: String) -> [PromptMetadataField] {
        var fields: [PromptMetadataField] = []

        if let description = firstRegexCapture(
            in: packet,
            pattern: #"<dc:description>.*?<rdf:li[^>]*>(.*?)</rdf:li>.*?</dc:description>"#
        ) {
            fields.append(PromptMetadataField(label: "Description", value: decodeXMLText(description)))
        }

        let attributeMappings: [(label: String, pattern: String)] = [
            ("Create Date", #"xmp:CreateDate="([^"]+)""#),
            ("Modify Date", #"xmp:ModifyDate="([^"]+)""#),
            ("Metadata Date", #"xmp:MetadataDate="([^"]+)""#),
            ("Creator Tool", #"xmp:CreatorTool="([^"]+)""#),
        ]

        for mapping in attributeMappings {
            if let value = firstRegexCapture(in: packet, pattern: mapping.pattern) {
                fields.append(PromptMetadataField(label: mapping.label, value: decodeXMLText(value)))
            }
        }

        return fields
    }

    private static func firstRegexCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else {
            return nil
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }

        return normalizedText(String(text[captureRange]))
    }

    private static func decodeXMLText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func parseParameterBlock(from value: String) -> ParsedParameterBlock? {
        let normalized = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.localizedCaseInsensitiveContains("Steps:") else { return nil }

        let lines = normalized
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard let parameterStartIndex = lines.lastIndex(where: { $0.contains("Steps:") }) else {
            return nil
        }

        let promptLines = Array(lines[..<parameterStartIndex])
        let parameterLine = lines[parameterStartIndex...].joined(separator: " ")
        let parameterPairs = parseParameterPairs(from: parameterLine)
        guard !parameterPairs.isEmpty else { return nil }

        var positivePromptLines: [String] = []
        var negativePromptLines: [String] = []
        var readingNegativePrompt = false

        for line in promptLines {
            if !readingNegativePrompt,
               line.lowercased().hasPrefix("negative prompt:")
            {
                readingNegativePrompt = true
                let prefix = line.index(line.startIndex, offsetBy: "Negative prompt:".count)
                let remainder = line[prefix...].trimmingCharacters(in: .whitespaces)
                if !remainder.isEmpty {
                    negativePromptLines.append(remainder)
                }
            } else if readingNegativePrompt {
                negativePromptLines.append(line)
            } else {
                positivePromptLines.append(line)
            }
        }

        let positivePrompt = positivePromptLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let negativePrompt = negativePromptLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = parameterPairs.map { PromptMetadataField(label: $0.0, value: $0.1) }
        let model = parameterPairs.first(where: { canonicalKey($0.0) == "model" || canonicalKey($0.0) == "modelname" })?.1

        return ParsedParameterBlock(
            prompt: positivePrompt,
            negativePrompt: negativePrompt.isEmpty ? nil : negativePrompt,
            parameterFields: fields,
            model: model
        )
    }

    private static func parseParameterPairs(from value: String) -> [(String, String)] {
        let pattern = #"([A-Za-z0-9 _./()-]+):\s*(.*?)(?=,\s+[A-Za-z0-9 _./()-]+:|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        let matches = regex.matches(in: value, range: range)

        return matches.compactMap { match in
            guard let keyRange = Range(match.range(at: 1), in: value),
                  let valueRange = Range(match.range(at: 2), in: value)
            else {
                return nil
            }

            let key = String(value[keyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let parsedValue = String(value[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !parsedValue.isEmpty else { return nil }
            return (key, parsedValue)
        }
    }

    private static func looksLikeJSON(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
    }

    private static func isTimestampField(_ key: String) -> Bool {
        [
            "datetime",
            "datetimeoriginal",
            "datetimedigitized",
            "creationtime",
            "createdate",
            "modifydate",
            "metadatadate",
        ].contains(key)
    }

    private static func isLikelyAIModelField(_ key: String) -> Bool {
        [
            "model",
            "modelname",
            "sdmodel",
            "checkpoint",
        ].contains(key)
    }

    private static func normalizedTimestamp(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: trimmed) {
            return isoFormatter.string(from: date)
        }

        isoFormatter.formatOptions = [.withInternetDateTime]
        if let date = isoFormatter.date(from: trimmed) {
            return isoFormatter.string(from: date)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)

        let formats = [
            "yyyy:MM:dd HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy/MM/dd HH:mm:ss",
        ]

        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return ISO8601DateFormatter().string(from: date)
            }
        }

        return trimmed
    }

    private static func deduplicatedFields(_ fields: [PromptMetadataField]) -> [PromptMetadataField] {
        var seen = Set<String>()
        var result: [PromptMetadataField] = []

        for field in fields {
            guard let normalizedValue = normalizedText(field.value) else { continue }
            let normalizedLabel = normalizedText(field.label) ?? field.label
            let identity = "\(canonicalKey(normalizedLabel))::\(normalizedValue)"
            guard seen.insert(identity).inserted else { continue }
            result.append(PromptMetadataField(label: normalizedLabel, value: normalizedValue))
        }

        return result
    }

    private static func prettifiedLabel(_ rawValue: String) -> String {
        let spaced = rawValue
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(
                of: #"(?<=[a-z0-9])(?=[A-Z])"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !spaced.isEmpty else { return "Metadata" }

        return spaced
            .split(separator: " ")
            .map { token in
                let lowercased = token.lowercased()
                return lowercased.prefix(1).uppercased() + lowercased.dropFirst()
            }
            .joined(separator: " ")
    }

    private static func canonicalKey(_ value: String) -> String {
        value
            .lowercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    private static func readUInt32(from data: Data, at offset: Int) -> Int {
        let bytes = data[offset..<(offset + 4)]
        return bytes.reduce(0) { partialResult, byte in
            (partialResult << 8) | Int(byte)
        }
    }

    private static func readUInt16(from data: Data, at offset: Int) -> Int {
        let bytes = data[offset..<(offset + 2)]
        return bytes.reduce(0) { partialResult, byte in
            (partialResult << 8) | Int(byte)
        }
    }

    /// PNG zTXt/iTXt payloads are full zlib streams (2-byte header + DEFLATE + Adler-32),
    /// which `MetadataZlib` decodes without capping the output size.
    private static func inflateZlib(_ data: Data) -> Data? {
        MetadataZlib.inflate(data)
    }
}

// MARK: - ComfyUI

/// Extracts prompts and sampler settings from ComfyUI's embedded graphs:
/// the API graph (`prompt` chunk: `{ nodeId: { class_type, inputs } }`, links are `["id", slot]`)
/// and, as a fallback, the UI workflow (`workflow` chunk: `{ nodes: [...], links: [...] }`).
enum ComfyUIGraphParser {
    struct Extraction {
        var prompt: String
        var negativePrompt: String?
        var model: String?
        var fields: [PromptMetadataField]
    }

    private typealias Node = [String: Any]

    private static let samplerClasses: Set<String> = [
        "KSampler", "KSamplerAdvanced", "SamplerCustom", "SamplerCustomAdvanced",
        "KSampler (Efficient)", "KSampler Adv. (Efficient)", "KSamplerSDXLAdvanced",
    ]
    /// Inputs that never carry conditioning; not followed when walking a conditioning chain.
    private static let nonConditioningInputs: Set<String> = [
        "clip", "model", "vae", "image", "images", "pixels", "latent", "latent_image", "samples", "mask",
        "control_net", "style_model", "clip_vision", "clip_vision_output", "upscale_model", "noise", "sigmas",
        "sampler", "guider",
    ]
    private static let textKeys = ["text", "text_g", "text_l", "prompt", "positive", "string", "value", "text_positive", "Text", "STRING"]

    // MARK: API graph

    static func extract(apiGraphJSON json: String) -> Extraction? {
        guard let data = json.data(using: .utf8),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        if let wrapped = root["prompt"] as? [String: Any], wrapped.values.contains(where: { ($0 as? Node)?["class_type"] != nil }) {
            root = wrapped
        }
        var graph: [String: Node] = [:]
        for (id, value) in root {
            if let node = value as? Node, node["class_type"] != nil { graph[id] = node }
        }
        guard !graph.isEmpty else { return nil }
        return GraphWalker(graph: graph).extraction()
    }

    private struct GraphWalker {
        let graph: [String: Node]
        let orderedIDs: [String]

        init(graph: [String: Node]) {
            self.graph = graph
            orderedIDs = graph.keys.sorted { a, b in
                switch (Int(a), Int(b)) {
                case let (x?, y?): return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a < b
                }
            }
        }

        func classType(_ id: String) -> String { graph[id]?["class_type"] as? String ?? "" }
        func inputs(_ id: String) -> [String: Any] { graph[id]?["inputs"] as? [String: Any] ?? [:] }

        static func link(_ value: Any?) -> (id: String, slot: Int)? {
            guard let array = value as? [Any], array.count == 2 else { return nil }
            let id: String
            if let s = array[0] as? String { id = s } else if let n = array[0] as? NSNumber { id = n.stringValue } else { return nil }
            guard let slot = (array[1] as? NSNumber)?.intValue else { return nil }
            return (id, slot)
        }

        static func scalarString(_ value: Any?) -> String? {
            switch value {
            case let s as String:
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : t
            case let n as NSNumber:
                if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
                let d = n.doubleValue
                if d.rounded() == d, abs(d) < 1e18 { return String(Int64(d)) }
                return String(format: "%g", d)
            default:
                return nil
            }
        }

        // MARK: Text

        func resolveText(_ value: Any?, depth: Int = 0) -> String? {
            guard depth < 24 else { return nil }
            if let s = value as? String {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : t
            }
            guard let link = Self.link(value), graph[link.id] != nil else { return nil }
            return textOfNode(link.id, depth: depth + 1)
        }

        func textOfNode(_ id: String, depth: Int) -> String? {
            let inputs = inputs(id)
            var parts: [String] = []
            for key in textKeys {
                if let text = resolveText(inputs[key], depth: depth), !parts.contains(text) { parts.append(text) }
            }
            if parts.isEmpty {
                // Generic string nodes (concatenate, text multiline, etc.).
                for key in inputs.keys.sorted() where key.lowercased().contains("text") || key.lowercased().contains("string") {
                    if let text = resolveText(inputs[key], depth: depth), !parts.contains(text) { parts.append(text) }
                }
            }
            if parts.isEmpty {
                // Primitive-style nodes that expose their value in widgets.
                if let text = Self.scalarString(graph[id]?["value"]) { parts.append(text) }
            }
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        }

        // MARK: Conditioning

        func resolveConditioning(_ value: Any?, depth: Int = 0, visited: Set<String> = []) -> [String] {
            guard depth < 32, let link = Self.link(value), graph[link.id] != nil, !visited.contains(link.id) else { return [] }
            var visited = visited
            visited.insert(link.id)
            let cls = classType(link.id)
            let inputs = inputs(link.id)

            if cls.hasPrefix("CLIPTextEncode") || cls.contains("TextEncode") {
                if let text = textOfNode(link.id, depth: depth) { return [text] }
            }
            // Nodes that pass both positive and negative through (ControlNetApplyAdvanced, InstructPix2Pix, ...).
            if inputs["positive"] != nil, inputs["negative"] != nil, Self.link(inputs["positive"]) != nil {
                let key = link.slot == 1 ? "negative" : "positive"
                return resolveConditioning(inputs[key], depth: depth + 1, visited: visited)
            }
            var texts: [String] = []
            for key in inputs.keys.sorted() where !nonConditioningInputs.contains(key) {
                guard Self.link(inputs[key]) != nil else { continue }
                for text in resolveConditioning(inputs[key], depth: depth + 1, visited: visited) where !texts.contains(text) {
                    texts.append(text)
                }
            }
            if texts.isEmpty, let text = textOfNode(link.id, depth: depth), cls.lowercased().contains("prompt") || cls.lowercased().contains("text") {
                texts.append(text)
            }
            return texts
        }

        /// Walks a conditioning chain and returns the first value found for any of `keys` (e.g. FluxGuidance).
        func findInConditioningChain(_ value: Any?, keys: [String], classContains: String, depth: Int = 0) -> String? {
            guard depth < 32, let link = Self.link(value), graph[link.id] != nil else { return nil }
            let inputs = inputs(link.id)
            if classType(link.id).contains(classContains) {
                for key in keys { if let v = Self.scalarString(inputs[key]) { return v } }
            }
            for key in inputs.keys.sorted() where !nonConditioningInputs.contains(key) {
                if let v = findInConditioningChain(inputs[key], keys: keys, classContains: classContains, depth: depth + 1) { return v }
            }
            return nil
        }

        // MARK: Scalars

        /// Value of the first matching key on `id`, following links into upstream nodes
        /// (primitives, RandomNoise, KSamplerSelect, BasicScheduler, CFGGuider...).
        func scalar(_ keys: [String], on id: String, via linkKeys: [String] = [], depth: Int = 0) -> String? {
            guard depth < 8 else { return nil }
            let inputs = inputs(id)
            for key in keys {
                guard let value = inputs[key] else { continue }
                if let s = Self.scalarString(value) { return s }
                if let link = Self.link(value), graph[link.id] != nil {
                    if let s = scalar(keys + ["value", "seed", "int", "float", "number", "Value", "string"], on: link.id, depth: depth + 1) {
                        return s
                    }
                }
            }
            for linkKey in linkKeys {
                if let link = Self.link(inputs[linkKey]), graph[link.id] != nil,
                   let s = scalar(keys, on: link.id, via: [], depth: depth + 1)
                {
                    return s
                }
            }
            return nil
        }

        // MARK: Model / LoRA / size

        func walkModelChain(from value: Any?) -> (model: String?, loras: [String]) {
            var loras: [String] = []
            var current = Self.link(value)
            var visited = Set<String>()
            while let link = current, graph[link.id] != nil, visited.insert(link.id).inserted, visited.count < 64 {
                let inputs = inputs(link.id)
                if let lora = loraDescription(link.id) { loras.append(lora) }
                for key in ["ckpt_name", "unet_name", "model_name", "base_ckpt_name"] {
                    if let name = Self.scalarString(inputs[key]) { return (name, loras) }
                }
                current = Self.link(inputs["model"]) ?? Self.link(inputs["base_model"])
            }
            return (nil, loras)
        }

        func loraDescription(_ id: String) -> String? {
            let inputs = inputs(id)
            guard let name = Self.scalarString(inputs["lora_name"]) else { return nil }
            let strength = Self.scalarString(inputs["strength_model"]) ?? Self.scalarString(inputs["strength"])
            let clip = Self.scalarString(inputs["strength_clip"])
            var description = name
            if let strength {
                description += clip.map { $0 == strength ? " (\(strength))" : " (\(strength)/\($0))" } ?? " (\(strength))"
            }
            return description
        }

        func size(from latentValue: Any?) -> (String, String)? {
            var current = Self.link(latentValue)
            var visited = Set<String>()
            while let link = current, graph[link.id] != nil, visited.insert(link.id).inserted, visited.count < 32 {
                if let w = scalar(["width"], on: link.id), let h = scalar(["height"], on: link.id) { return (w, h) }
                let inputs = inputs(link.id)
                current = Self.link(inputs["samples"]) ?? Self.link(inputs["latent"]) ?? Self.link(inputs["latent_image"])
            }
            return nil
        }

        // MARK: Extraction

        func samplerCandidates() -> [String] {
            let known = orderedIDs.filter { samplerClasses.contains(classType($0)) }
            let generic = orderedIDs.filter { id in
                guard !known.contains(id) else { return false }
                let inputs = inputs(id)
                let cls = classType(id)
                let hasCond = inputs["positive"] != nil || inputs["guider"] != nil
                let samplerLike = inputs["seed"] != nil || inputs["noise_seed"] != nil || inputs["steps"] != nil
                    || inputs["guider"] != nil || cls.lowercased().contains("sampler")
                return hasCond && samplerLike
            }
            let guiders = orderedIDs.filter { id in
                !known.contains(id) && !generic.contains(id) && classType(id).contains("Guider") && inputs(id)["model"] != nil
            }
            return known + generic + guiders
        }

        func extraction() -> Extraction? {
            var chosen: (id: String, positive: String, negative: String?, guider: String?)?
            for id in samplerCandidates() {
                let inputs = inputs(id)
                var positiveSource = inputs["positive"]
                var negativeSource = inputs["negative"]
                var guiderID: String?
                if positiveSource == nil, let guider = Self.link(inputs["guider"]), graph[guider.id] != nil {
                    guiderID = guider.id
                    let g = self.inputs(guider.id)
                    positiveSource = g["positive"] ?? g["conditioning"]
                    negativeSource = g["negative"]
                } else if classType(id).contains("Guider") {
                    guiderID = id
                    positiveSource = inputs["positive"] ?? inputs["conditioning"]
                }
                let positive = resolveConditioning(positiveSource).joined(separator: "\n")
                guard !positive.isEmpty else { continue }
                let negative = resolveConditioning(negativeSource).joined(separator: "\n")
                chosen = (id, positive, negative.isEmpty ? nil : negative, guiderID)
                break
            }

            if chosen == nil {
                // No resolvable sampler: fall back to text encoders in node order.
                let encoders = orderedIDs.filter { classType($0).hasPrefix("CLIPTextEncode") }
                    .compactMap { textOfNode($0, depth: 0) }
                guard let first = encoders.first else { return nil }
                return Extraction(
                    prompt: first,
                    negativePrompt: encoders.dropFirst().first,
                    model: fallbackModel(),
                    fields: [PromptMetadataField(label: "Generator", value: "ComfyUI")]
                )
            }
            guard let chosen else { return nil }

            let samplerID = chosen.id
            let samplerInputs = inputs(samplerID)
            var fields: [PromptMetadataField] = []

            let seed = scalar(["seed", "noise_seed"], on: samplerID, via: ["noise"])
            let steps = scalar(["steps"], on: samplerID, via: ["sigmas"])
            var cfg = scalar(["cfg"], on: samplerID, via: ["guider"])
            let samplerName = scalar(["sampler_name"], on: samplerID, via: ["sampler"])
            let scheduler = scalar(["scheduler"], on: samplerID, via: ["sigmas"])
            let denoise = scalar(["denoise"], on: samplerID, via: ["sigmas"])
            let guidance = findInConditioningChain(
                chosen.guider.map { inputs($0)["conditioning"] ?? inputs($0)["positive"] as Any } ?? samplerInputs["positive"],
                keys: ["guidance"],
                classContains: "Guidance"
            )
            if cfg == nil, let guider = chosen.guider { cfg = Self.scalarString(inputs(guider)["cfg"]) }

            let modelSource = samplerInputs["model"] ?? chosen.guider.flatMap { inputs($0)["model"] }
            var (model, loras) = walkModelChain(from: modelSource)
            if model == nil { model = fallbackModel() }
            if loras.isEmpty {
                loras = orderedIDs.filter { classType($0).hasPrefix("LoraLoader") || classType($0).contains("Lora") }
                    .compactMap { loraDescription($0) }
            }
            let size = size(from: samplerInputs["latent_image"]) ?? fallbackSize()

            if let steps { fields.append(.init(label: "Steps", value: steps)) }
            if let samplerName { fields.append(.init(label: "Sampler", value: samplerName)) }
            if let scheduler { fields.append(.init(label: "Scheduler", value: scheduler)) }
            if let cfg { fields.append(.init(label: "CFG scale", value: cfg)) }
            if let guidance { fields.append(.init(label: "Guidance", value: guidance)) }
            if let seed { fields.append(.init(label: "Seed", value: seed)) }
            if let size { fields.append(.init(label: "Size", value: "\(size.0)x\(size.1)")) }
            if let model { fields.append(.init(label: "Model", value: model)) }
            if let denoise, denoise != "1" { fields.append(.init(label: "Denoising strength", value: denoise)) }
            if !loras.isEmpty { fields.append(.init(label: "LoRAs", value: loras.joined(separator: ", "))) }
            fields.append(.init(label: "Generator", value: "ComfyUI"))

            return Extraction(prompt: chosen.positive, negativePrompt: chosen.negative, model: model, fields: fields)
        }

        func fallbackModel() -> String? {
            for id in orderedIDs {
                let inputs = inputs(id)
                for key in ["ckpt_name", "unet_name"] {
                    if let name = Self.scalarString(inputs[key]) { return name }
                }
            }
            return nil
        }

        func fallbackSize() -> (String, String)? {
            for id in orderedIDs where classType(id).contains("EmptyLatent") || classType(id).contains("EmptySD3Latent") {
                if let w = scalar(["width"], on: id), let h = scalar(["height"], on: id) { return (w, h) }
            }
            return nil
        }
    }

    // MARK: UI workflow (best effort)

    static func extract(workflowJSON json: String) -> Extraction? {
        guard let data = json.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let nodeList = root["nodes"] as? [[String: Any]]
        else { return nil }

        var nodes: [Int: [String: Any]] = [:]
        for node in nodeList {
            if let id = (node["id"] as? NSNumber)?.intValue { nodes[id] = node }
        }
        // link id -> origin node id
        var linkOrigin: [Int: (node: Int, slot: Int)] = [:]
        for case let link as [Any] in (root["links"] as? [Any] ?? []) where link.count >= 3 {
            if let linkID = (link[0] as? NSNumber)?.intValue,
               let from = (link[1] as? NSNumber)?.intValue,
               let slot = (link[2] as? NSNumber)?.intValue
            {
                linkOrigin[linkID] = (from, slot)
            }
        }
        for case let link as [String: Any] in (root["links"] as? [Any] ?? []) {
            if let linkID = (link["id"] as? NSNumber)?.intValue,
               let from = (link["origin_id"] as? NSNumber)?.intValue
            {
                linkOrigin[linkID] = (from, (link["origin_slot"] as? NSNumber)?.intValue ?? 0)
            }
        }

        func type(_ id: Int) -> String { nodes[id]?["type"] as? String ?? "" }
        func widgets(_ id: Int) -> [Any] { nodes[id]?["widgets_values"] as? [Any] ?? [] }
        func inputLink(_ id: Int, named name: String) -> (node: Int, slot: Int)? {
            guard let inputs = nodes[id]?["inputs"] as? [[String: Any]],
                  let input = inputs.first(where: { ($0["name"] as? String) == name }),
                  let linkID = (input["link"] as? NSNumber)?.intValue
            else { return nil }
            return linkOrigin[linkID]
        }
        func widgetString(_ id: Int, _ index: Int) -> String? {
            let values = widgets(id)
            guard index < values.count else { return nil }
            return GraphWalker.scalarString(values[index])
        }
        func text(of id: Int, depth: Int = 0) -> String? {
            guard depth < 24, nodes[id] != nil else { return nil }
            let cls = type(id)
            if cls.hasPrefix("CLIPTextEncode") || cls.contains("TextEncode") {
                if let upstream = inputLink(id, named: "text"), let t = text(of: upstream.node, depth: depth + 1) { return t }
                let strings = widgets(id).compactMap { $0 as? String }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                var unique: [String] = []
                for s in strings where !unique.contains(s) { unique.append(s) }
                // CLIPTextEncodeSDXL widgets mix numbers and text_g/text_l; keep the text ones.
                return unique.isEmpty ? nil : unique.joined(separator: "\n")
            }
            if cls.contains("Primitive") || cls.lowercased().contains("string") || cls.lowercased().contains("text") {
                if let s = widgets(id).compactMap({ $0 as? String }).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                    return s.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            // Pass-through conditioning node: follow its conditioning-typed inputs.
            if let inputs = nodes[id]?["inputs"] as? [[String: Any]] {
                for input in inputs where (input["type"] as? String) == "CONDITIONING" {
                    if let linkID = (input["link"] as? NSNumber)?.intValue,
                       let origin = linkOrigin[linkID],
                       let t = text(of: origin.node, depth: depth + 1)
                    {
                        return t
                    }
                }
            }
            return nil
        }

        let orderedIDs = nodes.keys.sorted()
        var fields: [PromptMetadataField] = []
        var positive: String?
        var negative: String?

        let samplerID = orderedIDs.first { samplerClasses.contains(type($0)) }
        if let samplerID {
            if let origin = inputLink(samplerID, named: "positive") { positive = text(of: origin.node) }
            if let origin = inputLink(samplerID, named: "negative") { negative = text(of: origin.node) }

            // KSampler: [seed, control_after_generate, steps, cfg, sampler_name, scheduler, denoise]
            // KSamplerAdvanced: [add_noise, noise_seed, control, steps, cfg, sampler_name, scheduler, start, end, return_noise]
            let offset = type(samplerID) == "KSamplerAdvanced" ? 1 : 0
            let values = widgets(samplerID)
            if values.count >= 6 + offset {
                if let seed = widgetString(samplerID, 0 + offset) { fields.append(.init(label: "Seed", value: seed)) }
                // Older workflows omit control_after_generate; detect by type of index 1+offset.
                let hasControl = values.count > 1 + offset && values[1 + offset] is String
                let base = hasControl ? 2 + offset : 1 + offset
                if let steps = widgetString(samplerID, base) { fields.append(.init(label: "Steps", value: steps)) }
                if let cfg = widgetString(samplerID, base + 1) { fields.append(.init(label: "CFG scale", value: cfg)) }
                if let sampler = widgetString(samplerID, base + 2) { fields.append(.init(label: "Sampler", value: sampler)) }
                if let scheduler = widgetString(samplerID, base + 3) { fields.append(.init(label: "Scheduler", value: scheduler)) }
                if offset == 0, let denoise = widgetString(samplerID, base + 4), denoise != "1" {
                    fields.append(.init(label: "Denoising strength", value: denoise))
                }
            }
        }

        let encoders = orderedIDs.filter { type($0).hasPrefix("CLIPTextEncode") }
        if positive == nil { positive = encoders.first.flatMap { text(of: $0) } }
        if negative == nil, samplerID == nil { negative = encoders.dropFirst().first.flatMap { text(of: $0) } }
        guard let positive, !positive.isEmpty else { return nil }

        if let latent = orderedIDs.first(where: { type($0).contains("EmptyLatent") || type($0).contains("EmptySD3Latent") }),
           let w = widgetString(latent, 0), let h = widgetString(latent, 1)
        {
            fields.append(.init(label: "Size", value: "\(w)x\(h)"))
        }
        let model = orderedIDs
            .first { ["CheckpointLoaderSimple", "CheckpointLoader", "UNETLoader", "CheckpointLoader|pysssss"].contains(type($0)) || type($0).hasPrefix("CheckpointLoader") }
            .flatMap { id in widgets(id).compactMap { $0 as? String }.first }
        if let model { fields.append(.init(label: "Model", value: model)) }
        let loras = orderedIDs.filter { type($0).hasPrefix("LoraLoader") }.compactMap { id -> String? in
            guard let name = widgetString(id, 0) else { return nil }
            if let strength = widgetString(id, 1) { return "\(name) (\(strength))" }
            return name
        }
        if !loras.isEmpty { fields.append(.init(label: "LoRAs", value: loras.joined(separator: ", "))) }
        fields.append(.init(label: "Generator", value: "ComfyUI"))

        return Extraction(prompt: positive, negativePrompt: negative, model: model, fields: fields)
    }
}
