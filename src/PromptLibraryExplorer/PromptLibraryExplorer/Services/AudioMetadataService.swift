import Foundation

// MARK: - Container Parsing (shared by reader and writer)

/// A RIFF chunk located by its payload range (offsets relative to the start of the file data).
fileprivate struct AudioWAVChunk {
    let id: String
    let payload: Range<Int>
}

fileprivate enum AudioBinary {
    /// Slices using offsets relative to the start of `data`.
    static func slice(_ data: Data, _ range: Range<Int>) -> Data {
        data[(data.startIndex + range.lowerBound)..<(data.startIndex + range.upperBound)]
    }

    static func byte(_ data: Data, _ offset: Int) -> UInt8 {
        data[data.startIndex + offset]
    }

    static func uint32BE(_ data: Data, at offset: Int) -> Int {
        (0..<4).reduce(0) { ($0 << 8) | Int(byte(data, offset + $1)) }
    }

    static func uint24BE(_ data: Data, at offset: Int) -> Int {
        (0..<3).reduce(0) { ($0 << 8) | Int(byte(data, offset + $1)) }
    }

    static func uint32LE(_ data: Data, at offset: Int) -> Int {
        (0..<4).reduce(0) { $0 | (Int(byte(data, offset + $1)) << ($1 * 8)) }
    }

    static func syncsafe(_ data: Data, at offset: Int) -> Int {
        (0..<4).reduce(0) { ($0 << 7) | Int(byte(data, offset + $1) & 0x7F) }
    }

    static func isSyncsafe(_ data: Data, at offset: Int) -> Bool {
        (0..<4).allSatisfy { byte(data, offset + $0) & 0x80 == 0 }
    }

    static func syncsafeData(for value: Int) -> Data {
        Data([
            UInt8((value >> 21) & 0x7F),
            UInt8((value >> 14) & 0x7F),
            UInt8((value >> 7) & 0x7F),
            UInt8(value & 0x7F),
        ])
    }

    static func bigEndianData(for value: Int) -> Data {
        var value = UInt32(value).bigEndian
        return Data(bytes: &value, count: MemoryLayout<UInt32>.size)
    }

    static func littleEndianData(for value: Int) -> Data {
        var value = UInt32(value).littleEndian
        return Data(bytes: &value, count: MemoryLayout<UInt32>.size)
    }

    /// Reverses ID3 unsynchronisation (FF 00 -> FF).
    static func removingUnsynchronisation(_ data: Data) -> Data {
        var output = Data()
        output.reserveCapacity(data.count)
        var previousWasFF = false
        for byte in data {
            if previousWasFF && byte == 0 {
                previousWasFF = false
                continue
            }
            output.append(byte)
            previousWasFF = byte == 0xFF
        }
        return output
    }
}

fileprivate enum AudioWAVLayout {
    /// Walks the RIFF chunks of a WAVE file.
    ///
    /// An oversized final `data` chunk (e.g. size 0xFFFFFFFF from a streaming recorder, or a
    /// truncated file) is clamped to end-of-file. In `strict` mode (used before writing) the walk
    /// must reach end-of-file cleanly — allowing only a single pad byte — and a `data` chunk must
    /// be present; otherwise it throws so nothing is written. Non-strict mode (reading) returns
    /// whatever chunks it could parse.
    static func parse(_ data: Data, strict: Bool) throws -> [AudioWAVChunk] {
        guard data.count >= 12,
              AudioBinary.slice(data, 0..<4) == Data("RIFF".utf8),
              AudioBinary.slice(data, 8..<12) == Data("WAVE".utf8)
        else {
            throw AudioMetadataWriter.WriterError.invalidWAV
        }

        var chunks: [AudioWAVChunk] = []
        var offset = 12

        while offset + 8 <= data.count {
            let idBytes = AudioBinary.slice(data, offset..<(offset + 4))
            guard idBytes.allSatisfy({ (0x20...0x7E).contains($0) }),
                  let chunkID = String(data: idBytes, encoding: .ascii)
            else {
                if strict { throw AudioMetadataWriter.WriterError.malformedWAV("invalid chunk ID at byte \(offset)") }
                break
            }

            var chunkSize = AudioBinary.uint32LE(data, at: offset + 4)
            let dataStart = offset + 8
            if dataStart + chunkSize > data.count {
                if chunkID == "data" {
                    chunkSize = data.count - dataStart
                } else {
                    if strict { throw AudioMetadataWriter.WriterError.malformedWAV("\(chunkID) chunk overruns the file") }
                    break
                }
            }

            chunks.append(AudioWAVChunk(id: chunkID, payload: dataStart..<(dataStart + chunkSize)))
            offset = dataStart + chunkSize + (chunkSize % 2)
        }

        if strict {
            // offset == count + 1 means the final odd-sized chunk is missing its pad byte.
            let remaining = data.count - offset
            guard remaining == 0 || remaining == 1 || remaining == -1 else {
                throw AudioMetadataWriter.WriterError.malformedWAV("\(remaining) unexpected byte(s) at the end of the file")
            }
            guard chunks.contains(where: { $0.id == "data" }) else {
                throw AudioMetadataWriter.WriterError.malformedWAV("no data chunk")
            }
        }

        return chunks
    }

    /// Parses the sub-chunks of a LIST/INFO payload (payload starts with "INFO").
    static func infoItems(in data: Data, list: AudioWAVChunk, strict: Bool) throws -> [AudioWAVChunk] {
        var items: [AudioWAVChunk] = []
        var offset = list.payload.lowerBound + 4
        let end = list.payload.upperBound

        while offset + 8 <= end {
            let idBytes = AudioBinary.slice(data, offset..<(offset + 4))
            guard idBytes.allSatisfy({ (0x20...0x7E).contains($0) }),
                  let itemID = String(data: idBytes, encoding: .ascii)
            else {
                if strict { throw AudioMetadataWriter.WriterError.malformedWAV("invalid INFO item") }
                break
            }

            let itemSize = AudioBinary.uint32LE(data, at: offset + 4)
            let dataStart = offset + 8
            guard dataStart + itemSize <= end else {
                if strict { throw AudioMetadataWriter.WriterError.malformedWAV("\(itemID) INFO item overruns its list") }
                break
            }

            items.append(AudioWAVChunk(id: itemID, payload: dataStart..<(dataStart + itemSize)))
            offset = dataStart + itemSize + (itemSize % 2)
        }

        if strict, end - offset > 1 {
            throw AudioMetadataWriter.WriterError.malformedWAV("trailing bytes in INFO list")
        }
        return items
    }

    static func isInfoList(_ chunk: AudioWAVChunk, in data: Data) -> Bool {
        chunk.id == "LIST"
            && chunk.payload.count >= 4
            && AudioBinary.slice(data, chunk.payload.lowerBound..<(chunk.payload.lowerBound + 4)) == Data("INFO".utf8)
    }
}

