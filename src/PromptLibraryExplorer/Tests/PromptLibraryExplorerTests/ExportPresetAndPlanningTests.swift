import XCTest
@testable import PromptLibraryExplorer

final class ExportPresetTests: TempDirectoryTestCase {
    func testDefaultsShipTheNamedPresets() {
        let names = ExportPreset.defaults.map(\.name)
        XCTAssertEqual(Array(names.prefix(4)), ["Web JPEG 2048", "Full-res PNG", "Instagram 1080", "HEIC Archive"])
        XCTAssertTrue(ExportPreset.defaults.contains(where: \.isSharingPreset))
        XCTAssertEqual(Set(ExportPreset.defaults.map(\.id)).count, ExportPreset.defaults.count, "ids are unique")

        let web = ExportPreset.webJPEG2048
        XCTAssertEqual(web.format, .jpeg)
        XCTAssertEqual(web.sizing.mode, .longEdge)
        XCTAssertEqual(web.sizing.longEdge, 2048)
        XCTAssertEqual(web.colorProfile, .sRGB)

        let sharing = ExportPreset.sharing
        XCTAssertEqual(sharing.format, .keepOriginal)
        XCTAssertEqual(sharing.sizing.mode, .original)
        XCTAssertEqual(sharing.metadata.mode, .stripAI)
        XCTAssertTrue(sharing.stripMediaMetadata)
    }

    func testPresetRoundTripsThroughJSON() throws {
        var preset = ExportPreset(name: "Custom")
        preset.format = .tiff
        preset.sizing = ExportSizing(mode: .exact, width: 800, height: 600)
        preset.quality = 0.42
        preset.colorProfile = .displayP3
        preset.metadata = ExportMetadataPolicy(mode: .keepOnly, keptFields: [.seed, .gps])
        preset.filenameTemplate = "{date}_{counter:3}"
        preset.destination = .subfolder
        preset.subfolderName = "Out"
        preset.collision = .skip
        preset.watermark.isEnabled = true
        preset.watermark.kind = .image
        preset.watermark.imagePath = "/tmp/logo.png"
        preset.watermark.position = .topLeft
        preset.exportRenderedDocuments = true

        let data = try ExportPresetStore.encode([preset])
        let decoded = try XCTUnwrap(ExportPresetStore.decode(data))
        XCTAssertEqual(decoded, [preset])
    }

    func testLenientDecodingKeepsGoodPresetsAndFillsDefaults() throws {
        let json = """
        {"version": 1, "presets": [
          {"id": "6E0C1F0A-0001-4000-8000-000000000001", "name": "Partial", "format": "jpeg", "futureKey": 3,
           "metadata": {"mode": "keepOnly", "keptFields": ["prompt", "somethingNew"]}},
          {"name": 42},
          {"name": "Unknown format", "format": "jxl"}
        ]}
        """
        let decoded = try XCTUnwrap(ExportPresetStore.decode(Data(json.utf8)))
        XCTAssertEqual(decoded.count, 3)
        XCTAssertEqual(decoded[0].name, "Partial")
        XCTAssertEqual(decoded[0].format, .jpeg)
        XCTAssertEqual(decoded[0].metadata.keptFields, [.prompt])
        XCTAssertEqual(decoded[0].filenameTemplate, "{name}")
        XCTAssertEqual(decoded[0].sizing, .original)
        XCTAssertEqual(decoded[1].name, "Preset")
        XCTAssertEqual(decoded[2].format, .keepOriginal)
    }

    @MainActor
    func testStorePersistsToItsFile() throws {
        let url = tempDir.appendingPathComponent("presets.json")
        let store = ExportPresetStore(fileURL: url)
        XCTAssertEqual(store.presets.count, ExportPreset.defaults.count, "first launch gets the defaults")

        let copy = store.add(copyOf: ExportPreset.webJPEG2048)
        XCTAssertEqual(copy.name, "Web JPEG 2048 Copy")
        store.delete(id: ExportPreset.fullResPNGID)
        store.delete(id: ExportPreset.sharingID) // never deletable

        let reloaded = ExportPresetStore(fileURL: url)
        XCTAssertEqual(reloaded.presets.map(\.id), store.presets.map(\.id))
        XCTAssertNil(reloaded.preset(id: ExportPreset.fullResPNGID))
        XCTAssertEqual(reloaded.sharingPreset.id, ExportPreset.sharingID)

        reloaded.restoreDefaults()
        XCTAssertNotNil(reloaded.preset(id: ExportPreset.fullResPNGID))
        XCTAssertNotNil(reloaded.preset(id: copy.id), "custom presets survive a restore")
    }

