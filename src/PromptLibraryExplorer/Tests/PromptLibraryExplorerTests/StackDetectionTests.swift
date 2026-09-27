import XCTest
@testable import PromptLibraryExplorer

final class StackDetectionTests: XCTestCase {
    private let folder = "/lib/shoot"

    private func c(
        _ name: String, modified: TimeInterval = 0, seed: String? = nil, prompt: String? = nil,
        size: (Int, Int)? = nil, dHash: UInt64? = nil, folder: String? = nil
    ) -> StackCandidate {
        StackCandidate(
            path: (folder ?? self.folder) + "/" + name,
            modified: Date(timeIntervalSince1970: 1_700_000_000 + modified),
            seed: seed, prompt: prompt, width: size?.0, height: size?.1, dHash: dHash
        )
    }

    private func names(_ stacks: [FileStack]) -> [[String]] {
        stacks.map { $0.members.map { ($0 as NSString).lastPathComponent } }
    }

    // MARK: Name patterns

    func testNameKeysStripVariantSuffixes() {
        func base(_ name: String) -> String { StackNamePattern.key(forFileName: name).base }
        XCTAssertEqual(base("portrait.png"), "portrait")
        XCTAssertEqual(base("portrait_1.png"), "portrait")
        XCTAssertEqual(base("portrait (2).png"), "portrait")
        XCTAssertEqual(base("portrait-upscaled.png"), "portrait")
        XCTAssertEqual(base("portrait_upscaled@2x.png"), "portrait")
        XCTAssertEqual(base("portrait-v2.png"), "portrait")
        XCTAssertEqual(base("Portrait copy 2.png"), "portrait")
        XCTAssertEqual(base("portrait_hires_x4.png"), "portrait")
        XCTAssertEqual(base("neon city-2.jpg"), "neon city")
        XCTAssertFalse(StackNamePattern.key(forFileName: "portrait_1.png").needsSamePrompt)

        let comfy = StackNamePattern.key(forFileName: "ComfyUI_00012_.png")
        XCTAssertTrue(comfy.needsSamePrompt, "counter sequences only link with the same prompt")
        XCTAssertEqual(comfy, StackNamePattern.key(forFileName: "ComfyUI_00013_.png"))
        XCTAssertEqual(StackNamePattern.key(forFileName: "render_00012_.png"), StackNamePattern.key(forFileName: "render_00020_.png"))
        XCTAssertNotEqual(base("v2.png"), "", "a name that is only a suffix keeps its stem")
    }

    func testNamePatternStacksVariantsInOneFolder() {
        let stacks = StackDetector.detect(candidates: [
            c("portrait.png"), c("portrait_1.png"), c("portrait (2).png"), c("portrait-upscaled.png"),
            c("landscape.png"),
            c("portrait_1.png", folder: "/lib/other"),
        ])
        XCTAssertEqual(names(stacks).map(Set.init), [Set(["portrait (2).png", "portrait_1.png", "portrait-upscaled.png", "portrait.png"])])
        XCTAssertEqual(stacks.first?.reasons, [.namePattern])
        XCTAssertFalse(stacks[0].members.contains("/lib/other/portrait_1.png"), "name patterns stay within a folder")
    }

    func testNamePatternRespectsDifferentPromptsAndShapes() {
        let stacks = StackDetector.detect(candidates: [
            c("scene_1.png", prompt: "a castle"), c("scene_2.png", prompt: "a forest"),
            c("hero_1.png", size: (1024, 1024)), c("hero_2.png", size: (1024, 1536)),
            c("dog_1.png", prompt: "a dog"), c("dog_2.png", prompt: "A  dog "),
        ])
        XCTAssertEqual(names(stacks), [["dog_1.png", "dog_2.png"]], "different prompts or aspect ratios don't link; prompt case/space does not matter")
    }

    func testComfyCountersNeedTheSamePrompt() {
        let stacks = StackDetector.detect(candidates: [
            c("ComfyUI_00012_.png", prompt: "neon samurai"),
            c("ComfyUI_00013_.png", prompt: "neon samurai"),
            c("ComfyUI_00014_.png", prompt: "desert road"),
            c("ComfyUI_00015_.png"),
            c("IMG_1234.jpg"), c("IMG_1235.jpg"),
        ])
        XCTAssertEqual(names(stacks), [["ComfyUI_00012_.png", "ComfyUI_00013_.png"]])
    }

