import CoreGraphics
import XCTest
@testable import PromptLibraryExplorer

// Compare Images: zoom / pan sync math between images of different sizes,
// anchored zoom, clamping, wipe geometry, decode sizes, eligibility and the
// "no deletion" rule. All pure.

final class CompareGeometryTests: XCTestCase {
    private let master = CGSize(width: 1024, height: 1024)
    private let upscale = CGSize(width: 4096, height: 4096)
    private let viewport = CGSize(width: 500, height: 500)
    private let backing: CGFloat = 2

    private func pane(_ image: CGSize) -> CompareViewState.Pane {
        CompareViewState.Pane(image: image, viewport: viewport)
    }

    private func assertPoint(_ a: CGPoint, _ b: CGPoint, accuracy: CGFloat = 1e-6, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, file: file, line: line)
    }

    // MARK: Fit and zoom levels

    func testFitScaleAndPaneZoom() {
        XCTAssertEqual(CompareGeometry.fitScale(image: master, viewport: viewport), 500.0 / 1024.0, accuracy: 1e-9)
        XCTAssertEqual(CompareGeometry.fitScale(image: CGSize(width: 2000, height: 1000), viewport: viewport), 0.25, accuracy: 1e-9)
        // Fit on a 2× screen: 500 pt = 1000 px for a 1024 px image → 97.7 %.
        let fit = CompareGeometry.paneZoom(.fit, image: master, viewport: viewport, backingScale: backing, framing: .matched, reference: master)
        XCTAssertEqual(fit, 1000.0 / 1024.0, accuracy: 1e-9)
    }

    func testMatchedFramingScalesEveryPaneToImageA() {
        // 100 % of the 1024 master = 25 % of the 4096 upscale: both span the same screen area.
        let zoomA = CompareGeometry.paneZoom(.scale(1), image: master, viewport: viewport, backingScale: backing, framing: .matched, reference: master)
        let zoomB = CompareGeometry.paneZoom(.scale(1), image: upscale, viewport: viewport, backingScale: backing, framing: .matched, reference: master)
        XCTAssertEqual(zoomA, 1, accuracy: 1e-9)
        XCTAssertEqual(zoomB, 0.25, accuracy: 1e-9)
        let widthA = master.width * CompareGeometry.pointsPerPixel(paneZoom: zoomA, backingScale: backing)
        let widthB = upscale.width * CompareGeometry.pointsPerPixel(paneZoom: zoomB, backingScale: backing)
        XCTAssertEqual(widthA, widthB, accuracy: 1e-9)
        // Round trip.
        XCTAssertEqual(CompareGeometry.sharedScale(fromPaneZoom: zoomB, image: upscale, framing: .matched, reference: master), 1, accuracy: 1e-9)
    }

    func testActualPixelsFramingKeepsNativeZoom() {
        let zoomB = CompareGeometry.paneZoom(.scale(1), image: upscale, viewport: viewport, backingScale: backing, framing: .actualPixels, reference: master)
        XCTAssertEqual(zoomB, 1)
    }

    // MARK: Sync: content offsets map between images of different sizes

    func testPanInOnePaneShowsTheSameContentInTheOther() {
        var state = CompareViewState()
        state.framing = .actualPixels
        state.zoom = .scale(1)  // both at 100 %: the upscale is 4× larger on screen
        state.pan(by: CGSize(width: -100, height: -50), in: pane(upscale), reference: master, backingScale: backing)

        // Same normalized centre in both panes.
        let rectA = state.imageRect(pane(master), reference: master, backingScale: backing)
        let rectB = state.imageRect(pane(upscale), reference: master, backingScale: backing)
        let centreA = CompareGeometry.normalizedPoint(viewPoint: CGPoint(x: 250, y: 250), imageRect: rectA)
        let centreB = CompareGeometry.normalizedPoint(viewPoint: CGPoint(x: 250, y: 250), imageRect: rectB)
        assertPoint(centreA, centreB)
        // Dragging left by 100 pt at 0.5 pt / px moves 200 px right in the upscale.
        XCTAssertEqual(state.center.x, 0.5 + 200.0 / 4096.0, accuracy: 1e-9)
        XCTAssertEqual(state.center.y, 0.5 + 100.0 / 4096.0, accuracy: 1e-9)
    }

    func testMappedOffsetBetweenDifferentSizes() {
        // 100 pt in a 1024 px image at 0.5 pt/px = 200 px = 19.5 % of it → 19.5 % of the upscale.
        let mapped = CompareGeometry.mappedOffset(
            CGSize(width: 100, height: -40),
            fromScale: 0.5, fromImage: master,
            toScale: 0.5, toImage: upscale
        )
        XCTAssertEqual(mapped.width, 400, accuracy: 1e-9)
        XCTAssertEqual(mapped.height, -160, accuracy: 1e-9)
        // With matched framing (upscale at a quarter of the scale) the offset is identical.
        let matched = CompareGeometry.mappedOffset(CGSize(width: 100, height: -40), fromScale: 0.5, fromImage: master, toScale: 0.125, toImage: upscale)
        XCTAssertEqual(matched.width, 100, accuracy: 1e-9)
        XCTAssertEqual(matched.height, -40, accuracy: 1e-9)
    }

    func testMatchedFramingPanLinesUpPaneRects() {
        var state = CompareViewState()
        state.zoom = .scale(2)
        state.pan(by: CGSize(width: 120, height: 30), in: pane(upscale), reference: master, backingScale: backing)
        let rectA = state.imageRect(pane(master), reference: master, backingScale: backing)
        let rectB = state.imageRect(pane(upscale), reference: master, backingScale: backing)
        XCTAssertEqual(rectA.minX, rectB.minX, accuracy: 1e-6)
        XCTAssertEqual(rectA.minY, rectB.minY, accuracy: 1e-6)
        XCTAssertEqual(rectA.width, rectB.width, accuracy: 1e-6)
    }

    // MARK: Anchored zoom, clamping, double-click

    func testZoomKeepsThePointUnderTheCursor() {
        var state = CompareViewState()
        state.zoom = .scale(1)
        let anchor = CGPoint(x: 400, y: 120)
        let before = CompareGeometry.normalizedPoint(viewPoint: anchor, imageRect: state.imageRect(pane(upscale), reference: upscale, backingScale: backing))
        state.zoom(by: 1.5, anchor: anchor, in: pane(upscale), reference: upscale, backingScale: backing)
        guard case let .scale(scale) = state.zoom else { return XCTFail("expected a scale") }
        XCTAssertEqual(scale, 1.5, accuracy: 1e-9)
        let after = CompareGeometry.normalizedPoint(viewPoint: anchor, imageRect: state.imageRect(pane(upscale), reference: upscale, backingScale: backing))
        assertPoint(before, after, accuracy: 1e-9)
    }

    func testZoomFromFitStartsAtTheFitScale() {
        var state = CompareViewState()
        state.zoom(by: 2, anchor: CGPoint(x: 250, y: 250), in: pane(master), reference: master, backingScale: backing)
        guard case let .scale(scale) = state.zoom else { return XCTFail("expected a scale") }
        XCTAssertEqual(scale, 2 * 1000.0 / 1024.0, accuracy: 1e-9)
    }

    func testCenterIsClampedToKeepTheImageCovering() {
        var state = CompareViewState()
        state.zoom = .scale(1)
        // Huge drag to the right: centre stops where the left edge meets the viewport.
        state.pan(by: CGSize(width: 10_000, height: 0), in: pane(upscale), reference: upscale, backingScale: backing)
        let displayedWidth = upscale.width * 0.5  // 2048 pt
        XCTAssertEqual(state.center.x, 250 / displayedWidth, accuracy: 1e-9)
        let rect = state.imageRect(pane(upscale), reference: upscale, backingScale: backing)
        XCTAssertEqual(rect.minX, 0, accuracy: 1e-6)
        // Smaller than the viewport: stays centred.
        XCTAssertEqual(CompareGeometry.clampedCenter(CGPoint(x: 0.1, y: 0.9), scale: 0.1, image: master, viewport: viewport), CGPoint(x: 0.5, y: 0.5))
    }

    func testPanDoesNothingAtFit() {
        var state = CompareViewState()
        state.pan(by: CGSize(width: 50, height: 50), in: pane(master), reference: master, backingScale: backing)
        XCTAssertEqual(state.center, CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(state.zoom, .fit)
    }

    func testDoubleClickTogglesFitAndActualPixels() {
        var state = CompareViewState()
        // Click the top-left quarter of the fitted master.
        let rect = state.imageRect(pane(master), reference: master, backingScale: backing)
        let point = CGPoint(x: rect.minX + rect.width * 0.25, y: rect.minY + rect.height * 0.25)
        state.toggleFitActual(at: point, in: pane(master), reference: master, backingScale: backing)
        XCTAssertEqual(state.zoom, .scale(1))
        // 1024 px at 0.5 pt/px = 512 pt wide in a 500 pt viewport: the centre clamps near 0.5.
        XCTAssertEqual(state.center.x, 250.0 / 512.0, accuracy: 1e-9)
        state.toggleFitActual(at: point, in: pane(master), reference: master, backingScale: backing)
        XCTAssertEqual(state.zoom, .fit)
        XCTAssertEqual(state.center, CGPoint(x: 0.5, y: 0.5))
    }

    func testPresetsMatchZoomLevels() {
        XCTAssertEqual(CompareZoomPreset.allCases.map(\.title), ["Fit", "50%", "100%", "200%", "400%"])
        XCTAssertEqual(CompareZoomPreset.matching(.scale(2)), .p200)
        XCTAssertEqual(CompareZoomPreset.matching(.fit), .fit)
        XCTAssertNil(CompareZoomPreset.matching(.scale(1.3)))
        XCTAssertEqual(CompareZoom.clamped(100), .scale(CompareZoom.maximumScale))
    }

    func testNearestNeighbourFrom200Percent() {
        var state = CompareViewState()
        state.zoom = .scale(2)
        XCTAssertTrue(state.usesNearestNeighbour(pane(master), reference: master, backingScale: backing))
        state.zoom = .scale(1)
        XCTAssertFalse(state.usesNearestNeighbour(pane(master), reference: master, backingScale: backing))
    }

    // MARK: Decode sizes

    func testDecodeSizeNeverExceedsNativeAndStepsBy512() {
        XCTAssertEqual(CompareGeometry.decodeLongEdge(paneZoom: 0.2, nativeLongEdge: 4096), 1024)  // 819 → 1024
        XCTAssertEqual(CompareGeometry.decodeLongEdge(paneZoom: 1, nativeLongEdge: 4096), 4096)
        XCTAssertEqual(CompareGeometry.decodeLongEdge(paneZoom: 4, nativeLongEdge: 4096), 4096, "never more than native")
        XCTAssertEqual(CompareGeometry.decodeLongEdge(paneZoom: 0.5, nativeLongEdge: 900), 512)
        XCTAssertEqual(CompareGeometry.decodeLongEdge(paneZoom: 0.9, nativeLongEdge: 900), 900)
    }

    // MARK: Wipe

    func testWipeRegionsAndDivider() {
        let size = CGSize(width: 800, height: 400)
        XCTAssertEqual(CompareWipeGeometry.bRegion(viewport: size, position: 0.25, orientation: .vertical), CGRect(x: 200, y: 0, width: 600, height: 400))
        XCTAssertEqual(CompareWipeGeometry.bRegion(viewport: size, position: 0.5, orientation: .horizontal), CGRect(x: 0, y: 200, width: 800, height: 200))
        XCTAssertEqual(CompareWipeGeometry.position(for: CGPoint(x: 600, y: 10), viewport: size, orientation: .vertical), 0.75)
        XCTAssertEqual(CompareWipeGeometry.position(for: CGPoint(x: -50, y: 10), viewport: size, orientation: .vertical), 0)
        XCTAssertTrue(CompareWipeGeometry.isOnDivider(CGPoint(x: 405, y: 100), viewport: size, position: 0.5, orientation: .vertical))
        XCTAssertFalse(CompareWipeGeometry.isOnDivider(CGPoint(x: 450, y: 100), viewport: size, position: 0.5, orientation: .vertical))
    }

    func testWipeBMatchesAsFrame() {
        let aRect = CGRect(x: 10, y: 20, width: 400, height: 400)
        // Same aspect ratio (a 4× upscale): exactly A's rect.
        XCTAssertEqual(CompareWipeGeometry.bRect(aRect: aRect, bImage: upscale, center: CGPoint(x: 0.3, y: 0.7)), aRect)
        // Wider B: same width, same normalized centre.
        let b = CompareWipeGeometry.bRect(aRect: aRect, bImage: CGSize(width: 2000, height: 1000), center: CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(b.width, 400)
        XCTAssertEqual(b.height, 200)
        XCTAssertEqual(b.midY, aRect.midY, accuracy: 1e-9)
    }

    func testWipeIndicesStayValidAndDistinct() {
        var state = CompareViewState()
        state.wipeA = 2
        state.wipeB = 2
        state.normalizeWipe(count: 3)
        XCTAssertNotEqual(state.wipeA, state.wipeB)
        state.swapWipe()
        XCTAssertEqual(state.wipeA, 0)
        XCTAssertEqual(state.wipeB, 2)
    }

    func testPaneGrid() {
        XCTAssertEqual(CompareGeometry.paneGrid(count: 2, size: viewport).columns, 2)
        XCTAssertEqual(CompareGeometry.paneGrid(count: 3, size: viewport).columns, 3)
        let four = CompareGeometry.paneGrid(count: 4, size: CGSize(width: 1200, height: 800))
        XCTAssertEqual(four.columns, 2)
        XCTAssertEqual(four.rows, 2)
    }

    // MARK: Eligibility and actions

    func testEligibilityNeedsTwoToFourImagesOrVideos() {
        func entries(_ names: [String]) -> [FileEntry] {
            names.map { FileEntry(url: URL(fileURLWithPath: "/lib/\($0)"), isDirectory: false) }
        }
        XCTAssertNil(CompareEligibility.paths(for: entries(["a.png"])))
        XCTAssertEqual(CompareEligibility.paths(for: entries(["a.png", "b.mov"])), ["/lib/a.png", "/lib/b.mov"])
        XCTAssertNotNil(CompareEligibility.paths(for: entries(["a.png", "b.png", "c.jpg", "d.webp"])))
        XCTAssertNil(CompareEligibility.paths(for: entries(["a.png", "b.png", "c.jpg", "d.webp", "e.png"])))
        XCTAssertNil(CompareEligibility.paths(for: entries(["a.png", "notes.plib"])))
        let folder = FileEntry(url: URL(fileURLWithPath: "/lib/folder"), isDirectory: true)
        XCTAssertNil(CompareEligibility.paths(for: entries(["a.png"]) + [folder]))
    }

    func testWindowOfALargeGroupContainsTheFocusedFile() {
        let paths = (1...9).map { "/lib/\($0).png" }
        XCTAssertEqual(CompareEligibility.window(of: paths, containing: "/lib/6.png").paths, ["/lib/5.png", "/lib/6.png", "/lib/7.png", "/lib/8.png"])
        let last = CompareEligibility.window(of: paths, containing: "/lib/9.png")
        XCTAssertEqual(last.paths, ["/lib/6.png", "/lib/7.png", "/lib/8.png", "/lib/9.png"], "the last page is full")
        XCTAssertTrue(last.paths.contains("/lib/9.png"))
        XCTAssertEqual(CompareEligibility.window(of: Array(paths.prefix(3)), containing: nil).paths.count, 3)
    }

    func testCompareOffersNoDeletion() {
        let words = ["trash", "delete", "remove", "discard", "reject"]
        for action in CompareImageAction.allCases {
            for word in words {
                XCTAssertFalse(action.title.lowercased().contains(word), "\(action.title) must not delete")
                XCTAssertFalse(action.rawValue.lowercased().contains(word))
            }
        }
        XCTAssertEqual(Set(CompareImageAction.allCases), [.revealInFinder, .copyPath, .copyPrompt])
    }
}
