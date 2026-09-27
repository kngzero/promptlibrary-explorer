import AppKit
import XCTest
@testable import PromptLibraryExplorer

// The Similar Images page (Library ▸ Similar Images): mode transitions, the
// keyboard focus model, card order, the results cache and the "nothing is
// ever offered for deletion" rule. All pure.

final class SimilarImagesPageModeTests: XCTestCase {
    private func context(_ folder: String?, root: String?, _ scope: VisualSearchScopeChoice) -> SimilarPageContext {
        SimilarPageContext(folderPath: folder, rootPath: root, scope: scope)
    }

    func testStartsInBrowserAndEntersAndLeaves() {
        var state = SimilarPageModeState()
        XCTAssertEqual(state.mode, .browser)
        XCTAssertFalse(state.isActive)
        state.enter()
        XCTAssertEqual(state.mode, .similarImages)
        state.enter()
        XCTAssertTrue(state.isActive, "entering twice stays on the page")
        state.leave()
        XCTAssertEqual(state.mode, .browser)
        state.toggle()
        XCTAssertTrue(state.isActive)
        state.toggle()
        XCTAssertFalse(state.isActive)
    }

    func testEnteringAndLeavingLeaveTheBrowserListingAndSelectionAlone() {
        // The browser's state isn't part of the mode at all: a snapshot taken
        // before entering needs no restore step after leaving.
        var listing = ListingModeState()
        listing.openCollection(UUID())
        let snapshot = SimilarPageBrowserSnapshot(
            listing: listing,
            smartFolderID: nil,
            selectedPaths: ["/lib/a.png", "/lib/b.png"],
            primaryPath: "/lib/b.png"
        )
        var state = SimilarPageModeState()
        state.enter()
        state.leave()
        XCTAssertEqual(snapshot.restoreStep(from: listing), .none)
        XCTAssertEqual(snapshot.selectedPaths, ["/lib/a.png", "/lib/b.png"])
        XCTAssertEqual(snapshot.primaryPath, "/lib/b.png")
    }

    func testCollectionSmartFolderTagAndRevealLeaveThePage() {
        for event in [SimilarPageNavigationEvent.collectionOpened, .smartFolderActivated, .tagFilterChanged, .fileRevealed] {
            var state = SimilarPageModeState()
            state.enter()
            XCTAssertEqual(state.handle(event), .leftPage, "\(event)")
            XCTAssertEqual(state.mode, .browser, "\(event)")
            // In the browser these change nothing about the mode.
            XCTAssertEqual(state.handle(event), .none, "\(event)")
            XCTAssertEqual(state.mode, .browser)
        }
    }

    func testSidebarFolderClickKeepsThePageAndReScopesThisFolder() {
        var state = SimilarPageModeState()
        state.enter()
        let old = context("/lib/a", root: "/lib", .folder)
        let new = context("/lib/b", root: "/lib", .folder)
        XCTAssertEqual(state.effect(from: old, to: new), .rerunSearch)
        XCTAssertTrue(state.isActive, "a folder click keeps the page")
        XCTAssertEqual(state.effect(from: old, to: old), .none)
        // Trailing slashes / "." don't count as a change.
        XCTAssertEqual(state.effect(from: old, to: context("/lib/a/", root: "/lib/", .folder)), .none)
    }

    func testWholeLibraryKeepsResultsUnlessTheRootChanges() {
        var state = SimilarPageModeState()
        state.enter()
        let old = context("/lib/a", root: "/lib", .library)
        XCTAssertEqual(state.effect(from: old, to: context("/lib/b", root: "/lib", .library)), .none)
        XCTAssertEqual(state.effect(from: old, to: context("/other", root: "/other", .library)), .rerunSearch)
        // Switching the scope control searches again.
        XCTAssertEqual(state.effect(from: old, to: context("/lib/a", root: "/lib", .folder)), .rerunSearch)
    }

    func testNoReactionsWhileInTheBrowser() {
        let state = SimilarPageModeState()
        XCTAssertEqual(
            state.effect(from: context("/lib/a", root: "/lib", .folder), to: context("/lib/b", root: "/lib", .folder)),
            .none
        )
    }
}

// MARK: - Borrowing the browser for the lightbox

final class SimilarImagesPageSnapshotTests: XCTestCase {
    private let group = VirtualListing(kind: .similarGroup(exact: false), title: "Similar Images · a.png", paths: ["/lib/a.png", "/lib/b.png"])

