import CoreSpotlight
import XCTest
@testable import PromptLibraryExplorer

/// Answers "dataless" for a fixed set of paths; everything else is local.
private struct MockCloudStatus: CloudFileStatusProviding {
    var dataless: Set<String> = []
    var snapshots: [String: CloudResourceSnapshot] = [:]

    func snapshot(forPath path: String, fast: Bool) -> CloudResourceSnapshot? {
        if let snapshot = snapshots[path] { return snapshot }
        return CloudResourceSnapshot(isDataless: dataless.contains(path))
    }
}

// MARK: - promptlibrary:// URLs

final class AutomationURLTests: XCTestCase {
    private let home = "/Users/tester"

    private func parse(_ string: String) -> Result<AutomationURLAction, AutomationURLError> {
        AutomationURL.parse(URL(string: string)!, home: home)
    }

    func testOpenPaths() {
        XCTAssertEqual(parse("promptlibrary://open?path=/Volumes/Art/Renders"), .success(.open(path: "/Volumes/Art/Renders")))
        XCTAssertEqual(parse("promptlibrary://open?path=~/Pictures/a%20b.png"), .success(.open(path: "/Users/tester/Pictures/a b.png")))
        XCTAssertEqual(parse("promptlibrary://open?path=~"), .success(.open(path: "/Users/tester")))
        XCTAssertEqual(parse("promptlibrary://reveal?file=/tmp/x/../y.png"), .success(.open(path: "/tmp/y.png")), "standardized")
        XCTAssertEqual(parse("promptlibrary://open?path=file:///Users/tester/z.png"), .success(.open(path: "/Users/tester/z.png")))
        XCTAssertEqual(parse("promptlibrary:open?path=/a"), .success(.open(path: "/a")), "no // form")
        XCTAssertEqual(parse("PromptLibrary://OPEN?PATH=/a"), .success(.open(path: "/a")), "case-insensitive scheme, action, key")
    }

    func testSearchAndCollection() {
        XCTAssertEqual(parse("promptlibrary://search?q=cinematic%20portrait"), .success(.search(query: "cinematic portrait")))
        XCTAssertEqual(parse("promptlibrary://find?query=%20cat%20"), .success(.search(query: "cat")), "trimmed")
        XCTAssertEqual(parse("promptlibrary://collection?name=Portfolio%202026"), .success(.collection(name: "Portfolio 2026")))
    }

    func testErrors() {
        XCTAssertEqual(parse("https://example.com/open?path=/a"), .failure(.wrongScheme))
        XCTAssertEqual(parse("promptlibrary://delete?path=/a"), .failure(.unknownAction("delete")), "no destructive actions")
        XCTAssertEqual(parse("promptlibrary://open"), .failure(.missingParameter("path")))
        XCTAssertEqual(parse("promptlibrary://open?path="), .failure(.missingParameter("path")))
        XCTAssertEqual(parse("promptlibrary://search?q=%20"), .failure(.missingParameter("q")))
        XCTAssertEqual(parse("promptlibrary://collection"), .failure(.missingParameter("name")))
        XCTAssertEqual(parse("promptlibrary://open?path=Pictures/x.png"), .failure(.relativePath("Pictures/x.png")))
    }

    func testBuildersRoundTrip() throws {
        let search = try XCTUnwrap(AutomationURL.searchURL(query: "red & blue #1 ?"))
        XCTAssertEqual(AutomationURL.parse(search, home: home), .success(.search(query: "red & blue #1 ?")))
        let open = try XCTUnwrap(AutomationURL.openURL(path: "/Users/tester/My Renders/ä.png"))
        XCTAssertEqual(AutomationURL.parse(open, home: home), .success(.open(path: "/Users/tester/My Renders/ä.png")))
        let collection = try XCTUnwrap(AutomationURL.collectionURL(name: "Picks+Best"))
        XCTAssertEqual(AutomationURL.parse(collection, home: home), .success(.collection(name: "Picks+Best")))
    }

    func testCollectionMatching() {
        let collections: [(id: Int, name: String)] = [(1, "Portfolio"), (2, "portfolio"), (3, "Café Shots")]
        XCTAssertEqual(AutomationCollectionMatcher.match("portfolio", in: collections), 2, "exact match wins")
        XCTAssertEqual(AutomationCollectionMatcher.match("PORTFOLIO", in: collections), 1, "then case-insensitive, first")
        XCTAssertEqual(AutomationCollectionMatcher.match(" cafe shots ", in: collections), 3, "diacritics and whitespace")
        XCTAssertNil(AutomationCollectionMatcher.match("Missing", in: collections))
    }

    func testURLSchemeIsRegisteredInInfoPlist() throws {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let data = try Data(contentsOf: plist)
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let types = try XCTUnwrap(info["CFBundleURLTypes"] as? [[String: Any]])
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        XCTAssertTrue(schemes.contains(AutomationURL.scheme))
    }
}

