import CoreServices
import XCTest
@testable import PromptLibraryExplorer

// MARK: - Coalescing & ignore rules (pure)

final class FolderWatchCoalescingTests: XCTestCase {
    private let root = "/Library Root"

    func testIgnoreRulesSkipAppDataTempAndHiddenFiles() {
        let ignored = [
            "/Library Root/.promptlibrary/curation.json",
            "/Library Root/sub/.plx-rename-1234",
            "/Library Root/._image.png",
            "/Library Root/.dropbox.cache/x/y.png",
            "/Library Root/.DS_Store",
            "/Library Root/video.mp4.part",
            "/Library Root/download.crdownload",
            "/Library Root/image.xmp",
            "/Library Root/~$doc.png",
        ]
        for path in ignored {
            XCTAssertTrue(FolderWatchIgnoreRules.isIgnored(path, under: root), path)
        }
        XCTAssertFalse(FolderWatchIgnoreRules.isIgnored("/Library Root/sub/image.png", under: root))
        XCTAssertFalse(FolderWatchIgnoreRules.isIgnored("/Library Root/clip.mp4", under: root))
        // Only components below the root count: a root inside a hidden folder still works.
        XCTAssertFalse(FolderWatchIgnoreRules.isIgnored("/Users/me/.hidden/lib/a.png", under: "/Users/me/.hidden/lib"))
        XCTAssertTrue(FolderWatchIgnoreRules.isIgnored("/Users/me/.hidden/lib/a.png"))
    }

    func testCoalescerMergesDuplicatesAndDropsMetadataOnlyEvents() {
        var coalescer = FolderEventCoalescer(roots: [root])
        coalescer.add([
            FolderWatchEvent(path: "/Library Root/a.png", flags: [.created, .isFile]),
            FolderWatchEvent(path: "/Library Root/a.png", flags: [.modified, .isFile]),
            FolderWatchEvent(path: "/Library Root/b.png", flags: [.metadataOnly, .isFile]),  // Finder tag change
            FolderWatchEvent(path: "/Library Root/.promptlibrary/curation.json", flags: [.modified, .isFile]),
            FolderWatchEvent(path: "/Library Root/c.png/", flags: [.removed, .isFile]),
        ])
        coalescer.add([FolderWatchEvent(path: "/Library Root/a.png", flags: [.modified, .isFile])])
        let batch = coalescer.drain()
        XCTAssertEqual(batch.paths, ["/Library Root/a.png", "/Library Root/c.png"])
        XCTAssertFalse(batch.rootChanged)
        XCTAssertTrue(batch.rescanDirectories.isEmpty)
        XCTAssertTrue(coalescer.drain().isEmpty, "drain starts a new batch")
    }

    func testCoalescerReportsRescanAndRootChanges() {
        var coalescer = FolderEventCoalescer(roots: [root])
        coalescer.add([
            FolderWatchEvent(path: "/Library Root/sub", flags: [.mustScanSubdirectories]),
            FolderWatchEvent(path: "/Library Root/sub", flags: [.mustScanSubdirectories]),
            FolderWatchEvent(path: "/Library Root", flags: [.rootChanged]),
        ])
        let batch = coalescer.drain()
        XCTAssertEqual(batch.rescanDirectories, ["/Library Root/sub"])
        XCTAssertTrue(batch.rootChanged)
        XCTAssertTrue(batch.paths.isEmpty)
    }

    func testFSEventsFlagMapping() {
        let raw = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile
            | kFSEventStreamEventFlagItemXattrMod)
        let flags = FolderWatcher.mapFlags(raw)
        XCTAssertTrue(flags.contains(.created))
        XCTAssertTrue(flags.contains(.isFile))
        XCTAssertTrue(flags.contains(.metadataOnly))
        XCTAssertTrue(flags.isContentChange)
        XCTAssertFalse(FolderWatcher.mapFlags(FSEventStreamEventFlags(kFSEventStreamEventFlagItemXattrMod)).isContentChange)
    }

    func testRecentWriteSuppressorExpires() {
        var suppressor = RecentWriteSuppressor(window: 5)
        let start = Date(timeIntervalSince1970: 1000)
        suppressor.note("/a", now: start)
        XCTAssertTrue(suppressor.isSuppressed("/a", now: start.addingTimeInterval(4)))
        XCTAssertFalse(suppressor.isSuppressed("/b", now: start.addingTimeInterval(4)))
        XCTAssertFalse(suppressor.isSuppressed("/a", now: start.addingTimeInterval(6)))
    }
}

