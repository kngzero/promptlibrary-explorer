import XCTest
@testable import PromptLibraryExplorer

// MARK: - PromptSimilarityService

final class PromptSimilarityServiceTests: XCTestCase {
    func testNormalizeStripsWeightsLorasAndPunctuation() {
        XCTAssertEqual(
            PromptSimilarityService.normalize("(Masterpiece:1.2), <lora:foo_v2:0.8> Best  QUALITY, [cat:-0.5]!"),
            "masterpiece best quality cat"
        )
    }

    func testWeightedAndPlainPromptsCluster() {
        let prompts = [
            "/lib/a.png": "a beautiful sunset over the ocean, highly detailed",
            "/lib/b.png": "A beautiful sunset over the ocean, (highly detailed:1.3)",
            "/lib/c.png": "cyberpunk robot in a rainy alley",
            "/lib/d.png": "",
        ]
        XCTAssertEqual(PromptSimilarityService.clusters(prompts: prompts), [["/lib/a.png", "/lib/b.png"]])
        XCTAssertEqual(PromptSimilarityService.similarity(prompts["/lib/a.png"]!, prompts["/lib/b.png"]!), 1)
    }

    func testThresholdControlsMembership() {
        let a = "portrait of an old fisherman, weathered face, dramatic lighting, film grain, 85mm lens, bokeh background"
        let b = "portrait of an old fisherman, weathered face, dramatic lighting, film grain, 85mm lens, bokeh sea"
        let s = PromptSimilarityService.similarity(a, b)
        XCTAssertGreaterThan(s, 0.6)
        XCTAssertLessThan(s, 1)
        let prompts = ["/a": a, "/b": b]
        XCTAssertEqual(PromptSimilarityService.clusters(prompts: prompts, threshold: s - 0.01), [["/a", "/b"]])
        XCTAssertEqual(PromptSimilarityService.clusters(prompts: prompts, threshold: s + 0.01), [])
    }

    func testClusterOrderingAndMinSize() {
        let prompts = [
            "/z1": "red car", "/z2": "red car", "/z3": "Red car!",
            "/a1": "blue boat on a lake", "/a2": "blue boat on a lake",
            "/solo": "something entirely different",
        ]
        let clusters = PromptSimilarityService.clusters(prompts: prompts)
        XCTAssertEqual(clusters, [["/z1", "/z2", "/z3"], ["/a1", "/a2"]], "largest first, members sorted")
        XCTAssertEqual(PromptSimilarityService.clusters(prompts: prompts, minClusterSize: 1).count, 3)
    }

    func testSimilarityEdgeCases() {
        XCTAssertEqual(PromptSimilarityService.similarity("", ""), 1)
        XCTAssertEqual(PromptSimilarityService.similarity("cat", ""), 0)
        XCTAssertEqual(PromptSimilarityService.similarity("cat dog", "fish bird"), 0)
    }
}

// MARK: - PromptFormatService

final class PromptFormatServiceTests: XCTestCase {
    private func entry(ratio: AspectRatio = .sixteenToNine, model: String = "N/A", fields: [PromptMetadataField]) -> PromptEntry {
        PromptEntry(
            prompt: "  a cat in a hat ",
            blindPrompt: "dog",
            generationInfo: GenerationInfo(aspectRatio: ratio, model: model, timestamp: "", numberOfImages: 1),
            images: [], referenceImages: [], rawImages: [], rawReferenceImages: [],
            embeddedMetadata: fields
        )
    }

    private let fields = [
        PromptMetadataField(label: "Seed", value: "42"),
        PromptMetadataField(label: "Steps", value: "30"),
        PromptMetadataField(label: "Model", value: "sdxl"),
        PromptMetadataField(label: "Size", value: "1024x576"),
    ]

