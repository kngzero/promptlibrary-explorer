import XCTest
@testable import PromptLibraryExplorer

final class CurationMergeEngineTests: XCTestCase {
    private func record(rating: Int?, at time: Double, device: String = "A") -> LibraryFileRecord {
        LibraryFileRecord(rating: Stamped(value: rating, modifiedAt: time, device: device))
    }

    private func document(_ files: [String: LibraryFileRecord]) -> LibraryCurationDocument {
        var document = LibraryCurationDocument()
        document.files = files
        return document
    }

    func testLastWriterWinsPerRecord() {
        var conflicts: [CurationConflict] = []
        let local = document(["a.png": record(rating: 2, at: 100), "b.png": record(rating: 5, at: 500)])
        let remote = document(["a.png": record(rating: 4, at: 200, device: "B"), "b.png": record(rating: 1, at: 300, device: "B")])
        let merged = CurationMergeEngine.merge(local: local, remote: remote, conflicts: &conflicts)
        XCTAssertEqual(merged.files["a.png"]?.rating?.value, 4, "remote is newer")
        XCTAssertEqual(merged.files["b.png"]?.rating?.value, 5, "local is newer")
        XCTAssertTrue(conflicts.isEmpty)
    }

    func testFieldsMergeIndependently() {
        var conflicts: [CurationConflict] = []
        var local = LibraryFileRecord()
        local.rating = Stamped(value: 3, modifiedAt: 500, device: "A")
        local.flag = Stamped(value: 1, modifiedAt: 100, device: "A")
        var remote = LibraryFileRecord()
        remote.rating = Stamped(value: 1, modifiedAt: 200, device: "B")
        remote.flag = Stamped(value: -1, modifiedAt: 400, device: "B")
        let merged = CurationMergeEngine.merge(local: document(["a.png": local]), remote: document(["a.png": remote]), conflicts: &conflicts)
        XCTAssertEqual(merged.files["a.png"]?.rating?.value, 3)
        XCTAssertEqual(merged.files["a.png"]?.flag?.value, -1)
    }

    func testSimultaneousChangesKeepLocalAndAreLogged() {
        var conflicts: [CurationConflict] = []
        let local = document(["a.png": record(rating: 2, at: 1000.5)])
        let remote = document(["a.png": record(rating: 4, at: 1001.9, device: "B")])
        let merged = CurationMergeEngine.merge(local: local, remote: remote, conflicts: &conflicts)
        XCTAssertEqual(merged.files["a.png"]?.rating?.value, 2)
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts.first?.key, "a.png")
        XCTAssertEqual(conflicts.first?.remoteDevice, "B")

        // The shared file gets the same answer on both Macs, so neither keeps rewriting it.
        var ignored: [CurationConflict] = []
        let fileOnA = CurationMergeEngine.merge(local: local, remote: remote, preferLocal: false, conflicts: &ignored)
        let fileOnB = CurationMergeEngine.merge(local: remote, remote: local, preferLocal: false, conflicts: &ignored)
        XCTAssertEqual(fileOnA.files["a.png"], fileOnB.files["a.png"])
        XCTAssertEqual(fileOnA.files["a.png"]?.rating?.value, 4, "the newer stamp")