    /// Opens the group the way the page does, then applies the restore step.
    private func roundTrip(from start: ListingModeState) -> (step: SimilarPageBrowserSnapshot.RestoreStep, end: ListingModeState) {
        let snapshot = SimilarPageBrowserSnapshot(listing: start, smartFolderID: nil, selectedPaths: ["/lib/x.png"], primaryPath: "/lib/x.png")
        var state = start
        state.openVirtual(group)
        let step = snapshot.restoreStep(from: state)
        switch step {
        case .none: break
        case .closeVirtualListing: state.closeVirtual()
        case let .openVirtual(listing): state.openVirtual(listing)
        case let .openCollection(id): state.openCollection(id)
        }
        return (step, state)
    }

    func testFolderListingComesBack() {
        let (step, end) = roundTrip(from: ListingModeState())
        XCTAssertEqual(step, .closeVirtualListing)
        XCTAssertEqual(end.mode, .folder)
    }

    func testCollectionComesBack() {
        let id = UUID()
        var start = ListingModeState()
        start.openCollection(id)
        let (step, end) = roundTrip(from: start)
        XCTAssertEqual(step, .closeVirtualListing)
        XCTAssertEqual(end.mode, .collection(id))
    }

    func testVirtualListingComesBackWithItsOrigin() {
        let id = UUID()
        var start = ListingModeState()
        start.openCollection(id)
        start.openVirtual(VirtualListing(kind: .similarTo(path: "/lib/a.png"), title: "Similar to a.png", paths: ["/lib/a.png"]))
        let (step, end) = roundTrip(from: start)
        guard case let .openVirtual(listing) = step else { return XCTFail("expected openVirtual, got \(step)") }
        XCTAssertEqual(listing.id, start.virtualListing?.id)
        XCTAssertEqual(end.virtualListing?.id, start.virtualListing?.id)
        XCTAssertEqual(end.virtualListing?.origin, .collection(id), "closing it later still returns to the collection")
    }

    func testNothingToDoWhenTheListingIsUnchanged() {
        let snapshot = SimilarPageBrowserSnapshot(listing: ListingModeState(), smartFolderID: nil, selectedPaths: [], primaryPath: nil)
        XCTAssertEqual(snapshot.restoreStep(from: ListingModeState()), .none)
        var collection = ListingModeState()
        collection.openCollection(UUID())
        XCTAssertEqual(snapshot.restoreStep(from: collection), .openCollection(nil))
    }
}

// MARK: - Keyboard focus

final class SimilarImagesPageFocusTests: XCTestCase {
    private let sets = [
        SimilarSet(id: "g1", paths: ["/lib/a/1.png", "/lib/a/2.png"], kind: .exact),
        SimilarSet(id: "g2", paths: ["/lib/b/1.png", "/lib/b/2.png", "/lib/c/3.png"], kind: .visual),
        SimilarSet(id: "g3", paths: ["/lib/d/1.png", "/lib/d/2.png"], kind: .visual),
    ]

    func testResolvesToTheFirstGroupAndCard() {
        let focus = SimilarPageFocus().resolved(in: sets)
        XCTAssertEqual(focus, SimilarPageFocus(groupID: "g1", path: "/lib/a/1.png"))
        XCTAssertEqual(SimilarPageFocus(groupID: "gone", path: "/x").resolved(in: sets).groupID, "g1")
        XCTAssertEqual(SimilarPageFocus(groupID: "g2", path: "/lib/c/3.png").resolved(in: sets).path, "/lib/c/3.png")
        XCTAssertEqual(SimilarPageFocus(groupID: "g2", path: "/lib/a/1.png").resolved(in: sets).path, "/lib/b/1.png")
        XCTAssertEqual(SimilarPageFocus(groupID: "g1").resolved(in: []), SimilarPageFocus())
    }

    func testGroupNavigationStopsAtBothEnds() {
        var focus = SimilarPageFocus().resolved(in: sets)
        focus = focus.movingGroup(by: -1, in: sets)
        XCTAssertEqual(focus.groupID, "g1", "↑ on the first group stays")
        focus = focus.movingGroup(by: 1, in: sets)
        XCTAssertEqual(focus, SimilarPageFocus(groupID: "g2", path: "/lib/b/1.png"), "a new group focuses its first card")
        focus = focus.movingGroup(by: 1, in: sets).movingGroup(by: 1, in: sets)
        XCTAssertEqual(focus.groupID, "g3", "↓ on the last group stays")
        XCTAssertEqual(SimilarPageFocus().movingGroup(by: -1, in: sets).groupID, "g3")
        XCTAssertEqual(SimilarPageFocus().movingGroup(by: 1, in: []), SimilarPageFocus())
    }

