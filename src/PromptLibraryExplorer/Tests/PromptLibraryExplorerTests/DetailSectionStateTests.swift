import XCTest
@testable import PromptLibraryExplorer

// Details-panel sections: expanded by default, collapse state persists per id
// (injected defaults).

@MainActor
final class DetailSectionStateTests: XCTestCase {
    func testSectionsStartExpandedAndCollapseStatePersists() throws {
        let suite = "DetailSectionStateTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let state = DetailSectionState(defaults: defaults)
        XCTAssertTrue(state.isExpanded("File Info"))

        state.setExpanded(false, for: "File Info")
        state.binding(for: "Prompt").wrappedValue = false
        XCTAssertFalse(state.isExpanded("File Info"))
        XCTAssertTrue(state.isExpanded("Generation Info"))

        let reloaded = DetailSectionState(defaults: defaults)
        XCTAssertFalse(reloaded.isExpanded("File Info"))
        XCTAssertFalse(reloaded.isExpanded("Prompt"))

        reloaded.setExpanded(true, for: "File Info")
        XCTAssertTrue(DetailSectionState(defaults: defaults).isExpanded("File Info"))
    }
}