        let tieA = document(["a.png": record(rating: 2, at: 0, device: "A")])
        let tieB = document(["a.png": record(rating: 4, at: 0, device: "B")])
        XCTAssertEqual(
            CurationMergeEngine.merge(local: tieA, remote: tieB, preferLocal: false, conflicts: &ignored).files["a.png"],
            CurationMergeEngine.merge(local: tieB, remote: tieA, preferLocal: false, conflicts: &ignored).files["a.png"]
        )
    }

    func testSimultaneousEditsSettleWithoutRewritingTheFile() {
        // Both Macs had different values before sync was turned on (baseline stamps).
        var currentA = CurationPortableState()
        currentA.files["a.png"] = PortableFileValues(rating: 2)
        var currentB = CurationPortableState()
        currentB.files["a.png"] = PortableFileValues(rating: 4)

        let aFirst = CurationMergeEngine.synchronize(ledger: nil, current: currentA, remotes: [], now: Date(), device: "A")
        let file1 = aFirst.fileDocument
        let bFirst = CurationMergeEngine.synchronize(ledger: nil, current: currentB, remotes: [file1], now: Date(), device: "B")
        XCTAssertEqual(bFirst.document.portableState.files["a.png"]?.rating, 4, "B keeps its own value")
        XCTAssertEqual(bFirst.conflicts.count, 1)
        let file2 = bFirst.fileDocument

        let aSecond = CurationMergeEngine.synchronize(ledger: aFirst.document, current: currentA, remotes: [file2], now: Date(), device: "A")
        XCTAssertEqual(aSecond.document.portableState.files["a.png"]?.rating, 2, "A keeps its own value")
        XCTAssertTrue(aSecond.fileDocument.hasSameContent(as: file2), "A has nothing to write back")
        let bSecond = CurationMergeEngine.synchronize(ledger: bFirst.document, current: currentB, remotes: [file2], now: Date(), device: "B")
        XCTAssertTrue(bSecond.fileDocument.hasSameContent(as: file2))
    }

    func testTombstonesStopResurrectionAndArePrunedAfterNinetyDays() {
        var conflicts: [CurationConflict] = []
        let now = Date(timeIntervalSince1970: 100 * 86_400)
        // Removed here (newer) vs an old copy elsewhere.
        let local = document(["a.png": record(rating: nil, at: now.timeIntervalSince1970 - 10)])
        let remote = document(["a.png": record(rating: 3, at: 50, device: "B")])
        let merged = CurationMergeEngine.merge(local: local, remote: remote, conflicts: &conflicts)
        XCTAssertNotNil(merged.files["a.png"]?.rating)
        XCTAssertNil(merged.files["a.png"]?.rating?.value, "the removal wins")
        XCTAssertNil(merged.portableState.files["a.png"])

        // Either way round, the newer removal wins.
        let revived = CurationMergeEngine.merge(local: remote, remote: local, conflicts: &conflicts)
        XCTAssertNil(revived.files["a.png"]?.rating?.value)

        let old = document(["gone.png": record(rating: nil, at: now.timeIntervalSince1970 - 91 * 86_400),
                            "recent.png": record(rating: nil, at: now.timeIntervalSince1970 - 5 * 86_400),
                            "live.png": record(rating: 2, at: 1)])
        let pruned = CurationMergeEngine.pruningTombstones(old, now: now)
        XCTAssertNil(pruned.files["gone.png"])
        XCTAssertNotNil(pruned.files["recent.png"])
        XCTAssertEqual(pruned.files["live.png"]?.rating?.value, 2, "live values never expire")
    }

    func testStampingBaselineThenChangesAndRemovals() {
        var current = CurationPortableState()
        current.files["a.png"] = PortableFileValues(rating: 3)
        current.files["b.png"] = PortableFileValues(flag: 1)

        // First sync: pre-existing values get the baseline stamp.
        let first = CurationMergeEngine.stamp(ledger: nil, current: current, now: Date(timeIntervalSince1970: 5000), device: "A")
        XCTAssertEqual(first.files["a.png"]?.rating?.modifiedAt, CurationMergeEngine.baselineStamp)

        // Then: a change is stamped now, an untouched value keeps its stamp, a removal
        // becomes a tombstone.
        current.files["a.png"] = PortableFileValues(rating: 5)
        current.files["b.png"] = nil
        current.files["c.png"] = PortableFileValues(tags: ["Hero"])
        let second = CurationMergeEngine.stamp(ledger: first, current: current, now: Date(timeIntervalSince1970: 6000), device: "A")
        XCTAssertEqual(second.files["a.png"]?.rating, Stamped(value: 5, modifiedAt: 6000, device: "A"))
        XCTAssertEqual(second.files["b.png"]?.flag, Stamped(value: nil, modifiedAt: 6000, device: "A"))
        XCTAssertEqual(second.files["c.png"]?.tags?.value, ["Hero"])
        XCTAssertNil(second.files["c.png"]?.rating, "values never set need no tombstone")

        // Unchanged state: nothing moves.
        let third = CurationMergeEngine.stamp(ledger: second, current: current, now: Date(timeIntervalSince1970: 7000), device: "A")
        XCTAssertEqual(third, second)
    }

    func testFirstSyncMergesIntoAnExistingFileInsteadOfOverwriting() {
        // Another Mac already wrote the file with a real edit.
        var remote = LibraryCurationDocument()
        remote.files["shared.png"] = record(rating: 5, at: 1000, device: "B")
        remote.files["theirs.png"] = record(rating: 1, at: 1000, device: "B")

        var current = CurationPortableState()
        current.files["shared.png"] = PortableFileValues(rating: 2)
        current.files["mine.png"] = PortableFileValues(rating: 4)
        let result = CurationMergeEngine.synchronize(ledger: nil, current: current, remotes: [remote], now: Date(timeIntervalSince1970: 2000), device: "A")
        let state = result.document.portableState
        XCTAssertEqual(state.files["theirs.png"]?.rating, 1)
        XCTAssertEqual(state.files["mine.png"]?.rating, 4)
        XCTAssertEqual(state.files["shared.png"]?.rating, 5, "a real edit elsewhere beats a pre-sync value")
    }

    func testConflictedCopyNames() {
        XCTAssertTrue(CurationMergeEngine.isConflictedCopy(fileName: "curation (Studio Mac's conflicted copy 2026-09-27).json"))
        XCTAssertTrue(CurationMergeEngine.isConflictedCopy(fileName: "curation (Kareem's MacBook Pro's Conflicted Copy).json"))
        XCTAssertFalse(CurationMergeEngine.isConflictedCopy(fileName: "curation.json"))
        XCTAssertFalse(CurationMergeEngine.isConflictedCopy(fileName: "notes (conflicted copy).txt"))
    }

    func testDocumentJSONRoundTrip() throws {
        var document = LibraryCurationDocument()
        document.files["a b/ü.png"] = LibraryFileRecord(
            rating: Stamped(value: 4, modifiedAt: 1727431200.123, device: "A"),
            tags: Stamped(value: ["Hero", "Draft"], modifiedAt: 1, device: "B"),
            favorite: Stamped(value: nil, modifiedAt: 2, device: "A")
        )
        document.tags["hero"] = Stamped(value: LibraryTagDefinition(name: "Hero", colorHex: "#EF4444"), modifiedAt: 3, device: "A")
        let decoded = try LibraryCurationDocument.decode(try document.encoded())
        XCTAssertTrue(decoded.hasSameContent(as: document))
        XCTAssertThrowsError(try LibraryCurationDocument.decode(Data("{\"format\":\"\(LibraryCurationDocument.formatIdentifier)\",\"schemaVersion\":7}".utf8)))
    }
}