// MARK: - Spotlight items

final class SpotlightItemBuilderTests: XCTestCase {
    private let row = LibraryIndexSpotlightRow(
        path: "/Lib/Renders/cat.png",
        name: "cat.png",
        folder: "/Lib/Renders",
        prompt: "a fluffy   orange cat\nsleeping on a windowsill",
        negative: "blurry",
        model: "sdxl_base",
        sampler: "Euler a",
        width: 1024,
        height: 768
    )

    func testAttributesFromFixtureEntry() throws {
        let entry = SpotlightEntry(
            row: row, tags: ["Cats", "favourites", "cats"], rating: 4,
            domain: SpotlightItemBuilder.domain(forRoot: "/Lib"), thumbnailData: Data([1, 2, 3])
        )
        let item = SpotlightItemBuilder.item(for: entry)
        XCTAssertEqual(item.uniqueIdentifier, "/Lib/Renders/cat.png")
        XCTAssertEqual(item.domainIdentifier, "root:/Lib")

        let attributes = item.attributeSet
        XCTAssertEqual(attributes.title, "cat.png")
        XCTAssertEqual(attributes.displayName, "cat.png")
        XCTAssertEqual(attributes.contentDescription, "a fluffy orange cat sleeping on a windowsill")
        XCTAssertEqual(attributes.textContent, "a fluffy   orange cat\nsleeping on a windowsill\nblurry")
        XCTAssertEqual(attributes.keywords, ["Cats", "favourites", "sdxl_base", "Euler a"], "tags then model and sampler, deduplicated")
        XCTAssertEqual(attributes.rating?.intValue, 4)
        XCTAssertEqual(attributes.contentURL, URL(fileURLWithPath: "/Lib/Renders/cat.png"))
        XCTAssertEqual(attributes.relatedUniqueIdentifier, "/Lib/Renders/cat.png")
        XCTAssertEqual(attributes.pixelWidth?.intValue, 1024)
        XCTAssertEqual(attributes.pixelHeight?.intValue, 768)
        XCTAssertEqual(attributes.thumbnailData, Data([1, 2, 3]))
        XCTAssertEqual(attributes.contentType, "public.png")
    }

    func testEmptyValuesAreLeftOut() {
        var bare = row
        bare.prompt = ""
        bare.negative = ""
        bare.model = "N/A"
        bare.sampler = "  "
        let attributes = SpotlightItemBuilder.attributes(for: SpotlightEntry(row: bare, tags: [], rating: 0, domain: "root:/Lib"))
        XCTAssertNil(attributes.contentDescription)
        XCTAssertNil(attributes.textContent)
        XCTAssertNil(attributes.keywords)
        XCTAssertNil(attributes.rating, "unrated files carry no rating")
    }

    func testExcerptCutsOnWordBoundary() {
        let long = Array(repeating: "word", count: 200).joined(separator: " ")
        let excerpt = SpotlightItemBuilder.excerpt(long, limit: 50)
        XCTAssertTrue(excerpt.hasSuffix("…"))
        XCTAssertLessThanOrEqual(excerpt.count, 51)
        XCTAssertFalse(excerpt.dropLast().hasSuffix(" "))
        XCTAssertEqual(SpotlightItemBuilder.excerpt("short  prompt"), "short prompt")
    }

    func testDomainIsLongestContainingRoot() {
        let roots = ["/Lib", "/Lib/Renders", "/Other"]
        XCTAssertEqual(SpotlightItemBuilder.domain(forPath: "/Lib/Renders/a.png", roots: roots), "root:/Lib/Renders")
        XCTAssertEqual(SpotlightItemBuilder.domain(forPath: "/Lib/x/a.png", roots: roots), "root:/Lib")
        XCTAssertEqual(SpotlightItemBuilder.domain(forPath: "/Library/a.png", roots: roots), "root:/Library",
                       "a root only matches at a path separator; no root falls back to the parent folder")
        XCTAssertEqual(SpotlightItemBuilder.domain(forPath: "/Loose/a.png", roots: []), "root:/Loose")
    }

    func testCurationDiffFindsChangedFilesOnly() {
        let changed = SpotlightController.changedPaths(
            oldRatings: ["/a": 3, "/b": 2], newRatings: ["/a": 3, "/b": 5, "/c": 1],
            oldTags: ["/d": ["x", "y"], "/e": ["z"]], newTags: ["/d": ["y", "x"], "/f": ["new"]]
        )
        XCTAssertEqual(changed, ["/b", "/c", "/e", "/f"])
    }

