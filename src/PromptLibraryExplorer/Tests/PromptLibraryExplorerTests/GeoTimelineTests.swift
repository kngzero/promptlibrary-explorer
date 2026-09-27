import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import SQLite3
import UniformTypeIdentifiers
import XCTest
@testable import PromptLibraryExplorer

// MARK: - Fixtures

private enum GeoFixture {
    /// A JPEG written by ImageIO with the given EXIF / GPS dictionaries.
    static func jpeg(exif: [CFString: Any]? = nil, gps: [CFString: Any]? = nil) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        var properties: [CFString: Any] = [:]
        if let exif { properties[kCGImagePropertyExifDictionary] = exif }
        if let gps { properties[kCGImagePropertyGPSDictionary] = gps }
        CGImageDestinationAddImage(destination, makeCGImage(width: 16, height: 12), properties as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// A PNG tIME chunk (UTC).
    static func tIME(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) -> Data {
        PNGFixture.chunk(type: "tIME", payload: Data([
            UInt8(year >> 8), UInt8(year & 0xFF), UInt8(month), UInt8(day), UInt8(hour), UInt8(minute), UInt8(second),
        ]))
    }

    /// A short H.264 .mov with QuickTime metadata.
    static func movie(to url: URL, metadata: [AVMetadataItem]) async throws {
        try? FileManager.default.removeItem(at: url)
        let width = 64, height = 48
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.metadata = metadata
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<5 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
            let pixelBuffer = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            memset(CVPixelBufferGetBaseAddress(pixelBuffer), 0x80, CVPixelBufferGetDataSize(pixelBuffer))
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            XCTAssertTrue(adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 5, timescale: 10))
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
    }

    static func metadataItem(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        return item
    }

    static func utcDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    static func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }
}

// MARK: - Capture dates: source precedence

final class CaptureDatePrecedenceTests: TempDirectoryTestCase {
    private let utc = TimeZone(secondsFromGMT: 0)!

    func testEXIFDateTimeOriginalWithOffset() throws {
        let url = try writeFile("photo.jpg", GeoFixture.jpeg(exif: [
            kCGImagePropertyExifDateTimeOriginal: "2019:07:04 15:30:00",
            kCGImagePropertyExifOffsetTimeOriginal: "+02:00",
            kCGImagePropertyExifDateTimeDigitized: "2020:01:01 00:00:00",
        ]))
        let capture = GeoMetadataExtractor.imageMetadata(at: url, timeZone: utc)
        XCTAssertEqual(capture.origin, .exif)
        XCTAssertEqual(capture.captureDate, GeoFixture.utcDate(2019, 7, 4, 13, 30))
        XCTAssertEqual(capture.utcOffset, 7200)

        // Capture beats the file's own dates.
        let resolved = CaptureDateResolver.resolve(capture: capture, created: GeoFixture.utcDate(2024, 1, 1), modified: GeoFixture.utcDate(2024, 2, 1))
        XCTAssertEqual(resolved?.source, .captured)
        XCTAssertEqual(resolved?.date, GeoFixture.utcDate(2019, 7, 4, 13, 30))
    }

    func testEXIFDateWithoutOffsetUsesTheGivenZoneAndKeepsWallClock() throws {
        let url = try writeFile("naive.jpg", GeoFixture.jpeg(exif: [kCGImagePropertyExifDateTimeOriginal: "2019:07:04 23:30:00"]))
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let capture = GeoMetadataExtractor.imageMetadata(at: url, timeZone: tokyo)
        XCTAssertEqual(capture.captureDate, GeoFixture.utcDate(2019, 7, 4, 14, 30))
        XCTAssertEqual(capture.utcOffset, 9 * 3600)
        // Bucketed in its own offset, it stays on the 4th even for a UTC calendar.
        let item = TimelineItem(path: url.path, date: capture.captureDate!, source: .captured, utcOffset: capture.utcOffset)
        XCTAssertEqual(TimelineBucketer.day(of: item, calendar: GeoFixture.calendar(utc)), TimelineDay(year: 2019, month: 7, day: 4))
    }

    func testDateTimeDigitizedIsTheFallbackWithinEXIF() throws {
        let url = try writeFile("digitized.jpg", GeoFixture.jpeg(exif: [
            kCGImagePropertyExifDateTimeDigitized: "2018:03:02 08:00:00",
            kCGImagePropertyExifOffsetTimeDigitized: "-05:00",
        ]))
        let capture = GeoMetadataExtractor.imageMetadata(at: url, timeZone: utc)
        XCTAssertEqual(capture.origin, .exif)
        XCTAssertEqual(capture.captureDate, GeoFixture.utcDate(2018, 3, 2, 13, 0))
        XCTAssertEqual(capture.utcOffset, -5 * 3600)
    }