// MARK: - Stores ↔ library file across Macs

@MainActor
final class CurationLibraryAdapterTests: XCTestCase {
    private var created: [CurationTestStores] = []
    private var tempRoots: [URL] = []

    override func tearDown() {
        MainActor.assumeIsolated {
            created.forEach { $0.tearDown() }
            created = []
        }
        tempRoots.forEach { try? FileManager.default.removeItem(at: $0) }
        tempRoots = []
        super.tearDown()
    }

    private func makeStores() -> CurationTestStores {
        let stores = CurationTestStores()
        created.append(stores)
        return stores
    }

    func testRelativeKeysRemapAcrossDifferentAbsoluteRoots() {
        let rootA = "/Users/a/Dropbox/Library"
        let rootB = "/Users/b/Library/CloudStorage/Dropbox/Library"
        let macA = makeStores().stores
        let macB = makeStores().stores

        let heroA = FileTag(name: "Hero", colorHex: "#EF4444")
        macA.tags.saveTags([heroA])
        macA.settings.saveRatings(["\(rootA)/shoot/a.png": 4, "/outside/x.png": 5])
        macA.flags.save(FlagBook(flags: ["\(rootA)/shoot/a.png": .pick]))
        macA.tags.saveAssignments(["\(rootA)/shoot/a.png": [heroA.id]])
        macA.favorites.saveFavorites(["\(rootA)/shoot"])
        macA.settings.saveCustomOrders(["\(rootA)/shoot": ["\(rootA)/shoot/b.png", "\(rootA)/shoot/a.png"]])
        let collection = FileCollection(name: "Selects", paths: ["\(rootA)/shoot/a.png", "/outside/x.png"], createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        macA.collections.replaceAll(collections: [collection], sets: [])
        var smart = SmartFolder(name: "Heroes", criteria: SmartFolderCriteria(tagIDs: [heroA.id]))
        smart.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        macA.smartFolders.saveSmartFolders([smart])

        let snapshotA = CurationLibraryAdapter.snapshot(root: rootA, stores: macA)
        XCTAssertEqual(snapshotA.files["shoot/a.png"], PortableFileValues(rating: 4, flag: 1, tags: ["hero"]))
        XCTAssertEqual(snapshotA.tags["hero"]?.name, "Hero")
        XCTAssertEqual(snapshotA.files["shoot"]?.favorite, true)
        XCTAssertNil(snapshotA.files.keys.first { $0.contains("outside") })
        XCTAssertEqual(snapshotA.collections[collection.id.uuidString]?.items, ["shoot/a.png"])

        // Mac A writes the file; Mac B (a tag of the same name but another id) merges it.
        let fileDocument = CurationMergeEngine.stamp(ledger: nil, current: snapshotA, now: Date(), device: "A")
        let data = try! fileDocument.encoded()
        let received = try! LibraryCurationDocument.decode(data)

        let heroB = FileTag(name: "hero", colorHex: "#22C55E")
        macB.tags.saveTags([heroB])
        let baseB = CurationLibraryAdapter.snapshot(root: rootB, stores: macB)
        let merged = CurationMergeEngine.synchronize(ledger: nil, current: baseB, remotes: [received], now: Date(), device: "B")
        let applied = CurationLibraryAdapter.apply(target: merged.document.portableState, base: baseB, root: rootB, stores: macB)
        XCTAssertGreaterThan(applied, 0)

        XCTAssertEqual(macB.settings.loadRatings(), ["\(rootB)/shoot/a.png": 4])
        XCTAssertEqual(macB.flags.load().flag(for: "\(rootB)/shoot/a.png"), .pick)
        XCTAssertEqual(macB.tags.loadAssignments()["\(rootB)/shoot/a.png"], [heroB.id], "tags match by name, case-insensitively")
        XCTAssertEqual(macB.favorites.loadFavorites(), ["\(rootB)/shoot"])
        XCTAssertEqual(macB.settings.loadCustomOrders()["\(rootB)/shoot"], ["\(rootB)/shoot/b.png", "\(rootB)/shoot/a.png"])
        XCTAssertEqual(macB.collections.all().first?.paths, ["\(rootB)/shoot/a.png"])
        XCTAssertEqual(macB.smartFolders.loadSmartFolders().first?.criteria.tagIDs, [heroB.id])

        // Applying again is a no-op: B is now in step with the file.
        let again = CurationLibraryAdapter.snapshot(root: rootB, stores: macB)
        XCTAssertEqual(again.files, merged.document.portableState.files)
    }

    func testRenameInsideRootMovesTheRelativeKeyOnTheOtherMac() {
        let rootA = "/A/Library", rootB = "/B/Library"
        let macA = makeStores().stores, macB = makeStores().stores
        macA.settings.saveRatings(["\(rootA)/old.png": 3])
        macB.settings.saveRatings(["\(rootB)/old.png": 3])

        // Both in step at t=baseline.
        let ledgerA = CurationMergeEngine.stamp(ledger: nil, current: CurationLibraryAdapter.snapshot(root: rootA, stores: macA), now: Date(), device: "A")
        let ledgerB = CurationMergeEngine.stamp(ledger: nil, current: CurationLibraryAdapter.snapshot(root: rootB, stores: macB), now: Date(), device: "B")

        // A renames the file (the view model migrates the store key).
        macA.settings.saveRatings(["\(rootA)/new.png": 3])
        let fileFromA = CurationMergeEngine.stamp(ledger: ledgerA, current: CurationLibraryAdapter.snapshot(root: rootA, stores: macA), now: Date(), device: "A")
        XCTAssertNil(fileFromA.files["old.png"]?.rating?.value)
        XCTAssertEqual(fileFromA.files["new.png"]?.rating?.value, 3)

        let baseB = CurationLibraryAdapter.snapshot(root: rootB, stores: macB)
        let merged = CurationMergeEngine.synchronize(ledger: ledgerB, current: baseB, remotes: [fileFromA], now: Date(), device: "B")
        CurationLibraryAdapter.apply(target: merged.document.portableState, base: baseB, root: rootB, stores: macB)
        XCTAssertEqual(macB.settings.loadRatings(), ["\(rootB)/new.png": 3])
    }

    func testApplySkipsValuesChangedMeanwhile() {
        let root = "/L"
        let mac = makeStores().stores
        mac.settings.saveRatings(["\(root)/a.png": 1])
        let base = CurationLibraryAdapter.snapshot(root: root, stores: mac)
        var target = base
        target.files["a.png"] = PortableFileValues(rating: 5)
        // The user rates the file while the merge runs.
        mac.settings.saveRatings(["\(root)/a.png": 2])
        CurationLibraryAdapter.apply(target: target, base: base, root: root, stores: mac)
        XCTAssertEqual(mac.settings.loadRatings()["\(root)/a.png"], 2)
    }

    func testConflictedCopyIsMergedThenRemovedOnDisk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CurationSync-\(UUID().uuidString)", isDirectory: true)
        tempRoots.append(root)
        let dataDirectory = LibrarySyncIO.dataDirectory(for: root)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)