// MARK: - Stability gate (injectable clock + stat)

final class FileStabilityGateTests: XCTestCase {
    private var stats: [String: FileStatSnapshot] = [:]
    private var t0 = Date(timeIntervalSince1970: 10_000)

    private func stat(_ path: String) -> FileStatSnapshot? { stats[path] }
    private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    func testGrowingFileIsReadyOnlyAfterItStopsChanging() {
        var gate = FileStabilityGate(stableInterval: 1.0)
        stats["/big.png"] = FileStatSnapshot(size: 100, mtime: 1)
        XCTAssertTrue(gate.track("/big.png", now: at(0), stat: stat))

        stats["/big.png"] = FileStatSnapshot(size: 5000, mtime: 2)   // still being written
        XCTAssertEqual(gate.poll(now: at(0.5), stat: stat).ready, [])
        stats["/big.png"] = FileStatSnapshot(size: 9000, mtime: 3)
        XCTAssertEqual(gate.poll(now: at(1.0), stat: stat).ready, [])
        XCTAssertEqual(gate.poll(now: at(1.5), stat: stat).ready, [], "stable for only 0.5 s")
        XCTAssertEqual(gate.poll(now: at(2.0), stat: stat).ready, ["/big.png"])
        XCTAssertTrue(gate.isEmpty)
    }

    func testVanishedFilesLeaveTheGate() {
        var gate = FileStabilityGate()
        stats["/tmp.png"] = FileStatSnapshot(size: 10, mtime: 1)
        gate.track("/tmp.png", now: at(0), stat: stat)
        stats["/tmp.png"] = nil
        let outcome = gate.poll(now: at(0.5), stat: stat)
        XCTAssertEqual(outcome.vanished, ["/tmp.png"])
        XCTAssertEqual(outcome.ready, [])
        XCTAssertTrue(gate.isEmpty)
        XCTAssertFalse(gate.track("/missing.png", now: at(1), stat: stat))
    }

    func testEmptyFilesWaitLongerAndMaximumWaitReleases() {
        var gate = FileStabilityGate(stableInterval: 1, emptyFileInterval: 5, maximumWait: 10)
        stats["/empty.png"] = FileStatSnapshot(size: 0, mtime: 1)
        gate.track("/empty.png", now: at(0), stat: stat)
        XCTAssertEqual(gate.poll(now: at(2), stat: stat).ready, [])
        XCTAssertEqual(gate.poll(now: at(5), stat: stat).ready, ["/empty.png"])

        stats["/forever.mp4"] = FileStatSnapshot(size: 1, mtime: 1)
        gate.track("/forever.mp4", now: at(0), stat: stat)
        var size: Int64 = 1
        var released: [String] = []
        for step in 1...12 {
            size += 1
            stats["/forever.mp4"] = FileStatSnapshot(size: size, mtime: Double(step))
            released += gate.poll(now: at(Double(step)), stat: stat).ready
        }
        XCTAssertEqual(released, ["/forever.mp4"], "a file that never settles is released after the maximum wait")
    }
}

// MARK: - Rule evaluation

