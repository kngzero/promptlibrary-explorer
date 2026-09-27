import AVFoundation
import Foundation
import ImageIO

// MARK: - Capture date & location: value types
//
// Timeline, Map, Sort by Capture Date, Group By Month / Year and the details
// panel's Date row all use the same "best date" for a file:
//   1. the capture date embedded in the file (EXIF DateTimeOriginal, the
//      QuickTime creation date, a PNG tIME chunk, or a timestamp a generator
//      wrote into its metadata), else
//   2. the file's creation date, else
//   3. its modification date,
// and they always say which one was used (`CaptureDateSource`).
//
// Location privacy: nothing here touches the network. GPS comes only from the
// file itself (EXIF GPS dictionary, QuickTime ISO 6709 location).

/// Which of the three dates a file's timeline / sort date is.
enum CaptureDateSource: Int, Sendable, Hashable, CaseIterable {
    case captured = 1
    case created = 2
    case modified = 3

    /// Details panel / tooltips: "Captured", "Created", "Modified".
    var title: String {
        switch self {
        case .captured: return "Captured"
        case .created: return "Created"
        case .modified: return "Modified"
        }
    }
}

/// Where an embedded capture date came from.
enum CaptureDateOrigin: Int, Sendable, Hashable, CaseIterable {
    case exif = 1
    case quickTime = 2
    case pngTime = 3
    case generator = 4

    var title: String {
        switch self {
        case .exif: return "EXIF date taken"
        case .quickTime: return "QuickTime creation date"
        case .pngTime: return "PNG time chunk"
        case .generator: return "generator metadata"
        }
    }
}

struct GeoCoordinate: Sendable, Hashable, Codable {
    var latitude: Double
    var longitude: Double
    /// Metres above sea level (negative below); nil when not recorded.
    var altitude: Double?

    init(latitude: Double, longitude: Double, altitude: Double? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
    }

    /// Valid WGS 84 range, and not the 0,0 "no fix" some cameras write.
    var isPlausible: Bool {
        latitude.isFinite && longitude.isFinite
            && (-90...90).contains(latitude) && (-180...180).contains(longitude)
            && !(latitude == 0 && longitude == 0)
    }

    /// "48.85770° N, 2.29500° E".
    var displayString: String {
        let lat = String(format: "%.5f° %@", abs(latitude), latitude >= 0 ? "N" : "S")
        let lon = String(format: "%.5f° %@", abs(longitude), longitude >= 0 ? "E" : "W")
        return "\(lat), \(lon)"
    }
}

/// What a file says about when and where it was made.
struct CaptureMetadata: Sendable, Hashable {
    var captureDate: Date?
    var origin: CaptureDateOrigin?
    /// Seconds east of GMT the capture's wall-clock time was expressed in
    /// (from the file, or the Mac's zone for an EXIF time without an offset).
    /// Timeline buckets use it, so a photo taken at 23:30 stays on its day.
    var utcOffset: Int?
    var coordinate: GeoCoordinate?

    init(captureDate: Date? = nil, origin: CaptureDateOrigin? = nil, utcOffset: Int? = nil, coordinate: GeoCoordinate? = nil) {
        self.captureDate = captureDate
        self.origin = origin
        self.utcOffset = utcOffset
        self.coordinate = coordinate
    }

    var isEmpty: Bool { captureDate == nil && coordinate == nil }
}

/// A file's resolved date for the timeline, sorting and grouping.
struct ResolvedCaptureDate: Sendable, Hashable {
    let date: Date
    let source: CaptureDateSource
    /// The capture's own UTC offset (captured dates only).
    let utcOffset: Int?
    let origin: CaptureDateOrigin?
}

