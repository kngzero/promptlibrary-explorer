import XCTest
@testable import PromptLibraryExplorer

/// Manual stacks are curation data: backups / exports (the curation bundle), imports
/// (merge and replace) and the library data file that syncs between Macs carry them.
@MainActor
final class StackCurationTests: XCTestCase {
    private var created: [CurationTestStores] = []
    private let root = "/Users/a/Dropbox/Library"
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
    private let stackA = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let stackB = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

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

    private func sampleBook() -> StackBook {
        StackBook(
            stacks: [
                ManualStack(id: stackA, paths: ["\(root)/shoot/a.png", "\(root)/shoot/a_up.png"], coverPath: "\(root)/shoot/a.png", createdAt: fixedDate),
                ManualStack(id: stackB, paths: ["\(root)/b.png", "\(root)/b2.png", "/elsewhere/b3.png"], createdAt: fixedDate),
            ],
            excludedPaths: ["\(root)/c.png"]
        )
    }

    private func bundle(from stores: CurationStores) -> CurationBundle {
        CurationBundleBuilder.make(from: stores, roots: [URL(fileURLWithPath: root)], reason: "manual", now: fixedDate, machineName: "Test Mac", deviceID: "device-A", appVersion: "1.0")
    }

    func testStoreRoundTripAndNotification() {
        let stores = makeStores().stores
        let posted = expectation(forNotification: CurationStoreEvents.didChange, object: nil) { note in
            (note.userInfo?[CurationStoreEvents.kindKey] as? String) == CurationStoreKind.stacks.rawValue
        }
        stores.stacks.save(sampleBook())
        wait(for: [posted], timeout: 1)
        XCTAssertEqual(stores.stacks.load(), sampleBook())
    }

    func testBundleRoundTripCarriesStacks() throws {
        let source = makeStores()
        source.stores.stacks.save(sampleBook())
        let exported = bundle(from: source.stores)
        XCTAssertEqual(exported.counts.stacks, 2)
        XCTAssertEqual(exported.stacks.first?.items.first?.relativePath, "shoot/a.png")
        XCTAssertEqual(exported.stacks.first?.cover?.relativePath, "shoot/a.png")
        XCTAssertTrue(exported.counts.summary.contains("2 stacks"))

        let decoded = try CurationBundle.decode(try exported.encoded())
        XCTAssertEqual(decoded, exported)

        let target = makeStores()
        let resolver = CurationPathResolver(localRoots: [], fileExists: { _ in false })
        let plan = CurationImporter.plan(decoded, into: target.stores, mode: .merge, includeSettings: false, resolver: resolver)
        XCTAssertEqual(plan.first { $0.id == "stacks" }?.added, 2)
        CurationImporter.apply(decoded, to: target.stores, mode: .merge, includeSettings: false, resolver: resolver)
        XCTAssertEqual(target.stores.stacks.load(), sampleBook())
        XCTAssertEqual(CurationImporter.plan(decoded, into: target.stores, mode: .merge, includeSettings: false, resolver: resolver)
            .first { $0.id == "stacks" }?.hasChanges, false, "importing again changes nothing")
    }

    func testImportRemapsStacksOntoAnotherMacsRoot() {
        let source = makeStores()
        source.stores.stacks.save(sampleBook())
        let exported = bundle(from: source.stores)
        let otherRoot = "/Volumes/Other/Dropbox/Library"
        let resolver = CurationPathResolver(localRoots: [URL(fileURLWithPath: otherRoot)], fileExists: { $0.hasPrefix(otherRoot) })
        let target = makeStores()
        CurationImporter.apply(exported, to: target.stores, mode: .replace, includeSettings: false, resolver: resolver)
        let book = target.stores.stacks.load()
        XCTAssertEqual(book.stacks.first?.paths, ["\(otherRoot)/shoot/a.png", "\(otherRoot)/shoot/a_up.png"])
        XCTAssertEqual(book.stacks.first?.coverPath, "\(otherRoot)/shoot/a.png")
        XCTAssertEqual(book.excludedPaths, ["\(otherRoot)/c.png"])
    }

    func testMergeKeepsLocalStacksAndReplaceRemovesThem() {
        let source = makeStores()
        source.stores.stacks.save(sampleBook())
        let exported = bundle(from: source.stores)
        let resolver = CurationPathResolver(localRoots: [], fileExists: { _ in false })

        let local = makeStores()
        let mine = ManualStack(paths: ["/local/x.png", "/local/y.png"], createdAt: fixedDate)
        local.stores.stacks.save(StackBook(stacks: [mine], excludedPaths: ["/local/z.png"]))
        CurationImporter.apply(exported, to: local.stores, mode: .merge, includeSettings: false, resolver: resolver)
        var book = local.stores.stacks.load()
        XCTAssertEqual(book.stacks.count, 3)
        XCTAssertTrue(book.stacks.contains(mine))
        XCTAssertEqual(book.excludedPaths, ["/local/z.png", "\(root)/c.png"])

        CurationImporter.apply(exported, to: local.stores, mode: .replace, includeSettings: false, resolver: resolver)
        book = local.stores.stacks.load()
        XCTAssertFalse(book.stacks.contains(mine))
        XCTAssertEqual(book, sampleBook())
    }