    func testCardNavigationStopsAtBothEndsAndStaysInTheGroup() {
        var focus = SimilarPageFocus(groupID: "g2", path: "/lib/b/1.png")
        focus = focus.movingCard(by: -1, in: sets)
        XCTAssertEqual(focus.path, "/lib/b/1.png")
        focus = focus.movingCard(by: 1, in: sets)
        XCTAssertEqual(focus.path, "/lib/b/2.png")
        focus = focus.movingCard(by: 1, in: sets).movingCard(by: 1, in: sets)
        XCTAssertEqual(focus.path, "/lib/c/3.png")
        XCTAssertEqual(focus.groupID, "g2", "→ on the last card never jumps to the next group")
        XCTAssertEqual(focus.cardIndex(in: sets), 2)
    }

    func testClickingSelectsGroupsAndFocusesCards() {
        let focus = SimilarPageFocus().resolved(in: sets)
        XCTAssertEqual(focus.selectingGroup("g3", in: sets), SimilarPageFocus(groupID: "g3", path: "/lib/d/1.png"))
        XCTAssertEqual(focus.selectingGroup("g1", in: sets), focus, "re-selecting keeps the focused card")
        XCTAssertEqual(focus.focusing("/lib/b/2.png", in: sets), SimilarPageFocus(groupID: "g2", path: "/lib/b/2.png"))
    }

    func testPageKeys() {
        func action(_ code: KeyCode, _ characters: String = "", _ modifiers: NSEvent.ModifierFlags = []) -> SimilarPageKeyAction? {
            SimilarPageKeyAction.action(keyCode: code.rawValue, characters: characters, modifiers: modifiers)
        }
        XCTAssertEqual(action(.upArrow, "", [.numericPad, .function]), .previousGroup)
        XCTAssertEqual(action(.downArrow), .nextGroup)
        XCTAssertEqual(action(.leftArrow), .previousCard)
        XCTAssertEqual(action(.rightArrow), .nextCard)
        XCTAssertEqual(action(.space, " "), .openLightbox)
        XCTAssertEqual(action(.returnKey, "\r"), .openLightbox)
        XCTAssertEqual(action(.escape), .leave)
        XCTAssertEqual(SimilarPageKeyAction.action(keyCode: 46, characters: "m", modifiers: []), .moreLikeThis)
        XCTAssertEqual(SimilarPageKeyAction.action(keyCode: 35, characters: "p", modifiers: []), .cull(.flag(.pick)))
        XCTAssertEqual(SimilarPageKeyAction.action(keyCode: 7, characters: "x", modifiers: []), .cull(.flag(.reject)))
        XCTAssertEqual(SimilarPageKeyAction.action(keyCode: 20, characters: "3", modifiers: []), .cull(.rating(3)))
        XCTAssertEqual(SimilarPageKeyAction.action(keyCode: 22, characters: "6", modifiers: []), .cull(.label(.red)))
        // Menu-owned combos and deletion keys pass through: the page does nothing with them.
        XCTAssertNil(action(.leftArrow, "", [.command]))
        XCTAssertNil(action(.upArrow, "", [.shift]))
        XCTAssertNil(SimilarPageKeyAction.action(keyCode: 46, characters: "m", modifiers: [.command]))
        XCTAssertNil(action(.delete))
        XCTAssertNil(action(.forwardDelete))
        XCTAssertNil(action(.delete, "", [.shift]))
        XCTAssertNil(action(.delete, "", [.command]))
        // Focus moves may repeat; actions never do.
        XCTAssertTrue(SimilarPageKeyAction.nextCard.allowsRepeat)
        XCTAssertFalse(SimilarPageKeyAction.cull(.flag(.pick)).allowsRepeat)
        XCTAssertFalse(SimilarPageKeyAction.openLightbox.allowsRepeat)
    }
}

// MARK: - Card order and "nothing is ever offered for deletion"

final class SimilarImagesPageRulesTests: XCTestCase {
    private let forbidden = ["trash", "delete", "remove", "keep", "best", "discard", "clean", "duplicate"]

