import ArtOfficialFormats
import CoreGraphics
import ImageIO
import XCTest
@testable import PromptLibraryExplorer

/// App-side integration of Mood boards / Story projects: type plumbing, smart folders,
/// Send to Mood / Story round trips, search-text extraction and the text exports.
final class ArtOfficialIntegrationTests: TempDirectoryTestCase {
    // MARK: Fixtures

    private func writePNG(_ name: String, width: Int = 40, height: Int = 30, rgb: (UInt8, UInt8, UInt8) = (200, 40, 40)) throws -> URL {
        try writeFile(name, AOFixtures.png(width: width, height: height, rgb: rgb))
    }

    private func writeJPEG(_ name: String, width: Int, height: Int) throws -> URL {
        let image = AOFixtures.image(width: width, height: height, rgb: (20, 90, 200), split: (240, 220, 30))
        return try writeFile(name, AOFixtures.encode(image, type: "public.jpeg"))
    }

    /// A PNG carrying an A1111-style `parameters` chunk.
    private func writePromptPNG(_ name: String, prompt: String) throws -> URL {
        try writeFile(name, PNGFixture.png(with: [PNGFixture.tEXt("parameters", "\(prompt)\nSteps: 20, Sampler: Euler, Seed: 7")]))
    }

    private func writeBoard(_ name: String, title: String, images: [(String, Data)], palette: [String]) throws -> URL {
        let draft = MoodboardDraft(
            title: title,
            subtitle: "Spring campaign",
            images: images.map { MoodboardDraft.Image(name: $0.0, data: $0.1, mimeType: "image/png") },
            palette: palette
        )
        let url = tempDir.appendingPathComponent(name)
        try MoodboardWriter.write(draft, to: url)
        return url
    }