enum CaptureDateResolver {
    /// Capture date → creation date → modification date. Nil when none is known.
    /// Dates at or before 1970-01-02 are treated as missing (unset EXIF / FS placeholders).
    static func resolve(capture: CaptureMetadata?, created: Date?, modified: Date?) -> ResolvedCaptureDate? {
        if let date = capture?.captureDate, isUsable(date) {
            return ResolvedCaptureDate(date: date, source: .captured, utcOffset: capture?.utcOffset, origin: capture?.origin)
        }
        if let created, isUsable(created) {
            return ResolvedCaptureDate(date: created, source: .created, utcOffset: nil, origin: nil)
        }
        if let modified, isUsable(modified) {
            return ResolvedCaptureDate(date: modified, source: .modified, utcOffset: nil, origin: nil)
        }
        return nil
    }

    static func isUsable(_ date: Date) -> Bool {
        date.timeIntervalSince1970 > 86_400 && date.timeIntervalSinceNow < 400 * 86_400
    }
}

// MARK: - Extraction

/// Reads capture dates and GPS from files. Never decodes pixels, never touches
/// the network, and skips online-only cloud files (they would download).
enum GeoMetadataExtractor {
    /// Bumped when extraction improves; index rows below it are re-read by the backfill.
    static let version = 1

    /// Images (ImageIO properties + PNG tIME + generator fields) and videos
    /// (QuickTime metadata). Other kinds, missing and online-only files return empty.
    /// `fields` are already-parsed generator fields (from `ImageMetadataParser`),
    /// if the caller has them; otherwise PNG / JPEG text metadata is parsed when no
    /// better date exists.
    static func read(url: URL, fields: [PromptMetadataField]? = nil) async -> CaptureMetadata {
        let name = url.lastPathComponent
        guard FileManager.default.fileExists(atPath: url.path),
              CloudFileStatus.isLocallyAvailable(url)
        else { return CaptureMetadata() }
        if FileHelpers.isVideoFile(name) { return await videoMetadata(at: url) }
        if FileHelpers.isImageFile(name) { return imageMetadata(at: url, fields: fields) }
        return CaptureMetadata()
    }

    // MARK: Images

    static func imageMetadata(at url: URL, fields: [PromptMetadataField]? = nil, timeZone: TimeZone = .current) -> CaptureMetadata {
        var result = CaptureMetadata()
        if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        {
            result = metadata(fromImageProperties: properties, timeZone: timeZone)
        }
        if result.captureDate == nil, url.pathExtension.lowercased() == "png", let date = pngTimeChunkDate(at: url) {
            result.captureDate = date
            result.origin = .pngTime
            result.utcOffset = 0
        }
        if result.captureDate == nil {
            let generatorFields: [PromptMetadataField]
            if let fields {
                generatorFields = fields
            } else if ["png", "jpg", "jpeg"].contains(url.pathExtension.lowercased()) {
                generatorFields = ImageMetadataParser.readMetadataUncached(at: url).fields
            } else {
                generatorFields = []
            }
            if let (date, offset) = generatorTimestamp(in: generatorFields, timeZone: timeZone) {
                result.captureDate = date
                result.origin = .generator
                result.utcOffset = offset
            }
        }
        return result
    }

