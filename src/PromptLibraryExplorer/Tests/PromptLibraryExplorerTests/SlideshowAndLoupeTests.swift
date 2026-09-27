import CoreGraphics
import XCTest
@testable import PromptLibraryExplorer

// Slideshow sequencing (seeded shuffle, loop / stop), what plays, options
// persistence (injected defaults), the loupe's geometry, the viewing
// controller's settings, and "no deletion" in the controls. All pure.

final class SlideshowSequenceTests: XCTestCase {
    func testShuffleIsDeterministicForASeed() {
        let a = SlideshowSequence(count: 20, start: 0, shuffle: true, loop: false, seed: 42)
        let b = SlideshowSequence(count: 20, start: 0, shuffle: true, loop: false, seed: 42)
        let c = SlideshowSequence(count: 20, start: 0, shuffle: true, loop: false, seed: 43)
        XCTAssertEqual(a.order, b.order)
        XCTAssertNotEqual(a.order, c.order)
        XCTAssertEqual(Set(a.order), Set(0..<20), "every slide exactly once")
        XCTAssertEqual(a.order.count, 20)
        XCTAssertNotEqual(a.order, Array(0..<20))
    }

    func testShuffleStartsOnTheChosenSlide() {
        let sequence = SlideshowSequence(count: 10, start: 7, shuffle: true, loop: true, seed: 1)
        XCTAssertEqual(sequence.current, 7)
        XCTAssertEqual(sequence.order.first, 7)
    }

    func testSeededGeneratorSequence() {
        var one = SeededGenerator(seed: 99)
        var two = SeededGenerator(seed: 99)
        let first = (0..<5).map { _ in one.next() }
        XCTAssertEqual(first, (0..<5).map { _ in two.next() })
        XCTAssertEqual(Set(first).count, 5)
    }

    func testInOrderStopsAtTheEndWithoutLoop() {
        var sequence = SlideshowSequence(count: 3, start: 1, shuffle: false, loop: false, seed: 0)
        XCTAssertEqual(sequence.current, 1)
        XCTAssertEqual(sequence.positionText, "2 / 3")
        XCTAssertEqual(sequence.advance(), 2)
        XCTAssertTrue(sequence.isAtEnd)
        XCTAssertNil(sequence.advance(), "stops at the end")
        XCTAssertEqual(sequence.current, 2, "stays on the last slide")
        XCTAssertEqual(sequence.goBack(), 1)
        XCTAssertEqual(sequence.goBack(), 0)
        XCTAssertNil(sequence.goBack(), "no wrap backwards without loop")
    }

    func testLoopWrapsBothWays() {
        var sequence = SlideshowSequence(count: 3, start: 2, shuffle: false, loop: true, seed: 0)
        XCTAssertEqual(sequence.advance(), 0)
        XCTAssertEqual(sequence.goBack(), 2)
        var shuffled = SlideshowSequence(count: 4, start: 0, shuffle: true, loop: true, seed: 5)
        let order = shuffled.order
        var played: [Int] = [shuffled.current!]
        for _ in 0..<7 { played.append(shuffled.advance()!) }
        XCTAssertEqual(played, order + order, "a loop replays the same order")
    }

    func testRestartAndEmpty() {
        var sequence = SlideshowSequence(count: 3, start: 2, shuffle: false, loop: false, seed: 0)
        sequence.restart()
        XCTAssertEqual(sequence.current, 0)
        var empty = SlideshowSequence(count: 0, start: 0, shuffle: true, loop: true, seed: 0)
        XCTAssertTrue(empty.isEmpty)
        XCTAssertNil(empty.current)
        XCTAssertNil(empty.advance())
        XCTAssertEqual(empty.positionText, "0 / 0")
    }
}

final class SlideshowPlanTests: XCTestCase {
    private func entry(_ name: String, directory: Bool = false) -> FileEntry {
        FileEntry(url: URL(fileURLWithPath: "/lib/\(name)"), isDirectory: directory)
    }

    func testListingPlaysInOrderStartingAtTheSelection() {
        let listing = [entry("sub", directory: true), entry("a.png"), entry("b.mp4"), entry("c.jpg"), entry("notes.plib")]
        let plan = SlideshowEligibility.slides(listing: listing, selectedPaths: ["/lib/c.jpg"], includeVideos: true)
        XCTAssertEqual(plan.slides.map(\.name), ["a.png", "b.mp4", "c.jpg"])
        XCTAssertEqual(plan.start, 2)
    }

    func testVideosCanBeLeftOut() {
        let listing = [entry("a.png"), entry("b.mov"), entry("board.mlmboard")]
        let plan = SlideshowEligibility.slides(listing: listing, selectedPaths: [], includeVideos: false)
        XCTAssertEqual(plan.slides.map(\.name), ["a.png", "board.mlmboard"])
        XCTAssertEqual(plan.start, 0)
    }