final class IngestRuleEngineTests: TempDirectoryTestCase {
    func testFiltersByTypeSizeAndIgnorePatterns() {
        var rules = IngestRules()
        rules.kinds = [.images, .videos]
        rules.minimumSizeBytes = 1000
        rules.ignorePatterns = ["*_temp_*", "previews/*"]

        XCTAssertNil(IngestRuleEngine.rejectionReason(name: "ComfyUI_0001.png", relativePath: "ComfyUI_0001.png", size: 5000, rules: rules))
        XCTAssertNil(IngestRuleEngine.rejectionReason(name: "clip.MP4", relativePath: "clip.MP4", size: nil, rules: rules))
        XCTAssertNotNil(IngestRuleEngine.rejectionReason(name: "song.mp3", relativePath: "song.mp3", size: 5000, rules: rules))
        XCTAssertNotNil(IngestRuleEngine.rejectionReason(name: "notes.txt", relativePath: "notes.txt", size: 5000, rules: rules))
        XCTAssertNotNil(IngestRuleEngine.rejectionReason(name: "small.png", relativePath: "small.png", size: 999, rules: rules))
        XCTAssertNotNil(IngestRuleEngine.rejectionReason(name: "ComfyUI_TEMP_01.png", relativePath: "ComfyUI_TEMP_01.png", size: 5000, rules: rules),
                        "patterns are case-insensitive")
        XCTAssertNotNil(IngestRuleEngine.rejectionReason(name: "a.png", relativePath: "previews/a.png", size: 5000, rules: rules))
        XCTAssertNotNil(IngestRuleEngine.rejectionReason(name: "a.png", relativePath: ".cache/a.png", size: 5000, rules: rules))

        rules.kinds = [.documents]
        XCTAssertNil(IngestRuleEngine.rejectionReason(name: "board.mlmboard", relativePath: "board.mlmboard", size: 5000, rules: rules))
        XCTAssertNil(IngestRuleEngine.rejectionReason(name: "shot.plib", relativePath: "shot.plib", size: 5000, rules: rules))
    }

    func testDatedSubfoldersAndDestination() throws {
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 7; components.hour = 12
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let date = try XCTUnwrap(calendar.date(from: components))

        XCTAssertEqual(IngestRuleEngine.datedSubfolderPath(template: "yyyy/MM-dd", date: date, timeZone: utc), "2026/09-07")
        XCTAssertEqual(IngestRuleEngine.datedSubfolderPath(template: "yyyy//MMMM", date: date, timeZone: utc), "2026/September")

        var rules = IngestRules()
        let library = tempDir.appendingPathComponent("Library")
        XCTAssertNil(IngestRuleEngine.destinationFolder(rules: rules, libraryRoot: library, date: date), "leave in place has no destination")
        rules.action = .copy
        XCTAssertEqual(IngestRuleEngine.destinationFolder(rules: rules, libraryRoot: library, date: date)?.path, library.path)
        XCTAssertNil(IngestRuleEngine.destinationFolder(rules: rules, libraryRoot: nil, date: date))
        rules.destinationPath = tempDir.appendingPathComponent("Dest").path
        rules.usesDatedSubfolders = true
        XCTAssertEqual(
            IngestRuleEngine.destinationFolder(rules: rules, libraryRoot: library, date: date, timeZone: utc)?.path,
            tempDir.appendingPathComponent("Dest/2026/09-07").standardizedFileURL.path
        )
    }

    func testRenameTemplateAndTagsByModel() {
        let url = tempDir.appendingPathComponent("ComfyUI_00001_.png")
        let context = RenameTemplateContext(url: url, index: 2, model: "checkpoints/juggernautXL_v9.safetensors", seed: "42")
        XCTAssertEqual(IngestRuleEngine.renamedFileName(template: "{model}_{seed}_{counter:3}", context: context), "juggernautXL_v9_42_003.png")
        XCTAssertNil(IngestRuleEngine.renamedFileName(template: "  ", context: context), "an empty template keeps the name")
        XCTAssertNil(IngestRuleEngine.renamedFileName(template: "{name}", context: context), "same name = no rename")

        var rules = IngestRules()
        rules.fixedTags = ["ComfyUI", " review ", "", "comfyui"]
        XCTAssertEqual(IngestRuleEngine.tagNames(rules: rules, model: "sdxl.safetensors"), ["ComfyUI", "review"])
        rules.tagWithModelName = true
        XCTAssertEqual(IngestRuleEngine.tagNames(rules: rules, model: "models\\sdxl_base.safetensors"), ["ComfyUI", "review", "sdxl_base"])
        XCTAssertEqual(IngestRuleEngine.tagNames(rules: rules, model: "N/A"), ["ComfyUI", "review"])
        XCTAssertEqual(IngestRuleEngine.tagNames(rules: rules, model: nil), ["ComfyUI", "review"])
        XCTAssertEqual(IngestRuleEngine.list(from: "a, b,,c "), ["a", "b", "c"])
    }