    func testPlainMidjourneyDalle() {
        let e = entry(fields: fields)
        XCTAssertEqual(PromptFormatService.format(e, as: .plain), "a cat in a hat")
        XCTAssertEqual(PromptFormatService.format(e, as: .midjourney), "/imagine prompt: a cat in a hat --ar 16:9 --no dog --seed 42")
        XCTAssertEqual(PromptFormatService.format(e, as: .dalle), "a cat in a hat\n\nSize: 1792x1024")
    }

    func testStableDiffusionUsesMetadataAndDefaults() {
        XCTAssertEqual(
            PromptFormatService.format(entry(fields: fields), as: .stableDiffusion),
            "a cat in a hat\nNegative prompt: dog\nSteps: 30, Sampler: Euler a, CFG scale: 7, Seed: 42, Size: 1024x576, Model: sdxl"
        )
        // No size field: derived from the aspect ratio. Entry model wins over metadata.
        XCTAssertEqual(
            PromptFormatService.format(entry(ratio: .threeToFour, model: "plib-model", fields: []), as: .stableDiffusion),
            "a cat in a hat\nNegative prompt: dog\nSteps: 20, Sampler: Euler a, CFG scale: 7, Size: 480x640, Model: plib-model"
        )
        XCTAssertFalse(PromptFormatService.format(entry(ratio: .notAvailable, fields: []), as: .stableDiffusion).contains("Size"))
    }

    func testJSON() throws {
        let json = PromptFormatService.format(entry(fields: fields), as: .json)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(object["prompt"] as? String, "a cat in a hat")
        XCTAssertEqual(object["negativePrompt"] as? String, "dog")
        let params = try XCTUnwrap(object["parameters"] as? [String: Any])
        XCTAssertEqual(params["seed"] as? Int, 42)
        XCTAssertEqual(params["steps"] as? Int, 30)
        XCTAssertEqual(params["model"] as? String, "sdxl")
        XCTAssertEqual(params["width"] as? Int, 1024)
        XCTAssertEqual(params["aspectRatio"] as? String, "16:9")
    }

    func testFormatTitlesAreUnique() {
        XCTAssertEqual(Set(PromptCopyFormat.allCases.map(\.title)).count, PromptCopyFormat.allCases.count)
    }
}

// MARK: - Smart folders

final class SmartFolderTests: XCTestCase {
    func testOldCriteriaBlobDecodesWithDefaults() throws {
        let json = #"{"searchQuery":"cat","fileTypes":["png","bogus"],"minRating":3,"dateRange":"lastDecade"}"#
        let c = try JSONDecoder().decode(SmartFolderCriteria.self, from: Data(json.utf8))
        XCTAssertEqual(c.searchQuery, "cat")
        XCTAssertEqual(c.fileTypes, [.png])
        XCTAssertEqual(c.minRating, 3)
        XCTAssertEqual(c.dateRange, .any)
        XCTAssertEqual(c.matchMode, .all)
        XCTAssertFalse(c.favoritesOnly)
        XCTAssertTrue(c.tagIDs.isEmpty)
        XCTAssertTrue(c.isActive)
    }

    func testOldSmartFolderBlobDecodes() throws {
        let id = UUID()
        let json = #"[{"id":"\#(id.uuidString)","name":"Old","createdAt":700000000,"criteria":{"favoritesOnly":true}}]"#
        let folders = try JSONDecoder().decode([SmartFolder].self, from: Data(json.utf8))
        XCTAssertEqual(folders.first?.id, id)
        XCTAssertEqual(folders.first?.criteria.favoritesOnly, true)
        XCTAssertEqual(folders.first?.criteria.modelContains, "")
    }