    /// EXIF DateTimeOriginal (then DateTimeDigitized) with its offset, and the GPS dictionary.
    static func metadata(fromImageProperties properties: [CFString: Any], timeZone: TimeZone = .current) -> CaptureMetadata {
        var result = CaptureMetadata()
        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            let candidates: [(CFString, CFString)] = [
                (kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifOffsetTimeOriginal),
                (kCGImagePropertyExifDateTimeDigitized, kCGImagePropertyExifOffsetTimeDigitized),
            ]
            for (dateKey, offsetKey) in candidates {
                guard let raw = exif[dateKey] as? String,
                      let parsed = parseEXIFDate(raw, offset: exif[offsetKey] as? String, timeZone: timeZone)
                else { continue }
                result.captureDate = parsed.date
                result.utcOffset = parsed.utcOffset
                result.origin = .exif
                break
            }
        }
        if let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] {
            result.coordinate = coordinate(fromGPS: gps)
        }
        return result
    }

    /// "2019:07:04 15:30:00" (+ optional ".123" and an OffsetTime like "+02:00").
    /// Without an offset the time is read in `timeZone` (the Mac's), and that
    /// zone's offset is returned so the wall-clock day is kept.
    static func parseEXIFDate(_ raw: String, offset: String?, timeZone: TimeZone = .current) -> (date: Date, utcOffset: Int)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        guard trimmed.count >= 19 else { return nil }
        let main = String(trimmed.prefix(19))
        let parts = main.split(whereSeparator: { $0 == ":" || $0 == " " || $0 == "-" || $0 == "T" })
        guard parts.count == 6 else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == 6, numbers[0] > 1900, (1...12).contains(numbers[1]), (1...31).contains(numbers[2]) else { return nil }
        let explicitOffset = offset.flatMap(parseUTCOffset)
        let zone = explicitOffset.flatMap(TimeZone.init(secondsFromGMT:)) ?? timeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        var components = DateComponents()
        components.year = numbers[0]; components.month = numbers[1]; components.day = numbers[2]
        components.hour = numbers[3]; components.minute = numbers[4]; components.second = numbers[5]
        guard var date = calendar.date(from: components) else { return nil }
        // Sub-seconds ("…:00.25").
        if trimmed.count > 20, trimmed[trimmed.index(trimmed.startIndex, offsetBy: 19)] == ".",
           let fraction = Double("0" + trimmed.dropFirst(19).prefix(while: { $0 == "." || $0.isNumber }))
        {
            date = date.addingTimeInterval(fraction)
        }
        return (date, explicitOffset ?? zone.secondsFromGMT(for: date))
    }

    /// "+02:00", "-0530", "Z" → seconds east of GMT.
    static func parseUTCOffset(_ raw: String) -> Int? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        if text == "Z" || text == "z" { return 0 }
        guard let sign = text.first, sign == "+" || sign == "-" else { return nil }
        let digits = text.dropFirst().filter(\.isNumber)
        guard digits.count == 4 || digits.count == 2 else { return nil }
        let hours = Int(digits.prefix(2)) ?? 0
        let minutes = digits.count == 4 ? Int(digits.suffix(2)) ?? 0 : 0
        guard hours <= 14, minutes < 60 else { return nil }
        return (sign == "-" ? -1 : 1) * (hours * 3600 + minutes * 60)
    }

    /// EXIF GPS: positive magnitudes + N/S, E/W refs; AltitudeRef 1 = below sea level.
    static func coordinate(fromGPS gps: [CFString: Any]) -> GeoCoordinate? {
        guard let latitude = number(gps[kCGImagePropertyGPSLatitude]),
              let longitude = number(gps[kCGImagePropertyGPSLongitude])
        else { return nil }
        let latRef = (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased() ?? "N"
        let lonRef = (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased() ?? "E"
        var altitude = number(gps[kCGImagePropertyGPSAltitude])
        if let value = altitude, number(gps[kCGImagePropertyGPSAltitudeRef]) == 1 { altitude = -abs(value) }
        let coordinate = GeoCoordinate(
            latitude: latRef.hasPrefix("S") ? -abs(latitude) : abs(latitude),
            longitude: lonRef.hasPrefix("W") ? -abs(longitude) : abs(longitude),
            altitude: altitude
        )
        return coordinate.isPlausible ? coordinate : nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    // MARK: PNG tIME

    /// The PNG tIME chunk (UTC by definition). Walks chunk headers only
    /// (seeking past each chunk's data), stopping at IEND.
    static func pngTimeChunkDate(at url: URL) -> Date? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let signature = try? handle.read(upToCount: 8), signature == Data([137, 80, 78, 71, 13, 10, 26, 10]) else { return nil }
        var offset: UInt64 = 8
        for _ in 0..<10_000 {
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let header = try? handle.read(upToCount: 8), header.count == 8
            else { return nil }
            let bytes = [UInt8](header)
            let length = UInt64(bytes[0]) << 24 | UInt64(bytes[1]) << 16 | UInt64(bytes[2]) << 8 | UInt64(bytes[3])
            let type = String(bytes: bytes[4..<8], encoding: .ascii) ?? ""
            if type == "tIME" {
                guard length == 7, let payload = try? handle.read(upToCount: 7) else { return nil }
                return pngTimeDate(from: payload)
            }
            if type == "IEND" { return nil }
            offset += 12 + length
        }
        return nil
    }

    /// 7 bytes: year (2, big-endian), month, day, hour, minute, second — UTC.
    static func pngTimeDate(from payload: Data) -> Date? {
        let bytes = [UInt8](payload)
        guard bytes.count >= 7 else { return nil }
        var components = DateComponents()
        components.year = Int(bytes[0]) << 8 | Int(bytes[1])
        components.month = Int(bytes[2]); components.day = Int(bytes[3])
        components.hour = Int(bytes[4]); components.minute = Int(bytes[5]); components.second = min(59, Int(bytes[6]))
        guard let year = components.year, year > 1900, (1...12).contains(bytes[2]), (1...31).contains(bytes[3]),
              bytes[4] < 24, bytes[5] < 60
        else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: components)
    }

    // MARK: Generator timestamps

    /// Field labels a generator may put a creation time under (compared without
    /// case, spaces or punctuation).
    static let generatorTimestampLabels: Set<String> = [
        "date", "datetime", "created", "createdat", "creationdate", "creationtime", "createdate",
        "timestamp", "generated", "generatedat", "generationtime", "generationdate", "time",
    ]

    static func generatorTimestamp(in fields: [PromptMetadataField], timeZone: TimeZone = .current) -> (Date, Int?)? {
        for field in fields {
            let key = String(field.label.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
            guard generatorTimestampLabels.contains(key), let parsed = parseTimestamp(field.value, timeZone: timeZone) else { continue }
            return parsed
        }
        return nil
    }

    /// ISO 8601 (with or without an offset), "yyyy-MM-dd HH:mm:ss", EXIF style,
    /// or Unix seconds / milliseconds.
    static func parseTimestamp(_ raw: String, timeZone: TimeZone = .current) -> (Date, Int?)? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.allSatisfy(\.isNumber), text.count == 10 || text.count == 13, let value = Double(text) {
            let date = Date(timeIntervalSince1970: text.count == 13 ? value / 1000 : value)
            return CaptureDateResolver.isUsable(date) ? (date, nil) : nil
        }
        guard text.count >= 19 else { return nil }
        let head = String(text.prefix(19))
        var rest = String(text.dropFirst(19))
        // Fractional seconds.
        if rest.hasPrefix(".") { rest = String(rest.drop(while: { $0 == "." || $0.isNumber })) }
        let offset = rest.isEmpty ? nil : parseUTCOffset(rest)
        if !rest.isEmpty, offset == nil { return nil }
        guard let parsed = parseEXIFDate(head, offset: rest.isEmpty ? nil : rest, timeZone: timeZone),
              CaptureDateResolver.isUsable(parsed.date)
        else { return nil }
        return (parsed.date, offset ?? parsed.utcOffset)
    }

    // MARK: Video

    static func videoMetadata(at url: URL, timeZone: TimeZone = .current) async -> CaptureMetadata {
        let asset = AVURLAsset(url: url)
        var result = CaptureMetadata()
        var items: [AVMetadataItem] = (try? await asset.load(.metadata)) ?? []
        if let formats = try? await asset.load(.availableMetadataFormats) {
            for format in formats {
                if let more = try? await asset.loadMetadata(for: format) { items.append(contentsOf: more) }
            }
        }
        for item in items {
            let identifier = item.identifier?.rawValue.lowercased() ?? ""
            let isCreation = item.identifier == .quickTimeMetadataCreationDate
                || item.commonKey == .commonKeyCreationDate
                || identifier.hasSuffix("creationdate")
            let isLocation = identifier.contains("iso6709")
                || item.commonKey == .commonKeyLocation
                || identifier.hasSuffix("%a9xyz") || identifier.hasSuffix("©xyz")
            if isCreation, result.captureDate == nil {
                if let string = try? await item.load(.stringValue), let (date, offset) = parseTimestamp(string, timeZone: timeZone) {
                    result.captureDate = date
                    result.utcOffset = offset ?? timeZone.secondsFromGMT(for: date)
                    result.origin = .quickTime
                } else if let date = try? await item.load(.dateValue), CaptureDateResolver.isUsable(date) {
                    result.captureDate = date
                    result.utcOffset = timeZone.secondsFromGMT(for: date)
                    result.origin = .quickTime
                }
            }
            if isLocation, result.coordinate == nil, let string = try? await item.load(.stringValue) {
                result.coordinate = parseISO6709(string)
            }
        }
        if result.captureDate == nil,
           let item = try? await asset.load(.creationDate),
           let date = try? await item.load(.dateValue),
           CaptureDateResolver.isUsable(date)
        {
            result.captureDate = date
            result.utcOffset = timeZone.secondsFromGMT(for: date)
            result.origin = .quickTime
        }
        return result
    }

    // MARK: ISO 6709

    /// "+48.8577+002.2950+035.000/", "-33.8688+151.2093/", DDMM / DDMMSS forms
    /// ("+404530.5-0740100/") and an optional "CRS…" suffix.
    static func parseISO6709(_ raw: String) -> GeoCoordinate? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let crs = text.range(of: "CRS") { text = String(text[..<crs.lowerBound]) }
        while text.hasSuffix("/") { text.removeLast() }
        var parts: [String] = []
        for character in text {
            if character == "+" || character == "-" {
                parts.append(String(character))
            } else if character.isNumber || character == "." {
                guard !parts.isEmpty else { return nil }
                parts[parts.count - 1].append(character)
            } else {
                return nil
            }
        }
        guard parts.count == 2 || parts.count == 3,
              let latitude = iso6709Angle(parts[0], degreeDigits: 2),
              let longitude = iso6709Angle(parts[1], degreeDigits: 3)
        else { return nil }
        let altitude = parts.count == 3 ? Double(parts[2]) : nil
        let coordinate = GeoCoordinate(latitude: latitude, longitude: longitude, altitude: altitude)
        return coordinate.isPlausible ? coordinate : nil
    }

    /// ±DD(D)[.d], ±DD(D)MM[.m] or ±DD(D)MMSS[.s].
    private static func iso6709Angle(_ part: String, degreeDigits: Int) -> Double? {
        guard let sign = part.first else { return nil }
        let body = part.dropFirst()
        let integer = body.prefix(while: \.isNumber)
        let fraction = body.dropFirst(integer.count)
        guard !integer.isEmpty, fraction.isEmpty || fraction.first == "." else { return nil }
        let fractionValue = fraction.isEmpty ? 0 : Double("0" + fraction) ?? 0
        var value: Double
        switch integer.count {
        case degreeDigits:
            value = (Double(integer) ?? 0) + fractionValue
        case degreeDigits + 2:
            let degrees = Double(integer.prefix(degreeDigits)) ?? 0
            let minutes = (Double(integer.suffix(2)) ?? 0) + fractionValue
            guard minutes < 60 else { return nil }
            value = degrees + minutes / 60
        case degreeDigits + 4:
            let degrees = Double(integer.prefix(degreeDigits)) ?? 0
            let minutes = Double(integer.dropFirst(degreeDigits).prefix(2)) ?? 0
            let seconds = (Double(integer.suffix(2)) ?? 0) + fractionValue
            guard minutes < 60, seconds < 60 else { return nil }
            value = degrees + minutes / 60 + seconds / 3600
        default:
            return nil
        }
        if sign == "-" { value = -value }
        return value
    }
}