/// A raw ID3v2 frame. `payload` is exactly the frame body as stored (not decoded), so
/// frames the writer doesn't edit can be re-emitted byte-for-byte.
fileprivate struct ID3Frame {
    let id: String
    let flags: Data // 2 bytes for v2.3/v2.4, empty for v2.2
    let payload: Data
}

fileprivate struct ID3Tag {
    let majorVersion: Int
    let frames: [ID3Frame]
    /// Offset where the audio (everything after the tag, including any footer) begins.
    let tagEnd: Int

    /// Parses an ID3v2 tag at the start of `data`. Returns nil if there's no tag.
    ///
    /// Handles v2.2 (3-char IDs, 3-byte sizes), v2.3 (plain sizes), and v2.4 (syncsafe sizes,
    /// with a fallback for writers that stored plain sizes), tag-level unsynchronisation, the
    /// extended header and the v2.4 footer. In `strict` mode any structural problem throws;
    /// otherwise the frames parsed so far are returned.
    static func parse(_ data: Data, strict: Bool) throws -> ID3Tag? {
        guard data.count >= 10, AudioBinary.slice(data, 0..<3) == Data("ID3".utf8) else { return nil }

        func fail(_ detail: String) throws -> ID3Tag? {
            if strict { throw AudioMetadataWriter.WriterError.malformedID3(detail) }
            return nil
        }

        let version = Int(AudioBinary.byte(data, 3))
        let flags = AudioBinary.byte(data, 5)
        guard (2...4).contains(version) else { return try fail("unsupported ID3v2.\(version) tag") }
        guard AudioBinary.isSyncsafe(data, at: 6) else { return try fail("invalid tag size") }

        let size = AudioBinary.syncsafe(data, at: 6)
        let hasFooter = version == 4 && flags & 0x10 != 0
        var tagEnd = 10 + size + (hasFooter ? 10 : 0)
        if tagEnd > data.count {
            if strict { throw AudioMetadataWriter.WriterError.malformedID3("tag is larger than the file") }
            tagEnd = data.count
        }

        var body = AudioBinary.slice(data, 10..<min(10 + size, data.count))
        if flags & 0x80 != 0, version < 4 {
            body = AudioBinary.removingUnsynchronisation(body)
        }

        var cursor = 0
        if flags & 0x40 != 0 {
            switch version {
            case 2:
                // In v2.2 this bit means the whole tag is compressed, which no one supports.
                return try fail("compressed ID3v2.2 tag")
            case 3:
                guard body.count >= 4 else { return try fail("truncated extended header") }
                cursor = 4 + AudioBinary.uint32BE(body, at: 0)
            default:
                guard body.count >= 4 else { return try fail("truncated extended header") }
                cursor = AudioBinary.syncsafe(body, at: 0)
            }
            guard cursor <= body.count else { return try fail("extended header overruns the tag") }
        }

        if let frames = walkFrames(body, from: cursor, version: version, syncsafeSizes: version == 4) {
            return ID3Tag(majorVersion: version, frames: frames, tagEnd: tagEnd)
        }
        // Some encoders (notably older iTunes) wrote v2.4 tags with plain frame sizes.
        if version == 4, let frames = walkFrames(body, from: cursor, version: version, syncsafeSizes: false) {
            return ID3Tag(majorVersion: version, frames: frames, tagEnd: tagEnd)
        }

        if strict { throw AudioMetadataWriter.WriterError.malformedID3("frame list couldn't be walked") }
        let partial = walkFrames(body, from: cursor, version: version, syncsafeSizes: version == 4, lenient: true)
        return ID3Tag(majorVersion: version, frames: partial ?? [], tagEnd: tagEnd)
    }

    /// Returns nil if the walk hits a malformed frame (unless `lenient`, which returns what it got).
    private static func walkFrames(
        _ body: Data,
        from start: Int,
        version: Int,
        syncsafeSizes: Bool,
        lenient: Bool = false
    ) -> [ID3Frame]? {
        let idLength = version == 2 ? 3 : 4
        let headerLength = version == 2 ? 6 : 10
        var frames: [ID3Frame] = []
        var offset = start

        while offset + headerLength <= body.count {
            // Padding: the rest of the tag is zeros.
            if AudioBinary.byte(body, offset) == 0 { break }

            let idBytes = AudioBinary.slice(body, offset..<(offset + idLength))
            guard idBytes.allSatisfy({ (0x41...0x5A).contains($0) || (0x30...0x39).contains($0) }),
                  let frameID = String(data: idBytes, encoding: .ascii)
            else {
                return lenient ? frames : nil
            }

            let frameSize: Int
            let frameFlags: Data
            if version == 2 {
                frameSize = AudioBinary.uint24BE(body, at: offset + 3)
                frameFlags = Data()
            } else {
                if syncsafeSizes {
                    guard AudioBinary.isSyncsafe(body, at: offset + 4) else { return lenient ? frames : nil }
                    frameSize = AudioBinary.syncsafe(body, at: offset + 4)
                } else {
                    frameSize = AudioBinary.uint32BE(body, at: offset + 4)
                }
                frameFlags = Data(AudioBinary.slice(body, (offset + 8)..<(offset + 10)))
            }

            let payloadStart = offset + headerLength
            guard payloadStart + frameSize <= body.count else { return lenient ? frames : nil }

            frames.append(ID3Frame(
                id: frameID,
                flags: frameFlags,
                payload: AudioBinary.slice(body, payloadStart..<(payloadStart + frameSize))
            ))
            offset = payloadStart + frameSize
        }

        return frames
    }

    /// The frame body with per-frame encodings removed, for display. Nil when it can't be decoded
    /// (compressed or encrypted frames).
    static func readablePayload(of frame: ID3Frame, version: Int) -> Data? {
        guard frame.flags.count == 2 else { return frame.payload }
        let format = AudioBinary.byte(frame.flags, 1)
        var payload = frame.payload

        if version == 3 {
            guard format & 0xC0 == 0 else { return nil } // compression / encryption
            if format & 0x20 != 0 { payload = payload.dropFirst(1) } // grouping ID
            return payload
        }

        guard format & 0x0C == 0 else { return nil } // compression / encryption
        if format & 0x40 != 0 { payload = payload.dropFirst(1) } // grouping ID
        if format & 0x02 != 0 { payload = AudioBinary.removingUnsynchronisation(payload) }
        if format & 0x01 != 0 { payload = payload.dropFirst(4) } // data length indicator
        return payload
    }

    /// v2.2 frame IDs with the v2.3 equivalents whose body format is identical
    /// (PIC is converted separately).
    static let v22FrameIDMap: [String: String] = [
        "TT1": "TIT1", "TT2": "TIT2", "TT3": "TIT3",
        "TP1": "TPE1", "TP2": "TPE2", "TP3": "TPE3", "TP4": "TPE4",
        "TAL": "TALB", "TYE": "TYER", "TDA": "TDAT", "TIM": "TIME", "TRD": "TRDA",
        "TRK": "TRCK", "TPA": "TPOS", "TCO": "TCON", "TCM": "TCOM", "TCR": "TCOP",
        "TEN": "TENC", "TSS": "TSSE", "TXT": "TEXT", "TLA": "TLAN", "TLE": "TLEN",
        "TBP": "TBPM", "TKE": "TKEY", "TMT": "TMED", "TOA": "TOPE", "TOF": "TOFN",
        "TOL": "TOLY", "TOR": "TORY", "TOT": "TOAL", "TPB": "TPUB", "TRC": "TSRC",
        "TSI": "TSIZ", "TFT": "TFLT", "TDY": "TDLY", "TXX": "TXXX",
        "TCP": "TCMP", "TS2": "TSO2", "TSA": "TSOA", "TSC": "TSOC", "TSP": "TSOP", "TST": "TSOT",
        "COM": "COMM", "ULT": "USLT", "WXX": "WXXX",
        "WAF": "WOAF", "WAR": "WOAR", "WAS": "WOAS", "WCM": "WCOM", "WCP": "WCOP", "WPB": "WPUB",
        "UFI": "UFID", "CNT": "PCNT", "POP": "POPM", "GEO": "GEOB", "MCI": "MCDI",
        "ETC": "ETCO", "SLT": "SYLT", "STC": "SYTC", "IPL": "IPLS", "RVA": "RVAD",
        "EQU": "EQUA", "REV": "RVRB", "BUF": "RBUF", "CRA": "AENC",
    ]

    /// Converts a v2.2 frame to its v2.3 form, or nil if there's no safe conversion.
    static func convertedFromV22(_ frame: ID3Frame) -> ID3Frame? {
        if frame.id == "PIC" {
            // PIC: enc, 3-char image format, picture type, description, data
            // APIC: enc, MIME type (Latin-1, NUL-terminated), picture type, description, data
            guard frame.payload.count >= 5 else { return nil }
            let format = String(data: AudioBinary.slice(frame.payload, 1..<4), encoding: .isoLatin1)?
                .trimmingCharacters(in: .whitespaces)
                .uppercased() ?? ""
            let mime: String
            switch format {
            case "JPG", "JPEG": mime = "image/jpeg"
            case "PNG": mime = "image/png"
            case "-->": mime = "-->"
            default: mime = "image/\(format.lowercased())"
            }
            var payload = Data([AudioBinary.byte(frame.payload, 0)])
            payload.append(Data(mime.utf8))
            payload.append(0)
            payload.append(AudioBinary.slice(frame.payload, 4..<frame.payload.count))
            return ID3Frame(id: "APIC", flags: Data([0, 0]), payload: payload)
        }

        guard let id = v22FrameIDMap[frame.id] else { return nil }
        return ID3Frame(id: id, flags: Data([0, 0]), payload: frame.payload)
    }
}