    func testCriteriaRoundTrip() throws {
        var c = SmartFolderCriteria()
        c.searchQuery = "q"
        c.fileTypes = [.jpg, .plib]
        c.tagIDs = [UUID()]
        c.modelContains = "flux"
        c.requiresNegativePrompt = true
        c.matchMode = .any
        c.dateRange = .lastWeek
        let decoded = try JSONDecoder().decode(SmartFolderCriteria.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(decoded, c)
    }

    private let entries = [
        FileEntry(url: URL(fileURLWithPath: "/lib/cat.png"), isDirectory: false, modifiedDate: Date()),
        FileEntry(url: URL(fileURLWithPath: "/lib/dog.jpg"), isDirectory: false, modifiedDate: Date()),
        FileEntry(url: URL(fileURLWithPath: "/lib/old.plib"), isDirectory: false, modifiedDate: Date(timeIntervalSince1970: 0)),
        FileEntry(url: URL(fileURLWithPath: "/lib/cats"), isDirectory: true, modifiedDate: Date()),
    ]

    private func names(_ criteria: SmartFolderCriteria, _ context: SmartFolderFilterContext = .init()) -> [String] {
        SmartFolderService.filter(entries, criteria: criteria, context: context).map(\.name)
    }

    func testAllAndAnyModes() {
        var c = SmartFolderCriteria()
        XCTAssertEqual(names(c), ["cat.png", "dog.jpg", "old.plib"], "no rules: every file, never folders")

        c.searchQuery = "cat"
        c.fileTypes = [.jpg]
        c.matchMode = .all
        XCTAssertEqual(names(c), [])
        c.matchMode = .any
        XCTAssertEqual(names(c), ["cat.png", "dog.jpg"])
    }

    func testRulesUseContextLookups() {
        let tag = UUID()
        let context = SmartFolderFilterContext(
            tagsByPath: ["/lib/dog.jpg": [tag]],
            favorites: ["/lib/old.plib"],
            ratings: ["/lib/cat.png": 4, "/lib/dog.jpg": 2],
            promptByPath: ["/lib/dog.jpg": "a Café scene", "/lib/cat.png": "  "],
            negativeByPath: ["/lib/cat.png": "blurry"],
            modelByPath: ["/lib/cat.png": "FLUX.1-dev"]
        )
        var c = SmartFolderCriteria(); c.minRating = 3
        XCTAssertEqual(names(c, context), ["cat.png"])
        c = SmartFolderCriteria(); c.tagIDs = [tag]
        XCTAssertEqual(names(c, context), ["dog.jpg"])
        c = SmartFolderCriteria(); c.favoritesOnly = true
        XCTAssertEqual(names(c, context), ["old.plib"])
        c = SmartFolderCriteria(); c.modelContains = "flux"
        XCTAssertEqual(names(c, context), ["cat.png"])
        c = SmartFolderCriteria(); c.requiresPrompt = true
        XCTAssertEqual(names(c, context), ["dog.jpg"], "whitespace-only prompt doesn't count")
        c = SmartFolderCriteria(); c.requiresNegativePrompt = true
        XCTAssertEqual(names(c, context), ["cat.png"])
        c = SmartFolderCriteria(); c.searchQuery = "cafe"
        XCTAssertEqual(names(c, context), ["dog.jpg"], "prompt search is diacritic-insensitive")
        c = SmartFolderCriteria(); c.dateRange = .lastYear
        XCTAssertEqual(names(c, context), ["cat.png", "dog.jpg"])
    }
}

// MARK: - MetadataZlib

final class MetadataZlibTests: XCTestCase {
    func testInflatesZlibStream() {
        let text = Data("hello zlib world, hello zlib world".utf8)
        XCTAssertEqual(MetadataZlib.inflate(Zlib.compress(text)), text)
    }

    func testInflatesRawDeflateWithoutHeader() {
        let text = Data("raw deflate payload".utf8)
        XCTAssertEqual(MetadataZlib.inflate(Zlib.rawDeflate(text)), text)
    }

    func testLargeHighlyCompressiblePayload() {
        let text = Data(String(repeating: "{\"class_type\":\"KSampler\"},", count: 100_000).utf8)
        let compressed = Zlib.compress(text)
        XCTAssertGreaterThan(text.count / compressed.count, 100)
        XCTAssertEqual(MetadataZlib.inflate(compressed), text)
    }

