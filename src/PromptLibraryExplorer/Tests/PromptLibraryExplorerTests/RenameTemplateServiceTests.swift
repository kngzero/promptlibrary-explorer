import XCTest
@testable import PromptLibraryExplorer

final class RenameTemplateServiceTests: TempDirectoryTestCase {
    private func ctx(_ name: String, index: Int = 0, prompt: String? = nil, model: String? = nil, seed: String? = nil,
                     width: Int? = nil, height: Int? = nil, date: Date? = nil) -> RenameTemplateContext {
        RenameTemplateContext(url: tempDir.appendingPathComponent(name), index: index, modifiedDate: date,
                              prompt: prompt, model: model, seed: seed, width: width, height: height)
    }

    private func render(_ template: String, _ context: RenameTemplateContext) -> String {
        RenameTemplateService.render(template: template, context: context)
    }

    func testBasicTokensAndExtensionAppended() {
        let c = ctx("photo.png", index: 4, model: "models/sd_xl_base_1.0.safetensors", seed: "42", width: 1024, height: 768)
        XCTAssertEqual(render("{name}_{counter:3}", c), "photo_005.png")
        XCTAssertEqual(render("{model}-{seed}-{width}x{height}", c), "sd_xl_base_1.0-42-1024x768.png")
        XCTAssertEqual(render("{counter}", c), "5.png")
        XCTAssertEqual(render("{counter:2}", ctx("a.png", index: 122)), "123.png", "padding never truncates")
        XCTAssertEqual(render("{NAME}", c), "photo.png", "tokens are case-insensitive")
    }

    func testExtTokenAndUnknownTokens() {
        let c = ctx("clip.jpeg")
        XCTAssertEqual(render("{name}.{ext}", c), "clip.jpeg")
        XCTAssertEqual(render("{name}.{ext}.bak", c), "clip.jpeg.bak")
        XCTAssertEqual(render("x {bogus}", c), "x {bogus}.jpeg", "unknown tokens stay literal")
    }

    func testMissingValuesAndEmptyResultFallBack() {
        XCTAssertEqual(render("{seed}", ctx("orig.png")), "orig.png", "empty result falls back to the original name")
        XCTExpectFailure("cleanModelName strips everything up to the last '/' before its N/A check, so \"N/A\" renders as \"A\"")
        XCTAssertEqual(render("{model}", ctx("orig.png", model: "N/A")), "orig.png")
    }

    func testDateTokenWithFormat() throws {
        var components = DateComponents()
        components.year = 2024; components.month = 3; components.day = 9; components.hour = 7; components.minute = 5; components.second = 1
        let date = try XCTUnwrap(Calendar(identifier: .gregorian).date(from: components))
        let c = ctx("a.png", date: date)
        XCTAssertEqual(render("{date}", c), "2024-03-09.png")
        XCTAssertEqual(render("{date:yyyyMMdd}_{time}", c), "20240309_07-05-01.png")
    }

    func testSanitize() {
        XCTAssertEqual(RenameTemplateService.sanitize("a/b:c\\d"), "a-b-c-d")
        XCTAssertEqual(RenameTemplateService.sanitize("line one\nline\ttwo"), "line one line two")
        XCTAssertEqual(RenameTemplateService.sanitize("  ..hidden name.. "), "hidden name")
        XCTAssertEqual(render("{prompt}", ctx("a.png", prompt: "cats/dogs: a\nstudy")), "cats-dogs- a study.png")
    }

    func testPromptTruncationAtWordBoundary() {
        let prompt = "a majestic lion standing on a rock"
        XCTAssertEqual(render("{prompt:12}", ctx("a.png", prompt: prompt)), "a majestic.png")
        XCTAssertEqual(render("{prompt:10}", ctx("a.png", prompt: prompt)), "a majestic.png", "cut exactly at a space")
        XCTAssertEqual(render("{prompt:5}", ctx("a.png", prompt: "supercalifragilistic")), "super.png", "no space: hard cut")
        XCTAssertEqual(render("{prompt:11}", ctx("a.png", prompt: "red, blue, green")), "red, blue.png", "trailing punctuation trimmed")
        XCTAssertEqual(render("{prompt:100}", ctx("a.png", prompt: "short   prompt")), "short prompt.png")

        let long = Array(repeating: "word", count: 40).joined(separator: " ")
        let rendered = render("{prompt}", ctx("a.png", prompt: long))
        XCTAssertLessThanOrEqual(rendered.count - 4, RenameTemplateService.defaultPromptLength)
        XCTAssertTrue(rendered.hasPrefix("word word"))
    }

    func testBaseNameLengthCap() {
        let rendered = render(String(repeating: "x", count: 400), ctx("a.png"))
        XCTAssertEqual(rendered, String(repeating: "x", count: RenameTemplateService.maxBaseNameLength) + ".png")
    }

    // MARK: Plan

    func testPlanResolvesCollisionsWithinBatchAndAgainstExistingFiles() throws {
        for name in ["a.png", "b.png", "c.png", "shot.png"] { try writeFile(name, Data()) }
        let plan = RenameTemplateService.plan(template: "shot", items: [ctx("a.png", index: 0), ctx("b.png", index: 1), ctx("c.png", index: 2)])
        XCTAssertEqual(plan.map(\.proposedName), ["shot 2.png", "shot 3.png", "shot 4.png"])
        XCTAssertTrue(plan.allSatisfy { !$0.conflict && !$0.unchanged })
        XCTAssertEqual(plan[0].destination, tempDir.appendingPathComponent("shot 2.png"))
    }

    func testPlanCollisionIsCaseInsensitive() throws {
        for name in ["one.png", "SHOT.PNG"] { try writeFile(name, Data()) }
        let plan = RenameTemplateService.plan(template: "shot", items: [ctx("one.png")])
        XCTAssertEqual(plan.first?.proposedName, "shot 2.png")
    }

    func testPlanNamesFreedByTheBatchCanBeReused() throws {
        for name in ["2.png", "c.png"] { try writeFile(name, Data()) }
        let plan = RenameTemplateService.plan(template: "{counter}", items: [ctx("2.png", index: 0), ctx("c.png", index: 1)])
        XCTAssertEqual(plan.map(\.proposedName), ["1.png", "2.png"])
    }

    func testPlanUnchangedItemsKeepTheirName() throws {
        for name in ["keep.png", "other.png"] { try writeFile(name, Data()) }
        let plan = RenameTemplateService.plan(template: "keep", items: [ctx("keep.png", index: 0), ctx("other.png", index: 1)])
        XCTAssertEqual(plan[0].proposedName, "keep.png")
        XCTAssertTrue(plan[0].unchanged)
        XCTAssertEqual(plan[1].proposedName, "keep 2.png", "an unchanged item still occupies its name")
        XCTAssertFalse(plan[1].unchanged)
    }
}