        var main = LibraryCurationDocument()
        main.files["a.png"] = LibraryFileRecord(rating: Stamped(value: 2, modifiedAt: 100, device: "B"))
        try main.encoded().write(to: LibrarySyncIO.fileURL(for: root))
        var conflicted = LibraryCurationDocument()
        conflicted.files["b.png"] = LibraryFileRecord(rating: Stamped(value: 4, modifiedAt: 200, device: "C"))
        let conflictedURL = dataDirectory.appendingPathComponent("curation (Other Mac's conflicted copy 2026-09-27).json")
        try conflicted.encoded().write(to: conflictedURL)
        let unrelated = dataDirectory.appendingPathComponent("notes.json")
        try Data("{}".utf8).write(to: unrelated)

        var current = CurationPortableState()
        current.files["c.png"] = PortableFileValues(favorite: true)
        let ledgerURL = root.appendingPathComponent("ledger.json")
        let computation = LibrarySyncComputation.run(root: root, ledgerURL: ledgerURL, current: current, now: Date(), device: "A")
        XCTAssertEqual(computation.conflictedURLs, [conflictedURL])
        let outcome = try computation.persist(root: root, ledgerURL: ledgerURL, now: Date(), device: "A", deviceName: "Test", appVersion: "1")
        XCTAssertTrue(outcome.wroteFile)

