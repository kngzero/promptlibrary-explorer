import XCTest
@testable import PromptLibraryExplorer

/// Isolated curation stores on a throwaway defaults suite and temp folder.
@MainActor
final class CurationTestStores {
    let suiteName = "CurationTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let directory: URL
    let stores: CurationStores

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CurationTests-\(UUID().uuidString)", isDirectory: true)
        stores = CurationStores.isolated(defaults: defaults, directory: directory)
    }

    func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
final class CurationBundleTests: XCTestCase {
    private var created: [CurationTestStores] = []

    override func tearDown() {
        MainActor.assumeIsolated {
            created.forEach { $0.tearDown() }
            created = []
        }
        super.tearDown()
    }

    private func makeStores() -> CurationTestStores {
        let stores = CurationTestStores()
        created.append(stores)
        return stores
    }

    private let root = "/Users/a/Dropbox/Library"
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    /// Fills every store with something.
    private func populate(_ stores: CurationStores) -> (hero: FileTag, set: CollectionSet) {
        stores.settings.saveRatings(["\(root)/a.png": 4, "\(root)/shoot/b.png": 2, "/elsewhere/c.png": 5])
        stores.flags.save(FlagBook(flags: ["\(root)/a.png": .pick, "\(root)/shoot/b.png": .reject]))
        let hero = FileTag(name: "Hero", colorHex: "#EF4444")
        let draft = FileTag(name: "Draft", colorHex: "#3B82F6")
        stores.tags.saveTags([hero, draft])
        stores.tags.saveAssignments(["\(root)/a.png": [hero.id, draft.id], "\(root)/shoot/b.png": [draft.id]])
        stores.favorites.saveFavorites(["\(root)/a.png", "\(root)/shoot"])
        stores.settings.saveCustomOrders(["\(root)/shoot": ["\(root)/shoot/b.png", "\(root)/shoot/a.png"]])

        var smart = SmartFolder(name: "Heroes", criteria: SmartFolderCriteria(minRating: 3, tagIDs: [hero.id]))
        smart.createdAt = fixedDate
        stores.smartFolders.saveSmartFolders([smart])

        let set = CollectionSet(name: "Client", createdAt: fixedDate)
        let collection = FileCollection(name: "Selects", paths: ["\(root)/a.png", "/elsewhere/c.png"], createdAt: fixedDate, parentID: set.id)
        stores.collections.replaceAll(collections: [collection], sets: [set])
        stores.snippets.replaceAll([PromptSnippet(title: "Light", text: "golden hour", category: "Lighting", createdAt: fixedDate)])
        stores.recents.replaceRecentFolders([RecentItem(path: root, name: "Library", timestamp: fixedDate)])
        stores.settingsDefaults.set(7.0, forKey: "thumbnailSize")
        stores.settingsDefaults.set("light", forKey: "appearanceMode")
        stores.settingsDefaults.set(false, forKey: "showStatusBar")
        return (hero, set)
    }

