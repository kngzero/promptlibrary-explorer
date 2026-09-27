import XCTest
@testable import PromptLibraryExplorer

// MARK: - Flag storage & path migration

final class FlagBookTests: XCTestCase {
    func testSetAndUnflagRemovesEntry() {
        var book = FlagBook()
        book.set(.pick, for: "/lib/a.png")
        book.set(.reject, for: "/lib/b.png")
        XCTAssertEqual(book.flag(for: "/lib/a.png"), .pick)
        XCTAssertEqual(book.flag(for: "/lib/missing.png"), .unflagged)
        book.set(.unflagged, for: "/lib/a.png")
        XCTAssertEqual(book.flags, ["/lib/b.png": .reject])
    }

    func testMigrateFileAndFolderDescendants() {
        var book = FlagBook(flags: [
            "/lib/a.png": .pick,
            "/lib/shoot/x.png": .reject,
            "/lib/shoot/deep/y.png": .pick,
            "/lib/shooting/z.png": .pick, // shares a prefix, not a descendant
        ])

        XCTAssertTrue(book.migrate(from: "/lib/a.png", to: "/lib/b.png"))
        XCTAssertEqual(book.flag(for: "/lib/b.png"), .pick)
        XCTAssertEqual(book.flag(for: "/lib/a.png"), .unflagged)

        XCTAssertTrue(book.migrate(from: "/lib/shoot", to: "/other/set"))
        XCTAssertEqual(book.flag(for: "/other/set/x.png"), .reject)
        XCTAssertEqual(book.flag(for: "/other/set/deep/y.png"), .pick)
        XCTAssertEqual(book.flag(for: "/lib/shooting/z.png"), .pick)
        XCTAssertEqual(book.flags.count, 4)

        XCTAssertFalse(book.migrate(from: "/nothing", to: "/else"))
    }

    func testRemoveAndRestoreForTrashUndo() {
        var book = FlagBook(flags: ["/lib/f/a.png": .pick, "/lib/f/b.png": .reject, "/lib/c.png": .pick])
        let removed = book.removeAll(under: "/lib/f")
        XCTAssertEqual(removed, ["/lib/f/a.png": .pick, "/lib/f/b.png": .reject])
        XCTAssertEqual(book.flags, ["/lib/c.png": .pick])

        // Undo puts the folder back, possibly under a new name.
        book.restore(removed, from: "/lib/f", to: "/lib/f 2")
        XCTAssertEqual(book.flag(for: "/lib/f 2/a.png"), .pick)
        XCTAssertEqual(book.flag(for: "/lib/f 2/b.png"), .reject)
    }

    func testFlagStoreRoundTripUsesInjectedDefaults() throws {
        let suite = "CullingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = FlagStore(defaults: defaults)
        XCTAssertEqual(store.load(), FlagBook())
        let book = FlagBook(flags: ["/a.png": .pick, "/b.png": .reject, "/c.png": .unflagged])
        store.save(book)
        XCTAssertEqual(store.load().flags, ["/a.png": .pick, "/b.png": .reject])

        // Unknown raw values are dropped rather than failing the whole load.
        defaults.set(try JSONEncoder().encode(["/a.png": 1, "/z.png": 42]), forKey: FlagStore.storageKey)
        XCTAssertEqual(store.load().flags, ["/a.png": .pick])
    }
}

// MARK: - Keys, labels, filters

final class CullActionTests: XCTestCase {
    func testKeyMapping() {
        XCTAssertEqual(CullAction(keyCharacters: "p"), .flag(.pick))
        XCTAssertEqual(CullAction(keyCharacters: "P"), .flag(.pick))
        XCTAssertEqual(CullAction(keyCharacters: "x"), .flag(.reject))
        XCTAssertEqual(CullAction(keyCharacters: "u"), .flag(.unflagged))
        XCTAssertEqual(CullAction(keyCharacters: "0"), .rating(0))
        XCTAssertEqual(CullAction(keyCharacters: "5"), .rating(5))
        XCTAssertEqual(CullAction(keyCharacters: "6"), .label(.red))
        XCTAssertEqual(CullAction(keyCharacters: "7"), .label(.yellow))
        XCTAssertEqual(CullAction(keyCharacters: "8"), .label(.green))
        XCTAssertEqual(CullAction(keyCharacters: "9"), .label(.blue))
        XCTAssertNil(CullAction(keyCharacters: "a"))
        XCTAssertNil(CullAction(keyCharacters: " "))
        XCTAssertNil(CullAction(keyCharacters: "12"))
        XCTAssertNil(CullAction(keyCharacters: "٣")) // non-ASCII digit
    }

    func testFinderLabelNumbersMatchFinder() {
        // Finder's labelNumber order (NSWorkspace.fileLabels indices).
        XCTAssertEqual(FinderLabel.none.rawValue, 0)
        XCTAssertEqual(FinderLabel.gray.rawValue, 1)
        XCTAssertEqual(FinderLabel.green.rawValue, 2)
        XCTAssertEqual(FinderLabel.purple.rawValue, 3)
        XCTAssertEqual(FinderLabel.blue.rawValue, 4)
        XCTAssertEqual(FinderLabel.yellow.rawValue, 5)
        XCTAssertEqual(FinderLabel.red.rawValue, 6)
        XCTAssertEqual(FinderLabel.orange.rawValue, 7)
        XCTAssertEqual(FinderLabel(labelNumber: nil), .none)
        XCTAssertEqual(FinderLabel(labelNumber: 99), .none)
        XCTAssertEqual(FinderLabel.menuOrder.count, 7)
        XCTAssertNil(FinderLabel.none.sortRank)
        XCTAssertEqual(FinderLabel.red.sortRank, 0)
    }