        XCTAssertFalse(FileManager.default.fileExists(atPath: conflictedURL.path), "the merged conflicted copy is removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path), "nothing else is touched")
        let written = try LibraryCurationDocument.decode(Data(contentsOf: LibrarySyncIO.fileURL(for: root))).portableState
        XCTAssertEqual(written.files["a.png"]?.rating, 2)
        XCTAssertEqual(written.files["b.png"]?.rating, 4)
        XCTAssertEqual(written.files["c.png"]?.favorite, true)

        // A second pass with nothing new doesn't rewrite the file.
        let second = LibrarySyncComputation.run(root: root, ledgerURL: ledgerURL, current: written, now: Date(), device: "A")
        XCTAssertFalse(try second.persist(root: root, ledgerURL: ledgerURL, now: Date(), device: "A", deviceName: "Test", appVersion: "1").wroteFile)
    }

    func testUnreadableLibraryFileIsNeverOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CurationSync-\(UUID().uuidString)", isDirectory: true)
        tempRoots.append(root)
        try FileManager.default.createDirectory(at: LibrarySyncIO.dataDirectory(for: root), withIntermediateDirectories: true)
        let garbage = Data("not json".utf8)
        try garbage.write(to: LibrarySyncIO.fileURL(for: root))

        var current = CurationPortableState()
        current.files["a.png"] = PortableFileValues(rating: 1)
        let ledgerURL = root.appendingPathComponent("ledger.json")
        let computation = LibrarySyncComputation.run(root: root, ledgerURL: ledgerURL, current: current, now: Date(), device: "A")
        XCTAssertNotNil(computation.blockingError)
        XCTAssertFalse(try computation.persist(root: root, ledgerURL: ledgerURL, now: Date(), device: "A", deviceName: "T", appVersion: "1").wroteFile)
        XCTAssertEqual(try Data(contentsOf: LibrarySyncIO.fileURL(for: root)), garbage)
    }

    func testLibraryRootIsTheNearestAncestorWithADataFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CurationSync-\(UUID().uuidString)", isDirectory: true)
        tempRoots.append(root)
        let sub = root.appendingPathComponent("shoot/day1", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        XCTAssertEqual(LibrarySyncIO.libraryRoot(for: sub).path, sub.standardizedFileURL.path)
        try FileManager.default.createDirectory(at: LibrarySyncIO.dataDirectory(for: root), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: LibrarySyncIO.fileURL(for: root))
        XCTAssertEqual(LibrarySyncIO.libraryRoot(for: sub).path, root.standardizedFileURL.path)
    }
}