    func testPNGTimeChunk() throws {
        let png = PNGFixture.png(with: [GeoFixture.tIME(year: 2022, month: 11, day: 5, hour: 18, minute: 45, second: 10)])
        let url = try writeFile("render.png", png)
        XCTAssertEqual(GeoMetadataExtractor.pngTimeChunkDate(at: url), GeoFixture.utcDate(2022, 11, 5, 18, 45, 10))
        let capture = GeoMetadataExtractor.imageMetadata(at: url, fields: [], timeZone: utc)
        XCTAssertEqual(capture.origin, .pngTime)
        XCTAssertEqual(capture.captureDate, GeoFixture.utcDate(2022, 11, 5, 18, 45, 10))
        XCTAssertEqual(capture.utcOffset, 0)
    }

    func testPNGWithoutTimeChunkHasNoCaptureDate() throws {
        let url = try writeFile("plain.png", PNGFixture.basePNG())
        XCTAssertNil(GeoMetadataExtractor.pngTimeChunkDate(at: url))
        XCTAssertNil(GeoMetadataExtractor.imageMetadata(at: url, fields: []).captureDate)
    }

    func testGeneratorTimestampFromParsedFields() throws {
        let fields = [
            PromptMetadataField(label: "Steps", value: "30"),
            PromptMetadataField(label: "Created At", value: "2023-02-01T10:00:00Z"),
        ]
        let parsed = try XCTUnwrap(GeoMetadataExtractor.generatorTimestamp(in: fields, timeZone: utc))
        XCTAssertEqual(parsed.0, GeoFixture.utcDate(2023, 2, 1, 10))
        XCTAssertEqual(parsed.1, 0)
        // A PNG whose only date is a generator field.
        let url = try writeFile("gen.png", PNGFixture.basePNG())
        let capture = GeoMetadataExtractor.imageMetadata(at: url, fields: fields, timeZone: utc)
        XCTAssertEqual(capture.origin, .generator)
        XCTAssertEqual(capture.captureDate, GeoFixture.utcDate(2023, 2, 1, 10))
        // PNG tIME comes before a generator field.
        let both = try writeFile("both.png", PNGFixture.png(with: [GeoFixture.tIME(year: 2021, month: 1, day: 2, hour: 3, minute: 4, second: 5)]))
        XCTAssertEqual(GeoMetadataExtractor.imageMetadata(at: both, fields: fields, timeZone: utc).origin, .pngTime)
    }

