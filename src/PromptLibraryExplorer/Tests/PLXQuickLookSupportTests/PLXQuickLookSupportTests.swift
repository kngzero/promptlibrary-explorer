import ArtOfficialFormats
import CoreGraphics
import Foundation
import ImageIO
@testable import PLXQuickLookSupport
import XCTest

final class PLXQuickLookSupportTests: XCTestCase {
    // MARK: Fixtures

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("plxql-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func png(width: Int = 64, height: Int = 48, rgb: (CGFloat, CGFloat, CGFloat) = (0.8, 0.2, 0.2)) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out as CFMutableData, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    private let tinyURI = "data:image/png;base64,iVBORw0KGgo="

    // MARK: Escaping / validation

    func testEscapeHTML() {
        XCTAssertEqual(PreviewHTML.esc("<a href=\"x\">'&'</a>"),
                       "&lt;a href=&quot;x&quot;&gt;&#39;&amp;&#39;&lt;/a&gt;")
    }

    func testSafeHex() {
        XCTAssertEqual(PreviewHTML.safeHex("#fff"), "#fff")
        XCTAssertEqual(PreviewHTML.safeHex("A1B2C3"), "#A1B2C3")
        XCTAssertEqual(PreviewHTML.safeHex("#11223344"), "#11223344")
        XCTAssertNil(PreviewHTML.safeHex("red"))
        XCTAssertNil(PreviewHTML.safeHex("#fff;background:url(x)"))
    }

    func testSafeImageURI() {
        XCTAssertEqual(PreviewHTML.safeImageURI(tinyURI), tinyURI)
        XCTAssertNil(PreviewHTML.safeImageURI("https://example.com/a.png"))
        XCTAssertNil(PreviewHTML.safeImageURI("data:image/png;base64,AAA\" onerror=\"x"))
        XCTAssertNil(PreviewHTML.safeImageURI("data:text/html;base64,AAAA"))
        XCTAssertNil(PreviewHTML.safeImageURI("data:image/svg+xml,<svg>"))
    }

    func testDuration() {
        XCTAssertEqual(PreviewHTML.duration(5), "5s")
        XCTAssertEqual(PreviewHTML.duration(125), "2m 05s")
    }

    // MARK: HTML builders

    func testMoodHTML() {
        let html = PreviewHTML.mood(MoodPreviewModel(
            title: "Summer <Board>", subtitle: "Campaign", boardImageURI: tinyURI,
            palette: ["#FFFFFF", "bogus", "1F2937"], imageCount: 7, tileCount: 9, layout: "grid"))
        XCTAssertTrue(html.hasPrefix("<!DOCTYPE html>"))
        XCTAssertTrue(html.contains("prefers-color-scheme: dark"))
        XCTAssertTrue(html.contains("Summer &lt;Board&gt;"))
        XCTAssertFalse(html.contains("<Board>"))
        XCTAssertTrue(html.contains("src=\"\(tinyURI)\""))
        XCTAssertTrue(html.contains("background:#FFFFFF"))
        XCTAssertTrue(html.contains("background:#1F2937"))
        XCTAssertFalse(html.contains("bogus"))
        XCTAssertTrue(html.contains("<dt>Images</dt><dd>7</dd>"))
    }

    func testStoryHTMLMultiProject() {
        let shot = StoryPreviewModel.Shot(label: "1.1", name: "Wide", types: ["WS"], description: "Sunrise over <hills>",
                                          durationSec: 4, status: "Planned", tags: ["dawn"], thumbURI: tinyURI)
        let scene = StoryPreviewModel.Scene(heading: "Scene 1 · Opening", slugline: "EXT. HILLS - DAY", shots: [shot])
        let a = StoryPreviewModel.Project(title: "Alpha", code: "ALP", status: "Planning", logline: "A tale",
                                          contactSheetURI: tinyURI, scenes: [scene])
        let b = StoryPreviewModel.Project(title: "Beta")
        let html = PreviewHTML.story(StoryPreviewModel(fileTitle: "Workspace", projects: [a, b]))
        XCTAssertTrue(html.contains("2 projects"))
        XCTAssertTrue(html.contains("href=\"#project-1\">Beta</a>"))
        XCTAssertTrue(html.contains("Scene 1 · Opening"))
        XCTAssertTrue(html.contains("EXT. HILLS - DAY"))
        XCTAssertTrue(html.contains("Sunrise over &lt;hills&gt;"))
        XCTAssertTrue(html.contains("WS · 4s · Planned"))
        XCTAssertTrue(html.contains("No scenes yet."))
        XCTAssertTrue(html.contains("<span>dawn</span>"))
    }

    func testPromptHTML() {
        let html = PreviewHTML.prompt(PromptPreviewModel(
            kindName: "Prompt Library", title: "cat", prompt: "A cat & a hat", imageURIs: [tinyURI],
            totalImageCount: 3, generation: [.init("Model", "flux")], analysis: [.init("Mood", "calm")]))
        XCTAssertTrue(html.contains("A cat &amp; a hat"))
        XCTAssertTrue(html.contains("<dt>Model</dt><dd>flux</dd>"))
        XCTAssertTrue(html.contains("<dt>Mood</dt><dd>calm</dd>"))
        XCTAssertTrue(html.contains("2 more image(s) not shown."))
        XCTAssertTrue(html.contains("class=\"hero\""))
    }

    // MARK: Details

    func testPlibDetails() throws {
        let json = """
        {"prompt":"p","generationInfo":{"model":"imagen","aspectRatio":"16:9","numberOfImages":"2",
         "timestamp":"2025-01-02T03:04:05Z"},"analysis":{"short_description":"Short","art_style":"Noir"}}
        """
        let d = PromptFileDetails.read(data: Data(json.utf8), kind: .plib)
        XCTAssertEqual(d.shortDescription, "Short")
        XCTAssertEqual(d.generation, [.init("Model", "imagen"), .init("Aspect ratio", "16:9"),
                                      .init("Images generated", "2"), .init("Created", "2025-01-02 03:04 UTC")])
        XCTAssertEqual(d.analysis, [.init("Art style", "Noir")])
    }

    func testAoeDetailsEpochMillis() {
        let json = #"{"timestamp":1735787045000,"model":"m1","image":{"mimeType":"image/png"}}"#
        let d = PromptFileDetails.read(data: Data(json.utf8), kind: .aoe)
        XCTAssertEqual(d.generation.first, .init("Model", "m1"))
        XCTAssertTrue(d.generation.contains(.init("Created", "2025-01-02 03:04 UTC")))
        XCTAssertTrue(d.generation.contains(.init("Image type", "image/png")))
    }

    func testDetailsGarbage() {
        XCTAssertEqual(PromptFileDetails.read(data: Data("nope".utf8), kind: .plib), PromptFileDetails())
    }

    // MARK: Thumbnail helpers

    func testFittedSize() {
        XCTAssertEqual(ThumbnailRenderer.fittedSize(CGSize(width: 1600, height: 900), in: CGSize(width: 256, height: 256)),
                       CGSize(width: 256, height: 144))
        XCTAssertEqual(ThumbnailRenderer.fittedSize(CGSize(width: 100, height: 200), in: CGSize(width: 64, height: 64)),
                       CGSize(width: 32, height: 64))
    }

    func testCaptionText() {
        XCTAssertEqual(ThumbnailRenderer.captionText("  a \n b\tc "), "a b c")
        let long = ThumbnailRenderer.captionText(String(repeating: "word ", count: 100))
        XCTAssertLessThanOrEqual(long.count, 160)
        XCTAssertTrue(long.hasSuffix("…"))
    }

    // MARK: End to end (writers -> factory / thumbnail)

    func testMoodboardEndToEnd() throws {
        let url = tempDir.appendingPathComponent("Board.mlmboard")
        try MoodboardWriter.write(MoodboardDraft(title: "Board T", subtitle: "Sub", images: [
            .init(name: "a.png", data: png(), mimeType: "image/png"),
            .init(name: "b.png", data: png(rgb: (0.1, 0.4, 0.9)), mimeType: "image/png"),
        ], palette: ["#FFFFFF", "#123456"]), to: url)
        let out = try PreviewContentFactory.make(for: url)
        XCTAssertEqual(out.title, "Board T")
        XCTAssertTrue(out.html.contains("data:image/jpeg;base64,"))
        XCTAssertTrue(out.html.contains("#123456"))
        XCTAssertTrue(out.html.contains("<dt>Images</dt><dd>2</dd>"))
        let thumb = try XCTUnwrap(ThumbnailRenderer.image(for: url, maxPixelSize: 300))
        XCTAssertEqual(max(thumb.width, thumb.height), 300)
    }

    func testStoryEndToEnd() throws {
        let url = tempDir.appendingPathComponent("Film.stry")
        try StoryWriter.write(StoryDraft(title: "Film", logline: "Log", sceneName: "Intro", shots: [
            .init(name: "s1.png", imageData: png(), description: "First <shot>"),
            .init(name: "s2.png", imageData: png(rgb: (0.2, 0.7, 0.3)), description: "Second"),
        ]), to: url)
        let out = try PreviewContentFactory.make(for: url)
        XCTAssertEqual(out.title, "Film")
        XCTAssertTrue(out.html.contains("First &lt;shot&gt;"))
        XCTAssertTrue(out.html.contains("Intro"))
        XCTAssertTrue(out.html.contains("class=\"thumb\" src=\"data:image/"))
        XCTAssertNotNil(ThumbnailRenderer.image(for: url, maxPixelSize: 256))
    }

    func testPlibAndAoeEndToEnd() throws {
        let b64 = png(width: 400, height: 300).base64EncodedString()
        let plib = tempDir.appendingPathComponent("Cat.plib")
        try Data("""
        {"prompt":"A cat in a hat","images":["data:image/png;base64,\(b64)"],
         "generationInfo":{"model":"flux","aspectRatio":"4:3","numberOfImages":1,"timestamp":"2025-01-02T03:04:05Z"}}
        """.utf8).write(to: plib)
        let out = try PreviewContentFactory.make(for: plib)
        XCTAssertEqual(out.title, "Cat")
        XCTAssertTrue(out.html.contains("A cat in a hat"))
        XCTAssertTrue(out.html.contains("<dd>flux</dd>"))
        let thumb = try XCTUnwrap(ThumbnailRenderer.image(for: plib, maxPixelSize: 400))
        XCTAssertEqual(thumb.width, 400)

        let aoe = tempDir.appendingPathComponent("Dog.aoe")
        try Data("""
        {"timestamp":1735787045000,"model":"m2","image":{"base64":"\(b64)","mimeType":"image/png"},
         "analysis":{"full_prompt":"A dog","short_description":"Dog"}}
        """.utf8).write(to: aoe)
        let aoeOut = try PreviewContentFactory.make(for: aoe)
        XCTAssertTrue(aoeOut.html.contains("A dog"))
        XCTAssertTrue(aoeOut.html.contains("<dd>m2</dd>"))
        XCTAssertNotNil(ThumbnailRenderer.image(for: aoe, maxPixelSize: 256))
    }

    func testPromptWithoutImageGetsTextCard() throws {
        let plib = tempDir.appendingPathComponent("Text.plib")
        try Data(#"{"prompt":"Only words here"}"#.utf8).write(to: plib)
        let thumb = try XCTUnwrap(ThumbnailRenderer.image(for: plib, maxPixelSize: 250))
        XCTAssertEqual(thumb.height, 250)
        XCTAssertEqual(thumb.width, 200)
    }

    func testUnsupportedExtensionThrows() {
        XCTAssertThrowsError(try PreviewContentFactory.make(for: tempDir.appendingPathComponent("x.txt")))
        XCTAssertNil(ThumbnailRenderer.image(for: tempDir.appendingPathComponent("x.txt"), maxPixelSize: 64))
    }

    // MARK: Fixture export (manual verification with qlmanage; see Extensions/README.md)

    /// `PLX_FIXTURE_DIR=/some/dir swift test --filter testExportFixtures` writes one sample
    /// of every supported type there. Skipped otherwise.
    func testExportFixtures() throws {
        guard let dir = ProcessInfo.processInfo.environment["PLX_FIXTURE_DIR"], !dir.isEmpty else {
            throw XCTSkip("Set PLX_FIXTURE_DIR to export Quick Look fixtures")
        }
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let colors: [(CGFloat, CGFloat, CGFloat)] = [(0.91, 0.45, 0.32), (0.25, 0.47, 0.71), (0.95, 0.80, 0.35),
                                                    (0.34, 0.62, 0.45), (0.55, 0.36, 0.64), (0.20, 0.22, 0.26)]
        let images = colors.enumerated().map { i, c in png(width: 640 + i * 40, height: 480, rgb: c) }
        try MoodboardWriter.write(MoodboardDraft(
            title: "Coastal Summer", subtitle: "Campaign 2026",
            images: images.enumerated().map { .init(name: "img\($0.offset).png", data: $0.element, mimeType: "image/png") },
            palette: ["#F7F3EC", "#E8734F", "#407AB5", "#F2CC59", "#33383F"]), to: out.appendingPathComponent("Sample.mlmboard"))
        try StoryWriter.write(StoryDraft(
            title: "Night Market", logline: "A street-food vendor finds a map.", sceneName: "Opening",
            sceneLocation: "Market", shots: images.prefix(5).enumerated().map {
                .init(name: "Shot \($0.offset + 1)", imageData: $0.element,
                      description: "Shot \($0.offset + 1): lanterns sway over the crowd.", tags: ["night"], types: ["WS"])
            }), to: out.appendingPathComponent("Sample.stry"))
        let b64 = png(width: 800, height: 600, rgb: (0.25, 0.47, 0.71)).base64EncodedString()
        try Data("""
        {"prompt":"A lighthouse on a basalt cliff at blue hour, long exposure, cinematic, soft fog rolling in",
         "images":["data:image/png;base64,\(b64)"],
         "generationInfo":{"model":"imagen-4","aspectRatio":"4:3","numberOfImages":1,"timestamp":"2026-09-01T10:00:00Z"},
         "analysis":{"short_description":"Lighthouse at blue hour","art_style":"Photographic","lighting":"Blue hour"}}
        """.utf8).write(to: out.appendingPathComponent("Sample.plib"))
        try Data("""
        {"timestamp":1788000000000,"model":"flux-pro","image":{"base64":"\(b64)","mimeType":"image/png"},
         "analysis":{"full_prompt":"Portrait of a fox in a knitted scarf, studio lighting","short_description":"Fox portrait"}}
        """.utf8).write(to: out.appendingPathComponent("Sample.aoe"))
        try Data(#"{"prompt":"Text-only prompt: a quiet library at dawn, dust in the light beams"}"#.utf8)
            .write(to: out.appendingPathComponent("TextOnly.plib"))
        for name in ["Sample.mlmboard", "Sample.stry", "Sample.plib", "Sample.aoe"] {
            let r = try PreviewContentFactory.make(for: out.appendingPathComponent(name))
            try Data(r.html.utf8).write(to: out.appendingPathComponent(name + ".html"))
        }
        // What the thumbnail extension draws, without going through Quick Look.
        for name in ["Sample.mlmboard", "Sample.stry", "Sample.plib", "Sample.aoe", "TextOnly.plib"] {
            let image = try XCTUnwrap(ThumbnailRenderer.image(for: out.appendingPathComponent(name), maxPixelSize: 512))
            let png = try XCTUnwrap(PreviewImageEncoder.encode(image, forceOpaque: false))
            try png.data.write(to: out.appendingPathComponent(name + ".thumb." + (png.mime == "image/png" ? "png" : "jpg")))
        }
    }
}
