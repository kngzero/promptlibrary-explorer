import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PromptLibraryExplorer

/// A fast gradient image (red rises left → right, green top → bottom in pixel rows).
private func gradientImage(width: Int, height: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let colors = [CGColor(red: 0, green: 0, blue: 0.5, alpha: 1), CGColor(red: 1, green: 0, blue: 0.5, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: 0), options: [])
    return context.makeImage()!
}

/// RGBA bytes of pixel (x, y), top-left origin.
private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
    var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let context = CGContext(
        data: &data, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let offset = (y * image.width + x) * 4
    return (data[offset], data[offset + 1], data[offset + 2])
}

private func pngData(_ image: CGImage) -> Data {
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    precondition(CGImageDestinationFinalize(destination))
    return data as Data
}

// MARK: - Recipe model

final class EditRecipeModelTests: XCTestCase {
    func testRecipeRoundTripsThroughJSON() throws {
        var recipe = EditRecipe()
        recipe.crop = EditRect(x: 0.1, y: 0.2, width: 0.5, height: 0.4)
        recipe.aspect = .landscape3x2
        recipe.straighten = -7.25
        recipe.quarterTurns = 3
        recipe.flipHorizontal = true
        recipe.exposure = 0.5
        recipe.contrast = -0.2
        recipe.saturation = 0.3
        recipe.temperature = -0.4
        let data = try JSONEncoder().encode(recipe)
        let decoded = try JSONDecoder().decode(EditRecipe.self, from: data)
        XCTAssertEqual(decoded, recipe.normalized())
        XCTAssertEqual(decoded.hashToken, recipe.hashToken)
        XCTAssertFalse(decoded.isIdentity)
    }

    func testMissingAndLegacyKeysMigrate() throws {
        let empty = try JSONDecoder().decode(EditRecipe.self, from: Data("{}".utf8))
        XCTAssertEqual(empty.version, 1)
        XCTAssertTrue(empty.isIdentity)

        // A hand-written "rotation" in degrees, out-of-range values, unknown keys / aspects.
        let legacy = try JSONDecoder().decode(EditRecipe.self, from: Data("""
        {"rotation": -90, "straighten": 60, "exposure": 9, "aspect": "7:3", "future": {"x": 1},
         "crop": {"x": -0.2, "y": 0, "width": 2, "height": 0.5}}
        """.utf8))
        XCTAssertEqual(legacy.quarterTurns, 3)
        XCTAssertEqual(legacy.straighten, 45)
        XCTAssertEqual(legacy.exposure, 2)
        XCTAssertEqual(legacy.aspect, .free)
        XCTAssertEqual(legacy.crop, EditRect(x: 0, y: 0, width: 1, height: 0.5))

        // A full-frame crop is no crop; the aspect alone changes nothing.
        var full = EditRecipe()
        full.crop = .full
        full.aspect = .square
        XCTAssertNil(full.normalized().crop)
        XCTAssertTrue(full.normalized().isIdentity)
    }

    func testBookSkipsBadEntriesAndMigratesPaths() throws {
        let json = Data("""
        {"version": 1, "recipes": {
          "/lib/a.png": {"quarterTurns": 1},
          "/lib/b.png": {"crop": "not a rect"},
          "/lib/shoot/c.png": {"flipVertical": true},
          "/lib/d.png": {}
        }}
        """.utf8)
        var book = try JSONDecoder().decode(EditBook.self, from: json)
        XCTAssertEqual(Set(book.recipes.keys), ["/lib/a.png", "/lib/shoot/c.png"], "identity and unreadable entries are dropped")

        XCTAssertTrue(book.migrate(from: "/lib/a.png", to: "/lib/renamed.png"))
        XCTAssertTrue(book.migrate(from: "/lib/shoot", to: "/lib/moved"))
        XCTAssertEqual(Set(book.recipes.keys), ["/lib/renamed.png", "/lib/moved/c.png"])
        XCTAssertFalse(book.migrate(from: "/nowhere", to: "/elsewhere"))

        // Trash takes recipes with it; undo puts them back (under the restored name).
        let removed = book.removeAll(under: "/lib/moved")
        XCTAssertEqual(Array(removed.keys), ["/lib/moved/c.png"])
        XCTAssertNil(book.recipes["/lib/moved/c.png"])
        book.restore(removed, from: "/lib/moved", to: "/lib/back")
        XCTAssertEqual(book.recipes["/lib/back/c.png"]?.flipVertical, true)
    }