    // MARK: Seed + prompt

    func testSameSeedAndPromptStack() {
        let stacks = StackDetector.detect(candidates: [
            c("00012-1234.png", seed: "1234", prompt: "red fox in snow"),
            c("00019-1234.png", seed: "1234", prompt: "Red fox in snow"),
            c("00020-1234.png", seed: "1234", prompt: "blue fox"),
            c("00021-99.png", seed: "99", prompt: "red fox in snow"),
            c("random-a.png", seed: "-1", prompt: "cat"), c("random-b.png", seed: "-1", prompt: "cat"),
        ])
        XCTAssertEqual(names(stacks), [["00012-1234.png", "00019-1234.png"]], "random seeds (-1) say nothing")
        XCTAssertEqual(stacks.first?.reasons, [.seedAndPrompt])
    }

    // MARK: Upscale lineage

    func testUpscaleLineageNeedsSameSignatureAspectAndLargerSize() {
        let hash: UInt64 = 0xF0F0_1234_ABCD_0077
        let stacks = StackDetector.detect(candidates: [
            c("master.png", size: (1024, 768), dHash: hash),
            c("big.png", size: (4096, 3072), dHash: hash ^ 0b101),          // 2 bits off, 4×
            c("same-size-copy.png", size: (1024, 768), dHash: hash),          // not larger
            c("cropped.png", size: (4096, 2048), dHash: hash),                // other aspect
            c("unrelated.png", size: (2048, 1536), dHash: ~hash),             // other picture
        ])
        XCTAssertEqual(names(stacks).map(Set.init), [Set(["big.png", "master.png", "same-size-copy.png"])],
                       "the same-size copy joins through the master; cropped and unrelated stay out")
        XCTAssertTrue(stacks[0].reasons.contains(.upscale))
        XCTAssertFalse(StackDetector.isUpscalePair(c("a", size: (1024, 768), dHash: hash), c("b", size: (1024, 768), dHash: hash)))
        XCTAssertTrue(StackDetector.isUpscalePair(c("a", size: (1024, 768), dHash: hash), c("b", size: (2048, 1536), dHash: hash)))
    }

    // MARK: Manual stacks and exclusions

    func testManualStacksWinAndExclusionsStayOut() {
        let manual = ManualStack(paths: ["\(folder)/a.png", "\(folder)/zebra.png", "/elsewhere/missing.png"])
        let stacks = StackDetector.detect(
            candidates: [c("a.png"), c("a_1.png"), c("a_2.png"), c("zebra.png"), c("b.png"), c("b_1.png")],
            manual: [manual],
            excluded: ["\(folder)/b_1.png"]
        )
        XCTAssertEqual(Set(names(stacks).map(Set.init)), [Set(["a_1.png", "a_2.png"]), Set(["a.png", "zebra.png"])])
        let manualStack = stacks.first { $0.isManual }
        XCTAssertEqual(manualStack?.id, "manual-\(manual.id.uuidString)")
        XCTAssertEqual(manualStack?.reasons, [.manual])
        XCTAssertNil(stacks.first { $0.members.contains("\(folder)/b.png") }, "b_1 is excluded, so b stands alone")
    }

    // MARK: Cover

    func testCoverIsNewestNeverLargest() {
        // The upscale is by far the largest file but older: the cover is the newest file.
        let hash: UInt64 = 42
        let stacks = StackDetector.detect(candidates: [
            c("master.png", modified: 300, size: (1024, 1024), dHash: hash),
            c("master-upscaled.png", modified: 100, size: (8192, 8192), dHash: hash),
            c("master_1.png", modified: 200, size: (1024, 1024)),
        ])
        XCTAssertEqual(stacks.count, 1)
        XCTAssertEqual((stacks[0].coverPath as NSString).lastPathComponent, "master.png")

        let modified: [String: Date] = ["/a": Date(timeIntervalSince1970: 1), "/b": Date(timeIntervalSince1970: 5)]
        XCTAssertEqual(StackCover.choose(members: ["/a", "/b"], manualCover: nil, modified: modified), "/b")
        XCTAssertEqual(StackCover.choose(members: ["/a", "/b"], manualCover: "/a", modified: modified), "/a", "the manual choice wins")
        XCTAssertEqual(StackCover.choose(members: ["/a", "/b"], manualCover: "/gone", modified: modified), "/b", "a cover that left falls back")
    }