    func testTimestampFormats() {
        XCTAssertEqual(GeoMetadataExtractor.parseTimestamp("1700000000", timeZone: utc)?.0, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(GeoMetadataExtractor.parseTimestamp("1700000000000", timeZone: utc)?.0, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(GeoMetadataExtractor.parseTimestamp("2021-06-15T10:20:30+0200", timeZone: utc)?.0, GeoFixture.utcDate(2021, 6, 15, 8, 20, 30))
        XCTAssertEqual(GeoMetadataExtractor.parseTimestamp("2021-06-15T10:20:30.250-03:30", timeZone: utc)?.1, -(3 * 3600 + 1800))
        XCTAssertEqual(GeoMetadataExtractor.parseTimestamp("2021-06-15 10:20:30", timeZone: utc)?.0, GeoFixture.utcDate(2021, 6, 15, 10, 20, 30))
        XCTAssertNil(GeoMetadataExtractor.parseTimestamp("yesterday", timeZone: utc))
        XCTAssertNil(GeoMetadataExtractor.parseTimestamp("2021-06-15T10:20:30 banana", timeZone: utc))
        XCTAssertEqual(GeoMetadataExtractor.parseUTCOffset("Z"), 0)
        XCTAssertEqual(GeoMetadataExtractor.parseUTCOffset("-0530"), -(5 * 3600 + 1800))
        XCTAssertNil(GeoMetadataExtractor.parseUTCOffset("+25:00"))
    }

    func testQuickTimeCreationDateAndLocationOnAGeneratedClip() async throws {
        let url = tempDir.appendingPathComponent("phone.mov")
        try await GeoFixture.movie(to: url, metadata: [
            GeoFixture.metadataItem(.quickTimeMetadataCreationDate, "2021-06-15T10:20:30+0200"),
            GeoFixture.metadataItem(.quickTimeMetadataLocationISO6709, "+48.8577+002.2950+035.000/"),
        ])
        let capture = await GeoMetadataExtractor.videoMetadata(at: url, timeZone: utc)
        XCTAssertEqual(capture.origin, .quickTime)
        XCTAssertEqual(capture.captureDate, GeoFixture.utcDate(2021, 6, 15, 8, 20, 30))
        XCTAssertEqual(capture.utcOffset, 7200)
        let coordinate = try XCTUnwrap(capture.coordinate)
        XCTAssertEqual(coordinate.latitude, 48.8577, accuracy: 1e-6)
        XCTAssertEqual(coordinate.longitude, 2.2950, accuracy: 1e-6)
        XCTAssertEqual(coordinate.altitude ?? 0, 35, accuracy: 1e-6)
    }

    func testFileDateFallbacks() {
        let created = GeoFixture.utcDate(2020, 5, 1)
        let modified = GeoFixture.utcDate(2020, 6, 1)
        XCTAssertEqual(CaptureDateResolver.resolve(capture: nil, created: created, modified: modified)?.source, .created)
        XCTAssertEqual(CaptureDateResolver.resolve(capture: CaptureMetadata(), created: nil, modified: modified)?.source, .modified)
        // Placeholder dates (the epoch) don't count.
        XCTAssertEqual(CaptureDateResolver.resolve(
            capture: CaptureMetadata(captureDate: Date(timeIntervalSince1970: 0), origin: .exif),
            created: Date(timeIntervalSince1970: 0), modified: modified
        )?.source, .modified)
        XCTAssertNil(CaptureDateResolver.resolve(capture: nil, created: nil, modified: nil))
        XCTAssertEqual(CaptureDateSource.allCases.map(\.title), ["Captured", "Created", "Modified"])
    }

    func testIndexingStoresCaptureDatesAndFileDates() async throws {
        let library = tempDir.appendingPathComponent("lib", isDirectory: true)
        let photo = library.appendingPathComponent("photo.jpg")
        let render = library.appendingPathComponent("render.png")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try GeoFixture.jpeg(
            exif: [kCGImagePropertyExifDateTimeOriginal: "2019:07:04 15:30:00", kCGImagePropertyExifOffsetTimeOriginal: "+02:00"],
            gps: [kCGImagePropertyGPSLatitude: 51.5007, kCGImagePropertyGPSLatitudeRef: "N",
                  kCGImagePropertyGPSLongitude: 0.1246, kCGImagePropertyGPSLongitudeRef: "W"]
        ).write(to: photo)
        try PNGFixture.basePNG().write(to: render)

        let service = LibraryIndexService(databaseURL: tempDir.appendingPathComponent("db/index.sqlite"))
        await service.indexLibrary(root: library, progress: nil)
        let rows = await service.captureRows(forPaths: [photo.path, render.path])
        let photoRow = try XCTUnwrap(rows[photo.path])
        XCTAssertTrue(photoRow.isExtracted)
        XCTAssertEqual(photoRow.resolved?.source, .captured)
        XCTAssertEqual(photoRow.capture.origin, .exif)
        XCTAssertEqual(photoRow.resolved?.date, GeoFixture.utcDate(2019, 7, 4, 13, 30))
        XCTAssertEqual(photoRow.capture.coordinate?.longitude ?? 0, -0.1246, accuracy: 1e-6)
        let renderRow = try XCTUnwrap(rows[render.path])
        XCTAssertTrue(renderRow.isExtracted)
        XCTAssertNil(renderRow.capture.captureDate)
        XCTAssertNotNil(renderRow.ctime)
        XCTAssertEqual(renderRow.resolved?.source, .created)
        let all = await service.captureRows(under: library)
        XCTAssertEqual(Set(all.map(\.path)), [photo.path, render.path])
        let pending = await service.captureBackfillPendingCount(under: library)
        XCTAssertEqual(pending, 0)
    }
}

// MARK: - GPS

final class GeoExtractionTests: TempDirectoryTestCase {
    func testEXIFGPSWrittenByImageIO() throws {
        let url = try writeFile("sydney.jpg", GeoFixture.jpeg(gps: [
            kCGImagePropertyGPSLatitude: 33.8688,
            kCGImagePropertyGPSLatitudeRef: "S",
            kCGImagePropertyGPSLongitude: 151.2093,
            kCGImagePropertyGPSLongitudeRef: "E",
            kCGImagePropertyGPSAltitude: 12.5,
            kCGImagePropertyGPSAltitudeRef: 1,
        ]))
        let coordinate = try XCTUnwrap(GeoMetadataExtractor.imageMetadata(at: url).coordinate)
        XCTAssertEqual(coordinate.latitude, -33.8688, accuracy: 1e-6)
        XCTAssertEqual(coordinate.longitude, 151.2093, accuracy: 1e-6)
        XCTAssertEqual(coordinate.altitude ?? 0, -12.5, accuracy: 1e-6)
    }

    func testWesternHemisphereAndNoFix() throws {
        let west = try writeFile("ny.jpg", GeoFixture.jpeg(gps: [
            kCGImagePropertyGPSLatitude: 40.7128, kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 74.0060, kCGImagePropertyGPSLongitudeRef: "W",
        ]))
        let coordinate = try XCTUnwrap(GeoMetadataExtractor.imageMetadata(at: west).coordinate)
        XCTAssertEqual(coordinate.longitude, -74.0060, accuracy: 1e-6)
        XCTAssertNil(coordinate.altitude)
        // 0,0 is a camera's "no fix", not the Gulf of Guinea.
        let zero = try writeFile("zero.jpg", GeoFixture.jpeg(gps: [
            kCGImagePropertyGPSLatitude: 0.0, kCGImagePropertyGPSLongitude: 0.0,
        ]))
        XCTAssertNil(GeoMetadataExtractor.imageMetadata(at: zero).coordinate)
        XCTAssertNil(GeoMetadataExtractor.imageMetadata(at: try writeFile("none.jpg", GeoFixture.jpeg())).coordinate)
    }

    func testISO6709DecimalDegrees() throws {
        let paris = try XCTUnwrap(GeoMetadataExtractor.parseISO6709("+48.8577+002.2950+035.000/"))
        XCTAssertEqual(paris.latitude, 48.8577, accuracy: 1e-9)
        XCTAssertEqual(paris.longitude, 2.2950, accuracy: 1e-9)
        XCTAssertEqual(paris.altitude ?? 0, 35, accuracy: 1e-9)

        let sydney = try XCTUnwrap(GeoMetadataExtractor.parseISO6709("-33.8688+151.2093/"))
        XCTAssertEqual(sydney.latitude, -33.8688, accuracy: 1e-9)
        XCTAssertEqual(sydney.longitude, 151.2093, accuracy: 1e-9)
        XCTAssertNil(sydney.altitude)

        // Negative longitude and altitude (below sea level), with a CRS suffix.
        let deadSea = try XCTUnwrap(GeoMetadataExtractor.parseISO6709("+31.5590+035.4732-430.5CRSWGS_84/"))
        XCTAssertEqual(deadSea.altitude ?? 0, -430.5, accuracy: 1e-9)
        let newYork = try XCTUnwrap(GeoMetadataExtractor.parseISO6709("+40.7128-074.0060-010.5/"))
        XCTAssertEqual(newYork.longitude, -74.0060, accuracy: 1e-9)
        XCTAssertEqual(newYork.altitude ?? 0, -10.5, accuracy: 1e-9)
        let south = try XCTUnwrap(GeoMetadataExtractor.parseISO6709("-22.9068-043.1729/"))
        XCTAssertEqual(south.latitude, -22.9068, accuracy: 1e-9)
        XCTAssertEqual(south.longitude, -43.1729, accuracy: 1e-9)
    }

    func testISO6709MinutesAndSeconds() throws {
        // ±DDMMSS.s ±DDDMMSS.s
        let dms = try XCTUnwrap(GeoMetadataExtractor.parseISO6709("+404530.5-0740100/"))
        XCTAssertEqual(dms.latitude, 40 + 45.0 / 60 + 30.5 / 3600, accuracy: 1e-9)
        XCTAssertEqual(dms.longitude, -(74 + 1.0 / 60), accuracy: 1e-9)
        // ±DDMM.m ±DDDMM.m
        let dm = try XCTUnwrap(GeoMetadataExtractor.parseISO6709("-3352.13+15112.56/"))
        XCTAssertEqual(dm.latitude, -(33 + 52.13 / 60), accuracy: 1e-9)
        XCTAssertEqual(dm.longitude, 151 + 12.56 / 60, accuracy: 1e-9)
    }

    func testISO6709Rejects() {
        XCTAssertNil(GeoMetadataExtractor.parseISO6709(""))
        XCTAssertNil(GeoMetadataExtractor.parseISO6709("48.8577,2.2950"))
        XCTAssertNil(GeoMetadataExtractor.parseISO6709("+95.0000+002.0000/"))
        XCTAssertNil(GeoMetadataExtractor.parseISO6709("+48.8577/"))
        XCTAssertNil(GeoMetadataExtractor.parseISO6709("+00.0000+000.0000/"))
        XCTAssertNil(GeoMetadataExtractor.parseISO6709("+4885+00229+1+2/"))
    }
}

// MARK: - Clustering

final class GeoClusteringTests: XCTestCase {
    private func point(_ id: String, _ lat: Double, _ lon: Double, day: Int = 1) -> GeoPoint {
        GeoPoint(id: id, coordinate: GeoCoordinate(latitude: lat, longitude: lon), date: GeoFixture.utcDate(2024, 1, day))
    }

    private var points: [GeoPoint] {
        [
            point("paris-1", 48.8584, 2.2945, day: 3),
            point("paris-2", 48.8606, 2.3376, day: 9),
            point("paris-3", 48.8530, 2.3499, day: 5),
            point("london", 51.5007, -0.1246, day: 2),
            point("sydney", -33.8568, 151.2153, day: 7),
            point("nowhere", 0, 0, day: 8),
        ]
    }

    func testDeterministicRegardlessOfInputOrder() {
        for zoom in [0, 3, 6, 12, 18] {
            let a = GeoClustering.cluster(points, zoom: zoom)
            let b = GeoClustering.cluster(points.reversed(), zoom: zoom)
            let c = GeoClustering.cluster(points.shuffled(), zoom: zoom)
            XCTAssertEqual(a, b, "zoom \(zoom)")
            XCTAssertEqual(a, c, "zoom \(zoom)")
            // Every plausible point is in exactly one cluster; 0,0 is dropped.
            XCTAssertEqual(a.reduce(0) { $0 + $1.count }, 5)
            XCTAssertEqual(Set(a.flatMap(\.memberIDs)).count, 5)
        }
    }

    func testClustersSplitAsZoomIncreases() {
        let world = GeoClustering.cluster(points, zoom: 2)
        let paris = try! XCTUnwrap(world.first { $0.memberIDs.contains("paris-1") })
        XCTAssertEqual(Set(paris.memberIDs), ["paris-1", "paris-2", "paris-3"])
        // Newest first: the badge shows paris-2 (the 9th).
        XCTAssertEqual(paris.memberIDs, ["paris-2", "paris-3", "paris-1"])
        XCTAssertEqual(paris.newestID, "paris-2")
        XCTAssertEqual(world.first?.id, paris.id, "largest cluster first")
        XCTAssertEqual(paris.center.latitude, (48.8584 + 48.8606 + 48.8530) / 3, accuracy: 1e-9)
        XCTAssertEqual(paris.minLongitude, 2.2945, accuracy: 1e-9)
        XCTAssertEqual(paris.maxLongitude, 2.3499, accuracy: 1e-9)

        let street = GeoClustering.cluster(points, zoom: 16)
        XCTAssertEqual(street.count, 5)
        XCTAssertTrue(street.allSatisfy { $0.count == 1 })
        XCTAssertTrue(street.allSatisfy { $0.id.hasPrefix("16/") })
    }

    func testCellsAndZoomLevels() {
        let a = GeoClustering.cell(for: GeoCoordinate(latitude: 10, longitude: -179.99), zoom: 0)
        XCTAssertEqual(a.x, 0)
        let b = GeoClustering.cell(for: GeoCoordinate(latitude: 10, longitude: 179.99), zoom: 0)
        XCTAssertEqual(b.x, GeoClustering.defaultCellsPerTile - 1)
        let north = GeoClustering.mercator(GeoCoordinate(latitude: 89, longitude: 0))
        XCTAssertEqual(north.y, 0, accuracy: 1e-9)

        XCTAssertEqual(GeoClustering.zoomLevel(longitudeDelta: 360, viewWidth: 256), 0)
        XCTAssertEqual(GeoClustering.zoomLevel(longitudeDelta: 360.0 / 1024, viewWidth: 256), 10)
        XCTAssertEqual(GeoClustering.zoomLevel(longitudeDelta: 360.0 / 1024, viewWidth: 512), 11)
        XCTAssertEqual(GeoClustering.zoomLevel(longitudeDelta: 0, viewWidth: 512), 0)
        XCTAssertEqual(GeoClustering.zoomLevel(longitudeDelta: 1e-9, viewWidth: 512), GeoClustering.zoomRange.upperBound)
    }

    func testRegionContainment() {
        XCTAssertTrue(GeoClustering.region(centerLatitude: 48.86, centerLongitude: 2.33, latitudeDelta: 1, longitudeDelta: 1,
                                           contains: GeoCoordinate(latitude: 48.85, longitude: 2.35)))
        XCTAssertFalse(GeoClustering.region(centerLatitude: 48.86, centerLongitude: 2.33, latitudeDelta: 1, longitudeDelta: 1,
                                            contains: GeoCoordinate(latitude: 51.5, longitude: -0.12)))
        // Across the antimeridian.
        XCTAssertTrue(GeoClustering.region(centerLatitude: 0, centerLongitude: 179.5, latitudeDelta: 4, longitudeDelta: 4,
                                           contains: GeoCoordinate(latitude: 0, longitude: -179.5)))
    }
}

// MARK: - Timeline bucketing

final class TimelineBucketingTests: XCTestCase {
    private let utc = GeoFixture.calendar(TimeZone(secondsFromGMT: 0)!)
    private let newYork = GeoFixture.calendar(TimeZone(identifier: "America/New_York")!)

    private func item(_ path: String, _ date: Date, offset: Int? = nil) -> TimelineItem {
        TimelineItem(path: path, date: date, source: offset == nil ? .modified : .captured, utcOffset: offset)
    }

    func testTimeZones() {
        // 23:30 on New Year's Eve in New York is 04:30 UTC on the 1st.
        let instant = GeoFixture.utcDate(2025, 1, 1, 4, 30)
        let captured = item("a", instant, offset: -5 * 3600)
        let fileDated = item("b", instant)
        XCTAssertEqual(TimelineBucketer.day(of: captured, calendar: utc), TimelineDay(year: 2024, month: 12, day: 31))
        XCTAssertEqual(TimelineBucketer.day(of: fileDated, calendar: utc), TimelineDay(year: 2025, month: 1, day: 1))
        XCTAssertEqual(TimelineBucketer.day(of: fileDated, calendar: newYork), TimelineDay(year: 2024, month: 12, day: 31))

        let years = TimelineBucketer.sections(for: [captured, fileDated], zoom: .year, calendar: utc)
        XCTAssertEqual(years.map(\.id), ["y2025", "y2024"])
        XCTAssertEqual(years.map { $0.items.map(\.path) }, [["b"], ["a"]])
        let sameZone = TimelineBucketer.sections(for: [captured, fileDated], zoom: .day, calendar: newYork)
        XCTAssertEqual(sameZone.map(\.id), ["d2024-12-31"])
        XCTAssertEqual(sameZone.first?.items.count, 2)
    }

    func testYearMonthDayBuckets() {
        let items = [
            item("jan-1-a", GeoFixture.utcDate(2024, 1, 1, 9)),
            item("jan-1-b", GeoFixture.utcDate(2024, 1, 1, 18)),
            item("jan-20", GeoFixture.utcDate(2024, 1, 20, 12)),
            item("apr-2", GeoFixture.utcDate(2024, 4, 2, 12), offset: 0),
            item("dec-2023", GeoFixture.utcDate(2023, 12, 31, 12)),
        ]
        let days = TimelineBucketer.sections(for: items, zoom: .day, calendar: utc)
        XCTAssertEqual(days.map(\.id), ["d2024-04-02", "d2024-01-20", "d2024-01-01", "d2023-12-31"])
        XCTAssertEqual(days[2].items.map(\.path), ["jan-1-b", "jan-1-a"], "newest first within a day")
        XCTAssertEqual(days[0].capturedCount, 1)
        XCTAssertEqual(days[2].capturedCount, 0)

        let months = TimelineBucketer.sections(for: items, zoom: .month, calendar: utc)
        XCTAssertEqual(months.map(\.id), ["m2024-04", "m2024-01", "m2023-12"])
        XCTAssertEqual(months.map(\.items.count), [1, 3, 1])
        XCTAssertNil(months[0].day)

        let years = TimelineBucketer.sections(for: items, zoom: .year, calendar: utc)
        XCTAssertEqual(years.map(\.id), ["y2024", "y2023"])
        XCTAssertEqual(years.map(\.items.count), [4, 1])
        XCTAssertNil(years[0].month)

        // Day items (what the lightbox walks).
        XCTAssertEqual(TimelineBucketer.dayItems(containing: items[0], in: items, calendar: utc).map(\.path), ["jan-1-b", "jan-1-a"])
    }

    func testMonthBinsIncludeEmptyMonthsAndJumpTargets() {
        let items = [
            item("jan", GeoFixture.utcDate(2024, 1, 10)),
            item("jan2", GeoFixture.utcDate(2024, 1, 11)),
            item("apr", GeoFixture.utcDate(2024, 4, 3)),
        ]
        let bins = TimelineBucketer.monthBins(for: items, calendar: utc)
        XCTAssertEqual(bins.map(\.id), ["2024-04", "2024-03", "2024-02", "2024-01"])
        XCTAssertEqual(bins.map(\.count), [1, 0, 0, 2])

        let days = TimelineBucketer.sections(for: items, zoom: .day, calendar: utc)
        // An empty month jumps to the next older period that exists.
        XCTAssertEqual(TimelineBucketer.sectionID(for: bins[1], in: days), "d2024-01-11")
        XCTAssertEqual(TimelineBucketer.sectionID(for: bins[0], in: days), "d2024-04-03")
        let years = TimelineBucketer.sections(for: items, zoom: .year, calendar: utc)
        XCTAssertEqual(TimelineBucketer.sectionID(for: bins[3], in: years), "y2024")
        XCTAssertNil(TimelineBucketer.sectionID(for: bins[0], in: []))
    }

    func testTitlesAndGroupKeys() {
        let locale = Locale(identifier: "en_US")
        let section = TimelineSection(id: "m2024-03", zoom: .month, year: 2024, month: 3, day: nil, items: [])
        XCTAssertEqual(TimelineBucketer.title(for: section, locale: locale), "March 2024")
        let year = TimelineSection(id: "y2024", zoom: .year, year: 2024, month: nil, day: nil, items: [])
        XCTAssertEqual(TimelineBucketer.title(for: year, locale: locale), "2024")

        // Group By Month / Year use the capture's own offset.
        let resolved = ResolvedCaptureDate(date: GeoFixture.utcDate(2025, 1, 1, 4, 30), source: .captured, utcOffset: -5 * 3600, origin: .exif)
        XCTAssertEqual(CaptureDateGrouping.key(for: resolved, byYear: true, calendar: utc).key, "2024")
        XCTAssertEqual(CaptureDateGrouping.key(for: resolved, byYear: false, calendar: utc).key, "2024-12")
        XCTAssertTrue(GroupByField.month.usesCaptureDates)
        XCTAssertFalse(GroupByField.day.usesCaptureDates)
        XCTAssertEqual(SortField.captureDate.title, "Capture Date")
    }

    func testFiftyThousandItemsBucketQuickly() {
        let base = GeoFixture.utcDate(2020, 1, 1).timeIntervalSince1970
        let items = (0..<50_000).map { index in
            item("/lib/\(index).png", Date(timeIntervalSince1970: base + Double(index) * 3_000))
        }
        let start = Date()
        let days = TimelineBucketer.sections(for: items, zoom: .day, calendar: utc)
        let bins = TimelineBucketer.monthBins(for: items, calendar: utc)
        XCTAssertEqual(days.reduce(0) { $0 + $1.items.count }, 50_000)
        XCTAssertGreaterThan(bins.count, 50)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }
}

// MARK: - Index migration

final class CaptureIndexMigrationTests: TempDirectoryTestCase {
    /// The index schema before capture dates existed.
    private func makeOldDatabase(at url: URL, fileRowPath: String, mtime: Double) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let schema = """
        CREATE TABLE files(
            id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE, folder TEXT, name TEXT, mtime REAL, size INTEGER,
            model TEXT, sampler TEXT, seed TEXT, steps TEXT, cfg TEXT, width INTEGER, height INTEGER
        );
        CREATE INDEX files_folder ON files(folder);
        CREATE VIRTUAL TABLE prompts USING fts5(path UNINDEXED, name, prompt, negative, tokenize = 'unicode61 remove_diacritics 2');
        CREATE TABLE roots(root TEXT PRIMARY KEY, last_indexed REAL);
        """
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)
        let folder = (fileRowPath as NSString).deletingLastPathComponent
        let insert = """
        INSERT INTO files(id, path, folder, name, mtime, size, model, sampler, seed, steps, cfg, width, height)
        VALUES(1, '\(fileRowPath)', '\(folder)', 'photo.jpg', \(mtime), 1234, 'dreamshaper', 'Euler a', '42', '30', '7', 16, 12);
        INSERT INTO prompts(rowid, path, name, prompt, negative) VALUES(1, '\(fileRowPath)', 'photo.jpg', 'a lighthouse at dusk', 'blurry');
        INSERT INTO roots(root, last_indexed) VALUES('\(folder)', 1700000000);
        """
        XCTAssertEqual(sqlite3_exec(db, insert, nil, nil, nil), SQLITE_OK)
    }

