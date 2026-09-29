import XCTest
@testable import PromptLibraryExplorer

// Generation Info's aspect ratio comes from the pixels.

final class AspectRatioLabelTests: XCTestCase {
    func testCommonRatiosWithinOnePercent() {
        XCTAssertEqual(AspectRatioLabel.label(width: 768, height: 1376), "9:16")   // Gemini portrait
        XCTAssertEqual(AspectRatioLabel.label(width: 1024, height: 1024), "1:1")
        XCTAssertEqual(AspectRatioLabel.label(width: 1920, height: 1080), "16:9")
        XCTAssertEqual(AspectRatioLabel.label(width: 1920, height: 2400), "4:5")
        XCTAssertEqual(AspectRatioLabel.label(width: 6000, height: 4000), "3:2")
    }

    func testOtherRatiosReduceOrFallBackToDecimal() {
        XCTAssertEqual(AspectRatioLabel.label(width: 1400, height: 1000), "7:5")
        XCTAssertEqual(AspectRatioLabel.label(width: 1000, height: 1379), "1:1.38")
        XCTAssertEqual(AspectRatioLabel.label(width: 2537, height: 1000), "2.54:1")
        XCTAssertNil(AspectRatioLabel.label(width: 0, height: 100))
    }
}