    func testFilterConfigFlagAndLabelFilters() {
        var config = FilterConfig()
        XCTAssertTrue(config.passesCullFilters(flag: .reject, labelNumber: nil))

        config.flagFilter = .hideRejects
        XCTAssertEqual(config.activeCount, 1)
        XCTAssertTrue(config.passesCullFilters(flag: .pick, labelNumber: nil))
        XCTAssertTrue(config.passesCullFilters(flag: .unflagged, labelNumber: nil))
        XCTAssertFalse(config.passesCullFilters(flag: .reject, labelNumber: nil))

        config.flagFilter = .picks
        XCTAssertFalse(config.passesCullFilters(flag: .unflagged, labelNumber: nil))

        config.flagFilter = .all
        config.labelFilter = [FinderLabel.red.rawValue, FinderLabel.none.rawValue]
        XCTAssertEqual(config.activeCount, 1)
        XCTAssertTrue(config.passesCullFilters(flag: .unflagged, labelNumber: 6))
        XCTAssertTrue(config.passesCullFilters(flag: .unflagged, labelNumber: nil), "no label counts as None")
        XCTAssertFalse(config.passesCullFilters(flag: .unflagged, labelNumber: 4))

        XCTAssertNotEqual(config, FilterConfig(), "clearAllFilters resets to FilterConfig()")
    }
}

// MARK: - Smart folders

final class CullSmartFolderTests: XCTestCase {
    func testOldJSONDecodesWithoutFlagOrLabelRules() throws {
        let json = #"{"searchQuery":"","fileTypes":["png"],"minRating":2,"dateRange":"any","tagIDs":[],"favoritesOnly":false,"matchMode":"all"}"#
        let criteria = try JSONDecoder().decode(SmartFolderCriteria.self, from: Data(json.utf8))
        XCTAssertEqual(criteria.flag, .all)
        XCTAssertTrue(criteria.labels.isEmpty)
        XCTAssertEqual(criteria.minRating, 2)
    }

    func testFlagAndLabelRulesRoundTripAndTolerateBadValues() throws {
        var criteria = SmartFolderCriteria()
        criteria.flag = .picks
        criteria.labels = [6, 0]
        XCTAssertTrue(criteria.isActive)
        let decoded = try JSONDecoder().decode(SmartFolderCriteria.self, from: JSONEncoder().encode(criteria))
        XCTAssertEqual(decoded.flag, .picks)
        XCTAssertEqual(decoded.labels, [6, 0])

        let bad = #"{"flag":"sometimes","labels":[3,42]}"#
        let tolerant = try JSONDecoder().decode(SmartFolderCriteria.self, from: Data(bad.utf8))
        XCTAssertEqual(tolerant.flag, .all)
        XCTAssertEqual(tolerant.labels, [3])
    }

    func testFilterByFlagAndLabel() {
        let a = FileEntry(url: URL(fileURLWithPath: "/lib/a.png"), isDirectory: false, labelNumber: 6)
        let b = FileEntry(url: URL(fileURLWithPath: "/lib/b.png"), isDirectory: false, labelNumber: 0)
        let c = FileEntry(url: URL(fileURLWithPath: "/lib/c.png"), isDirectory: false)
        let context = SmartFolderFilterContext(flags: ["/lib/a.png": .pick, "/lib/c.png": .reject])

        var criteria = SmartFolderCriteria()
        criteria.flag = .hideRejects
        XCTAssertEqual(SmartFolderService.filter([a, b, c], criteria: criteria, context: context).map(\.name), ["a.png", "b.png"])

        criteria.flag = .rejects
        XCTAssertEqual(SmartFolderService.filter([a, b, c], criteria: criteria, context: context).map(\.name), ["c.png"])

        criteria = SmartFolderCriteria()
        criteria.labels = [FinderLabel.red.rawValue]
        XCTAssertEqual(SmartFolderService.filter([a, b, c], criteria: criteria, context: context).map(\.name), ["a.png"])
    }
}

// MARK: - Finder labels on disk

final class FinderLabelFileTests: XCTestCase {
    func testLabelWrittenToFileShowsUpInDirectoryListing() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CullingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("shot.png")
        try Data([0x89, 0x50]).write(to: file)
        XCTAssertEqual(FileSystemService.labelNumber(at: file), 0)

        try FileSystemService.setLabelNumber(FinderLabel.red.rawValue, at: file)
        XCTAssertEqual(FileSystemService.labelNumber(at: file), 6)
        let tags = try file.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
        XCTAssertEqual(tags.count, 1, "Finder sees exactly one colour tag")

        let listed = try FileSystemService.readDirectory(at: dir)
        XCTAssertEqual(listed.first(where: { $0.name == "shot.png" })?.labelNumber, 6)
        XCTAssertEqual(FileEntry.load(from: file)?.labelNumber, 6)

        try FileSystemService.setLabelNumber(0, at: file)
        XCTAssertEqual(FileSystemService.labelNumber(at: file), 0)
    }
}
