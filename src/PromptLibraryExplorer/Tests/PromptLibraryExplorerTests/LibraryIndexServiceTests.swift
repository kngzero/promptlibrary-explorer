import XCTest
@testable import PromptLibraryExplorer

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(Int, Int)] = []
    func append(_ done: Int, _ total: Int) { lock.lock(); values.append((done, total)); lock.unlock() }
    var totals: [Int] { lock.lock(); defer { lock.unlock() }; return values.map(\.1) }
}

final class LibraryIndexServiceTests: TempDirectoryTestCase {
    private var library: URL!
    private var service: LibraryIndexService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        library = tempDir.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        service = LibraryIndexService(databaseURL: tempDir.appendingPathComponent("db/index.sqlite"))

        try addImage("cat.png", prompt: "a fluffy orange cat sleeping", negative: "blurry", extra: "Seed: 11, Size: 640x480")
        try addImage("dog.png", prompt: "a happy dog running on the beach")
        try addImage("sub/lion.png", prompt: "majestic lion portrait, golden mane")
        try addImage("sub/cat_and_dog.png", prompt: "two friends playing together")
        try writeFile("Library/.hidden/secret.png", PNGFixture.png(with: [PNGFixture.tEXt("parameters", "hidden cat\nSteps: 1")]))
        try writeFile("Library/notes.txt", Data("cat cat cat".utf8))
    }

    override func tearDownWithError() throws {
        service = nil
        library = nil
        try super.tearDownWithError()
    }

    private func addImage(_ name: String, prompt: String, negative: String? = nil, extra: String = "Seed: 1") throws {
        var text = prompt
        if let negative { text += "\nNegative prompt: \(negative)" }
        text += "\nSteps: 20, Sampler: Euler, \(extra)"
        try writeFile("Library/\(name)", PNGFixture.png(with: [PNGFixture.tEXt("parameters", text)]))
    }

    private func path(_ name: String) -> String { library.appendingPathComponent(name).path }

    private func search(_ query: String, under root: URL? = nil) async -> [String] {
        await service.search(query, under: root).map(\.path).sorted()
    }

    private func index() async -> [Int] {
        let log = ProgressLog()
        await service.indexLibrary(root: library) { done, total in log.append(done, total) }
        return log.totals
    }

    func testIndexAndQuerySyntax() async throws {
        _ = await index()

        let catHits = await search("cat")
        XCTAssertEqual(catHits, [path("cat.png"), path("sub/cat_and_dog.png")], "prompt or file name; hidden folders and non-media skipped")
        let andHits = await search("cat dog")
        XCTAssertEqual(andHits, [path("sub/cat_and_dog.png")])
        let phraseHits = await search("\"orange cat\"")
        XCTAssertEqual(phraseHits, [path("cat.png")])
        let wrongOrder = await search("\"cat orange\"")
        XCTAssertEqual(wrongOrder, [])
        let excluded = await search("cat -dog")
        XCTAssertEqual(excluded, [path("cat.png")])
        let prefix = await search("maj*")
        XCTAssertEqual(prefix, [path("sub/lion.png")])
        let caseInsensitive = await search("LION")
        XCTAssertEqual(caseInsensitive, [path("sub/lion.png")])
        // Negative prompts are searchable (lowest weight); `neg:` targets them alone.
        let negativeMatch = await search("blurry")
        XCTAssertEqual(negativeMatch, [path("cat.png")])
        let negativeOnly = await search("neg:blurry")
        XCTAssertEqual(negativeOnly, [path("cat.png")])
        let positiveWordAsNegative = await search("neg:lion")
        XCTAssertEqual(positiveWordAsNegative, [], "neg: must not match positive prompts")
        let rooted = await search("cat", under: library.appendingPathComponent("sub"))
        XCTAssertEqual(rooted, [path("sub/cat_and_dog.png")])
        let nothing = await search("-cat")
        XCTAssertEqual(nothing, [])
    }

    func testSnippetMarksMatches() async throws {
        _ = await index()
        let hitHits = await service.search("orange", under: nil)
        let hit = try XCTUnwrap(hitHits.first)
        XCTAssertEqual(hit.fileName, "cat.png")
        XCTAssertEqual(hit.folderPath, library.path)
        XCTAssertEqual(hit.snippet, "a fluffy «orange» cat sleeping")
    }

    func testParametersAndStats() async throws {
        _ = await index()
        let params = await service.parameters(forPaths: [path("cat.png"), path("dog.png"), "/nope.png"])
        XCTAssertEqual(params[path("cat.png")]?.seed, "11")
        XCTAssertEqual(params[path("cat.png")]?.steps, "20")
        XCTAssertEqual(params[path("cat.png")]?.sampler, "Euler")
        XCTAssertEqual(params[path("cat.png")]?.width, 640)
        XCTAssertEqual(params[path("dog.png")]?.width, 8, "pixel size used when metadata has none")
        XCTAssertNil(params["/nope.png"])

        let all = await service.stats(under: nil)
        XCTAssertEqual(all.fileCount, 4)
        XCTAssertNotNil(all.lastIndexed)
        let sub = await service.stats(under: library.appendingPathComponent("sub"))
        XCTAssertEqual(sub.fileCount, 2)
        XCTAssertNotNil(sub.lastIndexed, "a sub-folder is covered by its indexed ancestor")
    }

    func testReindexSkipsUnchangedAndPicksUpChanges() async throws {
        let first = await index()
        XCTAssertEqual(first.first, 4)
        let second = await index()
        XCTAssertEqual(second, [0], "nothing re-extracted when unchanged")

        try addImage("dog.png", prompt: "a sleepy dog under a tree with a much longer prompt")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: path("dog.png"))
        try FileManager.default.removeItem(atPath: path("sub/lion.png"))
        let third = await index()
        XCTAssertEqual(third.first, 1)

        let tree = await search("tree")
        XCTAssertEqual(tree, [path("dog.png")])
        let beach = await search("beach")
        XCTAssertEqual(beach, [])
        let lion = await search("lion")
        XCTAssertEqual(lion, [], "deleted files are dropped")
    }

    func testMovePathForFileAndFolder() async throws {
        _ = await index()

        await service.movePath(from: path("cat.png"), to: path("renamed.png"))
        let movedHits = await service.search("fluffy", under: nil)
        let moved = try XCTUnwrap(movedHits.first)
        XCTAssertEqual(moved.path, path("renamed.png"))
        XCTAssertEqual(moved.fileName, "renamed.png")

        await service.movePath(from: path("sub"), to: path("moved/deeper"))
        let lionHits = await service.search("lion", under: nil)
        let lion = try XCTUnwrap(lionHits.first)
        XCTAssertEqual(lion.path, path("moved/deeper/lion.png"))
        XCTAssertEqual(lion.folderPath, path("moved/deeper"))
        let underNew = await search("friends", under: library.appendingPathComponent("moved"))
        XCTAssertEqual(underNew, [path("moved/deeper/cat_and_dog.png")])
        let underOld = await search("lion", under: library.appendingPathComponent("sub"))
        XCTAssertEqual(underOld, [])
        let params = await service.parameters(forPaths: [path("moved/deeper/lion.png")])
        XCTAssertEqual(params[path("moved/deeper/lion.png")]?.steps, "20")
    }

    func testRemoveEntriesAndReset() async throws {
        _ = await index()
        await service.removeEntries(under: path("sub"))
        let lion = await search("lion")
        XCTAssertEqual(lion, [])
        let cat = await search("cat")
        XCTAssertEqual(cat, [path("cat.png")])

        await service.removeEntries(under: path("cat.png"))
        let catAfter = await search("cat")
        XCTAssertEqual(catAfter, [])
        let count = await service.stats(under: nil).fileCount
        XCTAssertEqual(count, 1)

        await service.reset()
        let stats = await service.stats(under: nil)
        XCTAssertEqual(stats.fileCount, 0)
        XCTAssertNil(stats.lastIndexed)
        let dog = await search("dog")
        XCTAssertEqual(dog, [])
    }

    func testDatabaseStaysInsideTempDirectory() async {
        _ = await index()
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("db/index.sqlite").path))
    }
}