    func testCardsKeepTheEnginesDisplayOrderNeverSizeOrResolution() {
        let paths = ["/lib/z/huge.png", "/lib/a/small.png", "/lib/a/big.png", "/lib/m/mid.png"]
        let engineOrder = paths.sorted(by: VisualIndexService.displayOrder)
        let set = SimilarSet(id: "g", paths: engineOrder, kind: .visual)
        let info: [String: SimilarImageInfo] = [
            "/lib/z/huge.png": SimilarImageInfo(pixelWidth: 8192, pixelHeight: 8192, fileSize: 90_000_000, folderPath: "/lib/z", isVideo: false),
            "/lib/a/small.png": SimilarImageInfo(pixelWidth: 256, pixelHeight: 256, fileSize: 1_000, folderPath: "/lib/a", isVideo: false),
            "/lib/a/big.png": SimilarImageInfo(pixelWidth: 4096, pixelHeight: 4096, fileSize: 9_000_000, folderPath: "/lib/a", isVideo: false),
            "/lib/m/mid.png": SimilarImageInfo(pixelWidth: 1024, pixelHeight: 1024, fileSize: 500_000, folderPath: "/lib/m", isVideo: false),
        ]
        let cards = SimilarImagesModel.rows(for: set, info: info).map(\.path)
        XCTAssertEqual(cards, engineOrder)
        XCTAssertEqual(cards.first?.hasPrefix("/lib/a/"), true, "folder, then name — not the largest file first")
        // ← / → walk the cards in that same order.
        var focus = SimilarPageFocus().resolved(in: [set])
        var walked = [focus.path]
        for _ in 1..<engineOrder.count {
            focus = focus.movingCard(by: 1, in: [set])
            walked.append(focus.path)
        }
        XCTAssertEqual(walked.compactMap { $0 }, engineOrder)
    }

    func testNoActionOnThePageDeletesMarksOrRanks() {
        let texts = SimilarCardAction.displayOrder.map { "\($0.rawValue) \($0.title) \($0.systemImage)" }
            + SimilarGroupPageAction.displayOrder.map { "\($0.rawValue) \($0.title) \($0.systemImage)" }
        XCTAssertEqual(SimilarCardAction.displayOrder.count, SimilarCardAction.allCases.count)
        XCTAssertEqual(SimilarGroupPageAction.displayOrder.count, SimilarGroupPageAction.allCases.count)
        for text in texts {
            for word in forbidden {
                XCTAssertFalse(text.lowercased().contains(word), "\"\(text)\" mentions \(word)")
            }
        }
    }

    func testKindLabelsAreNeutral() {
        // Exact vs Similar is the only distinction between groups; both use one style.
        XCTAssertEqual(Set([SimilarSet.Kind.exact.rawValue, SimilarSet.Kind.visual.rawValue]), ["exact", "visual"])
    }
}

// MARK: - Results cache

final class SimilarImagesPageCacheTests: XCTestCase {
    private func entry(_ id: String) -> SimilarResultsEntry {
        SimilarResultsEntry(sets: [SimilarSet(id: id, paths: ["/a", "/b"], kind: .exact)], info: [:], indexedCount: 2)
    }

    func testKeysRoundStrictnessAndSeparateSearches() {
        let folder = VisualScope.folder(URL(fileURLWithPath: "/lib/a"))
        XCTAssertEqual(
            SimilarResultsKey(scope: folder, strictness: 0.8512, includeVideos: true),
            SimilarResultsKey(scope: folder, strictness: 0.85, includeVideos: true)
        )
        XCTAssertNotEqual(
            SimilarResultsKey(scope: folder, strictness: 0.85, includeVideos: true),
            SimilarResultsKey(scope: folder, strictness: 0.85, includeVideos: false)
        )
        XCTAssertNotEqual(
            SimilarResultsKey(scope: folder, strictness: 0.85, includeVideos: true),
            SimilarResultsKey(scope: .library(URL(fileURLWithPath: "/lib")), strictness: 0.85, includeVideos: true)
        )
        XCTAssertEqual(SimilarResultsKey.rounded(.nan), 0.85)
        XCTAssertEqual(SimilarResultsKey.rounded(2), 1)
    }

    func testStoresAndEvictsLeastRecentlyUsed() {
        var cache = SimilarResultsCache(capacity: 2)
        let a = SimilarResultsKey(scope: .folder(URL(fileURLWithPath: "/lib/a")), strictness: 0.85, includeVideos: true)
        let b = SimilarResultsKey(scope: .folder(URL(fileURLWithPath: "/lib/b")), strictness: 0.85, includeVideos: true)
        let c = SimilarResultsKey(scope: .folder(URL(fileURLWithPath: "/lib/c")), strictness: 0.85, includeVideos: true)
        cache.store(entry("a"), for: a)
        cache.store(entry("b"), for: b)
        cache.touch(a)
        cache.store(entry("c"), for: c)
        XCTAssertNotNil(cache.entry(for: a))
        XCTAssertNil(cache.entry(for: b), "least recently used goes first")
        XCTAssertEqual(cache.entry(for: c)?.sets.first?.id, "c")
        XCTAssertEqual(cache.count, 2)
    }