    func testThumbnailSkipsDatalessAndNonImages() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PLESpot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("a.png")
        try PNGFixture.basePNG(width: 40, height: 20).write(to: png)
        let text = dir.appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: text)

        XCTAssertNotNil(SpotlightItemBuilder.thumbnailData(forPath: png.path))
        XCTAssertNil(SpotlightItemBuilder.thumbnailData(forPath: text.path))
        CloudFileStatus.withProvider(MockCloudStatus(dataless: [png.path])) {
            XCTAssertNil(SpotlightItemBuilder.thumbnailData(forPath: png.path), "never reads an online-only file")
        }
    }
}

// MARK: - Cloud placeholders

final class CloudFileStatusTests: TempDirectoryTestCase {
    func testAvailabilityDecisions() {
        let notDownloaded = URLUbiquitousItemDownloadingStatus.notDownloaded.rawValue
        let current = URLUbiquitousItemDownloadingStatus.current.rawValue
        XCTAssertEqual(CloudFileStatus.availability(from: CloudResourceSnapshot()), .local)
        XCTAssertEqual(CloudFileStatus.availability(from: CloudResourceSnapshot(isDataless: true)), .cloudOnly)
        XCTAssertEqual(CloudFileStatus.availability(from: CloudResourceSnapshot(isDataless: true, isDownloading: true)), .downloading)
        XCTAssertEqual(CloudFileStatus.availability(from: CloudResourceSnapshot(
            isDataless: false, isUbiquitous: true, downloadingStatus: notDownloaded
        )), .cloudOnly, "legacy iCloud placeholder")
        XCTAssertEqual(CloudFileStatus.availability(from: CloudResourceSnapshot(
            isDataless: false, isUbiquitous: true, downloadingStatus: current
        )), .local)
        XCTAssertEqual(CloudFileStatus.availability(from: CloudResourceSnapshot(
            isDataless: true, isUbiquitous: true, downloadingStatus: current
        )), .cloudOnly, "dataless wins over a lagging status key")
        XCTAssertEqual(CloudFileStatus.availability(from: CloudResourceSnapshot(
            isDataless: false, isUbiquitous: false, downloadingStatus: notDownloaded
        )), .local, "the status only counts for ubiquitous items")
    }

    func testInjectedProviderDrivesChecks() throws {
        let file = try writeFile("a.png", Data([0]))
        XCTAssertTrue(CloudFileStatus.isLocallyAvailable(file))
        CloudFileStatus.withProvider(MockCloudStatus(dataless: [file.path])) {
            XCTAssertFalse(CloudFileStatus.isLocallyAvailable(file))
            XCTAssertTrue(CloudFileStatus.isCloudOnly(path: file.path, isDirectory: false))
            XCTAssertFalse(CloudFileStatus.isCloudOnly(path: file.path, isDirectory: true), "folders are never online-only")
            XCTAssertEqual(CloudFileStatus.availability(for: file), .cloudOnly)
        }
        XCTAssertTrue(CloudFileStatus.isLocallyAvailable(file), "provider restored")
    }

    func testSystemProviderOnLocalFiles() throws {
        let file = try writeFile("local.bin", Data(repeating: 7, count: 4096))
        let snapshot = try XCTUnwrap(SystemCloudFileStatusProvider().snapshot(forPath: file.path, fast: false))
        XCTAssertFalse(snapshot.isDataless)
        XCTAssertEqual(CloudFileStatus.availability(from: snapshot), .local)
        XCTAssertNil(SystemCloudFileStatusProvider().snapshot(forPath: tempDir.appendingPathComponent("missing").path, fast: true))
        XCTAssertTrue(CloudFileStatus.isLocallyAvailable(tempDir.appendingPathComponent("missing")), "missing files keep their own error handling")
    }

