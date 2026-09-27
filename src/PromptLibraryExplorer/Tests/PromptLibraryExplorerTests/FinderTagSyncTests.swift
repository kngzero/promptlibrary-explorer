import XCTest
@testable import PromptLibraryExplorer

final class FinderTagMergeTests: XCTestCase {
    func testThreeWayMerge() {
        // Never synced: union.
        XCTAssertEqual(FinderTagMerge.threeWay(base: nil, app: ["Hero"], finder: ["Client"]), ["Hero", "Client"])
        // Added on either side since the last sync.
        XCTAssertEqual(FinderTagMerge.threeWay(base: ["Hero"], app: ["Hero", "New"], finder: ["Hero"]), ["Hero", "New"])
        XCTAssertEqual(FinderTagMerge.threeWay(base: ["Hero"], app: ["Hero"], finder: ["Hero", "Finder"]), ["Hero", "Finder"])
        // Removed on either side: stays removed, isn't re-added from the other side.
        XCTAssertEqual(FinderTagMerge.threeWay(base: ["Hero", "Old"], app: ["Hero"], finder: ["Hero", "Old"]), ["Hero"])
        XCTAssertEqual(FinderTagMerge.threeWay(base: ["Hero", "Old"], app: ["Hero", "Old"], finder: ["Hero"]), ["Hero"])
        // Case-insensitive; the app's spelling wins.
        XCTAssertEqual(FinderTagMerge.threeWay(base: nil, app: ["Hero"], finder: ["hero"]), ["Hero"])
        XCTAssertTrue(FinderTagMerge.sameSet(["A", "b"], ["B", "a"]))
    }

    func testColourLabelNamesAreNotUserTags() {
        XCTAssertEqual(FinderTagIO.userTags(["Red", "Hero", "Gray", "green"]), ["Hero"])
        XCTAssertTrue(FinderTagIO.isLabelName("Purple"))
        XCTAssertFalse(FinderTagIO.isLabelName("Portrait"))
    }
}

/// Real files in a temp folder: Finder tags are extended attributes.
final class FinderTagIOTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FinderTagTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeFile(_ name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: url)
        // A known, old mtime so any change would show.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)], ofItemAtPath: url.path)
        return url
    }

    private func mtime(_ url: URL) throws -> Date {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        return try XCTUnwrap(fresh.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
    }

    func testWritingTagsKeepsMtimeAndLabel() throws {
        let url = try makeFile("a.png")
        try FileSystemService.setLabelNumber(FinderLabel.red.rawValue, at: url)
        let before = try mtime(url)

        try FinderTagIO.writeUserTags(["Hero", "Client"], at: url)
        let names = try XCTUnwrap(FinderTagIO.readTagNames(at: url))
        XCTAssertEqual(FinderTagIO.userTags(names), ["Hero", "Client"])
        XCTAssertEqual(FileSystemService.labelNumber(at: url), FinderLabel.red.rawValue, "the colour label survives")
        XCTAssertEqual(try mtime(url), before, "tag writes must not touch the modification date")

        try FinderTagIO.writeUserTags([], at: url)
        XCTAssertEqual(FinderTagIO.userTags(FinderTagIO.readTagNames(at: url) ?? ["x"]), [])
        XCTAssertEqual(FileSystemService.labelNumber(at: url), FinderLabel.red.rawValue)
        XCTAssertEqual(try mtime(url), before)
    }

    func testReadDirectoryReportsTagNames() throws {
        let url = try makeFile("b.png")
        try FinderTagIO.writeUserTags(["Portfolio"], at: url)
        let entry = try XCTUnwrap(FileSystemService.readDirectory(at: directory).first { $0.name == "b.png" })
        XCTAssertEqual(entry.tagNames, ["Portfolio"])
    }

    func testRemovalPropagatesInBothDirections() throws {
        let url = try makeFile("c.png")
        let state = FinderTagSyncState(url: directory.appendingPathComponent("state.json"))
        let before = try mtime(url)

        // First contact: app has Hero, Finder has Client → both get both.
        try FinderTagIO.writeUserTags(["Client"], at: url)
        let first = try XCTUnwrap(FinderTagSyncer.sync(path: url.path, appNames: ["Hero"], finderNames: nil, state: state))
        XCTAssertEqual(Set(first.names), ["Hero", "Client"])
        XCTAssertTrue(first.appNeedsUpdate)
        XCTAssertTrue(first.wroteFinder)
        XCTAssertEqual(Set(FinderTagIO.userTags(FinderTagIO.readTagNames(at: url) ?? [])), ["Hero", "Client"])

        // Removed in the app → removed from Finder (not re-added to the app).
        let second = try XCTUnwrap(FinderTagSyncer.sync(path: url.path, appNames: ["Hero"], finderNames: nil, state: state))
        XCTAssertEqual(second.names, ["Hero"])
        XCTAssertFalse(second.appNeedsUpdate)
        XCTAssertEqual(FinderTagIO.userTags(FinderTagIO.readTagNames(at: url) ?? []), ["Hero"])

        // Removed in Finder → removed from the app.
        try FinderTagIO.writeUserTags([], at: url)
        let third = try XCTUnwrap(FinderTagSyncer.sync(path: url.path, appNames: ["Hero"], finderNames: nil, state: state))
        XCTAssertEqual(third.names, [])
        XCTAssertTrue(third.appNeedsUpdate)

        // In step: nothing to do.
        XCTAssertNil(FinderTagSyncer.sync(path: url.path, appNames: [], finderNames: nil, state: state))
        XCTAssertEqual(try mtime(url), before)

        // The base state persists.
        state.flush()
        XCTAssertEqual(FinderTagSyncState(url: directory.appendingPathComponent("state.json")).base(for: url.path), [])
    }

    @MainActor
    func testApplyToAppCreatesTagsForUnknownNames() throws {
        let suite = "FinderTagTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = TagService(defaults: defaults)
        let hero = FileTag(name: "Hero", colorHex: "#EF4444")
        let red = FileTag(name: "Red", colorHex: "#EF4444") // an app tag named like a label
        service.saveTags([hero, red])
        service.saveAssignments(["/x.png": [red.id]])

        let outcomes = [FinderTagSyncOutcome(path: "/x.png", names: ["hero", "Client"], appNeedsUpdate: true, wroteFinder: false)]
        XCTAssertEqual(FinderTagSyncer.applyToApp(outcomes, tags: service), 1)
        let tags = service.loadTags()
        let client = try XCTUnwrap(tags.first { $0.name == "Client" })
        XCTAssertEqual(tags.count, 3)
        XCTAssertEqual(Set(service.loadAssignments()["/x.png"] ?? []), [red.id, hero.id, client.id])
    }
}
