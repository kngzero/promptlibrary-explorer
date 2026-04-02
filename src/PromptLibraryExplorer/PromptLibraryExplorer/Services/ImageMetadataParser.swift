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

        return Metadata(
            prompt: prompt,
            negativePrompt: negativePrompt,
            model: model,
            timestamp: timestamp,
            fields: deduplicatedFields(displayFields)
        )
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

    private static func inflateZlib(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }

        let outputCapacity = max(data.count * 32, 4096)
        var output = Data(count: outputCapacity)

        let decodedSize = output.withUnsafeMutableBytes { destinationBuffer in
            data.withUnsafeBytes { sourceBuffer in
                guard let destinationBase = destinationBuffer.bindMemory(to: UInt8.self).baseAddress,
                      let sourceBase = sourceBuffer.bindMemory(to: UInt8.self).baseAddress
                else {
                    return 0
                }

                return compression_decode_buffer(
                    destinationBase,
                    destinationBuffer.count,
                    sourceBase,
                    sourceBuffer.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }

        guard decodedSize > 0 else { return nil }
        output.removeSubrange(decodedSize..<output.count)
        return output
    }
}