    func testEligibility() {
        XCTAssertTrue(EditEligibility.isEditable("a.png"))
        XCTAssertTrue(EditEligibility.isEditable("b.JPG"))
        XCTAssertFalse(EditEligibility.isEditable("clip.mov"))
        XCTAssertFalse(EditEligibility.isEditable("song.mp3"))
        XCTAssertFalse(EditEligibility.isEditable("board.mlmboard"))
        XCTAssertFalse(EditEligibility.isEditable("snap.plib"))
        XCTAssertNotNil(EditEligibility.reason(forName: "clip.mov"))
        XCTAssertNil(EditEligibility.reason(forName: "a.png"))
    }
}

// MARK: - Geometry

final class EditGeometryTests: XCTestCase {
    private let size = CGSize(width: 3000, height: 2000)

    func testNormalizedAndPixelRectsRoundTrip() {
        let pixels = CGRect(x: 300, y: 200, width: 1500, height: 1000)
        let normalized = EditGeometry.normalizedRect(for: pixels, in: size)
        XCTAssertEqual(normalized, EditRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5))
        XCTAssertEqual(EditGeometry.pixelRect(for: normalized, in: size), pixels)
        // Whole pixels, inside the frame.
        let odd = EditGeometry.pixelRect(for: EditRect(x: 0.33333, y: 0.5, width: 0.9, height: 0.7), in: size)
        XCTAssertEqual(odd.minX, 1000)
        XCTAssertLessThanOrEqual(odd.maxX, 3000)
        XCTAssertLessThanOrEqual(odd.maxY, 2000)
    }

    func testAspectPresetsProduceTheirRatios() {
        let expected: [EditAspect: CGSize] = [
            .square: CGSize(width: 2000, height: 2000),
            .original: CGSize(width: 3000, height: 2000),
            .landscape3x2: CGSize(width: 3000, height: 2000),
            .portrait4x5: CGSize(width: 1600, height: 2000),
            .landscape16x9: CGSize(width: 3000, height: 1688),
            .portrait9x16: CGSize(width: 1125, height: 2000),
            .portrait2x3: CGSize(width: 1333, height: 2000),
        ]
        for (aspect, output) in expected {
            var recipe = EditRecipe()
            let ratio = EditGeometry.cropPixelRatio(for: aspect, sourceSize: size, quarterTurns: 0)
            recipe.crop = EditGeometry.maxCrop(ratio: ratio, angle: 0, sourceSize: size)
            let result = EditGeometry.outputSize(for: recipe.normalized(), sourceSize: size)
            XCTAssertEqual(result.width, output.width, accuracy: 1, "\(aspect)")
            XCTAssertEqual(result.height, output.height, accuracy: 1, "\(aspect)")
        }
        XCTAssertNil(EditGeometry.cropPixelRatio(for: .free, sourceSize: size, quarterTurns: 0))
    }

    func testQuarterTurnsSwapTheOutputAndTheLockedRatio() {
        var recipe = EditRecipe()
        recipe.quarterTurns = 1
        XCTAssertEqual(EditGeometry.outputSize(for: recipe, sourceSize: size), CGSize(width: 2000, height: 3000))
        // 16:9 output after a quarter turn is a 9:16 crop in source space.
        let ratio = EditGeometry.cropPixelRatio(for: .landscape16x9, sourceSize: size, quarterTurns: 1) ?? 0
        XCTAssertEqual(ratio, 9.0 / 16.0, accuracy: 1e-9)
        recipe.crop = EditGeometry.maxCrop(ratio: ratio, angle: 0, sourceSize: size)
        let output = EditGeometry.outputSize(for: recipe.normalized(), sourceSize: size)
        XCTAssertEqual(output.width / output.height, 16.0 / 9.0, accuracy: 0.01)
        // "Original" follows the turned frame.
        XCTAssertEqual(EditGeometry.frameRatio(sourceSize: size, quarterTurns: 1), 2.0 / 3.0, accuracy: 1e-9)
    }

    func testCropsStayOnTheImageAfterStraighten() {
        for angle in [-45.0, -20, -3.5, 0, 1, 12, 30, 45] {
            for ratio in [nil, 1.0, 16.0 / 9.0, 9.0 / 16.0] {
                let crop = EditGeometry.maxCrop(ratio: ratio, angle: angle, sourceSize: size)
                XCTAssertTrue(EditGeometry.isValid(crop, angle: angle, sourceSize: size), "max crop \(angle)° \(String(describing: ratio))")
                if let ratio {
                    XCTAssertEqual(crop.width * 3000 / (crop.height * 2000), ratio, accuracy: 1e-6)
                }
            }
            // An arbitrary crop shrinks until valid.
            let fitted = EditGeometry.fitted(EditRect(x: 0.6, y: 0.05, width: 0.4, height: 0.9), angle: angle, sourceSize: size)
            XCTAssertTrue(EditGeometry.isValid(fitted, angle: angle, sourceSize: size, tolerance: 1e-5), "fitted \(angle)°")
        }
        XCTAssertFalse(EditGeometry.isValid(.full, angle: 10, sourceSize: size), "a straightened full frame shows empty corners")
        XCTAssertTrue(EditGeometry.isValid(.full, angle: 0, sourceSize: size))

        // A drag towards an empty corner stops at the edge.
        let valid = EditGeometry.maxCrop(ratio: nil, angle: 15, sourceSize: size)
        let pushed = EditGeometry.constrained(from: valid, toward: EditRect(x: 0, y: 0, width: valid.width, height: valid.height), angle: 15, sourceSize: size)
        XCTAssertTrue(EditGeometry.isValid(pushed, angle: 15, sourceSize: size, tolerance: 1e-5))
    }

    func testDisplaySpaceRoundTripsForEveryTurnAndFlip() {
        let rect = EditRect(x: 0.1, y: 0.2, width: 0.3, height: 0.5)
        for turns in 0..<4 {
            for flipH in [false, true] {
                for flipV in [false, true] {
                    let display = EditGeometry.displayRect(fromCrop: rect, quarterTurns: turns, flipH: flipH, flipV: flipV)
                    let back = EditGeometry.cropRect(fromDisplay: display, quarterTurns: turns, flipH: flipH, flipV: flipV)
                    XCTAssertEqual(back.x, rect.x, accuracy: 1e-9)
                    XCTAssertEqual(back.y, rect.y, accuracy: 1e-9)
                    XCTAssertEqual(back.width, rect.width, accuracy: 1e-9)
                    XCTAssertEqual(back.height, rect.height, accuracy: 1e-9)
                }
            }
        }
        // A quarter turn clockwise moves the top-left region to the top-right.
        let turned = EditGeometry.displayRect(fromCrop: EditRect(x: 0, y: 0, width: 0.25, height: 0.5), quarterTurns: 1, flipH: false, flipV: false)
        XCTAssertEqual(turned, EditRect(x: 0.5, y: 0, width: 0.5, height: 0.25))
        // A horizontal flip mirrors x.
        let flipped = EditGeometry.displayRect(fromCrop: EditRect(x: 0, y: 0, width: 0.25, height: 1), quarterTurns: 0, flipH: true, flipV: false)
        XCTAssertEqual(flipped, EditRect(x: 0.75, y: 0, width: 0.25, height: 1))
    }

    func testLockedRatioDragsKeepTheirRatioAndStayInside() {
        let start = EditRect(x: 0.25, y: 0.25, width: 0.4, height: 0.4)
        for handle in EditCropHandle.allCases where handle != .move {
            for (dx, dy) in [(0.3, 0.1), (-0.5, -0.4), (0.05, -0.2)] {
                let result = EditCropHandle.dragged(start, handle: handle, dx: dx, dy: dy, ratio: 1)
                XCTAssertEqual(result.width, result.height, accuracy: 1e-9, "\(handle)")
                XCTAssertGreaterThanOrEqual(result.x, -1e-9)
                XCTAssertGreaterThanOrEqual(result.y, -1e-9)
                XCTAssertLessThanOrEqual(result.maxX, 1 + 1e-9)
                XCTAssertLessThanOrEqual(result.maxY, 1 + 1e-9)
            }
        }
        let moved = EditCropHandle.dragged(start, handle: .move, dx: 0.9, dy: -0.9, ratio: nil)
        XCTAssertEqual(moved, EditRect(x: 0.6, y: 0, width: 0.4, height: 0.4))
    }
}