struct AudioTagMetadata {
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    var genre: String = ""
    var trackNumber: String = ""
    var date: String = ""
    var comment: String = ""
    var copyright: String = ""

    static let empty = AudioTagMetadata()

    var isEmpty: Bool {
        [
            title,
            artist,
            album,
            genre,
            trackNumber,
            date,
            comment,
            copyright,
        ].allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

actor AudioMetadataParser {
    struct Metadata {
        let tags: AudioTagMetadata
        let fields: [PromptMetadataField]
        let searchText: String

        static let empty = Metadata(
            tags: .empty,
            fields: [],
            searchText: ""
        )
    }

    static let shared = AudioMetadataParser()

    private var cache: [String: Metadata] = [:]

    func parse(at url: URL) async -> Metadata {
        let path = url.path
        if let cached = cache[path] {
            return cached
        }
        // Online-only cloud file: nothing to show until it's downloaded (not cached).
        guard CloudFileStatus.isLocallyAvailable(url) else { return .empty }

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

    private static func readMetadata(at url: URL) -> Metadata {
        let ext = url.pathExtension.lowercased()

        let rawFields: [PromptMetadataField]
        switch ext {
        case "mp3":
            rawFields = readMP3Fields(at: url)
        case "wav":
            rawFields = readWAVFields(at: url)
        default:
            rawFields = []
        }

        let dedupedFields = deduplicatedFields(rawFields)
        guard !dedupedFields.isEmpty else {
            return .empty
        }

        return Metadata(
            tags: extractedTags(from: dedupedFields),
            fields: dedupedFields,
            searchText: buildSearchText(from: dedupedFields)
        )
    }

    private static func readMP3Fields(at url: URL) -> [PromptMetadataField] {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              let tag = try? ID3Tag.parse(data, strict: false)
        else {
            return []
        }

        var fields: [PromptMetadataField] = []
        for frame in tag.frames {
            // v2.2 frames use 3-character IDs; map them to their v2.3 equivalents.
            let frameID = tag.majorVersion == 2 ? ID3Tag.v22FrameIDMap[frame.id] : frame.id
            guard let frameID,
                  let payload = ID3Tag.readablePayload(of: frame, version: tag.majorVersion)
            else {
                continue
            }
            fields.append(contentsOf: parseID3Frame(id: frameID, data: Data(payload)))
        }

        return fields
    }

    private static func parseID3Frame(id: String, data: Data) -> [PromptMetadataField] {
        guard !data.isEmpty else { return [] }

        switch id {
        case "COMM":
            guard let value = decodeID3CommentFrame(data) else { return [] }
            return [PromptMetadataField(label: "Comment", value: value)]
        default:
            guard let label = id3Label(for: id),
                  let value = decodeID3TextFrame(data)
            else {
                return []
            }
            return [PromptMetadataField(label: label, value: value)]
        }
    }

    private static func readWAVFields(at url: URL) -> [PromptMetadataField] {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              let chunks = try? AudioWAVLayout.parse(data, strict: false)
        else {
            return []
        }

        var fields: [PromptMetadataField] = []

        for chunk in chunks where AudioWAVLayout.isInfoList(chunk, in: data) {
            guard let items = try? AudioWAVLayout.infoItems(in: data, list: chunk, strict: false) else { continue }
            for item in items {
                if let label = wavInfoLabel(for: item.id),
                   let value = normalizedText(decodeWAVInfoString(AudioBinary.slice(data, item.payload)))
                {
                    fields.append(PromptMetadataField(label: label, value: value))
                }
            }
        }

        return fields
    }

    private static func decodeID3TextFrame(_ data: Data) -> String? {
        guard let encoding = id3Encoding(for: data[0]) else { return nil }
        return decodeID3Bytes(data.dropFirst(), encoding: encoding)
    }

    private static func decodeID3CommentFrame(_ data: Data) -> String? {
        guard data.count > 4,
              let encoding = id3Encoding(for: data[0])
        else {
            return nil
        }

        let payload = Data(data.dropFirst(4))
        guard let split = splitID3SeparatedData(payload, encoding: encoding) else {
            return decodeID3Bytes(payload, encoding: encoding)
        }

        return normalizedText(split.value)
    }

    private static func splitID3SeparatedData(_ data: Data, encoding: String.Encoding) -> (description: String, value: String)? {
        let separatorLength = id3SeparatorLength(for: encoding)
        var index = 0

        while index + separatorLength <= data.count {
            if separatorLength == 1 {
                if data[index] == 0 {
                    let descriptionData = data.prefix(index)
                    let valueData = data.dropFirst(index + separatorLength)
                    let description = decodeID3Bytes(descriptionData, encoding: encoding) ?? ""
                    let value = decodeID3Bytes(valueData, encoding: encoding) ?? ""
                    return (description, value)
                }
            } else if data[index] == 0 && data[index + 1] == 0 {
                let descriptionData = data.prefix(index)
                let valueData = data.dropFirst(index + separatorLength)
                let description = decodeID3Bytes(descriptionData, encoding: encoding) ?? ""
                let value = decodeID3Bytes(valueData, encoding: encoding) ?? ""
                return (description, value)
            }

            index += separatorLength == 1 ? 1 : 2
        }

        return nil
    }

    private static func decodeID3Bytes<S: DataProtocol>(_ bytes: S, encoding: String.Encoding) -> String? {
        let data = Data(bytes)
        guard !data.isEmpty else { return "" }
        return normalizedText(String(data: data, encoding: encoding) ?? "")
    }

    private static func id3Encoding(for byte: UInt8) -> String.Encoding? {
        switch byte {
        case 0: return .isoLatin1
        case 1: return .utf16
        case 2: return .utf16BigEndian
        case 3: return .utf8
        default: return nil
        }
    }

    private static func id3SeparatorLength(for encoding: String.Encoding) -> Int {
        switch encoding {
        case .utf16, .utf16BigEndian:
            return 2
        default:
            return 1
        }
    }

    private static func id3Label(for frameID: String) -> String? {
        switch frameID {
        case "TIT2": return "Title"
        case "TPE1": return "Artist"
        case "TALB": return "Album"
        case "TCON": return "Genre"
        case "TRCK": return "Track Number"
        case "TDRC", "TYER": return "Date"
        case "TCOP": return "Copyright"
        case "TSSE": return "Software"
        default: return nil
        }
    }

    private static func wavInfoLabel(for chunkID: String) -> String? {
        switch chunkID {
        case "INAM": return "Title"
        case "IART": return "Artist"
        case "IPRD": return "Album"
        case "IGNR": return "Genre"
        case "IPRT": return "Track Number"
        case "ICRD": return "Date"
        case "ICMT": return "Comment"
        case "ICOP": return "Copyright"
        case "ISFT": return "Software"
        default: return nil
        }
    }

    private static func decodeWAVInfoString(_ data: Data) -> String {
        let trimmedData = data.prefix { $0 != 0 }
        if let text = String(data: trimmedData, encoding: .utf8) {
            return text
        }
        if let text = String(data: trimmedData, encoding: .isoLatin1) {
            return text
        }
        return ""
    }

    private static func extractedTags(from fields: [PromptMetadataField]) -> AudioTagMetadata {
        var tags = AudioTagMetadata.empty

        for field in fields {
            switch canonicalKey(field.label) {
            case "title":
                if tags.title.isEmpty { tags.title = field.value }
            case "artist":
                if tags.artist.isEmpty { tags.artist = field.value }
            case "album":
                if tags.album.isEmpty { tags.album = field.value }
            case "genre":
                if tags.genre.isEmpty { tags.genre = field.value }
            case "tracknumber", "track":
                if tags.trackNumber.isEmpty { tags.trackNumber = field.value }
            case "date", "year":
                if tags.date.isEmpty { tags.date = field.value }
            case "comment":
                if tags.comment.isEmpty { tags.comment = field.value }
            case "copyright":
                if tags.copyright.isEmpty { tags.copyright = field.value }
            default:
                continue
            }
        }

        return tags
    }

    private static func buildSearchText(from fields: [PromptMetadataField]) -> String {
        var seen = Set<String>()
        var values: [String] = []

        for field in fields {
            let key = canonicalKey(field.label)
            guard key != "software",
                  let normalizedValue = normalizedText(field.value)
            else {
                continue
            }

            let identity = normalizedValue.lowercased()
            guard seen.insert(identity).inserted else { continue }
            values.append(normalizedValue)
        }

        return values.joined(separator: "\n")
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

    private static func canonicalKey(_ value: String) -> String {
        value
            .lowercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    private static func normalizedText(_ value: String) -> String? {
        let trimmed = value
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum AudioMetadataWriter {
    enum WriterError: LocalizedError {
        case unsupportedFormat(String)
        case invalidMP3
        case invalidWAV
        case malformedWAV(String)
        case malformedID3(String)
        case unsupportedID3Frame(String)
        case fileTooLarge
        case verificationFailed(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let ext):
                return "Cannot embed audio metadata in .\(ext) files. Only MP3 and WAV are supported."
            case .invalidMP3:
                return "The file is not a valid MP3."
            case .invalidWAV:
                return "The file is not a valid WAV."
            case .malformedWAV(let detail):
                return "The WAV's structure couldn't be read safely (\(detail)). The file was not modified."
            case .malformedID3(let detail):
                return "The existing ID3 tag couldn't be read safely (\(detail)). The file was not modified."
            case .unsupportedID3Frame(let id):
                return "The ID3v2.2 tag contains a \(id) frame that can't be converted safely. The file was not modified."
            case .fileTooLarge:
                return "The file is too large to rewrite as a standard WAV."
            case .verificationFailed(let detail):
                return "The rewritten file failed verification (\(detail)). The original file was not modified."
            }
        }
    }

    private static let softwareName = "PromptLibrary Explorer"

    static func write(_ metadata: AudioTagMetadata, to url: URL) throws {
        switch url.pathExtension.lowercased() {
        case "mp3":
            try writeMP3(metadata, to: url)
        case "wav":
            try writeWAV(metadata, to: url)
        default:
            throw WriterError.unsupportedFormat(url.pathExtension.lowercased())
        }
    }

    // MARK: - MP3 (ID3v2)

    /// Frame IDs the editor owns. COMM is handled separately: only comments with an empty
    /// description are replaced (iTunes stores e.g. iTunNORM in described COMM frames).
    private static let editedID3FrameIDs: Set<String> = ["TIT2", "TPE1", "TALB", "TCON", "TRCK", "TDRC", "TYER", "TCOP"]

    private static func writeMP3(_ metadata: AudioTagMetadata, to url: URL) throws {
        let original = try Data(contentsOf: url, options: .alwaysMapped)
        let existingTag = try ID3Tag.parse(original, strict: true)
        let audioRange = (existingTag?.tagEnd ?? 0)..<original.count

        // v2.3 and v2.4 tags keep their version; v2.2 is upgraded to v2.3; new tags are v2.4.
        let version: Int
        var existingFrames: [ID3Frame]
        switch existingTag?.majorVersion {
        case nil:
            version = 4
            existingFrames = []
        case 2:
            version = 3
            existingFrames = try existingTag!.frames.map { frame in
                guard let converted = ID3Tag.convertedFromV22(frame) else {
                    throw WriterError.unsupportedID3Frame(frame.id)
                }
                return converted
            }
        default:
            version = existingTag!.majorVersion
            existingFrames = existingTag!.frames
        }

        existingFrames.removeAll { frame in
            editedID3FrameIDs.contains(frame.id) || (frame.id == "COMM" && isUndescribedComment(frame, version: version))
        }

        var newFrames: [ID3Frame] = []
        func addText(_ id: String, _ text: String) {
            if let frame = buildID3TextFrame(id: id, text: text, version: version) { newFrames.append(frame) }
        }
        addText("TIT2", metadata.title)
        addText("TPE1", metadata.artist)
        addText("TALB", metadata.album)
        addText("TCON", metadata.genre)
        addText("TRCK", metadata.trackNumber)
        addText(version == 4 ? "TDRC" : "TYER", metadata.date)
        if let comment = buildID3CommentFrame(text: metadata.comment, version: version) { newFrames.append(comment) }
        addText("TCOP", metadata.copyright)
        if !metadata.isEmpty, !existingFrames.contains(where: { $0.id == "TSSE" }) {
            addText("TSSE", softwareName)
        }

        // Edited frames first so readers that take the first match see the new values.
        let frames = newFrames + existingFrames

        var tag = Data()
        if !frames.isEmpty {
            var frameData = Data()
            for frame in frames { frameData.append(serializedID3Frame(frame, version: version)) }

            tag.append(Data("ID3".utf8))
            tag.append(UInt8(version))
            tag.append(0) // revision
            tag.append(0) // flags: no unsynchronisation, extended header, or footer
            tag.append(AudioBinary.syncsafeData(for: frameData.count))
            tag.append(frameData)
        }

        var output = Data()
        output.reserveCapacity(tag.count + audioRange.count)
        output.append(tag)
        output.append(AudioBinary.slice(original, audioRange))

        try verifyMP3(output, originalAudio: AudioBinary.slice(original, audioRange), expectedFrames: frames, version: version)
        try MetadataFileReplacer.replaceContents(of: url, with: output)
    }

    private static func verifyMP3(_ output: Data, originalAudio: Data, expectedFrames: [ID3Frame], version: Int) throws {
        let reparsed: ID3Tag?
        do {
            reparsed = try ID3Tag.parse(output, strict: true)
        } catch {
            throw WriterError.verificationFailed("new ID3 tag couldn't be re-read")
        }

        let audioStart = reparsed?.tagEnd ?? 0
        guard output.count - audioStart == originalAudio.count,
              AudioBinary.slice(output, audioStart..<output.count) == originalAudio
        else {
            throw WriterError.verificationFailed("audio data changed")
        }

        let frames = reparsed?.frames ?? []
        guard frames.count == expectedFrames.count,
              zip(frames, expectedFrames).allSatisfy({ $0.id == $1.id && $0.flags == $1.flags && $0.payload == $1.payload })
        else {
            throw WriterError.verificationFailed("ID3 frames didn't read back")
        }
        if let reparsed, reparsed.majorVersion != version {
            throw WriterError.verificationFailed("ID3 version changed")
        }
    }

    /// Whether a COMM frame has an empty content description (the "plain" comment the editor owns).
    private static func isUndescribedComment(_ frame: ID3Frame, version: Int) -> Bool {
        guard let payload = ID3Tag.readablePayload(of: frame, version: version), payload.count >= 5 else {
            return false
        }
        let encoding = AudioBinary.byte(payload, 0)
        var cursor = 4 // encoding + language

        switch encoding {
        case 1, 2:
            if payload.count >= cursor + 2 {
                let bom = (AudioBinary.byte(payload, cursor), AudioBinary.byte(payload, cursor + 1))
                if bom == (0xFF, 0xFE) || bom == (0xFE, 0xFF) { cursor += 2 }
            }
            return payload.count >= cursor + 2
                && AudioBinary.byte(payload, cursor) == 0
                && AudioBinary.byte(payload, cursor + 1) == 0
        default:
            return AudioBinary.byte(payload, cursor) == 0
        }
    }

    /// v2.4 text uses UTF-8; v2.3 has no UTF-8, so Latin-1 is used when possible and UTF-16 with BOM otherwise.
    private static func encodedID3Text(_ text: String, version: Int) -> (encoding: UInt8, data: Data, terminator: Data) {
        if version == 4 {
            return (3, Data(text.utf8), Data([0]))
        }
        if let latin1 = text.data(using: .isoLatin1) {
            return (0, latin1, Data([0]))
        }
        return (1, text.data(using: .utf16) ?? Data(), Data([0, 0])) // .utf16 includes a BOM
    }

    private static func buildID3TextFrame(id: String, text: String, version: Int) -> ID3Frame? {
        let text = trimmed(text)
        guard !text.isEmpty else { return nil }

        let encoded = encodedID3Text(text, version: version)
        var payload = Data([encoded.encoding])
        payload.append(encoded.data)
        return ID3Frame(id: id, flags: Data([0, 0]), payload: payload)
    }

    private static func buildID3CommentFrame(text: String, version: Int) -> ID3Frame? {
        let text = trimmed(text)
        guard !text.isEmpty else { return nil }

        let encoded = encodedID3Text(text, version: version)
        var payload = Data([encoded.encoding])
        payload.append(Data("eng".utf8))
        if encoded.encoding == 1 {
            payload.append(contentsOf: [0xFF, 0xFE]) // BOM for the empty description
        }
        payload.append(encoded.terminator) // empty description
        payload.append(encoded.data)
        return ID3Frame(id: "COMM", flags: Data([0, 0]), payload: payload)
    }

    private static func serializedID3Frame(_ frame: ID3Frame, version: Int) -> Data {
        var data = Data(frame.id.utf8)
        data.append(version == 4
            ? AudioBinary.syncsafeData(for: frame.payload.count)
            : AudioBinary.bigEndianData(for: frame.payload.count))
        data.append(frame.flags.count == 2 ? frame.flags : Data([0, 0]))
        data.append(frame.payload)
        return data
    }

    // MARK: - WAV (RIFF LIST/INFO)

    private static let editedInfoIDs: Set<String> = ["INAM", "IART", "IPRD", "IGNR", "IPRT", "ICRD", "ICMT", "ICOP"]

    private static func writeWAV(_ metadata: AudioTagMetadata, to url: URL) throws {
        let original = try Data(contentsOf: url, options: .alwaysMapped)
        let chunks = try AudioWAVLayout.parse(original, strict: true)

        // Keep INFO items the editor doesn't manage (engineer, subject, keywords, …).
        var preservedItems: [(id: String, value: Data)] = []
        for chunk in chunks where AudioWAVLayout.isInfoList(chunk, in: original) {
            for item in try AudioWAVLayout.infoItems(in: original, list: chunk, strict: true)
            where !editedInfoIDs.contains(item.id) {
                preservedItems.append((item.id, AudioBinary.slice(original, item.payload)))
            }
        }

        var items: [(id: String, value: Data)] = []
        func addItem(_ id: String, _ value: String) {
            let value = trimmed(value)
            guard !value.isEmpty else { return }
            var valueData = Data(value.utf8)
            valueData.append(0)
            items.append((id, valueData))
        }
        addItem("INAM", metadata.title)
        addItem("IART", metadata.artist)
        addItem("IPRD", metadata.album)
        addItem("IGNR", metadata.genre)
        addItem("IPRT", metadata.trackNumber)
        addItem("ICRD", metadata.date)
        addItem("ICMT", metadata.comment)
        addItem("ICOP", metadata.copyright)
        items.append(contentsOf: preservedItems)
        if !metadata.isEmpty, !items.contains(where: { $0.id == "ISFT" }) {
            addItem("ISFT", softwareName)
        }

        var infoChunk: Data?
        if !items.isEmpty {
            var infoPayload = Data("INFO".utf8)
            for item in items { infoPayload.append(serializedRIFFChunk(id: item.id, payload: item.value)) }
            infoChunk = serializedRIFFChunk(id: "LIST", payload: infoPayload)
        }

        let hasExistingInfo = chunks.contains { AudioWAVLayout.isInfoList($0, in: original) }
        var keptChunks: [AudioWAVChunk] = []

        // Built in place (RIFF size patched at the end) so large files are copied only once.
        var body = Data()
        body.reserveCapacity(original.count + (infoChunk?.count ?? 0) + 8)
        body.append(Data("RIFF".utf8))
        body.append(Data(count: 4)) // RIFF size placeholder
        body.append(Data("WAVE".utf8))
        var insertedInfoChunk = false

        for chunk in chunks {
            if AudioWAVLayout.isInfoList(chunk, in: original) {
                // Merged INFO goes where the first existing INFO list was.
                if !insertedInfoChunk, let infoChunk { body.append(infoChunk) }
                insertedInfoChunk = true
                continue
            }
            if !hasExistingInfo, !insertedInfoChunk, chunk.id == "data" {
                if let infoChunk { body.append(infoChunk) }
                insertedInfoChunk = true
            }
            body.append(serializedRIFFChunk(id: chunk.id, payload: AudioBinary.slice(original, chunk.payload)))
            keptChunks.append(chunk)
        }

        let riffSize = body.count - 8
        guard riffSize <= Int(UInt32.max) else { throw WriterError.fileTooLarge }
        body.replaceSubrange(4..<8, with: AudioBinary.littleEndianData(for: riffSize))
        let output = body

        try verifyWAV(output, original: original, keptChunks: keptChunks, expectedInfoItems: items)
        try MetadataFileReplacer.replaceContents(of: url, with: output)
    }

    private static func verifyWAV(
        _ output: Data,
        original: Data,
        keptChunks: [AudioWAVChunk],
        expectedInfoItems: [(id: String, value: Data)]
    ) throws {
        let chunks: [AudioWAVChunk]
        do {
            chunks = try AudioWAVLayout.parse(output, strict: true)
        } catch {
            throw WriterError.verificationFailed("RIFF structure couldn't be re-read")
        }

        let infoLists = chunks.filter { AudioWAVLayout.isInfoList($0, in: output) }
        let otherChunks = chunks.filter { !AudioWAVLayout.isInfoList($0, in: output) }

        guard otherChunks.count == keptChunks.count,
              zip(otherChunks, keptChunks).allSatisfy({ written, kept in
                  written.id == kept.id
                      && AudioBinary.slice(output, written.payload) == AudioBinary.slice(original, kept.payload)
              })
        else {
            throw WriterError.verificationFailed("audio chunks changed")
        }

        let items = try infoLists.flatMap { try AudioWAVLayout.infoItems(in: output, list: $0, strict: true) }
        guard items.count == expectedInfoItems.count,
              zip(items, expectedInfoItems).allSatisfy({ $0.id == $1.id && AudioBinary.slice(output, $0.payload) == $1.value })
        else {
            throw WriterError.verificationFailed("INFO tags didn't read back")
        }
    }

    private static func serializedRIFFChunk(id: String, payload: Data) -> Data {
        var data = Data()
        data.reserveCapacity(payload.count + 9)
        data.append(Data(id.utf8))
        data.append(AudioBinary.littleEndianData(for: payload.count))
        data.append(payload)
        if payload.count % 2 == 1 {
            data.append(0)
        }
        return data
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