    private func columns(at url: URL) -> Set<String> {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        var names = Set<String>()
        if sqlite3_prepare_v2(db, "PRAGMA table_info(files)", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                names.insert(String(cString: sqlite3_column_text(stmt, 1)))
            }
        }
        sqlite3_finalize(stmt)
        return names
    }

    func testMigrationAddsColumnsWithoutDataLossAndBackfills() async throws {
        let library = tempDir.appendingPathComponent("lib", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let photo = library.appendingPathComponent("photo.jpg")
        try GeoFixture.jpeg(
            exif: [kCGImagePropertyExifDateTimeOriginal: "2017:08:21 18:25:00", kCGImagePropertyExifOffsetTimeOriginal: "-07:00"],
            gps: [kCGImagePropertyGPSLatitude: 44.0, kCGImagePropertyGPSLatitudeRef: "N",
                  kCGImagePropertyGPSLongitude: 121.0, kCGImagePropertyGPSLongitudeRef: "W"]
        ).write(to: photo)
        let mtime = try XCTUnwrap(photo.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).timeIntervalSince1970

        let dbURL = tempDir.appendingPathComponent("db/index.sqlite")
        try makeOldDatabase(at: dbURL, fileRowPath: photo.path, mtime: mtime)
        XCTAssertFalse(columns(at: dbURL).contains("capture_date"))

        let service = LibraryIndexService(databaseURL: dbURL)
        // Opening migrates in place: the old row, its prompt and its parameters survive.
        let stats = await service.stats(under: nil)
        XCTAssertEqual(stats.fileCount, 1)
        let hits = await service.search("lighthouse", under: nil)
        XCTAssertEqual(hits.map(\.path), [photo.path])
        let parameters = await service.parameters(forPaths: [photo.path])
        XCTAssertEqual(parameters[photo.path]?.model, "dreamshaper")
        XCTAssertEqual(parameters[photo.path]?.seed, "42")
        let migrated = columns(at: dbURL)
        for column in LibraryIndexService.captureColumns.map(\.name) {
            XCTAssertTrue(migrated.contains(column), column)
        }

        // Not read yet: the row falls back to its modification date.
        let beforeRows = await service.captureRows(forPaths: [photo.path])
        let before = try XCTUnwrap(beforeRows[photo.path])
        XCTAssertFalse(before.isExtracted)
        XCTAssertEqual(before.resolved?.source, .modified)
        let pending = await service.captureBackfillPendingCount(under: library)
        XCTAssertEqual(pending, 1)

        // The backfill reads it.
        let updated = await service.backfillCaptureMetadata(under: library)
        XCTAssertEqual(updated, 1)
        let afterRows = await service.captureRows(forPaths: [photo.path])
        let after = try XCTUnwrap(afterRows[photo.path])
        XCTAssertTrue(after.isExtracted)
        XCTAssertEqual(after.resolved?.source, .captured)
        XCTAssertEqual(after.resolved?.date, GeoFixture.utcDate(2017, 8, 22, 1, 25))
        XCTAssertEqual(after.capture.utcOffset, -7 * 3600)
        XCTAssertEqual(after.capture.coordinate?.longitude ?? 0, -121, accuracy: 1e-9)
        let pendingAfter = await service.captureBackfillPendingCount(under: library)
        XCTAssertEqual(pendingAfter, 0)
        // Still searchable, parameters intact.
        let hitsAfter = await service.search("lighthouse", under: nil)
        XCTAssertEqual(hitsAfter.count, 1)
        let parametersAfter = await service.parameters(forPaths: [photo.path])
        XCTAssertEqual(parametersAfter[photo.path]?.sampler, "Euler a")

        // Re-opening an already migrated database is a no-op.
        let reopened = LibraryIndexService(databaseURL: dbURL)
        let reopenedRow = await reopened.captureRows(forPaths: [photo.path])[photo.path]
        XCTAssertEqual(reopenedRow?.resolved?.source, .captured)
    }

    func testStoreCaptureOnlyTouchesUnchangedRows() async throws {
        let library = tempDir.appendingPathComponent("lib", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let file = library.appendingPathComponent("a.png")
        try PNGFixture.basePNG().write(to: file)
        let service = LibraryIndexService(databaseURL: tempDir.appendingPathComponent("db/index.sqlite"))
        await service.indexLibrary(root: library, progress: nil)
        let rows = await service.captureRows(forPaths: [file.path])
        let row = try XCTUnwrap(rows[file.path])
        let mtime = try XCTUnwrap(row.mtime).timeIntervalSince1970
        let capture = CaptureMetadata(captureDate: GeoFixture.utcDate(2020, 2, 2), origin: .generator, utcOffset: 0,
                                      coordinate: GeoCoordinate(latitude: 1, longitude: 2))
        // A stale mtime (the file changed since it was read) is ignored.
        await service.storeCapture([CaptureIndexUpdate(path: file.path, mtime: mtime - 100, ctime: nil, capture: capture)])
        let unchanged = await service.captureRows(forPaths: [file.path])
        XCTAssertNil(unchanged[file.path]?.capture.captureDate)
        await service.storeCapture([CaptureIndexUpdate(path: file.path, mtime: mtime, ctime: nil, capture: capture)])
        let storedRows = await service.captureRows(forPaths: [file.path])
        let stored = try XCTUnwrap(storedRows[file.path])
        XCTAssertEqual(stored.capture.captureDate, GeoFixture.utcDate(2020, 2, 2))
        XCTAssertEqual(stored.capture.origin, .generator)
        XCTAssertNotNil(stored.ctime, "the creation date is kept when the update has none")
    }
}

// MARK: - Controller

@MainActor
final class GeoTimelineControllerTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "GeoTimelineControllerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testChoicesPersistAndItemsSortNewestFirst() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("GeoCtl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = LibraryIndexService(databaseURL: dir.appendingPathComponent("index.sqlite"))
        let controller = GeoTimelineController(defaults: defaults, index: index)
        XCTAssertEqual(controller.scope, .folder)
        XCTAssertEqual(controller.zoom, .day)
        controller.scope = .library
        controller.zoom = .month
        let again = GeoTimelineController(defaults: defaults, index: index)
        XCTAssertEqual(again.scope, .library)
        XCTAssertEqual(again.zoom, .month)

        controller.calendar = GeoFixture.calendar(TimeZone(secondsFromGMT: 0)!)
        let generation = controller.beginLoad()
        controller.setItems([
            TimelineItem(path: "/a", date: GeoFixture.utcDate(2024, 1, 1), source: .created),
            TimelineItem(path: "/b", date: GeoFixture.utcDate(2024, 3, 1), source: .captured, utcOffset: 0,
                         origin: .exif, coordinate: GeoCoordinate(latitude: 10, longitude: 20)),
        ], unfilteredCount: 2, generation: generation)
        XCTAssertEqual(controller.items.map(\.path), ["/b", "/a"])
        XCTAssertEqual(controller.geoPoints.map(\.id), ["/b"])
        // A stale load's results are dropped.
        _ = controller.beginLoad()
        controller.setItems([], unfilteredCount: 0, generation: generation)
        XCTAssertEqual(controller.items.count, 2)

        // Buckets arrive off the main actor.
        for _ in 0..<200 where controller.sections.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(controller.sections.map(\.id), ["m2024-03", "m2024-01"])
        XCTAssertEqual(controller.monthBins.count, 3)
        XCTAssertEqual(GeoTimelineController.placeKey(for: GeoCoordinate(latitude: 48.85771, longitude: 2.29501)), "48.86,2.30")
    }

    func testReadCapturesFallsBackToTheFileAndCaches() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("GeoCtl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let photo = dir.appendingPathComponent("p.jpg")
        try GeoFixture.jpeg(exif: [kCGImagePropertyExifDateTimeOriginal: "2016:05:05 05:05:05", kCGImagePropertyExifOffsetTimeOriginal: "+00:00"]).write(to: photo)
        let index = LibraryIndexService(databaseURL: dir.appendingPathComponent("index.sqlite"))
        let controller = GeoTimelineController(defaults: defaults, index: index)
        let entry = try XCTUnwrap(FileEntry.load(from: photo))
        let capture = await controller.capture(for: entry)
        XCTAssertEqual(capture.captureDate, GeoFixture.utcDate(2016, 5, 5, 5, 5, 5))
        // Cached: a second read works even with the file gone.
        try FileManager.default.removeItem(at: photo)
        let cached = await controller.capture(for: entry)
        XCTAssertEqual(cached.origin, .exif)
    }
}