// MARK: - Rendering

final class EditRendererTests: TempDirectoryTestCase {
    func testSquareCropOf3000By2000Is2000By2000() throws {
        let image = gradientImage(width: 3000, height: 2000)
        var recipe = EditRecipe()
        recipe.aspect = .square
        recipe.crop = EditGeometry.maxCrop(ratio: 1, angle: 0, sourceSize: CGSize(width: 3000, height: 2000))
        let output = try XCTUnwrap(EditRenderer.render(image, recipe: recipe))
        XCTAssertEqual(output.width, 2000)
        XCTAssertEqual(output.height, 2000)
        XCTAssertEqual(CGSize(width: output.width, height: output.height), EditGeometry.outputSize(for: recipe.normalized(), sourceSize: CGSize(width: 3000, height: 2000)))
    }

    func testTurnsFlipsAndStraightenGiveThePlannedSizes() throws {
        let size = CGSize(width: 300, height: 200)
        let image = gradientImage(width: 300, height: 200)

        var turned = EditRecipe()
        turned.quarterTurns = 1
        let turnedOutput = try XCTUnwrap(EditRenderer.render(image, recipe: turned))
        XCTAssertEqual(turnedOutput.width, 200)
        XCTAssertEqual(turnedOutput.height, 300)

        var straightened = EditRecipe()
        straightened.straighten = 10
        straightened.crop = EditGeometry.maxCrop(ratio: nil, angle: 10, sourceSize: size)
        let straightOutput = try XCTUnwrap(EditRenderer.render(image, recipe: straightened))
        let planned = EditGeometry.outputSize(for: straightened.normalized(), sourceSize: size)
        XCTAssertEqual(CGFloat(straightOutput.width), planned.width)
        XCTAssertEqual(CGFloat(straightOutput.height), planned.height)

        // The full frame in the crop tool keeps the turned frame's size.
        let frame = try XCTUnwrap(EditRenderer.render(image, recipe: straightened, showingFullFrame: true))
        XCTAssertEqual(frame.width, 300)
        XCTAssertEqual(frame.height, 200)

        // Previews scale down to fit.
        let small = try XCTUnwrap(EditRenderer.render(image, recipe: turned, maxPixelSize: 90))
        XCTAssertEqual(max(small.width, small.height), 90)
    }