    func testATwoFileSelectionPlaysOnlyTheSelectionInListingOrder() {
        let listing = [entry("a.png"), entry("b.png"), entry("c.png"), entry("d.png")]
        let plan = SlideshowEligibility.slides(listing: listing, selectedPaths: ["/lib/d.png", "/lib/b.png"], includeVideos: true)
        XCTAssertEqual(plan.slides.map(\.name), ["b.png", "d.png"])
        XCTAssertEqual(plan.start, 0)
    }

    func testTheListingIsTheSourceOfTruthForFilters() {
        // A filtered listing (e.g. rejects hidden) never brings hidden files back.
        let visible = [entry("keep1.png"), entry("keep2.png")]
        let plan = SlideshowEligibility.slides(listing: visible, selectedPaths: ["/lib/hidden-reject.png", "/lib/keep2.png"], includeVideos: true)
        XCTAssertEqual(plan.slides.map(\.name), ["keep1.png", "keep2.png"])
    }

    func testPromptExcerpt() {
        XCTAssertEqual(SlideshowEligibility.promptExcerpt("a cat\n\n on a  mat"), "a cat on a  mat")
        let long = String(repeating: "word ", count: 60)
        let excerpt = SlideshowEligibility.promptExcerpt(long, limit: 40)
        XCTAssertTrue(excerpt.hasSuffix("…"))
        XCTAssertLessThanOrEqual(excerpt.count, 41)
    }

    func testOptionsRoundTripThroughInjectedDefaults() throws {
        let suite = "SlideshowPlanTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(SlideshowOptions.load(from: defaults), SlideshowOptions())
        var options = SlideshowOptions()
        options.interval = 12
        options.transition = .slide
        options.shuffle = true
        options.loop = false
        options.showPromptExcerpt = true
        options.includeVideos = false
        options.background = .white
        options.save(to: defaults)
        XCTAssertEqual(SlideshowOptions.load(from: defaults), options)
        options.interval = 99
        XCTAssertEqual(options.clampedInterval, 30)
        options.interval = 0
        XCTAssertEqual(options.clampedInterval, 2)
    }

    func testKeysAreBareArrowsSpaceAndEscapeOnly() {
        XCTAssertEqual(SlideshowKeyAction.action(keyCode: KeyCode.leftArrow.rawValue, hasModifiers: false), .previous)
        XCTAssertEqual(SlideshowKeyAction.action(keyCode: KeyCode.rightArrow.rawValue, hasModifiers: false), .next)
        XCTAssertEqual(SlideshowKeyAction.action(keyCode: KeyCode.space.rawValue, hasModifiers: false), .playPause)
        XCTAssertEqual(SlideshowKeyAction.action(keyCode: KeyCode.escape.rawValue, hasModifiers: false), .close)
        XCTAssertNil(SlideshowKeyAction.action(keyCode: KeyCode.rightArrow.rawValue, hasModifiers: true), "⌘→ etc. belong to the menus")
        XCTAssertNil(SlideshowKeyAction.action(keyCode: KeyCode.delete.rawValue, hasModifiers: false), "Delete does nothing in a slideshow")
    }

    func testSlideshowControlsOfferNoDeletion() {
        for action in SlideshowControlAction.allCases {
            for word in ["trash", "delete", "remove", "reject"] {
                XCTAssertFalse(action.title.lowercased().contains(word), action.title)
            }
        }
    }
}

@MainActor
final class SlideshowModelTests: XCTestCase {
    private func entries(_ names: [String]) -> [FileEntry] {
        names.map { FileEntry(url: URL(fileURLWithPath: "/nonexistent-slideshow-test/\($0)"), isDirectory: false) }
    }

    func testTogglingIncludeVideosRebuildsAroundTheCurrentSlide() {
        var options = SlideshowOptions()
        options.includeVideos = true
        let model = SlideshowModel(slides: entries(["a.png", "b.mov", "c.png"]), start: 2, options: options, seed: 7)
        XCTAssertEqual(model.slides.count, 3)
        XCTAssertEqual(model.currentEntry?.name, "c.png")
        model.options.includeVideos = false
        XCTAssertEqual(model.slides.map(\.name), ["a.png", "c.png"])
        XCTAssertEqual(model.currentEntry?.name, "c.png", "stays on the slide shown")
        model.end()
    }

    func testCaptionUsesTheRatingProvider() {
        var options = SlideshowOptions()
        options.showRating = true
        let model = SlideshowModel(slides: entries(["a.png"]), start: 0, options: options, seed: 1) { _ in 4 }
        XCTAssertNil(model.captionRating, "nothing displayed yet")
        XCTAssertTrue(model.captionLines.isEmpty)
        model.end()
    }
}