    func testOlderBundlesWithoutStacksStillImport() throws {
        let json = """
        {"format": "com.artofficial.promptlibrary.curation-bundle", "schemaVersion": 1, "appVersion": "1.0",
         "createdAt": "2026-09-27T10:15:00.000Z", "machineName": "Old", "deviceID": "x", "reason": "manual",
         "counts": {"ratings": 0}}
        """
        let bundle = try CurationBundle.decode(Data(json.utf8))
        XCTAssertTrue(bundle.stacks.isEmpty)
        XCTAssertTrue(bundle.stackExclusions.isEmpty)
        XCTAssertEqual(bundle.counts.stacks, 0)
    }

    // MARK: Library data file (sync between Macs)

    func testLibrarySyncCarriesStacksBetweenMacs() {
        let macA = makeStores()
        macA.stores.stacks.save(sampleBook())
        let snapshotA = CurationLibraryAdapter.snapshot(root: root, stores: macA.stores)
        XCTAssertEqual(snapshotA.stacks.count, 2)
        XCTAssertEqual(snapshotA.stackExclusions, ["c.png": true])
        let bValue = snapshotA.stacks.values.first { $0.items.contains("b.png") }
        XCTAssertEqual(bValue?.items, ["b.png", "b2.png"], "members in other libraries stay out of this file")

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let a = CurationMergeEngine.synchronize(ledger: nil, current: snapshotA, remotes: [], now: now, device: "A")
        let decoded = try? LibraryCurationDocument.decode(try a.fileDocument.encoded())
        XCTAssertEqual(decoded?.stacks, a.fileDocument.stacks)

        // Mac B at another path picks them up.
        let otherRoot = "/Volumes/B/Library"
        let macB = makeStores()
        let baseB = CurationLibraryAdapter.snapshot(root: otherRoot, stores: macB.stores)
        let b = CurationMergeEngine.synchronize(ledger: nil, current: baseB, remotes: [a.fileDocument], now: now, device: "B")
        CurationLibraryAdapter.apply(target: b.document.portableState, base: baseB, root: otherRoot, stores: macB.stores)
        let bookB = macB.stores.stacks.load()
        XCTAssertEqual(bookB.stacks.count, 2)
        XCTAssertEqual(bookB.stacks.first { $0.paths.contains("\(otherRoot)/shoot/a.png") }?.coverPath, "\(otherRoot)/shoot/a.png")
        XCTAssertEqual(bookB.excludedPaths, ["\(otherRoot)/c.png"])

        // B unstacks one; A's next sync removes it (a tombstone, not a resurrection).
        let unstackID = bookB.stacks.first { $0.paths.contains("\(otherRoot)/b.png") }!.id
        var edited = bookB
        edited.dissolve(id: unstackID)
        macB.stores.stacks.save(edited)
        let later = now.addingTimeInterval(60)
        let b2 = CurationMergeEngine.synchronize(
            ledger: b.document, current: CurationLibraryAdapter.snapshot(root: otherRoot, stores: macB.stores),
            remotes: [b.fileDocument], now: later, device: "B"
        )
        XCTAssertNotNil(b2.fileDocument.stacks[unstackID.uuidString], "kept as a tombstone")
        XCTAssertNil(b2.fileDocument.stacks[unstackID.uuidString]?.value)

        let baseA2 = CurationLibraryAdapter.snapshot(root: root, stores: macA.stores)
        let a2 = CurationMergeEngine.synchronize(ledger: a.document, current: baseA2, remotes: [b2.fileDocument], now: later.addingTimeInterval(5), device: "A")
        CurationLibraryAdapter.apply(target: a2.document.portableState, base: baseA2, root: root, stores: macA.stores)
        let bookA = macA.stores.stacks.load()
        XCTAssertNil(bookA.stack(containing: "\(root)/b.png"), "the unstack arrived")
        XCTAssertTrue(bookA.excludedPaths.contains("\(root)/b.png"), "and so did the exclusion")
        XCTAssertNotNil(bookA.stack(containing: "\(root)/shoot/a.png"))
    }

    func testMergeEngineMergesStackRecords() {
        var local = LibraryCurationDocument()
        local.stacks["S"] = Stamped(value: LibraryStackValue(createdAt: "2026-01-01T00:00:00Z", items: ["a", "b"], cover: nil), modifiedAt: 100, device: "A")
        var remote = LibraryCurationDocument()
        remote.stacks["S"] = Stamped(value: LibraryStackValue(createdAt: "2026-01-01T00:00:00Z", items: ["a", "b"], cover: "b"), modifiedAt: 200, device: "B")
        remote.stackExclusions["c"] = Stamped(value: true, modifiedAt: 200, device: "B")
        var conflicts: [CurationConflict] = []
        let merged = CurationMergeEngine.merge(local: local, remote: remote, conflicts: &conflicts)
        XCTAssertEqual(merged.stacks["S"]?.value?.cover, "b", "newer stamp wins")
        XCTAssertEqual(merged.stackExclusions["c"]?.value, true)
        XCTAssertFalse(merged.hasSameContent(as: local))
        XCTAssertFalse(merged.isEmpty)
    }

    func testOlderLibraryFilesWithoutStacksStillDecode() throws {
        let json = #"{"format": "com.artofficial.promptlibrary.library-curation", "schemaVersion": 1, "files": {}}"#
        let document = try LibraryCurationDocument.decode(Data(json.utf8))
        XCTAssertTrue(document.stacks.isEmpty)
        XCTAssertTrue(document.isEmpty)
    }
}