    private func assertSameStores(_ lhs: CurationStores, _ rhs: CurationStores, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lhs.settings.loadRatings(), rhs.settings.loadRatings(), file: file, line: line)
        XCTAssertEqual(lhs.flags.load(), rhs.flags.load(), file: file, line: line)
        XCTAssertEqual(lhs.tags.loadTags(), rhs.tags.loadTags(), file: file, line: line)
        XCTAssertEqual(lhs.tags.loadAssignments(), rhs.tags.loadAssignments(), file: file, line: line)
        XCTAssertEqual(lhs.favorites.loadFavorites(), rhs.favorites.loadFavorites(), file: file, line: line)
        XCTAssertEqual(lhs.settings.loadCustomOrders(), rhs.settings.loadCustomOrders(), file: file, line: line)
        XCTAssertEqual(lhs.smartFolders.loadSmartFolders(), rhs.smartFolders.loadSmartFolders(), file: file, line: line)
        XCTAssertEqual(lhs.collections.all(), rhs.collections.all(), file: file, line: line)
        XCTAssertEqual(lhs.collections.allSets(), rhs.collections.allSets(), file: file, line: line)
        XCTAssertEqual(lhs.snippets.all(), rhs.snippets.all(), file: file, line: line)
        XCTAssertEqual(lhs.recents.loadAllRecentFolders(), rhs.recents.loadAllRecentFolders(), file: file, line: line)
    }

    private func bundle(from stores: CurationStores) -> CurationBundle {
        CurationBundleBuilder.make(
            from: stores, roots: [URL(fileURLWithPath: root)], reason: "manual",
            now: fixedDate, machineName: "Test Mac", deviceID: "device-A", appVersion: "1.0"
        )
    }

    func testExportWipeImportRoundTrip() throws {
        let source = makeStores()
        _ = populate(source.stores)
        let exported = bundle(from: source.stores)

        // Header, counts and both path forms.
        XCTAssertEqual(exported.format, CurationBundle.formatIdentifier)
        XCTAssertEqual(exported.schemaVersion, 1)
        XCTAssertEqual(exported.machineName, "Test Mac")
        XCTAssertEqual(exported.counts.ratings, 3)
        XCTAssertEqual(exported.counts.flags, 2)
        XCTAssertEqual(exported.counts.taggedFiles, 2)
        XCTAssertEqual(exported.counts.collections, 1)
        let fileA = try XCTUnwrap(exported.files.first { $0.path == "\(root)/a.png" })
        XCTAssertEqual(fileA.root, 0)
        XCTAssertEqual(fileA.relativePath, "a.png")
        XCTAssertNil(exported.files.first { $0.path == "/elsewhere/c.png" }?.root)

        // JSON round trip is lossless.
        let data = try exported.encoded()
        let decoded = try CurationBundle.decode(data)
        XCTAssertEqual(decoded, exported)

        // Import into empty ("wiped") stores reproduces everything.
        let target = makeStores()
        let resolver = CurationPathResolver(localRoots: [], fileExists: { _ in false })
        CurationImporter.apply(decoded, to: target.stores, mode: .replace, includeSettings: true, resolver: resolver)
        assertSameStores(source.stores, target.stores)
        XCTAssertEqual(target.defaults.double(forKey: "thumbnailSize"), 7)
        XCTAssertEqual(target.defaults.string(forKey: "appearanceMode"), "light")
        XCTAssertEqual(target.defaults.object(forKey: "showStatusBar") as? Bool, false)
    }

    func testReplaceRemovesAndMergeKeepsLocalData() throws {
        let source = makeStores()
        _ = populate(source.stores)
        let exported = bundle(from: source.stores)
        let resolver = CurationPathResolver(localRoots: [], fileExists: { _ in false })

        let local = makeStores()
        local.stores.settings.saveRatings(["/local/only.png": 1, "\(root)/a.png": 1])
        let localTag = FileTag(name: "Mine", colorHex: "#22C55E")
        local.stores.tags.saveTags([localTag])
        local.stores.tags.saveAssignments(["\(root)/a.png": [localTag.id]])

        let plan = CurationImporter.plan(exported, into: local.stores, mode: .merge, includeSettings: false, resolver: resolver)
        let ratings = try XCTUnwrap(plan.first { $0.id == "ratings" })
        XCTAssertEqual(ratings.incoming, 3)
        XCTAssertEqual(ratings.added, 2)
        XCTAssertEqual(ratings.changed, 1)
        XCTAssertEqual(ratings.removed, 0)
        XCTAssertNil(plan.first { $0.id == "settings" })

        CurationImporter.apply(exported, to: local.stores, mode: .merge, includeSettings: false, resolver: resolver)
        let merged = local.stores.settings.loadRatings()
        XCTAssertEqual(merged["/local/only.png"], 1, "merge keeps local-only values")
        XCTAssertEqual(merged["\(root)/a.png"], 4, "the export's value wins")
        XCTAssertEqual(Set(local.stores.tags.loadAssignments()["\(root)/a.png"] ?? []).count, 3, "tag assignments union")

        let replacePlan = CurationImporter.plan(exported, into: local.stores, mode: .replace, includeSettings: false, resolver: resolver)
        XCTAssertEqual(replacePlan.first { $0.id == "ratings" }?.removed, 1)
        CurationImporter.apply(exported, to: local.stores, mode: .replace, includeSettings: false, resolver: resolver)
        XCTAssertNil(local.stores.settings.loadRatings()["/local/only.png"])
        XCTAssertFalse(local.stores.tags.loadTags().contains(localTag))
    }

    func testImportRemapsRelativePathsOntoAnotherMacsRoot() throws {
        let source = makeStores()
        _ = populate(source.stores)
        let exported = bundle(from: source.stores)

        let otherRoot = "/Volumes/Other/Dropbox/Library"
        let resolver = CurationPathResolver(
            localRoots: [URL(fileURLWithPath: otherRoot)],
            fileExists: { $0.hasPrefix(otherRoot) }
        )
        let target = makeStores()
        CurationImporter.apply(exported, to: target.stores, mode: .replace, includeSettings: false, resolver: resolver)
        XCTAssertEqual(target.stores.settings.loadRatings()["\(otherRoot)/shoot/b.png"], 2)
        XCTAssertEqual(target.stores.settings.loadRatings()["/elsewhere/c.png"], 5, "paths outside every root stay absolute")
        XCTAssertEqual(target.stores.collections.all().first?.paths, ["\(otherRoot)/a.png", "/elsewhere/c.png"])
        XCTAssertEqual(target.stores.settings.loadCustomOrders()["\(otherRoot)/shoot"]?.first, "\(otherRoot)/shoot/b.png")
    }

    func testRejectsForeignAndNewerFiles() {
        XCTAssertThrowsError(try CurationBundle.decode(Data("{\"format\":\"other\"}".utf8))) { error in
            XCTAssertEqual(error as? CurationBundleError, .notABundle)
        }
        let newer = "{\"format\":\"\(CurationBundle.formatIdentifier)\",\"schemaVersion\":99}"
        XCTAssertThrowsError(try CurationBundle.decode(Data(newer.utf8))) { error in
            XCTAssertEqual(error as? CurationBundleError, .newerSchema(99))
        }
        // Minimal valid bundle: everything else defaults.
        let minimal = "{\"format\":\"\(CurationBundle.formatIdentifier)\",\"schemaVersion\":1,\"createdAt\":\"2026-09-27T10:00:00Z\"}"
        XCTAssertNoThrow(try CurationBundle.decode(Data(minimal.utf8)))
    }

    // MARK: Backups

    func testBackupRetentionKeepsFourteenDailyEightWeeklyAndRecentEvents() {
        let calendar = Calendar(identifier: .iso8601)
        let now = fixedDate
        var backups: [(name: String, date: Date, reason: CurationBackupReason)] = []
        for day in 0..<120 {
            let date = calendar.date(byAdding: .day, value: -day, to: now)!
            backups.append(("daily-\(day)", date, .daily))
            // A second backup the same day is redundant.
            backups.append(("daily-\(day)-b", date.addingTimeInterval(-60), .daily))
        }
        for index in 0..<25 {
            backups.append(("event-\(index)", now.addingTimeInterval(Double(-index * 3600)), .preImport))
        }
        let keep = CurationBackupService.retained(backups, now: now, calendar: calendar)
        let keptDaily = keep.filter { $0.hasPrefix("daily-") }
        XCTAssertTrue((0..<14).allSatisfy { keep.contains("daily-\($0)") }, "the last 14 days")
        XCTAssertFalse(keep.contains("daily-0-b"))
        XCTAssertEqual(keptDaily.count, 14 + 8, "plus one per week for 8 older weeks")
        XCTAssertFalse(keep.contains("daily-119"))
        XCTAssertEqual(keep.filter { $0.hasPrefix("event-") }.count, 20)
        XCTAssertTrue(keep.contains("event-0"))
        XCTAssertFalse(keep.contains("event-24"))
    }

    func testBackupServiceWritesMirrorsAndLists() throws {
        let stores = makeStores()
        _ = populate(stores.stores)
        let folder = stores.directory.appendingPathComponent("Backups")
        let extra = stores.directory.appendingPathComponent("Dropbox Backups")
        let service = CurationBackupService(directory: folder, extraDirectory: extra, machineName: "Studio Mac")
        let data = try bundle(from: stores.stores).encoded()
        let url = try service.write(data, date: fixedDate, reason: .preImport)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: extra.appendingPathComponent(url.lastPathComponent).path))
        let parsed = try XCTUnwrap(CurationBackupService.parse(fileName: url.lastPathComponent))
        XCTAssertEqual(parsed.reason, .preImport)
        XCTAssertEqual(parsed.machine, "Studio-Mac")

        let listed = service.list()
        XCTAssertEqual(listed.count, 1, "the mirrored copy isn't listed twice")
        XCTAssertEqual(listed.first?.counts.ratings, 3)
        XCTAssertEqual(listed.first?.machineName, "Test Mac")
        XCTAssertEqual(service.latestDate(reason: .preImport), fixedDate)
        XCTAssertNil(service.latestDate(reason: .daily))
    }
}