    /// The geometry's idea of "on the image" matches what the renderer draws, so the
    /// straighten direction is the same in both (positive = clockwise).
    func testStraightenValidityMatchesRenderedCoverage() throws {
        let width = 300, height = 200
        let size = CGSize(width: width, height: height)
        var recipe = EditRecipe()
        recipe.straighten = 15
        let frame = try XCTUnwrap(EditRenderer.render(gradientImage(width: width, height: height), recipe: recipe, showingFullFrame: true))
        var alpha = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(
            data: &alpha, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(frame, in: CGRect(x: 0, y: 0, width: width, height: height))
        var checked = 0, mismatched = 0, empty = 0
        for y in stride(from: 2, to: height - 2, by: 4) {
            for x in stride(from: 2, to: width - 2, by: 4) {
                let a = alpha[(y * width + x) * 4 + 3]
                guard a > 250 || a < 5 else { continue }
                let probe = EditRect(x: (Double(x) + 0.5) / Double(width) - 0.001, y: (Double(y) + 0.5) / Double(height) - 0.001, width: 0.002, height: 0.002)
                if EditGeometry.isValid(probe, angle: 15, sourceSize: size) != (a > 250) { mismatched += 1 }
                if a < 5 { empty += 1 }
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 3000)
        XCTAssertGreaterThan(empty, 100, "the straightened frame has empty corners")
        // Only pixels on the rotated edge may disagree; the wrong direction would get
        // whole corner triangles wrong.
        XCTAssertLessThan(Double(mismatched) / Double(checked), 0.01)
        // The top-left corner is empty, the centre covered.
        XCTAssertLessThan(alpha[(1 * width + 1) * 4 + 3], 5)
        XCTAssertGreaterThan(alpha[((height / 2) * width + width / 2) * 4 + 3], 250)
    }

    func testHorizontalFlipMirrorsPixels() throws {
        let image = gradientImage(width: 100, height: 20)
        XCTAssertLessThan(pixel(image, x: 2, y: 10).r, 40, "left edge is dark")
        var recipe = EditRecipe()
        recipe.flipHorizontal = true
        let flipped = try XCTUnwrap(EditRenderer.render(image, recipe: recipe))
        XCTAssertGreaterThan(pixel(flipped, x: 2, y: 10).r, 215, "after the flip the bright right edge is on the left")
        XCTAssertLessThan(pixel(flipped, x: 97, y: 10).r, 40)
    }

    func testFileRenderingUsesADownsampledDecodeForPreviews() throws {
        let url = try writeFile("big.png", pngData(gradientImage(width: 1200, height: 800)))
        var recipe = EditRecipe()
        recipe.crop = EditRect(x: 0, y: 0, width: 0.5, height: 0.5)
        let size = CGSize(width: 1200, height: 800)
        XCTAssertLessThan(EditRenderer.previewDecodeLongEdge(sourceSize: size, recipe: recipe, maxPixelSize: 200), 1200)
        let preview = try XCTUnwrap(EditRenderer.render(url: url, recipe: recipe, maxPixelSize: 200))
        XCTAssertEqual(max(preview.width, preview.height), 200)
        let full = try XCTUnwrap(EditRenderer.render(url: url, recipe: recipe, maxPixelSize: nil))
        XCTAssertEqual(full.width, 600)
        XCTAssertEqual(full.height, 400)
    }
}

// MARK: - Cache keys, exports

final class EditIntegrationTests: TempDirectoryTestCase {
    func testThumbnailCacheKeyChangesWithTheRecipe() throws {
        let url = try writeFile("tile.png", pngData(gradientImage(width: 40, height: 30)))
        let path = url.standardizedFileURL.path
        defer { EditRecipeIndex.shared.set(nil, for: path) }

        let plain = try XCTUnwrap(ThumbnailService.cacheSignature(for: url, size: 256))
        var recipe = EditRecipe()
        recipe.quarterTurns = 1
        EditRecipeIndex.shared.set(recipe, for: path)
        let edited = try XCTUnwrap(ThumbnailService.cacheSignature(for: url, size: 256))
        XCTAssertNotEqual(plain, edited)
        recipe.flipVertical = true
        EditRecipeIndex.shared.set(recipe, for: path)
        let editedAgain = try XCTUnwrap(ThumbnailService.cacheSignature(for: url, size: 256))
        XCTAssertNotEqual(edited, editedAgain)
        XCTAssertEqual(ThumbnailService.cacheSignature(for: url, size: 256, ignoringEdits: true), plain, "Show Original uses the plain key")
        XCTAssertEqual(EditCacheKey.signature("base", recipe: .identity), "base")

        // Exports pick the edit up by default; "Export original" leaves it out.
        let items = [ExportSourceItem(url: url)]
        let preset = ExportPreset(name: "Test")
        let folder = tempDir.appendingPathComponent("out", isDirectory: true)
        let withEdits = ExportJobPlanner.plan(items: items, preset: preset, chosenFolder: folder)
        XCTAssertEqual(withEdits.first?.edit, recipe.normalized())
        let original = ExportJobPlanner.plan(items: items, preset: preset, chosenFolder: folder, applyEdits: false)
        XCTAssertNil(original.first?.edit)
    }

    func testSaveEditedCopyNeverOverwritesAndLeavesTheOriginalUntouched() async throws {
        let base = pngData(gradientImage(width: 60, height: 40))
        let originalData = PNGFixture.png(with: [PNGFixture.tEXt("parameters", "a red fox, Steps: 20")], base: base)
        let url = try writeFile("fox.png", originalData)
        let squatter = try writeFile("fox (edited).png", Data("keep me".utf8))

        var recipe = EditRecipe()
        recipe.crop = EditGeometry.maxCrop(ratio: 1, angle: 0, sourceSize: CGSize(width: 60, height: 40))
        let written = try await EditCopyWriter.write(source: url, recipe: recipe, stripAIMetadata: false)

        XCTAssertEqual(written.lastPathComponent, "fox (edited 2).png")
        XCTAssertEqual(try Data(contentsOf: url), originalData, "the original is byte-identical")
        XCTAssertEqual(try Data(contentsOf: squatter), Data("keep me".utf8), "an existing file is never replaced")
        let output = try Data(contentsOf: written)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(output as CFData, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 40)
        XCTAssertEqual(props[kCGImagePropertyPixelHeight] as? Int, 40)
        XCTAssertFalse(PNGFixture.textChunks(output, keyword: "parameters").isEmpty, "the copy keeps the prompt metadata")

        // With "Strip AI metadata" the prompt stays out of the copy.
        let stripped = try await EditCopyWriter.write(source: url, recipe: recipe, stripAIMetadata: true)
        XCTAssertEqual(stripped.lastPathComponent, "fox (edited 3).png")
        XCTAssertTrue(PNGFixture.textChunks(try Data(contentsOf: stripped), keyword: "parameters").isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), originalData)
    }

    func testCopyNamesSkipTakenNames() {
        let source = URL(fileURLWithPath: "/lib/shot.jpg")
        let taken: Set<String> = ["/lib/shot (edited).jpg", "/lib/shot (edited 2).jpg"]
        let destination = EditCopyWriter.destination(for: source, fileExtension: "jpg", exists: { taken.contains($0) })
        XCTAssertEqual(destination.path, "/lib/shot (edited 3).jpg")
    }
}

// MARK: - Curation data: bundles and library sync

@MainActor
final class EditCurationTests: XCTestCase {
    private var created: [CurationTestStores] = []