    private func writeStory(_ name: String, title: String, shots: [StoryDraft.Shot]) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try StoryWriter.write(StoryDraft(title: title, logline: "A quiet heist.", shots: shots), to: url)
        return url
    }

    // MARK: Type detection & filters

    func testTypeDetectionForNewExtensions() {
        XCTAssertTrue(FileHelpers.isMoodboardFile("Board.MLMBOARD"))
        XCTAssertTrue(FileHelpers.isStoryFile("film.stry"))
        XCTAssertTrue(FileHelpers.isStoryFile("old.mlseq"))
        XCTAssertFalse(FileHelpers.isStoryFile("board.mlmboard"))
        XCTAssertFalse(FileHelpers.isMoodboardFile("x.plib"))
        XCTAssertTrue(FileHelpers.isArtOfficialDocumentFile("a.stry"))
        XCTAssertFalse(FileHelpers.isArtOfficialDocumentFile("a.png"))

        XCTAssertEqual(FileHelpers.filterType(forName: "a.mlmboard"), .moodboard)
        XCTAssertEqual(FileHelpers.filterType(forName: "a.stry"), .story)
        XCTAssertEqual(FileHelpers.filterType(forName: "a.MLSEQ"), .story)
        XCTAssertEqual(FileHelpers.describeFileType("mlmboard"), "Mood Board")
        XCTAssertEqual(FileHelpers.describeFileType("stry"), "Story Project")

        let board = FileEntry(url: URL(fileURLWithPath: "/tmp/x/board.mlmboard"), isDirectory: false)
        XCTAssertTrue(FileHelpers.isPreviewable(board))
        XCTAssertEqual(FileHelpers.typeSortDescriptor(for: board).rank, 1, "sorts with the other Art Official documents")
        XCTAssertEqual(FileHelpers.typeSortDescriptor(for: board).typeLabel, "Mood Board")
        XCTAssertTrue(FileHelpers.isDroppable("/tmp/a.stry"))
        XCTAssertTrue(LibraryIndexService.isIndexable("a.mlmboard"))
        XCTAssertTrue(LibraryIndexService.isIndexable("a.stry"))

        var filters = FilterConfig()
        XCTAssertFalse(filters.hides(.moodboard))
        filters.setHidden(true, for: .story)
        XCTAssertTrue(filters.hides(.story))
        XCTAssertEqual(filters.activeCount, 1)
        XCTAssertEqual(Set(FileTypeFilter.allCases.map(\.displayName)).count, FileTypeFilter.allCases.count)
    }

    func testSmartFolderDecodesNewAndUnknownFileTypes() throws {
        let json = #"{"fileTypes": ["moodboard", "story", "hologram", "plib"], "minRating": 2}"#
        let criteria = try JSONDecoder().decode(SmartFolderCriteria.self, from: Data(json.utf8))
        XCTAssertEqual(criteria.fileTypes, [.moodboard, .story, .plib], "unknown types are dropped, not fatal")
        XCTAssertEqual(criteria.minRating, 2)

        // Old saved data without the new cases still decodes.
        let old = try JSONDecoder().decode(SmartFolderCriteria.self, from: Data(#"{"fileTypes": ["png", "other"]}"#.utf8))
        XCTAssertEqual(old.fileTypes, [.png, .other])

        // Round trip.
        let encoded = try JSONEncoder().encode(criteria)
        XCTAssertEqual(try JSONDecoder().decode(SmartFolderCriteria.self, from: encoded).fileTypes, criteria.fileTypes)

        XCTAssertTrue(SmartFolderFileType.moodboard.matches("Look.mlmboard"))
        XCTAssertTrue(SmartFolderFileType.story.matches("Cut.mlseq"))
        XCTAssertFalse(SmartFolderFileType.story.matches("Look.mlmboard"))
        XCTAssertFalse(SmartFolderFileType.other.matches("Look.mlmboard"), "documents have their own type now")
        XCTAssertTrue(SmartFolderFileType.other.matches("notes.txt"))
    }

    // MARK: Send to Mood

    func testSendToMoodRoundTrip() throws {
        let small = try writePNG("red.png", rgb: (220, 30, 30))
        let blue = try writePNG("blue.png", rgb: (30, 60, 220))
        let big = try writeJPEG("wide.jpg", width: 3000, height: 1200)
        let text = try writeFile("notes.txt", Data("not an image".utf8))
        let items = [small, blue, big, text].map { ArtOfficialSendItem(url: $0) }

        let progress = ProgressRecorder()
        let result = ArtOfficialSendBuilder.moodboardDraft(title: "Spring Looks", items: items) { done, total in
            progress.record(done, total)
        }
        XCTAssertEqual(result.addedCount, 3)
        XCTAssertEqual(result.skippedNames, ["notes.txt"])
        XCTAssertEqual(progress.last?.done, 4)
        XCTAssertEqual(progress.last?.total, 4)
        XCTAssertNotNil(result.draft.palette)

        let out = tempDir.appendingPathComponent("Spring Looks.mlmboard")
        try MoodboardWriter.write(result.draft, to: out)
        let board = try MoodboardReader.read(from: out)

        XCTAssertEqual(board.title, "Spring Looks")
        XCTAssertEqual(board.assets.count, 3)
        XCTAssertEqual(board.imageTileCount, 3)
        XCTAssertEqual(board.assets.map(\.name), ["red.png", "blue.png", "wide.jpg"], "display order kept")
        XCTAssertFalse(board.palette.isEmpty)

        // Small PNG passes through as PNG; the big JPEG is downscaled and stays JPEG.
        XCTAssertEqual(board.assets[0].image.mimeType, "image/png")
        XCTAssertEqual(board.assets[0].image.data(), try Data(contentsOf: small))
        XCTAssertEqual(board.assets[2].image.mimeType, "image/jpeg")
        let size = try XCTUnwrap(board.assets[2].image.pixelSize())
        XCTAssertEqual(max(size.width, size.height), CGFloat(ArtOfficialSendBuilder.maxMoodImagePixels))
        XCTAssertEqual(size.width / size.height, 2.5, accuracy: 0.01)
    }

    // MARK: Send to Story

    func testSendToStoryRoundTripUsesAppPromptsAndTags() async throws {
        let first = try writePromptPNG("shot_a.png", prompt: "a lighthouse at dusk, cinematic")
        let second = try writePromptPNG("shot_b.png", prompt: "rain on a neon street")
        let video = try writeFile("clip.mp4", Data([0, 0, 0, 24]))

        // Descriptions come from the app's prompt data, as the view model gathers it.
        var items: [ArtOfficialSendItem] = []
        for url in [first, second, video] {
            let entry = FileEntry(url: url, isDirectory: false)
            let parsed = await ExplorerViewModel.parsePromptData(for: entry)
            items.append(ArtOfficialSendItem(url: url, prompt: parsed.prompt ?? "", tags: url == first ? ["hero", "dusk"] : []))
        }
        XCTAssertEqual(items[0].prompt, "a lighthouse at dusk, cinematic")

        let result = ArtOfficialSendBuilder.storyDraft(title: "Night Shoot", items: items)
        XCTAssertEqual(result.addedCount, 2)
        XCTAssertEqual(result.skippedNames, ["clip.mp4"])

        let out = tempDir.appendingPathComponent("Night Shoot.stry")
        try StoryWriter.write(result.draft, to: out)
        let story = try StoryReader.read(from: out)

        XCTAssertEqual(story.projects.count, 1)
        let project = try XCTUnwrap(story.projects.first)
        XCTAssertEqual(project.title, "Night Shoot")
        XCTAssertEqual(project.scenes.count, 1)
        XCTAssertEqual(project.shotCount, 2)
        XCTAssertEqual(project.allShots.map(\.name), ["shot_a.png", "shot_b.png"])
        XCTAssertEqual(project.allShots.map(\.description), ["a lighthouse at dusk, cinematic", "rain on a neon street"])
        XCTAssertEqual(project.allShots[0].tags, ["hero", "dusk"])
        let thumb = try XCTUnwrap(project.allShots[0].thumb)
        XCTAssertNotNil(thumb.data(), "thumbnail embedded")
        XCTAssertLessThanOrEqual(max(thumb.pixelSize()?.width ?? 0, thumb.pixelSize()?.height ?? 0), 1024)
    }

    func testSendHelpers() {
        XCTAssertEqual(ArtOfficialSendBuilder.defaultTitle("  Picks ", fallback: "Story"), "Picks")
        XCTAssertEqual(ArtOfficialSendBuilder.defaultTitle(nil, fallback: "Story"), "Story")
        XCTAssertEqual(ArtOfficialSendBuilder.suggestedFileName(title: "a/b: c", fileExtension: "stry"), "a-b- c.stry")
        XCTAssertTrue(ArtOfficialSendBuilder.isSendable("x.webp"))
        XCTAssertFalse(ArtOfficialSendBuilder.isSendable("x.mlmboard"))
    }

    // MARK: Search text

    func testIndexRecordExtractionForMoodAndStory() async throws {
        let boardURL = try writeBoard(
            "look.mlmboard",
            title: "Sunset Palette",
            images: [("golden-hour.png", AOFixtures.png())],
            palette: ["#FFAA33", "#112233"]
        )
        let storyURL = try writeStory("heist.stry", title: "Midnight Vault", shots: [
            StoryDraft.Shot(name: "Crane down", description: "slow crane down onto the vault door", tags: ["vfx"]),
        ])

        func candidate(_ url: URL) -> LibraryIndexCandidate {
            LibraryIndexCandidate(path: url.path, name: url.lastPathComponent, folder: url.deletingLastPathComponent().path, mtime: 1, size: 1)
        }

        let boardRecord = await LibraryIndexExtractor.record(for: candidate(boardURL))
        XCTAssertEqual(boardRecord.title, "Sunset Palette")
        XCTAssertTrue(boardRecord.prompt.contains("Sunset Palette"))
        XCTAssertTrue(boardRecord.prompt.contains("Spring campaign"))
        XCTAssertTrue(boardRecord.prompt.contains("golden-hour.png"))
        XCTAssertTrue(boardRecord.prompt.contains("#FFAA33"), "palette hex is searchable")
        XCTAssertTrue(LibraryIndexService.searchableNameColumn(for: boardRecord).contains("Sunset Palette"))

        let storyRecord = await LibraryIndexExtractor.record(for: candidate(storyURL))
        XCTAssertEqual(storyRecord.title, "Midnight Vault")
        XCTAssertTrue(storyRecord.prompt.contains("slow crane down onto the vault door"))
        XCTAssertTrue(storyRecord.prompt.contains("A quiet heist."))
        XCTAssertTrue(storyRecord.prompt.contains("vfx"))

        // End to end through the library index.
        let service = LibraryIndexService(databaseURL: tempDir.appendingPathComponent("db/index.sqlite"))
        await service.indexLibrary(root: tempDir, progress: nil)
        let sunset = await service.search("sunset", under: nil).map(\.path)
        XCTAssertEqual(sunset, [boardURL.path])
        let hex = await service.search("ffaa33", under: nil).map(\.path)
        XCTAssertEqual(hex, [boardURL.path])
        let crane = await service.search("crane vault", under: nil).map(\.path)
        XCTAssertEqual(crane, [storyURL.path])

        // The in-folder prompt index pass sees the same text.
        let parsed = await ExplorerViewModel.parsePromptData(for: FileEntry(url: storyURL, isDirectory: false))
        XCTAssertTrue(parsed.searchText?.contains("slow crane down") == true)
        XCTAssertNil(parsed.prompt, "documents have no positive prompt of their own")
    }

    func testDocumentParserInvalidatesOnChange() async throws {
        let url = try writeBoard("b.mlmboard", title: "First", images: [], palette: [])
        let first = await ArtOfficialDocumentParser.shared.parse(at: url)
        XCTAssertEqual(first?.moodboard?.title, "First")

        _ = try writeBoard("b.mlmboard", title: "Second Title", images: [], palette: [])
        let second = await ArtOfficialDocumentParser.shared.parse(at: url)
        XCTAssertEqual(second?.moodboard?.title, "Second Title", "size/mtime change drops the cached parse")

        await ArtOfficialDocumentParser.shared.invalidate(path: url.path)
        let notABoard = try writeFile("c.mlmboard", Data("garbage".utf8))
        let bad = await ArtOfficialDocumentParser.shared.parse(at: notABoard)
        XCTAssertNil(bad)
    }

    // MARK: Text exports & lightbox steps

    func testPaletteAndShotListExports() {
        let palette = ["#ffaa33", "abc", "nope", "#112233"]
        XCTAssertEqual(ArtOfficialTextExport.palette(palette, as: .hexList), "#FFAA33\n#AABBCC\n#112233")
        XCTAssertEqual(ArtOfficialTextExport.palette(palette, as: .json), ##"["#FFAA33", "#AABBCC", "#112233"]"##)
        XCTAssertEqual(
            ArtOfficialTextExport.palette(["#010203"], as: .cssVariables),
            ":root {\n  --palette-1: #010203;\n}"
        )

        let shots = [
            StoryShot(id: "a", index: 0, name: "Wide, establishing", types: ["WS"], description: "He said \"go\""),
            StoryShot(id: "b", index: 1, name: "Close", description: "eyes"),
        ]
        let scene = StoryScene(id: "s", index: 0, name: "Rooftop", number: 1, shots: shots)
        let project = StoryProject(id: "p", title: "Test", scenes: [scene])

        let csv = ArtOfficialTextExport.shotList(project, as: .csv).components(separatedBy: "\n")
        XCTAssertEqual(csv.count, 3)
        XCTAssertTrue(csv[1].hasPrefix(#"1,Rooftop,1,"Wide, establishing",WS,"#))
        XCTAssertTrue(csv[1].contains(#""He said ""go""""#))

        let text = ArtOfficialTextExport.shotList(project, as: .text)
        XCTAssertTrue(text.contains("Scene 1: Rooftop"))
        XCTAssertTrue(text.contains("2. Close"))

        let steps = project.storyboardSteps
        XCTAssertEqual(steps.map(\.positionLabel), ["Scene 1 · Shot 1", "Scene 1 · Shot 2"])
        XCTAssertEqual(LightboxDocumentStep.steps(for: .story(StoryDocument(projects: [project]))).count, 2)

        XCTAssertEqual(ArtOfficialTextExport.formatDuration(5), "5s")
        XCTAssertEqual(ArtOfficialTextExport.formatDuration(65), "1:05")
        XCTAssertEqual(ArtOfficialTextExport.formatDuration(3723), "1:02:03")
    }

    func testExtractionWritesUniqueNames() throws {
        let url = try writeBoard(
            "e.mlmboard",
            title: "E",
            images: [("same.png", AOFixtures.png()), ("same.png", AOFixtures.png(rgb: (1, 2, 3)))],
            palette: []
        )
        let board = try MoodboardReader.read(from: url)
        let folder = tempDir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("same.png"))

        let result = ArtOfficialExtraction.extractImages(from: board, to: folder)
        XCTAssertEqual(result.written, 2)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(names, ["same 2.png", "same 3.png", "same.png"])

        XCTAssertEqual(LightboxDocumentStep.steps(for: .moodboard(board)).count, 2)
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(done: Int, total: Int)] = []
    func record(_ done: Int, _ total: Int) { lock.lock(); values.append((done, total)); lock.unlock() }
    var last: (done: Int, total: Int)? { lock.lock(); defer { lock.unlock() }; return values.last }
}