    func testRejectsBadInput() {
        XCTAssertNil(MetadataZlib.inflate(Data()))
        var fdict = Zlib.compress(Data("x".utf8))
        fdict[1] = 0xBB // 0x78BB: FDICT set, valid FCHECK
        XCTAssertEqual((UInt16(fdict[0]) << 8 | UInt16(fdict[1])) % 31, 0)
        XCTAssertNil(MetadataZlib.inflate(fdict))
        let truncated = Zlib.compress(Data(String(repeating: "abcdefgh", count: 500).utf8)).prefix(6)
        XCTAssertNil(MetadataZlib.inflate(Data(truncated)))
    }
}

// MARK: - FileHelpers / small models

final class FileHelpersTests: XCTestCase {
    func testTypeChecks() {
        XCTAssertTrue(FileHelpers.isImageFile("A.PNG"))
        XCTAssertTrue(FileHelpers.isImageFile("x.heic"))
        XCTAssertFalse(FileHelpers.isImageFile("x.mov"))
        XCTAssertFalse(FileHelpers.isImageFile("noext"))
        XCTAssertTrue(FileHelpers.isVideoFile("clip.MOV"))
        XCTAssertTrue(FileHelpers.isAudioFile("a.wav"))
        XCTAssertTrue(FileHelpers.isPlibFile("p.PLIB"))
        XCTAssertTrue(FileHelpers.isAoeFile("e.aoe"))
        XCTAssertTrue(FileHelpers.isPromptSnapshotFile("e.aoe"))
        XCTAssertFalse(FileHelpers.isDroppable("readme.txt"))
        XCTAssertTrue(FileHelpers.isDroppable("song.mp3"))
    }