    override func tearDown() {
        MainActor.assumeIsolated {
            created.forEach { $0.tearDown() }
            created = []
        }
        super.tearDown()
    }

    private func makeStores() -> CurationTestStores {
        let stores = CurationTestStores()
        created.append(stores)
        return stores
    }

    private func sampleRecipe() -> EditRecipe {
        var recipe = EditRecipe()
        recipe.crop = EditRect(x: 0.1, y: 0.1, width: 0.6, height: 0.5)
        recipe.straighten = 2.5
        recipe.quarterTurns = 1
        recipe.saturation = 0.25
        return recipe.normalized()
    }

    func testEditsRoundTripThroughACurationBundle() throws {
        let root = "/Users/a/Dropbox/Library"
        let source = makeStores()
        let recipe = sampleRecipe()
        source.stores.edits.save(EditBook(recipes: ["\(root)/a.png": recipe, "/elsewhere/b.jpg": recipe]))

        let bundle = CurationBundleBuilder.make(
            from: source.stores, roots: [URL(fileURLWithPath: root)], reason: "manual",
            now: Date(timeIntervalSince1970: 1_700_000_000), machineName: "Test Mac", deviceID: "device", appVersion: "1"
        )
        XCTAssertEqual(bundle.counts.edits, 2)
        XCTAssertEqual(bundle.edits.first { $0.item.path == "\(root)/a.png" }?.item.relativePath, "a.png")
        let decoded = try CurationBundle.decode(bundle.encoded())
        XCTAssertEqual(decoded, bundle)

        let target = makeStores()
        let resolver = CurationPathResolver(localRoots: [], fileExists: { _ in false })
        let plan = CurationImporter.plan(decoded, into: target.stores, mode: .merge, includeSettings: false, resolver: resolver)
        XCTAssertEqual(plan.first { $0.id == "edits" }?.added, 2)
        CurationImporter.apply(decoded, to: target.stores, mode: .replace, includeSettings: false, resolver: resolver)
        XCTAssertEqual(target.stores.edits.load(), source.stores.edits.load())

        // Bundles from before edits existed read as having none.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: bundle.encoded()) as? [String: Any])
        json.removeValue(forKey: "edits")
        let older = try CurationBundle.decode(JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(older.edits.isEmpty)
    }

    func testEditsSyncThroughTheLibraryFileAcrossRoots() throws {
        let rootA = "/Users/a/Dropbox/Library"
        let rootB = "/Users/b/Library/CloudStorage/Dropbox/Library"
        let macA = makeStores().stores
        let macB = makeStores().stores
        let recipe = sampleRecipe()
        macA.edits.save(EditBook(recipes: ["\(rootA)/shoot/a.png": recipe, "/outside/x.png": recipe]))

        let snapshotA = CurationLibraryAdapter.snapshot(root: rootA, stores: macA)
        XCTAssertEqual(snapshotA.edits, ["shoot/a.png": recipe], "files outside the root stay out")
        let ledgerA = CurationMergeEngine.stamp(ledger: nil, current: snapshotA, now: Date(), device: "A")
        let received = try LibraryCurationDocument.decode(ledgerA.encoded())
        XCTAssertEqual(received.edits["shoot/a.png"]?.value, recipe, "the recipe survives the JSON round trip exactly")

        let baseB = CurationLibraryAdapter.snapshot(root: rootB, stores: macB)
        let merged = CurationMergeEngine.synchronize(ledger: nil, current: baseB, remotes: [received], now: Date(), device: "B")
        CurationLibraryAdapter.apply(target: merged.document.portableState, base: baseB, root: rootB, stores: macB)
        XCTAssertEqual(macB.edits.load().recipes, ["\(rootB)/shoot/a.png": recipe])

        // Mac A reverts: the tombstone removes the edit on Mac B.
        macA.edits.save(EditBook(recipes: ["/outside/x.png": recipe]))
        let later = Date().addingTimeInterval(60)
        let revertA = CurationMergeEngine.synchronize(ledger: ledgerA, current: CurationLibraryAdapter.snapshot(root: rootA, stores: macA), remotes: [], now: later, device: "A")
        XCTAssertTrue(revertA.fileDocument.edits["shoot/a.png"]?.isTombstone ?? false)
        let baseB2 = CurationLibraryAdapter.snapshot(root: rootB, stores: macB)
        let mergedB2 = CurationMergeEngine.synchronize(ledger: merged.document, current: baseB2, remotes: [revertA.fileDocument], now: later, device: "B")
        CurationLibraryAdapter.apply(target: mergedB2.document.portableState, base: baseB2, root: rootB, stores: macB)
        XCTAssertTrue(macB.edits.load().recipes.isEmpty)
    }

    func testControllerFollowsRenamesAndTrashUndo() {
        let suite = "EditControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let index = EditRecipeIndex()
        let controller = EditController(store: EditStore(defaults: defaults), index: index)
        let recipe = sampleRecipe()

        let replaced = controller.apply(["/lib/a.png": recipe])
        XCTAssertEqual(replaced.count, 1)
        XCTAssertEqual(replaced["/lib/a.png"], .some(nil), "undo would write 'no recipe' back")
        XCTAssertTrue(controller.isEdited("/lib/a.png"))
        XCTAssertEqual(index.recipe(for: "/lib/a.png"), recipe)
        XCTAssertFalse(controller.token(for: "/lib/a.png").isEmpty)

        controller.itemDidMove(from: "/lib/a.png", to: "/lib/b.png")
        XCTAssertFalse(controller.isEdited("/lib/a.png"))
        XCTAssertTrue(controller.isEdited("/lib/b.png"))
        XCTAssertEqual(EditStore(defaults: defaults).load().recipes["/lib/b.png"], recipe, "persisted")

        let snapshot = controller.removeAll(under: "/lib/b.png")
        XCTAssertFalse(controller.isEdited("/lib/b.png"))
        controller.restore(snapshot, from: "/lib/b.png", to: "/lib/b 2.png")
        XCTAssertTrue(controller.isEdited("/lib/b 2.png"))

        // Revert (nil) and an identity recipe both remove the edit.
        controller.apply(["/lib/b 2.png": .identity])
        XCTAssertFalse(controller.isEdited("/lib/b 2.png"))
        XCTAssertTrue(controller.apply(["/lib/b 2.png": nil]).isEmpty, "nothing to change")
    }

    func testSessionUndoRedoAndDirtyState() {
        let session = EditorSession(path: "/lib/a.png", savedRecipe: nil)
        XCTAssertFalse(session.isDirty)
        session.flip(horizontal: true)
        session.rotate(clockwise: true)
        XCTAssertTrue(session.isDirty)
        XCTAssertEqual(session.recipe.quarterTurns, 1)
        session.undo()
        XCTAssertEqual(session.recipe.quarterTurns, 0)
        XCTAssertTrue(session.recipe.flipHorizontal)
        session.redo()
        XCTAssertEqual(session.recipe.quarterTurns, 1)

        // One gesture = one undo step.
        session.beginInteraction()
        for value in stride(from: 0.1, through: 0.9, by: 0.1) {
            session.interactiveChange { $0.exposure = value }
        }
        session.endInteraction()
        session.undo()
        XCTAssertEqual(session.recipe.exposure, 0)
        session.revertToOriginal()
        XCTAssertFalse(session.isDirty)
    }
}
