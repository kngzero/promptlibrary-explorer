import XCTest
@testable import PromptLibraryExplorer

final class TagSuggestionTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "TagSuggestionTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: Classification filtering (mocked Vision results)

    func testContentSuggestionsApplyThresholdGenericFilterAndLimit() {
        let labels = [
            ImageLabel(identifier: "structure", confidence: 0.97),   // generic
            ImageLabel(identifier: "people", confidence: 0.95),      // generic
            ImageLabel(identifier: "people_portrait", confidence: 0.9),
            ImageLabel(identifier: "hot_air_balloon", confidence: 0.8),
            ImageLabel(identifier: "portrait_photography", confidence: 0.7), // same readable name as above
            ImageLabel(identifier: "neon", confidence: 0.36),
            ImageLabel(identifier: "sunset_sunrise", confidence: 0.34),     // below 0.35
            ImageLabel(identifier: "cat", confidence: 0.05),
        ]
        let names = TagSuggestionEngine.contentSuggestions(from: labels).map(\.name)
        XCTAssertEqual(names, ["portrait", "hot air balloon", "neon"])
        XCTAssertEqual(TagSuggestionEngine.contentSuggestions(from: labels, threshold: 0.3, limit: 2).map(\.name), ["portrait", "hot air balloon"])
        XCTAssertEqual(TagSuggestionEngine.contentSuggestions(from: labels, threshold: 0.3).last?.name, "sunset")
        XCTAssertTrue(TagSuggestionEngine.contentSuggestions(from: []).isEmpty)
    }

    func testStoredLabelsKeepStrongestAboveFloor() {
        var observations: [(identifier: String, confidence: Float)] = (0..<40).map { ("label\($0)", Float($0) / 40) }
        observations.append(("tiny", 0.01))
        let stored = ImageTextRecognizer.storedLabels(observations)
        XCTAssertEqual(stored.count, ImageTextRecognizer.storedLabelLimit)
        XCTAssertEqual(stored.first?.identifier, "label39")
        XCTAssertFalse(stored.contains { $0.identifier == "tiny" })
    }

    func testColourAndModelSuggestions() {
        XCTAssertEqual(TagSuggestionEngine.colourSuggestion(from: [DominantColor(hex: "#E02020", weight: 0.6)])?.name, "red")
        XCTAssertNil(TagSuggestionEngine.colourSuggestion(from: [DominantColor(hex: "#808080", weight: 0.9)]), "neutrals aren't suggested")
        XCTAssertNil(TagSuggestionEngine.colourSuggestion(from: [DominantColor(hex: "#E02020", weight: 0.05)]), "a sliver of colour isn't the image's colour")
        XCTAssertNil(TagSuggestionEngine.colourSuggestion(from: []))

        XCTAssertEqual(TagSuggestionEngine.modelSuggestion(from: "sd_xl_base_1.0.safetensors")?.name, "sd xl base 1.0")
        XCTAssertEqual(TagSuggestionEngine.modelSuggestion(from: "juggernautXL_v9 [31e35c80fc]")?.name, "juggernautXL v9")
        XCTAssertEqual(TagSuggestionEngine.modelSuggestion(from: "models/checkpoints/flux1-dev.sft")?.name, "flux1-dev")
        XCTAssertNil(TagSuggestionEngine.modelSuggestion(from: "N/A"))
        XCTAssertNil(TagSuggestionEngine.modelSuggestion(from: nil))
    }

    func testSuggestionsDropExistingTagsAndDuplicates() {
        let suggestions = TagSuggestionEngine.suggestions(
            labels: [ImageLabel(identifier: "red", confidence: 0.9), ImageLabel(identifier: "people_portrait", confidence: 0.8)],
            colors: [DominantColor(hex: "#E02020", weight: 0.7)],
            model: "flux1-dev.safetensors",
            existingTagNames: ["Portrait"]
        )
        XCTAssertEqual(suggestions.map(\.name), ["red", "flux1-dev"], "existing tags (any case) and duplicate names are dropped")
        XCTAssertEqual(suggestions.map(\.source), [.content, .model])
    }

    // MARK: Applying requires confirmation

    func testApplyingRequiresConfirmation() {
        let tags = TagService(defaults: defaults)
        let existing = FileTag(name: "Portrait", colorHex: "#EF4444")
        let keep = FileTag(name: "Keeper", colorHex: "#22C55E")
        tags.saveTags([existing, keep])
        tags.saveAssignments(["/a.png": [keep.id]])

        var plan = TagSuggestionPlan(suggestions: [
            (path: "/a.png", suggestions: [
                TagSuggestion(name: "portrait", source: .content, confidence: 0.9),
                TagSuggestion(name: "neon", source: .content, confidence: 0.5),
            ]),
            (path: "/b.png", suggestions: [TagSuggestion(name: "red", source: .colour, confidence: 1)]),
            (path: "/c.png", suggestions: []),
        ])
        XCTAssertEqual(plan.rows.count, 2, "files without suggestions aren't listed")
        XCTAssertEqual(plan.checkedCount, 3)
        plan.toggle(path: "/b.png", suggestionID: "red")
        XCTAssertEqual(plan.checkedCount, 2)
        XCTAssertEqual(plan.fileCount, 1)

        let before = (tags.loadTags(), tags.loadAssignments())
        XCTAssertEqual(TagSuggestionApplier.apply(plan, confirmed: false, tags: tags), .needsConfirmation)
        XCTAssertEqual(tags.loadTags(), before.0, "nothing changes without confirmation")
        XCTAssertEqual(tags.loadAssignments(), before.1)

        let outcome = TagSuggestionApplier.apply(plan, confirmed: true, tags: tags)
        XCTAssertEqual(outcome, .applied(files: 1, tags: 2, createdTags: ["neon"]))
        let names = Set(tags.loadTags().map(\.name))
        XCTAssertEqual(names, ["Portrait", "Keeper", "neon"], "\"portrait\" reuses the existing tag")
        let assigned = Set(tags.loadAssignments()["/a.png"] ?? [])
        XCTAssertTrue(assigned.contains(keep.id), "suggestions only add")
        XCTAssertTrue(assigned.contains(existing.id))
        XCTAssertEqual(assigned.count, 3)
        XCTAssertNil(tags.loadAssignments()["/b.png"], "unchecked suggestions aren't applied")

        // Applying the same plan again adds nothing new.
        XCTAssertEqual(TagSuggestionApplier.apply(plan, confirmed: true, tags: tags), .applied(files: 1, tags: 0, createdTags: []))
    }

    func testCheckAllAndUncheckAll() {
        var plan = TagSuggestionPlan(suggestions: [(path: "/a.png", suggestions: [TagSuggestion(name: "cat", source: .content, confidence: 0.9)])])
        plan.setAll(false)
        XCTAssertEqual(plan.checkedCount, 0)
        XCTAssertTrue(plan.assignments.isEmpty)
        plan.setAll(true)
        XCTAssertEqual(plan.assignments, ["/a.png": ["cat"]])
    }
}