    func testFilterTypeAndSortRank() {
        XCTAssertEqual(FileHelpers.filterType(forName: "x.JPEG"), .jpg)
        XCTAssertEqual(FileHelpers.filterType(forName: "x.tif"), .otherImages)
        XCTAssertEqual(FileHelpers.filterType(forName: "x.m4v"), .video)
        XCTAssertEqual(FileHelpers.filterType(forName: "x.flac"), .audio)
        XCTAssertEqual(FileHelpers.filterType(forName: "x.txt"), .unsupported)
        XCTAssertNil(FileHelpers.filterType(for: FileEntry(url: URL(fileURLWithPath: "/d.png"), isDirectory: true)))

        func rank(_ name: String, dir: Bool = false) -> Int {
            FileHelpers.typeRank(for: FileEntry(url: URL(fileURLWithPath: "/x/\(name)"), isDirectory: dir))
        }
        XCTAssertEqual([rank("f", dir: true), rank("a.plib"), rank("a.png"), rank("a.mp4"), rank("a.mp3"), rank("a.txt")], [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(FileHelpers.canonicalTypeExtension("JPEG"), "jpg")
        XCTAssertEqual(FileHelpers.canonicalTypeExtension(nil), "")
        XCTAssertEqual(FileHelpers.describeFileType("jpeg"), "JPEG Image")
        XCTAssertEqual(FileHelpers.describeFileType("xyz"), "XYZ File")
    }

    func testStringHeuristics() {
        XCTAssertTrue(FileHelpers.isLikelyAbsolutePath("/Users/x"))
        XCTAssertTrue(FileHelpers.isLikelyAbsolutePath("C:\\images\\a.png"))
        XCTAssertFalse(FileHelpers.isLikelyAbsolutePath("images/a.png"))
        XCTAssertTrue(FileHelpers.isLikelyBase64(String(repeating: "QUJD", count: 40)))
        XCTAssertFalse(FileHelpers.isLikelyBase64("short"))
        XCTAssertEqual(FileHelpers.mimeFromExtension("JPG"), "image/jpeg")
        XCTAssertEqual(FileHelpers.mimeFromExtension(nil), "application/octet-stream")
    }

    func testSortAndGroupTitles() {
        XCTAssertEqual(Set(SortField.allCases.map(\.title)).count, SortField.allCases.count)
        XCTAssertEqual(Set(GroupByField.allCases.map(\.title)).count, GroupByField.allCases.count)
        XCTAssertFalse(SortField.custom.supportsDirection)
        XCTAssertTrue(SortField.name.supportsDirection)
        XCTAssertEqual(SortConfig(), SortConfig(field: .type, direction: .asc))
        var filter = FilterConfig()
        XCTAssertEqual(filter.activeCount, 0)
        filter.setHidden(true, for: .video)
        filter.filterMinRating = 2
        XCTAssertEqual(filter.activeCount, 2)
    }

    func testMigratedPathMapping() {
        XCTAssertEqual(CollectionServiceStorage.migrated("/a/b", from: "/a/b", to: "/c"), "/c")
        XCTAssertEqual(CollectionServiceStorage.migrated("/a/b/x/y.png", from: "/a/b", to: "/c/d"), "/c/d/x/y.png")
        XCTAssertEqual(CollectionServiceStorage.migrated("/a/b/x.png", from: "/a/b/", to: "/c/"), "/c/x.png")
        XCTAssertNil(CollectionServiceStorage.migrated("/a/bc/x.png", from: "/a/b", to: "/c"), "sibling with shared prefix")
        XCTAssertNil(CollectionServiceStorage.migrated("/z", from: "/a", to: "/c"))
    }

    func testFTSQueryTranslation() {
        XCTAssertEqual(
            LibraryIndexService.ftsQuery(from: #"a "b c" -d e*"#),
            // Plain terms also match negative prompts; `-word` excludes on name/prompt only.
            #"({name prompt negative} : ("a" AND "b c" AND "e"*)) NOT ({name prompt} : "d")"#
        )
        XCTAssertNil(LibraryIndexService.ftsQuery(from: "-only -negatives"))
        XCTAssertNil(LibraryIndexService.ftsQuery(from: "  ,, ;; "))
        XCTAssertEqual(LibraryIndexService.ftsQuery(from: #"NEAR(x" OR"#), #"{name prompt negative} : ("NEAR(x""" AND "OR")"#)
        let range = LibraryIndexService.descendantRange("/a")
        XCTAssertEqual(range.0, "/a/")
        XCTAssertEqual(range.1, "/a0")
        XCTAssertEqual(LibraryIndexService.normalizedPath("/a/b//"), "/a/b")
    }
}

// MARK: - FolderSearchService

final class FolderSearchServiceTests: TempDirectoryTestCase {
    private func mkdir(_ path: String) throws {
        try FileManager.default.createDirectory(at: tempDir.appendingPathComponent(path), withIntermediateDirectories: true)
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        for dir in ["Cats", "a/cats2", "a/b/CATalog", ".hiddencat", "a/.secret/cat_inside_hidden", "Thing.app/Contents/cat_in_pkg",
                    "catpkg.app/Contents", "dogs"] {
            try mkdir(dir)
        }
        try writeFile("cat.txt", Data("not a folder".utf8))
    }

    func testFindsFoldersShallowFirstSkippingHiddenAndPackages() async {
        let matches = await FolderSearchService.findFolders(matching: "cat", under: tempDir)
        XCTAssertEqual(matches.map(\.name), ["Cats", "cats2", "CATalog"])
        XCTAssertEqual(matches.map(\.relativeParent), ["", "a", "a/b"])
    }

    func testLimitAndEmptyQuery() async {
        let limited = await FolderSearchService.findFolders(matching: "cat", under: tempDir, limit: 1)
        XCTAssertEqual(limited.count, 1)
        let empty = await FolderSearchService.findFolders(matching: "   ", under: tempDir)
        XCTAssertTrue(empty.isEmpty)
        let none = await FolderSearchService.findFolders(matching: "zebra", under: tempDir)
        XCTAssertTrue(none.isEmpty)
    }
}