    func testManualCoverIsHonoured() {
        let manual = ManualStack(paths: ["\(folder)/old.png", "\(folder)/new.png"], coverPath: "\(folder)/old.png")
        let stacks = StackDetector.detect(candidates: [c("old.png", modified: 0), c("new.png", modified: 99)], manual: [manual])
        XCTAssertEqual(stacks.first?.coverPath, "\(folder)/old.png")
    }

    // MARK: Presentation

    func testPresentationCollapsesToCoverAndExpandsInline() {
        let stack = FileStack(id: "s", members: ["/f/a", "/f/c", "/f/e"], coverPath: "/f/c", manualID: nil, reasons: [.namePattern])
        let items = ["/f/a", "/f/b", "/f/c", "/f/d", "/f/e"]

        let collapsed = StackPresentation.apply(to: items, path: { $0 }, stacks: [stack], expanded: [])
        XCTAssertEqual(collapsed.items, ["/f/b", "/f/c", "/f/d"], "the cover stands for the stack at its own position")
        XCTAssertEqual(collapsed.presentation.heads["/f/c"]?.visibleCount, 3)
        XCTAssertEqual(collapsed.presentation.heads["/f/c"]?.isExpanded, false)

        let expanded = StackPresentation.apply(to: items, path: { $0 }, stacks: [stack], expanded: ["s"])
        XCTAssertEqual(expanded.items, ["/f/b", "/f/c", "/f/a", "/f/e", "/f/d"], "members follow the cover")
        XCTAssertEqual(expanded.presentation.expandedMembers, ["/f/a": "s", "/f/e": "s"])

        // Filters hid the cover: the first visible member stands in; one visible member = no stack.
        let filtered = StackPresentation.apply(to: ["/f/a", "/f/b", "/f/e"], path: { $0 }, stacks: [stack], expanded: [])
        XCTAssertEqual(filtered.items, ["/f/a", "/f/b"])
        XCTAssertEqual(filtered.presentation.heads["/f/a"]?.visibleCount, 2)
        let single = StackPresentation.apply(to: ["/f/a", "/f/b"], path: { $0 }, stacks: [stack], expanded: [])
        XCTAssertEqual(single.items, ["/f/a", "/f/b"])
        XCTAssertTrue(single.presentation.heads.isEmpty)
    }

    // MARK: Stack book

    func testStackBookEdits() {
        var book = StackBook()
        let first = book.createStack(paths: ["/a", "/b", "/c"])
        XCTAssertNotNil(first)
        XCTAssertNil(book.createStack(paths: ["/x"]), "one file is not a stack")
        let second = book.createStack(paths: ["/c", "/d"])
        XCTAssertEqual(book.stack(containing: "/c")?.id, second?.id, "a file is in one manual stack")
        XCTAssertEqual(book.stack(containing: "/a")?.paths, ["/a", "/b"])

        book.setCover("/b", stackID: first!.id)
        XCTAssertEqual(book.stack(containing: "/a")?.coverPath, "/b")
        book.remove("/b")
        XCTAssertNil(book.stack(containing: "/a"), "a stack left with one member dissolves")
        XCTAssertTrue(book.excludedPaths.contains("/b"))

        book.dissolve(id: second!.id)
        XCTAssertTrue(book.stacks.isEmpty)
        XCTAssertTrue(book.excludedPaths.isSuperset(of: ["/c", "/d"]), "unstacked files stay out of automatic stacks")
        _ = book.createStack(paths: ["/c", "/d"])
        XCTAssertFalse(book.excludedPaths.contains("/c"), "stacking again lifts the exclusion")

        XCTAssertTrue(book.migrate(from: "/c", to: "/renamed-c"))
        XCTAssertEqual(book.stack(containing: "/renamed-c")?.paths, ["/renamed-c", "/d"])
    }
}