    func testIndexChangesDropOnlyAffectedSearches() {
        var cache = SimilarResultsCache()
        let folderA = SimilarResultsKey(scope: .folder(URL(fileURLWithPath: "/lib/a")), strictness: 0.85, includeVideos: true)
        let folderB = SimilarResultsKey(scope: .folder(URL(fileURLWithPath: "/lib/b")), strictness: 0.85, includeVideos: true)
        let library = SimilarResultsKey(scope: .library(URL(fileURLWithPath: "/lib")), strictness: 0.85, includeVideos: true)
        let other = SimilarResultsKey(scope: .library(URL(fileURLWithPath: "/elsewhere")), strictness: 0.85, includeVideos: true)
        for key in [folderA, folderB, library, other] { cache.store(entry("x"), for: key) }

        cache.invalidate(paths: ["/lib/a/new.png"])
        XCTAssertNil(cache.entry(for: folderA), "a file in the folder")
        XCTAssertNil(cache.entry(for: library), "a file under the root")
        XCTAssertNotNil(cache.entry(for: folderB))
        XCTAssertNotNil(cache.entry(for: other))

        // A finished run over the root touches every search under it.
        cache.store(entry("x"), for: folderA)
        cache.invalidate(paths: ["/lib"])
        XCTAssertNil(cache.entry(for: folderA))
        XCTAssertNil(cache.entry(for: folderB))
        XCTAssertNotNil(cache.entry(for: other))
        // Files deeper down don't change a This Folder search.
        let deep = SimilarResultsKey(scope: .folder(URL(fileURLWithPath: "/elsewhere")), strictness: 0.5, includeVideos: false)
        XCTAssertFalse(deep.isAffected(byChangeAt: "/elsewhere/sub/x.png"))
        XCTAssertTrue(deep.isAffected(byChangeAt: "/elsewhere/x.png"))

        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
    }

    @MainActor
    func testControlsPersistWithDefaults() throws {
        let suite = "SimilarImagesPageTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = SimilarImagesModel(defaults: defaults)
        XCTAssertEqual(model.strictness, 0.85)
        XCTAssertTrue(model.includeVideos, "Include Videos defaults on")
        XCTAssertNil(model.selectedSet)
        model.strictness = 0.6
        model.includeVideos = false
        let reloaded = SimilarImagesModel(defaults: defaults)
        XCTAssertEqual(reloaded.strictness, 0.6)
        XCTAssertFalse(reloaded.includeVideos)
    }
}

// MARK: - Comparison layout

final class SimilarImagesPageLayoutTests: XCTestCase {
    func testColumns() {
        let wide = CGSize(width: 1400, height: 900)
        XCTAssertEqual(SimilarComparisonView.layout(count: 2, size: wide).columns, 2)
        XCTAssertEqual(SimilarComparisonView.layout(count: 3, size: wide).columns, 3)
        XCTAssertEqual(SimilarComparisonView.layout(count: 4, size: CGSize(width: 900, height: 900)).columns, 2, "4 goes 2 × 2, not 3 + 1")
        XCTAssertEqual(SimilarComparisonView.layout(count: 4, size: wide).columns, 4)
        XCTAssertEqual(SimilarComparisonView.layout(count: 9, size: wide).columns, 5)
        XCTAssertEqual(SimilarComparisonView.layout(count: 2, size: CGSize(width: 300, height: 600)).columns, 1)
        let two = SimilarComparisonView.layout(count: 2, size: wide)
        XCTAssertGreaterThan(two.previewHeight, 400, "two files get big previews")
        XCTAssertLessThanOrEqual(two.previewHeight, two.cardWidth * 1.25)
    }

    func testPreviewsAreDownsampledToBucketedSizes() {
        XCTAssertEqual(SimilarCardPreview.bucketedSize(for: CGSize(width: 300, height: 200)), 384)
        XCTAssertEqual(SimilarCardPreview.bucketedSize(for: CGSize(width: 10, height: 10)), 128)
        XCTAssertEqual(SimilarCardPreview.bucketedSize(for: CGSize(width: 5000, height: 3000)), 1024, "never full resolution")
    }
}