    func testKeepOriginalResolvesPerSource() {
        XCTAssertEqual(ExportFormat.keepOriginal.resolved(forSourceExtension: "PNG"), .png)
        XCTAssertEqual(ExportFormat.keepOriginal.resolved(forSourceExtension: "jpeg"), .jpeg)
        XCTAssertEqual(ExportFormat.keepOriginal.resolved(forSourceExtension: "gif"), .png)
        XCTAssertEqual(ExportFormat.jpeg.resolved(forSourceExtension: "png"), .jpeg)
        if !ExportFormat.webp.isAvailable {
            XCTAssertFalse(ExportFormat.availableCases.contains(.webp), "WebP is hidden when ImageIO can't write it")
            XCTAssertEqual(ExportFormat.webp.resolved(forSourceExtension: "png"), .png)
        }
    }
}

final class ExportGeometryTests: XCTestCase {
    private func plan(_ w: Int, _ h: Int, _ sizing: ExportSizing) -> ExportResizePlan {
        ExportGeometry.plan(sourceWidth: w, sourceHeight: h, sizing: sizing)
    }

    func testOriginalKeepsSize() {
        let p = plan(1024, 768, .original)
        XCTAssertEqual(p.outputWidth, 1024)
        XCTAssertEqual(p.outputHeight, 768)
        XCTAssertFalse(p.changesPixels)
    }

    func testLongEdgeScalesDownButNeverUpByDefault() {
        let landscape = plan(4000, 3000, ExportSizing(mode: .longEdge, longEdge: 2048))
        XCTAssertEqual(landscape.outputWidth, 2048)
        XCTAssertEqual(landscape.outputHeight, 1536)
        XCTAssertTrue(landscape.changesPixels)

        let portrait = plan(1000, 3000, ExportSizing(mode: .longEdge, longEdge: 1080))
        XCTAssertEqual(portrait.outputWidth, 360)
        XCTAssertEqual(portrait.outputHeight, 1080)

        let small = plan(800, 600, ExportSizing(mode: .longEdge, longEdge: 2048))
        XCTAssertEqual(small.outputWidth, 800)
        XCTAssertFalse(small.changesPixels)

        let upscaled = plan(800, 600, ExportSizing(mode: .longEdge, longEdge: 1600, allowUpscale: true))
        XCTAssertEqual(upscaled.outputWidth, 1600)
        XCTAssertEqual(upscaled.outputHeight, 1200)
    }

    func testScalePercent() {
        let half = plan(1001, 500, ExportSizing(mode: .scale, scalePercent: 50))
        XCTAssertEqual(half.outputWidth, 501)
        XCTAssertEqual(half.outputHeight, 250)
        XCTAssertFalse(plan(10, 10, ExportSizing(mode: .scale, scalePercent: 100)).changesPixels)
        let tiny = plan(10, 10, ExportSizing(mode: .scale, scalePercent: 0))
        XCTAssertEqual(tiny.outputWidth, 1, "clamped to at least 1 px (1%)")
    }

    func testExactSizeCropsToFillCentred() {
        let wide = plan(2000, 1000, ExportSizing(mode: .exact, width: 1080, height: 1080))
        XCTAssertEqual(wide.outputWidth, 1080)
        XCTAssertEqual(wide.outputHeight, 1080)
        XCTAssertEqual(wide.sourceCrop, CGRect(x: 500, y: 0, width: 1000, height: 1000))

        let tall = plan(1000, 3000, ExportSizing(mode: .exact, width: 800, height: 1000))
        XCTAssertEqual(tall.sourceCrop.width, 1000)
        XCTAssertEqual(tall.sourceCrop.height, 1250, accuracy: 0.001)
        XCTAssertEqual(tall.sourceCrop.minY, 875, accuracy: 0.001)
    }

    func testEstimatesKeepSourceSizeWhenNotReencoding() {
        XCTAssertEqual(ExportEstimator.estimatedBytes(
            sourceBytes: 12_345, sourcePixels: 100, outputPixels: 100,
            sourceFormat: .png, outputFormat: .png, quality: 0.9, reencodes: false
        ), 12_345)
        let jpegHigh = ExportEstimator.estimatedBytes(sourceBytes: 0, sourcePixels: 0, outputPixels: 1_000_000, sourceFormat: .png, outputFormat: .jpeg, quality: 0.95, reencodes: true)
        let jpegLow = ExportEstimator.estimatedBytes(sourceBytes: 0, sourcePixels: 0, outputPixels: 1_000_000, sourceFormat: .png, outputFormat: .jpeg, quality: 0.5, reencodes: true)
        XCTAssertGreaterThan(jpegHigh, jpegLow)
    }
}

final class ExportNamingTests: XCTestCase {
    private let folder = URL(fileURLWithPath: "/tmp/plx-export-tests/out", isDirectory: true)
    private let sourceFolder = URL(fileURLWithPath: "/tmp/plx-export-tests/src", isDirectory: true)