    func testArrivalAndSourceMembership() {
        let since = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(IngestRuleEngine.isNewArrival(arrival: since.addingTimeInterval(5), since: since))
        XCTAssertTrue(IngestRuleEngine.isNewArrival(arrival: since.addingTimeInterval(-1), since: since), "slack for coarse timestamps")
        XCTAssertFalse(IngestRuleEngine.isNewArrival(arrival: since.addingTimeInterval(-60), since: since))
        XCTAssertTrue(IngestRuleEngine.isNewArrival(arrival: nil, since: nil))

        var source = IngestSource(path: "/Src")
        XCTAssertTrue(IngestRuleEngine.isWithinSource("/Src/a.png", source: source))
        XCTAssertTrue(IngestRuleEngine.isWithinSource("/Src/sub/a.png", source: source))
        XCTAssertFalse(IngestRuleEngine.isWithinSource("/Src2/a.png", source: source))
        source.includeSubfolders = false
        XCTAssertFalse(IngestRuleEngine.isWithinSource("/Src/sub/a.png", source: source))
        XCTAssertEqual(IngestRuleEngine.relativePath(of: "/Src/sub/a.png", inSource: "/Src"), "sub/a.png")
    }

    func testRulesDecodeTolerantly() throws {
        let json = #"{"action":"move","fixedTags":["x"]}"#
        let rules = try JSONDecoder().decode(IngestRules.self, from: Data(json.utf8))
        XCTAssertEqual(rules.action, .move)
        XCTAssertEqual(rules.fixedTags, ["x"])
        XCTAssertEqual(rules.kinds, .all)
        XCTAssertEqual(rules.datedSubfolderTemplate, IngestRules.defaultDatedTemplate)
    }
}

// MARK: - Execution: never overwrites, never deletes

final class IngestExecutorTests: TempDirectoryTestCase {
    private func bytes(_ text: String) -> Data { Data(text.utf8) }

    func testCopyNeverOverwritesAnExistingName() throws {
        let source = try writeFile("Src/a.png", bytes("new image"))
        let existing = try writeFile("Lib/a.png", bytes("an older, different file"))
        let lib = existing.deletingLastPathComponent()

        let result = IngestExecutor.execute(
            IngestPlan(source: source, action: .copy, destinationFolder: lib, targetName: nil),
            duplicates: IngestDuplicateIndex(root: lib)
        )
        guard case let .copied(from, to) = result else { return XCTFail("expected a copy, got \(result)") }
        XCTAssertEqual(from.path, source.standardizedFileURL.path)
        XCTAssertEqual(to.lastPathComponent, "a 2.png")
        XCTAssertEqual(try Data(contentsOf: existing), bytes("an older, different file"), "existing file untouched")
        XCTAssertEqual(try Data(contentsOf: to), bytes("new image"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "a copy keeps the source")
    }

    func testMoveIntoDatedFolderWithRename() throws {
        let source = try writeFile("Src/ComfyUI_0001.png", bytes("pixels"))
        let folder = tempDir.appendingPathComponent("Lib/2026/09-27", isDirectory: true)
        let result = IngestExecutor.execute(
            IngestPlan(source: source, action: .move, destinationFolder: folder, targetName: "renamed.png"),
            duplicates: IngestDuplicateIndex(root: tempDir.appendingPathComponent("Lib"))
        )
        guard case let .moved(_, to) = result else { return XCTFail("expected a move, got \(result)") }
        XCTAssertEqual(to.path, folder.appendingPathComponent("renamed.png").standardizedFileURL.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: to), bytes("pixels"))
    }