    func testReadDirectoryMarksOnlineOnlyFiles() throws {
        let cloud = try writeFile("Lib/cloud.png", Data([0]))
        _ = try writeFile("Lib/local.png", Data([0]))
        try FileManager.default.createDirectory(at: tempDir.appendingPathComponent("Lib/Sub"), withIntermediateDirectories: true)
        // FileManager may list /var/… as /private/var/…; mark both spellings.
        let mock = MockCloudStatus(dataless: [cloud.path, "/private" + cloud.path])
        let entries = try CloudFileStatus.withProvider(mock) {
            try FileSystemService.readDirectory(at: tempDir.appendingPathComponent("Lib"))
        }
        let flags = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0.isCloudOnly) })
        XCTAssertEqual(flags, ["cloud.png": true, "local.png": false, "Sub": false])
    }

    // MARK: Guards: background work skips dataless files

    private func promptPNG(_ name: String, prompt: String) throws -> URL {
        try writeFile(name, PNGFixture.png(with: [PNGFixture.tEXt("parameters", "\(prompt)\nSteps: 20, Sampler: Euler, Seed: 1")]))
    }

    func testMetadataParsersSkipDatalessFiles() async throws {
        let url = try promptPNG("guard-\(UUID().uuidString).png", prompt: "a lighthouse at dusk")
        let mock = MockCloudStatus(dataless: [url.path])

        let uncached = CloudFileStatus.withProvider(mock) { ImageMetadataParser.readMetadataUncached(at: url) }
        XCTAssertEqual(uncached.prompt, "")
        let parsed = await CloudFileStatus.withProvider(mock) { await ImageMetadataParser.shared.parse(at: url) }
        XCTAssertEqual(parsed.prompt, "")
        // Not cached as empty: once downloaded the prompt is read.
        let afterDownload = await ImageMetadataParser.shared.parse(at: url)
        XCTAssertEqual(afterDownload.prompt, "a lighthouse at dusk")

        let plib = try writeFile("x.plib", Data("{}".utf8))
        let entry = await CloudFileStatus.withProvider(MockCloudStatus(dataless: [plib.path])) {
            await PlibParser.shared.parse(at: plib)
        }
        XCTAssertNil(entry)
    }

    func testLibraryIndexSkipsDatalessFilesAndRetriesAfterDownload() async throws {
        let library = tempDir.appendingPathComponent("Library", isDirectory: true)
        let url = try promptPNG("Library/harbor.png", prompt: "foggy harbor with fishing boats")
        let service = LibraryIndexService(databaseURL: tempDir.appendingPathComponent("db/index.sqlite"))

        await CloudFileStatus.withProvider(MockCloudStatus(dataless: [url.path])) {
            await service.indexLibrary(root: library, progress: nil)
        }
        var hits = await service.search("fishing", under: nil).map(\.path)
        XCTAssertEqual(hits, [], "the prompt of an online-only file isn't read")
        hits = await service.search("harbor", under: nil).map(\.path)
        XCTAssertEqual(hits, [url.path], "its name is still searchable")

        // Downloaded (same mtime and size): the next pass reads it.
        await service.indexLibrary(root: library, progress: nil)
        hits = await service.search("fishing", under: nil).map(\.path)
        XCTAssertEqual(hits, [url.path])

        let rows = await service.spotlightRows(forPaths: [url.path])
        XCTAssertEqual(rows.first?.prompt, "foggy harbor with fishing boats")
        XCTAssertEqual(rows.first?.sampler, "Euler")
        let roots = await service.indexedRoots()
        XCTAssertEqual(roots, [library.path])
    }

    func testVisualIndexSkipsDatalessFiles() async throws {
        let url = try writeFile("v/red.png", PNGFixture.basePNG(width: 32, height: 32))
        let service = VisualIndexService(databaseURL: tempDir.appendingPathComponent("db/visual.sqlite"))
        await CloudFileStatus.withProvider(MockCloudStatus(dataless: [url.path])) {
            await service.index(paths: [url.path])
        }
        var signatures = await service.signatures(forPaths: [url.path])
        XCTAssertTrue(signatures.isEmpty)
        await service.index(paths: [url.path])
        signatures = await service.signatures(forPaths: [url.path])
        XCTAssertEqual(signatures.count, 1, "picked up once downloaded")
    }

    func testHoverScrubAndWaveformSkipDatalessFiles() async throws {
        // (ThumbnailService.shared isn't exercised: it prunes the app's real disk cache.)
        let video = try writeFile("t/clip.mov", Data([0, 1, 2]))
        let audio = try writeFile("t/voice.wav", Data([0, 1, 2]))
        let mock = MockCloudStatus(dataless: [video.path, audio.path])
        let strip = await CloudFileStatus.withProvider(mock) { await MediaScrubStripService.strip(for: video) }
        XCTAssertNil(strip)
        let peaks = await CloudFileStatus.withProvider(mock) { await MediaWaveformService.peaks(for: audio, bucketCount: 8) }
        XCTAssertNil(peaks)
    }

    @MainActor
    func testControllerStateAndSettingDefault() throws {
        let suite = "PLE.cloud.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = CloudFileController(defaults: defaults)
        XCTAssertTrue(controller.autoDownloadOnOpen, "on by default (explicit opens only)")
        controller.autoDownloadOnOpen = false
        XCTAssertFalse(CloudFileController(defaults: defaults).autoDownloadOnOpen, "persisted")

        var entry = FileEntry(url: URL(fileURLWithPath: "/x/a.png"), isDirectory: false)
        XCTAssertFalse(controller.isCloudOnly(entry))
        entry.isCloudOnly = true
        XCTAssertTrue(controller.isCloudOnly(entry))
        // With the setting off an explicit open doesn't download.
        let started = CloudFileStatus.withProvider(MockCloudStatus(dataless: ["/x/a.png"])) {
            controller.downloadForExplicitOpen(entry.url)
        }
        XCTAssertFalse(started)
        XCTAssertFalse(controller.isDownloading("/x/a.png"))
    }
}