    private func request(_ name: String, ext: String, folder: URL? = nil, index: Int = 0, seed: String? = nil) -> ExportNameRequest {
        let url = sourceFolder.appendingPathComponent(name)
        return ExportNameRequest(
            source: url,
            context: RenameTemplateContext(url: url, index: index, seed: seed),
            outputExtension: ext,
            folder: folder ?? self.folder
        )
    }

    func testTemplateUsesOutputExtensionAndTokens() {
        let names = ExportNamePlanner.plan(
            template: "{name}_s{seed}_{counter:3}",
            requests: [request("cat.png", ext: "jpg", index: 0, seed: "42"), request("dog.png", ext: "jpg", index: 1, seed: "7")],
            collision: .unique,
            existingNames: { _ in [] }
        )
        XCTAssertEqual(names.map(\.destination.lastPathComponent), ["cat_s42_001.jpg", "dog_s7_002.jpg"])
        XCTAssertTrue(names.allSatisfy { $0.action == .write })
    }

    func testCollisionsWithinTheBatchAlwaysGetNumbers() {
        let names = ExportNamePlanner.plan(
            template: "export",
            requests: [request("a.png", ext: "png"), request("b.png", ext: "png"), request("c.png", ext: "png")],
            collision: .overwrite,
            existingNames: { _ in [] }
        )
        XCTAssertEqual(names.map(\.destination.lastPathComponent), ["export.png", "export 2.png", "export 3.png"])
    }

    func testCollisionPoliciesAgainstExistingFiles() {
        let existing: Set<String> = ["Cat.jpg", "cat 2.jpg"]
        let unique = ExportNamePlanner.plan(template: "{name}", requests: [request("cat.png", ext: "jpg")], collision: .unique, existingNames: { _ in existing })
        XCTAssertEqual(unique[0].destination.lastPathComponent, "cat 3.jpg", "case-insensitive, skips taken numbers")
        XCTAssertEqual(unique[0].action, .write)

        let overwrite = ExportNamePlanner.plan(template: "{name}", requests: [request("cat.png", ext: "jpg")], collision: .overwrite, existingNames: { _ in existing })
        XCTAssertEqual(overwrite[0].destination.lastPathComponent, "cat.jpg")
        XCTAssertEqual(overwrite[0].action, .overwrite)

        let skip = ExportNamePlanner.plan(template: "{name}", requests: [request("cat.png", ext: "jpg")], collision: .skip, existingNames: { _ in existing })
        XCTAssertEqual(skip[0].action, .skip)
    }

    func testNeverTargetsAnOriginal() {
        // Exporting into the source folder with the same name and format.
        let names = ExportNamePlanner.plan(
            template: "{name}",
            requests: [request("cat.png", ext: "png", folder: sourceFolder)],
            collision: .overwrite,
            existingNames: { _ in ["cat.png"] }
        )
        XCTAssertEqual(names[0].destination.lastPathComponent, "cat 2.png")
        XCTAssertEqual(names[0].action, .write)
    }

    func testEmptyTemplateFallsBackToName() {
        let names = ExportNamePlanner.plan(template: "  ", requests: [request("cat.png", ext: "heic")], collision: .unique, existingNames: { _ in [] })
        XCTAssertEqual(names[0].destination.lastPathComponent, "cat.heic")
    }

    func testJobPlannerRoutesKindsAndDestinations() {
        var preset = ExportPreset.webJPEG2048
        preset.destination = .subfolder
        preset.subfolderName = "Web/Out"
        let items = ["a.png", "b.mp4", "c.mlmboard", "d.txt"].map { ExportSourceItem(url: sourceFolder.appendingPathComponent($0)) }
        let jobs = ExportJobPlanner.plan(items: items, preset: preset, chosenFolder: nil, existingNames: { _ in [] })
        XCTAssertEqual(jobs.map(\.kind), [.image, .video, .document, .unsupported])
        XCTAssertEqual(jobs[0].destination.path, "/tmp/plx-export-tests/src/Web-Out/a.jpg")
        XCTAssertEqual(jobs[0].format, .jpeg)
        XCTAssertEqual(jobs[1].destination.lastPathComponent, "b.mp4")
        XCTAssertEqual(jobs[2].destination.lastPathComponent, "c.jpg")
        XCTAssertEqual(jobs[3].action, .skip)

        let preview = ExportJobPlanner.preview(items: items, preset: preset, chosenFolder: nil, existingNames: { _ in [] })
        XCTAssertEqual(preview.imageCount, 1)
        XCTAssertEqual(preview.mediaCount, 1)
        XCTAssertEqual(preview.documentCount, 1)
        XCTAssertEqual(preview.unsupportedCount, 1)
        XCTAssertEqual(preview.samples.map(\.output), ["a.jpg", "b.mp4"], "skipped documents aren't listed")
    }
}