    func testExactDuplicateIsLinkedAndNothingIsDeletedOrOverwritten() throws {
        let content = bytes("identical bytes 0123456789")
        let existing = try writeFile("Lib/older/keep-me.png", content)
        let source = try writeFile("Src/new-download.png", content)
        let lib = tempDir.appendingPathComponent("Lib")
        let before = try FileManager.default.subpathsOfDirectory(atPath: lib.path).sorted()

        for action in [IngestAction.copy, .move] {
            let result = IngestExecutor.execute(
                IngestPlan(source: source, action: action, destinationFolder: lib.appendingPathComponent("2026/09-27"), targetName: nil),
                duplicates: IngestDuplicateIndex(root: lib)
            )
            XCTAssertEqual(result, .duplicate(source: source.standardizedFileURL, existing: existing.standardizedFileURL))
            XCTAssertEqual(result.finalURL?.path, existing.standardizedFileURL.path, "the Inbox links the existing file")
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "the source is never removed")
            XCTAssertEqual(try Data(contentsOf: source), content)
            XCTAssertEqual(try Data(contentsOf: existing), content)
        }
        let after = try FileManager.default.subpathsOfDirectory(atPath: lib.path).sorted()
        XCTAssertEqual(after, before, "nothing was added to (or removed from) the destination")
    }

    func testSameSizeDifferentContentIsNotADuplicate() throws {
        _ = try writeFile("Lib/a.png", bytes("AAAA"))
        let source = try writeFile("Src/b.png", bytes("BBBB"))
        let lib = tempDir.appendingPathComponent("Lib")
        let result = IngestExecutor.execute(
            IngestPlan(source: source, action: .copy, destinationFolder: lib, targetName: nil),
            duplicates: IngestDuplicateIndex(root: lib)
        )
        guard case .copied = result else { return XCTFail("expected a copy, got \(result)") }
    }

    func testLeaveInPlaceRenamesWithoutOverwriting() throws {
        let source = try writeFile("Src/a.png", bytes("one"))
        let taken = try writeFile("Src/b.png", bytes("two"))
        let result = IngestExecutor.execute(
            IngestPlan(source: source, action: .leaveInPlace, destinationFolder: nil, targetName: "b.png"),
            duplicates: nil
        )
        guard case let .renamedInPlace(_, to) = result else { return XCTFail("expected a rename, got \(result)") }
        XCTAssertEqual(to.lastPathComponent, "b 2.png")
        XCTAssertEqual(try Data(contentsOf: taken), bytes("two"))
        XCTAssertEqual(
            IngestExecutor.execute(IngestPlan(source: to, action: .leaveInPlace, destinationFolder: nil, targetName: nil), duplicates: nil),
            .surfaced(to)
        )
    }

    func testCopyWithoutDestinationFailsSafely() throws {
        let source = try writeFile("Src/a.png", bytes("x"))
        let result = IngestExecutor.execute(IngestPlan(source: source, action: .copy, destinationFolder: nil, targetName: nil), duplicates: nil)
        guard case .failed = result else { return XCTFail("expected a failure, got \(result)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testPipelineAppliesRulesTemplatesAndTags() async throws {
        let srcDir = tempDir.appendingPathComponent("Src", isDirectory: true)
        let lib = tempDir.appendingPathComponent("Lib", isDirectory: true)
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        let image = try writeFile("Src/ComfyUI_0007_.png", bytes("image data"))
        let skipped = try writeFile("Src/notes.txt", bytes("text"))

        var source = IngestSource(path: srcDir.standardizedFileURL.path)
        source.rules.action = .move
        source.rules.usesDatedSubfolders = true
        source.rules.datedSubfolderTemplate = "yyyy"
        source.rules.renameTemplate = "{model}_{counter:2}"
        source.rules.fixedTags = ["inbox"]
        source.rules.tagWithModelName = true

        let results = await IngestPipeline.process(
            paths: [image.standardizedFileURL.path, skipped.standardizedFileURL.path],
            source: source,
            libraryRoot: lib,
            now: Date(),
            metadata: { _ in IngestFileMetadata(model: "ckpt/dreamshaper_8.safetensors") }
        )
        XCTAssertEqual(results.count, 1, "the text file isn't a supported type")
        let result = try XCTUnwrap(results.first)
        guard case let .moved(_, to) = result.execution else { return XCTFail("expected a move, got \(result.execution)") }
        XCTAssertEqual(to.lastPathComponent, "dreamshaper_8_01.png")
        XCTAssertEqual(to.deletingLastPathComponent().deletingLastPathComponent().path, lib.standardizedFileURL.path)
        XCTAssertEqual(result.tags, ["inbox", "dreamshaper_8"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: skipped.path))
    }
}

// MARK: - Catch-up scan & the controller

@MainActor
private final class FakeIngestHost: IngestHost {
    var libraryRoot: URL?
    var toasts: [String] = []
    var moves: [(from: URL, to: URL)] = []
    var copies: [URL] = []
    var inboxChanges = 0

    var ingestLibraryRoot: URL? { libraryRoot }
    func ingestDidPerform(moves: [(from: URL, to: URL)], copies: [URL]) async {
        self.moves += moves
        self.copies += copies
    }
    func ingestDidChangeCuration() {}
    func ingestInboxDidChange() { inboxChanges += 1 }
    func ingestShowToast(_ message: String, type: ToastType) { toasts.append(message) }
}

@MainActor
final class IngestCatchUpTests: TempDirectoryTestCase {
    private func makeController() -> IngestController {
        let controller = IngestController(
            store: IngestStore(fileURL: tempDir.appendingPathComponent("state/ingest.json")),
            gate: FileStabilityGate(stableInterval: 0.05, emptyFileInterval: 0.05)
        )
        controller.watchesLive = false
        controller.feedsIndexes = false
        controller.pollInterval = 0.02
        controller.debounce = 0.01
        controller.curationWriter = { _, _ in false }
        controller.metadataReader = { _ in IngestFileMetadata() }
        return controller
    }

    func testScanUsesLastScanTimestampAndProcessedPaths() throws {
        let a = try writeFile("Src/a.png", Data("a".utf8))
        _ = try writeFile("Src/sub/b.png", Data("b".utf8))
        _ = try writeFile("Src/.hidden/c.png", Data("c".utf8))
        _ = try writeFile("Src/readme.txt", Data("t".utf8))
        var source = IngestSource(path: tempDir.appendingPathComponent("Src").path)

        let past = Date().addingTimeInterval(-3600)
        let future = Date().addingTimeInterval(3600)
        let names = { (paths: [String]) in paths.map { ($0 as NSString).lastPathComponent }.sorted() }

        XCTAssertEqual(names(IngestPipeline.scan(source: source, since: past, processed: [])), ["a.png", "b.png"])
        XCTAssertEqual(IngestPipeline.scan(source: source, since: future, processed: []), [], "nothing arrived after the last scan")
        let aPath = source.path + "/" + a.lastPathComponent
        XCTAssertEqual(names(IngestPipeline.scan(source: source, since: past, processed: [aPath])), ["b.png"])
        source.includeSubfolders = false
        XCTAssertEqual(names(IngestPipeline.scan(source: source, since: nil, processed: [])), ["a.png"])
        XCTAssertTrue(IngestPipeline.scan(source: source, since: nil, processed: []).allSatisfy { $0.hasPrefix(source.path + "/") })
    }

    func testCatchUpOnLaunchProcessesFilesAddedWhileClosedOnce() async throws {
        let srcDir = tempDir.appendingPathComponent("Src", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        let controller = makeController()
        let host = FakeIngestHost()
        controller.host = host
        var source = try XCTUnwrap(controller.addSource(srcDir))
        // The app last ran an hour ago; this file arrived since.
        source.lastScan = Date().addingTimeInterval(-3600)
        controller.updateSource(source)
        _ = try writeFile("Src/while-closed.png", Data("x".utf8))

        await controller.catchUpOnLaunch()
        await controller.waitForIdle()
        XCTAssertEqual(controller.visibleItems.map { ($0.path as NSString).lastPathComponent }, ["while-closed.png"])
        XCTAssertEqual(controller.unseenCount, 1)
        XCTAssertTrue(host.toasts.contains { $0.contains("1 new file since last run") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: srcDir.appendingPathComponent("while-closed.png").path),
                      "leave in place keeps the file")

        // A second launch finds nothing new (timestamp + processed set).
        await controller.catchUpOnLaunch()
        await controller.waitForIdle()
        XCTAssertEqual(controller.visibleItems.count, 1)

        controller.markAllSeen()
        XCTAssertEqual(controller.unseenCount, 0)
        controller.clearInbox()
        XCTAssertTrue(controller.visibleItems.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: srcDir.appendingPathComponent("while-closed.png").path),
                      "clearing the Inbox never touches files")
    }

    func testCatchUpRespectsProcessWhileClosedOff() async throws {
        let srcDir = tempDir.appendingPathComponent("Src", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        let controller = makeController()
        let host = FakeIngestHost()
        controller.host = host
        var source = try XCTUnwrap(controller.addSource(srcDir))
        source.lastScan = Date().addingTimeInterval(-3600)
        source.processWhileClosed = false
        controller.updateSource(source)
        _ = try writeFile("Src/while-closed.png", Data("x".utf8))

        await controller.catchUpOnLaunch()
        await controller.waitForIdle()
        XCTAssertTrue(controller.visibleItems.isEmpty)
        XCTAssertTrue(host.toasts.isEmpty)
        let lastScan = try XCTUnwrap(controller.source(id: source.id)?.lastScan)
        XCTAssertGreaterThan(lastScan, Date().addingTimeInterval(-60), "the timestamp still moves on")
    }

    func testLiveEventCopiesNewFileIntoLibraryAndPersists() async throws {
        let srcDir = tempDir.appendingPathComponent("Src", isDirectory: true)
        let lib = tempDir.appendingPathComponent("Lib", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        let controller = makeController()
        let host = FakeIngestHost()
        host.libraryRoot = lib
        controller.host = host
        var source = try XCTUnwrap(controller.addSource(srcDir))
        source.rules.action = .copy
        controller.updateSource(source)

        let file = try writeFile("Src/new.png", Data("fresh".utf8))
        let path = srcDir.standardizedFileURL.path + "/new.png"
        controller.receive([FolderWatchEvent(path: path, flags: [.created, .isFile])])
        try await Task.sleep(nanoseconds: 50_000_000)
        await controller.waitForIdle()

        let copied = lib.appendingPathComponent("new.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(host.copies.map(\.lastPathComponent), ["new.png"])
        XCTAssertEqual(controller.inboxPaths(sourceID: source.id).map { ($0 as NSString).lastPathComponent }, ["new.png"])

        // The same event again (e.g. a later modification) is not ingested twice.
        controller.receive([FolderWatchEvent(path: path, flags: [.modified, .isFile])])
        try await Task.sleep(nanoseconds: 50_000_000)
        await controller.waitForIdle()
        XCTAssertEqual(host.copies.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lib.appendingPathComponent("new 2.png").path))

        // State survives a relaunch.
        let reloaded = IngestController(store: IngestStore(fileURL: tempDir.appendingPathComponent("state/ingest.json")))
        XCTAssertEqual(reloaded.sources.map(\.id), [source.id])
        XCTAssertEqual(reloaded.sources.first?.rules.action, .copy)
        XCTAssertEqual(reloaded.visibleItems.count, 1)

        // Inbox entries follow a rename made in the app.
        controller.itemDidMove(from: copied.standardizedFileURL.path, to: lib.appendingPathComponent("renamed.png").path)
        XCTAssertEqual(controller.inboxPaths(sourceID: nil).map { ($0 as NSString).lastPathComponent }, ["renamed.png"])
    }
}

// MARK: - Live listing updates

@MainActor
final class LiveListingUpdateTests: TempDirectoryTestCase {
    private func entry(_ path: String, size: Int64, mtime: Double, isDirectory: Bool = false) -> FileEntry {
        FileEntry(
            url: URL(fileURLWithPath: path),
            isDirectory: isDirectory,
            children: isDirectory ? [] : nil,
            modifiedDate: Date(timeIntervalSince1970: mtime),
            creationDate: nil,
            fileSize: isDirectory ? nil : size,
            labelNumber: 0
        )
    }

    func testPlanKeepsOnlyChangesThatTouchTheListing() {
        let listed = [
            entry("/Lib/Folder/same.png", size: 10, mtime: 100),
            entry("/Lib/Folder/rewritten.png", size: 10, mtime: 100),
            entry("/Lib/Folder/gone.png", size: 10, mtime: 100),
        ]
        var set = FolderLiveChangeSet()
        set.removed = ["/Lib/Folder/gone.png", "/Lib/Other/unrelated.png", "/Lib/OldFolder"]
        set.changedFiles = [
            "/Lib/Folder/same.png": FileStatSnapshot(size: 10, mtime: 100),       // the app's own write: already listed as is
            "/Lib/Folder/rewritten.png": FileStatSnapshot(size: 20, mtime: 200),
            "/Lib/Folder/new.png": FileStatSnapshot(size: 5, mtime: 300),
            "/Lib/Folder/Sub/deeper.png": FileStatSnapshot(size: 5, mtime: 300),
        ]
        set.changedDirectories = ["/Lib/Folder/New Folder"]

        let plan = LiveListingChangePlan.make(set: set, listed: listed, folderPath: "/Lib/Folder", sidebarFolderPaths: ["/Lib/OldFolder"])
        XCTAssertEqual(plan.removed, ["/Lib/Folder/gone.png"])
        XCTAssertEqual(plan.modified, ["/Lib/Folder/rewritten.png"])
        XCTAssertEqual(Set(plan.added), ["/Lib/Folder/new.png", "/Lib/Folder/New Folder"])
        XCTAssertTrue(plan.folderTreeChanged)

        // A collection / virtual listing only refreshes files it lists.
        let virtual = LiveListingChangePlan.make(set: set, listed: listed, folderPath: nil, sidebarFolderPaths: [])
        XCTAssertEqual(virtual.added, [])
        XCTAssertEqual(virtual.removed, ["/Lib/Folder/gone.png"])
        XCTAssertEqual(virtual.modified, ["/Lib/Folder/rewritten.png"])

        XCTAssertTrue(LiveListingChangePlan.make(
            set: FolderLiveChangeSet(changedFiles: ["/Lib/Folder/same.png": FileStatSnapshot(size: 10, mtime: 100)]),
            listed: listed, folderPath: "/Lib/Folder", sidebarFolderPaths: []
        ).isEmpty, "unchanged files cause no refresh")
    }

    func testControllerDeliversRemovalsAtOnceAndNewFilesOnceStable() async throws {
        let suite = "PLETests.liveUpdates.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = FolderWatcherController(
            defaults: defaults,
            gate: FileStabilityGate(stableInterval: 0.1, emptyFileInterval: 0.1)
        )
        controller.feedsIndexes = false
        controller.debounce = 0.01
        controller.pollInterval = 0.02
        var received: [FolderLiveChangeSet] = []
        controller.onChanges = { received.append($0) }

        let folder = tempDir.standardizedFileURL.path
        let file = try writeFile("new.png", Data("pixels".utf8))
        controller.receive([
            FolderWatchEvent(path: folder + "/new.png", flags: [.created, .isFile]),
            FolderWatchEvent(path: folder + "/deleted.png", flags: [.removed, .isFile]),
            FolderWatchEvent(path: folder + "/.promptlibrary/curation.json", flags: [.modified, .isFile]),
        ])
        try await Task.sleep(nanoseconds: 50_000_000)
        await controller.waitForIdle()

        XCTAssertEqual(received.flatMap(\.removed), [folder + "/deleted.png"])
        let changed = received.flatMap { $0.changedFiles.keys }
        XCTAssertEqual(changed, [folder + "/new.png"])
        XCTAssertEqual(received.first(where: { !$0.changedFiles.isEmpty })?.changedFiles[folder + "/new.png"]?.size, 6)
        XCTAssertFalse(received.contains { $0.changedFiles.keys.contains { $0.contains(".promptlibrary") } })
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testFSEventsStreamReportsNewFiles() throws {
        let folder = tempDir.resolvingSymlinksInPath().path
        let seen = expectation(description: "FSEvents reports the new file")
        seen.assertForOverFulfill = false
        let watcher = FolderWatcher(paths: [folder], latency: 0.1) { events in
            if events.contains(where: { $0.path.hasSuffix("/fsevents-probe.png") }) { seen.fulfill() }
        }
        XCTAssertTrue(watcher.start())
        defer { watcher.stop() }
        // Give the stream a moment to begin before writing.
        Thread.sleep(forTimeInterval: 0.3)
        try writeFile("fsevents-probe.png", Data("x".utf8))
        wait(for: [seen], timeout: 10)
    }
}
