import XCTest
@testable import PromptLibraryExplorer

// Pure tests for the visual-search UI models (no database, no view model).

// MARK: - Colour filter / smart-folder decoding

final class VisualFeaturesColorFilterTests: XCTestCase {
    func testColorFilterNormalisesDedupesAndCapsAtThree() throws {
        let filter = try XCTUnwrap(ColorFilter(palette: ["ff0000", "#F00", "#00ff00", "bogus", "#0000FF", "#FFFFFF"], tolerance: 2))
        XCTAssertEqual(filter.palette, ["#FF0000", "#00FF00", "#0000FF"])
        XCTAssertEqual(filter.tolerance, 1, "tolerance is clamped to 0…1")
        XCTAssertNil(ColorFilter(palette: ["nope", ""]))
    }

    func testColorFilterDecodingIsLenient() throws {
        let missingTolerance = try JSONDecoder().decode(ColorFilter.self, from: Data(##"{"palette":["#112233","zz"]}"##.utf8))
        XCTAssertEqual(missingTolerance.palette, ["#112233"])
        XCTAssertEqual(missingTolerance.tolerance, ColorFilter.defaultTolerance)
        XCTAssertThrowsError(try JSONDecoder().decode(ColorFilter.self, from: Data(#"{"palette":["zz"]}"#.utf8)))
    }

    func testColorFilterStorageRoundTripAndGarbage() throws {
        let filter = try XCTUnwrap(ColorFilter(palette: ["#123456"], tolerance: 0.4))
        XCTAssertEqual(ColorFilter(storageString: filter.storageString), filter)
        XCTAssertNil(ColorFilter(storageString: ""))
        XCTAssertNil(ColorFilter(storageString: "not json"))
        XCTAssertNil(ColorFilter(storageString: #"{"palette":[]}"#))
    }

    func testFilterConfigColourFilterCountsAsActiveAndResets() throws {
        var config = FilterConfig()
        XCTAssertEqual(config.activeCount, 0)
        config.colorFilter = ColorFilter(palette: ["#FF0000"])
        XCTAssertEqual(config.activeCount, 1)
        XCTAssertNotEqual(config, FilterConfig(), "clearAllFilters compares against FilterConfig()")
        config = FilterConfig()
        XCTAssertNil(config.colorFilter)
    }

    func testSmartFolderCriteriaWithoutDominantColourStillDecodes() throws {
        let old = #"{"searchQuery":"cat","minRating":3,"labels":[2]}"#
        let criteria = try JSONDecoder().decode(SmartFolderCriteria.self, from: Data(old.utf8))
        XCTAssertNil(criteria.dominantColor)
        XCTAssertEqual(criteria.searchQuery, "cat")
        XCTAssertEqual(criteria.minRating, 3)
    }

    func testSmartFolderCriteriaDominantColourRoundTripsAndBadRuleIsDropped() throws {
        var criteria = SmartFolderCriteria()
        XCTAssertFalse(criteria.isActive)
        criteria.dominantColor = ColorFilter(palette: ["#3366CC"], tolerance: 0.2)
        XCTAssertTrue(criteria.isActive)
        let decoded = try JSONDecoder().decode(SmartFolderCriteria.self, from: JSONEncoder().encode(criteria))
        XCTAssertEqual(decoded.dominantColor, criteria.dominantColor)

        let malformed = #"{"minRating":2,"dominantColor":{"palette":["xyz"]}}"#
        let lenient = try JSONDecoder().decode(SmartFolderCriteria.self, from: Data(malformed.utf8))
        XCTAssertNil(lenient.dominantColor, "a bad palette drops the rule, not the folder")
        XCTAssertEqual(lenient.minRating, 2)
    }

    func testSmartFolderDominantColourRule() throws {
        var criteria = SmartFolderCriteria()
        criteria.dominantColor = ColorFilter(palette: ["#D02020"], tolerance: 0.2)
        let red = FileEntry(url: URL(fileURLWithPath: "/lib/red.png"), isDirectory: false)
        let blue = FileEntry(url: URL(fileURLWithPath: "/lib/blue.png"), isDirectory: false)
        let unindexed = FileEntry(url: URL(fileURLWithPath: "/lib/new.png"), isDirectory: false)
        let context = SmartFolderFilterContext(dominantColorsByPath: [
            red.path: [DominantColor(hex: "#CC2222", weight: 0.6)],
            blue.path: [DominantColor(hex: "#2244CC", weight: 0.7)],
        ])
        let result = SmartFolderService.filter([red, blue, unindexed], criteria: criteria, context: context)
        XCTAssertEqual(result.map(\.path), [red.path])
    }

    func testPaletteMatcherToleranceAndWeights() throws {
        let colors = [DominantColor(hex: "#2E7D32", weight: 0.5), DominantColor(hex: "#FFEB3B", weight: 0.01)]
        let strict = try XCTUnwrap(ColorFilter(palette: ["#2E7D32"], tolerance: 0))
        XCTAssertTrue(PaletteMatcher.matches(colors, filter: strict))
        let yellow = try XCTUnwrap(ColorFilter(palette: ["#FFEB3B"], tolerance: 0))
        XCTAssertFalse(PaletteMatcher.matches(colors, filter: yellow), "colours under the minimum weight are ignored")
        let both = try XCTUnwrap(ColorFilter(palette: ["#2E7D32", "#1565C0"], tolerance: 0.1))
        XCTAssertFalse(PaletteMatcher.matches(colors, filter: both), "every palette colour must be present")
        XCTAssertFalse(PaletteMatcher.matches([], filter: strict))
    }
}

// MARK: - Colour families

final class VisualFeaturesColorFamilyTests: XCTestCase {
    func testHueBuckets() {
        let cases: [(String, ColorFamily)] = [
            ("#E53935", .red), ("#FB8C00", .orange), ("#FDD835", .yellow),
            ("#43A047", .green), ("#00ACC1", .cyan), ("#1E88E5", .blue),
            ("#8E24AA", .purple), ("#D81B60", .pink), ("#FF0000", .red), ("#FF0033", .red),
        ]
        for (hex, family) in cases {
            XCTAssertEqual(ColorFamily(hex: hex), family, hex)
        }
    }

    func testNeutralsDarkAndLight() {
        XCTAssertEqual(ColorFamily(hex: "#111111"), .dark)
        XCTAssertEqual(ColorFamily(hex: "#1A0A30"), .dark, "very dark colours are Dark whatever the hue")
        XCTAssertEqual(ColorFamily(hex: "#808080"), .neutral)
        XCTAssertEqual(ColorFamily(hex: "#F5F5F5"), .light)
        XCTAssertEqual(ColorFamily(hex: "#FFFDF5"), .light)
        XCTAssertNil(ColorFamily(hex: "nope"))
    }

    func testFamilyUsesFirstDominantColour() {
        XCTAssertEqual(ColorFamily.of([DominantColor(hex: "#1E88E5", weight: 0.6), DominantColor(hex: "#E53935", weight: 0.4)]), .blue)
        XCTAssertNil(ColorFamily.of([]))
    }

    func testGroupByOffersColourFamilyWithoutGenerationParameters() {
        XCTAssertTrue(GroupByField.allCases.contains(.colorFamily))
        XCTAssertEqual(GroupByField.colorFamily.title, "Colour Family")
        XCTAssertFalse(GroupByField.colorFamily.needsGenerationParameters)
    }
}

// MARK: - Virtual listing state

final class VisualFeaturesListingStateTests: XCTestCase {
    private func listing(_ title: String = "Similar to a.png") -> VirtualListing {
        VirtualListing(kind: .similarTo(path: "/lib/a.png"), title: title, paths: ["/lib/a.png", "/lib/b.png"])
    }

    func testOpenSimilarListingThenCloseReturnsToFolder() {
        var state = ListingModeState()
        XCTAssertEqual(state.mode, .folder)
        let similar = listing()
        state.openVirtual(similar)
        XCTAssertEqual(state.virtualListing?.id, similar.id)
        XCTAssertEqual(state.virtualListing?.origin, .folder)
        state.closeVirtual()
        XCTAssertEqual(state.mode, .folder)
    }

    func testOpeningFromACollectionReturnsToIt() {
        let collection = UUID()
        var state = ListingModeState(collectionID: collection)
        state.openVirtual(listing())
        XCTAssertNil(state.collectionID, "collection and virtual listing never overlap")
        XCTAssertEqual(state.virtualListing?.origin, .collection(collection))
        state.closeVirtual()
        XCTAssertEqual(state.mode, .collection(collection))
    }

    func testChainedListingsCloseToTheOriginalOrigin() {
        let collection = UUID()
        var state = ListingModeState(collectionID: collection)
        state.openVirtual(listing("first"))
        state.openVirtual(listing("second"))
        XCTAssertEqual(state.virtualListing?.title, "second")
        state.closeVirtual()
        XCTAssertEqual(state.mode, .collection(collection))
    }

    func testCollectionModeUnaffected() {
        let a = UUID(), b = UUID()
        var state = ListingModeState()
        state.openCollection(a)
        XCTAssertEqual(state.mode, .collection(a))
        state.openCollection(b)
        XCTAssertEqual(state.mode, .collection(b))
        state.closeVirtual()  // nothing to close
        XCTAssertEqual(state.mode, .collection(b))
        state.openCollection(nil)
        XCTAssertEqual(state.mode, .folder)
    }

    func testCollectionOrFolderReplacesVirtualListing() {
        var state = ListingModeState()
        state.openVirtual(listing())
        let collection = UUID()
        state.openCollection(collection)
        XCTAssertNil(state.virtualListing)
        XCTAssertEqual(state.mode, .collection(collection))

        state.openVirtual(listing())
        state.selectFolder()
        XCTAssertEqual(state.mode, .folder)
    }

    func testVirtualListingFollowsRenames() {
        var similar = listing()
        XCTAssertTrue(similar.migratePaths(from: "/lib", to: "/archive"))
        XCTAssertEqual(similar.paths, ["/archive/a.png", "/archive/b.png"])
        XCTAssertEqual(similar.sourcePath, "/archive/a.png")
        XCTAssertFalse(similar.migratePaths(from: "/elsewhere", to: "/x"))
    }
}

// MARK: - Similar Images: inspection only

final class VisualFeaturesSimilarImagesTests: XCTestCase {
    private let forbidden = ["trash", "delete", "remove", "keep", "best", "discard", "clean"]

    /// The Similar Images page's card and group actions (the old sheet's
    /// `SimilarGroupAction` was folded into these).
    func testPageExposesNoDeletionAction() {
        XCTAssertEqual(Set(SimilarCardAction.allCases), [.openInLightbox, .revealInFinder, .moreLikeThis, .copyPrompt])
        XCTAssertEqual(Set(SimilarGroupPageAction.allCases), [.selectInBrowser, .addToCollection, .openAsListing])
        let texts = SimilarCardAction.allCases.map { $0.rawValue + " " + $0.title + " " + $0.systemImage }
            + SimilarGroupPageAction.allCases.map { $0.rawValue + " " + $0.title + " " + $0.systemImage }
        for text in texts {
            for word in forbidden {
                XCTAssertFalse(text.lowercased().contains(word), "\(text) mentions \(word)")
            }
        }
    }

    func testRowsKeepTheGroupsOwnOrderAndNeverRankBySize() {
        let set = SimilarSet(id: "g", paths: ["/lib/a/small.png", "/lib/b/huge.png", "/lib/c/mid.png"], kind: .visual)
        let info: [String: SimilarImageInfo] = [
            "/lib/a/small.png": SimilarImageInfo(pixelWidth: 512, pixelHeight: 512, fileSize: 10, folderPath: "/lib/a", isVideo: false),
            "/lib/b/huge.png": SimilarImageInfo(pixelWidth: 4096, pixelHeight: 4096, fileSize: 9_000, folderPath: "/lib/b", isVideo: false),
            "/lib/c/mid.png": SimilarImageInfo(pixelWidth: 1024, pixelHeight: 1024, fileSize: 500, folderPath: "/lib/c", isVideo: false),
        ]
        XCTAssertEqual(SimilarImagesModel.rows(for: set, info: info).map(\.path), set.paths)
        XCTAssertEqual(info["/lib/b/huge.png"]?.resolutionText, "4096 × 4096")
    }

    func testMoreLikeThisKeyIsBareM() {
        XCTAssertTrue(VisualSearchKeys.isMoreLikeThis(characters: "m", modifiers: []))
        XCTAssertTrue(VisualSearchKeys.isMoreLikeThis(characters: "M", modifiers: [.capsLock]))
        XCTAssertFalse(VisualSearchKeys.isMoreLikeThis(characters: "m", modifiers: [.command]))
        XCTAssertFalse(VisualSearchKeys.isMoreLikeThis(characters: "m", modifiers: [.shift]))
        XCTAssertFalse(VisualSearchKeys.isMoreLikeThis(characters: "n", modifiers: []))
        // Not a culling key.
        XCTAssertNil(CullAction(keyCharacters: "m"))
    }
}