final class LoupeGeometryTests: XCTestCase {
    func testLightboxImageRectMirrorsFitScaleAndOffset() {
        let rect = LoupeGeometry.lightboxImageRect(
            imageSize: CGSize(width: 2000, height: 1000),
            viewport: CGSize(width: 1036, height: 836),
            padding: 18, zoomScale: 1, offset: .zero
        )
        XCTAssertEqual(rect, CGRect(x: 18, y: 168, width: 1000, height: 500))
        let zoomed = LoupeGeometry.lightboxImageRect(
            imageSize: CGSize(width: 2000, height: 1000),
            viewport: CGSize(width: 1036, height: 836),
            padding: 18, zoomScale: 2, offset: CGSize(width: 100, height: -20)
        )
        XCTAssertEqual(zoomed, CGRect(x: 518 + 100 - 1000, y: 418 - 20 - 500, width: 2000, height: 1000))
    }

    func testPixelUnderThePointer() {
        let rect = CGRect(x: 100, y: 100, width: 400, height: 200)
        let pixel = LoupeGeometry.pixel(at: CGPoint(x: 300, y: 150), imageRect: rect, pixelSize: CGSize(width: 4000, height: 2000))
        XCTAssertEqual(pixel, CGPoint(x: 2000, y: 500))
        XCTAssertNil(LoupeGeometry.pixel(at: CGPoint(x: 50, y: 150), imageRect: rect, pixelSize: CGSize(width: 4000, height: 2000)))
    }

    func testMagnificationIsScreenPixelsPerImagePixel() {
        // 180 pt loupe on a 2× screen = 360 screen px; at 2× that's 180 image px, at 4× 90.
        let two = LoupeGeometry.sourceRect(around: CGPoint(x: 1000, y: 1000), diameter: 180, magnification: 2, backingScale: 2)
        XCTAssertEqual(two.width, 180)
        XCTAssertEqual(two.midX, 1000)
        let four = LoupeGeometry.sourceRect(around: CGPoint(x: 1000, y: 1000), diameter: 180, magnification: 4, backingScale: 2)
        XCTAssertEqual(four.width, 90)
    }

    func testEdgeOfTheImageIsPlacedInsideTheLoupe() throws {
        let source = CGRect(x: -45, y: 10, width: 90, height: 90)
        let part = try XCTUnwrap(LoupeGeometry.visiblePart(of: source, pixelSize: CGSize(width: 500, height: 500), diameter: 180))
        XCTAssertEqual(part.crop, CGRect(x: 0, y: 10, width: 45, height: 90))
        XCTAssertEqual(part.placement, CGRect(x: 90, y: 0, width: 90, height: 180))
        XCTAssertNil(LoupeGeometry.visiblePart(of: CGRect(x: -200, y: 0, width: 90, height: 90), pixelSize: CGSize(width: 500, height: 500), diameter: 180))
    }
}

@MainActor
final class ViewingControllerSettingsTests: XCTestCase {
    func testLoupeAndHistogramSettingsPersistInInjectedDefaults() throws {
        let suite = "ViewingControllerSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let controller = ViewingController(defaults: defaults)
        XCTAssertFalse(controller.loupeEnabled)
        XCTAssertEqual(controller.loupeMagnification, 2)
        XCTAssertTrue(controller.loupeNearestNeighbour)
        XCTAssertFalse(controller.histogramEnabled)

        controller.loupeEnabled = true
        controller.loupeMagnification = 4
        controller.loupeNearestNeighbour = false
        controller.histogramEnabled = true

        let reloaded = ViewingController(defaults: defaults)
        XCTAssertTrue(reloaded.loupeEnabled)
        XCTAssertEqual(reloaded.loupeMagnification, 4)
        XCTAssertFalse(reloaded.loupeNearestNeighbour)
        XCTAssertTrue(reloaded.histogramEnabled)
    }

    func testPointerIsOnlyTrackedWhileTheLoupeIsOn() throws {
        let suite = "ViewingControllerSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = ViewingController(defaults: defaults)
        controller.updateLightboxPointer(CGPoint(x: 5, y: 5))
        XCTAssertNil(controller.lightboxPointer)
        controller.loupeEnabled = true
        controller.updateLightboxPointer(CGPoint(x: 5, y: 5))
        XCTAssertEqual(controller.lightboxPointer, CGPoint(x: 5, y: 5))
        controller.loupeEnabled = false
        controller.updateLightboxPointer(CGPoint(x: 6, y: 6))
        XCTAssertNil(controller.lightboxPointer)
    }

    func testComparePageNeedsTwoToFourFiles() throws {
        let suite = "ViewingControllerSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = ViewingController(defaults: defaults)
        controller.showComparePage(paths: ["/x/a.png"])
        XCTAssertNil(controller.comparePage)
        controller.showComparePage(paths: ["/nonexistent-compare/a.png", "/nonexistent-compare/b.png"])
        XCTAssertEqual(controller.comparePage?.paths.count, 2)
        controller.closeComparePage()
        XCTAssertNil(controller.comparePage)
    }
}
