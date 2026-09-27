import XCTest
@testable import PromptLibraryExplorer

final class XMPSidecarCodecTests: XCTestCase {
    /// As Lightroom Classic writes it: properties as attributes, keywords as a Bag, plus
    /// develop settings the app must never drop.
    static let lightroomSidecar = """
    <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 7.0-c000 1.000000, 0000/00/00-00:00:00        ">
     <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
      <rdf:Description rdf:about=""
        xmlns:xmp="http://ns.adobe.com/xap/1.0/"
        xmlns:dc="http://purl.org/dc/elements/1.1/"
        xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
        xmlns:lr="http://ns.adobe.com/lightroom/1.0/"
       xmp:Rating="4"
       xmp:Label="Red"
       crs:Version="15.0"
       crs:Exposure2012="+0.35">
       <dc:subject>
        <rdf:Bag>
         <rdf:li>portrait</rdf:li>
         <rdf:li>studio</rdf:li>
        </rdf:Bag>
       </dc:subject>
       <lr:hierarchicalSubject>
        <rdf:Bag>
         <rdf:li>people|portrait</rdf:li>
        </rdf:Bag>
       </lr:hierarchicalSubject>
      </rdf:Description>
     </rdf:RDF>
    </x:xmpmeta>
    """

    func testReadsLightroomSidecar() throws {
        let values = try XCTUnwrap(XMPSidecarCodec.parse(Data(Self.lightroomSidecar.utf8)))
        XCTAssertEqual(values.rating, 4)
        XCTAssertEqual(values.label, "Red")
        XCTAssertEqual(values.finderLabel, .red)
        XCTAssertEqual(values.subjects, ["portrait", "studio"])
        XCTAssertNil(values.flag)
        XCTAssertNil(values.descriptionText)
    }

    func testReadsElementFormAndBridgeReject() throws {
        let xml = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:xap="http://ns.adobe.com/xap/1.0/" xmlns:dc="http://purl.org/dc/elements/1.1/">
        <xap:Rating>-1</xap:Rating><dc:description><rdf:Alt><rdf:li xml:lang="x-default">a red fox</rdf:li></rdf:Alt></dc:description>
        </rdf:Description></rdf:RDF></x:xmpmeta>
        """
        let values = try XCTUnwrap(XMPSidecarCodec.parse(Data(xml.utf8)))
        XCTAssertEqual(values.rating, 0)
        XCTAssertEqual(values.flag, .reject, "Bridge's -1 rating means rejected")
        XCTAssertEqual(values.descriptionText, "a red fox")
    }

    func testWriteReadRoundTrip() throws {
        let values = XMPSidecarValues(
            rating: 5, label: "Blue", subjects: ["Hero", "Client & Co"],
            descriptionText: "a lighthouse at dusk, <cinematic>", flag: .pick, negativePrompt: "blurry, text"
        )
        let data = XMPSidecarCodec.render(values, updating: nil)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("xmp:Rating=\"5\""))
        XCTAssertTrue(text.contains("http://ns.artofficial.app/promptlibrary/1.0/"))
        XCTAssertEqual(XMPSidecarCodec.parse(data), values)
    }

    func testUpdatingLightroomSidecarKeepsEverythingElse() throws {
        let updated = XMPSidecarCodec.render(
            XMPSidecarValues(rating: 2, label: nil, subjects: ["studio"], flag: .reject),
            updating: Data(Self.lightroomSidecar.utf8)
        )
        let text = try XCTUnwrap(String(data: updated, encoding: .utf8))
        XCTAssertTrue(text.contains("crs:Exposure2012=\"+0.35\""), "develop settings survive")
        XCTAssertTrue(text.contains("people|portrait"), "other keyword fields survive")
        XCTAssertFalse(text.contains("xmp:Label"), "a cleared label is removed")
        let values = try XCTUnwrap(XMPSidecarCodec.parse(updated))
        XCTAssertEqual(values.rating, 2)
        XCTAssertEqual(values.subjects, ["studio"])
        XCTAssertEqual(values.flag, .reject)
        XCTAssertEqual(text.components(separatedBy: "xmp:Rating").count - 1, 1, "no duplicate properties")
    }

    func testImportFillsOnlyEmptyFieldsAndAppWins() {
        let sidecar = XMPSidecarValues(rating: 4, label: "Red", subjects: ["portrait"], flag: .pick)
        let (fresh, freshConflicts) = SidecarImporter.plan(path: "/a.png", sidecar: sidecar, app: SidecarAppValues())
        XCTAssertEqual(fresh, SidecarImport(path: "/a.png", rating: 4, flag: .pick, tagNames: ["portrait"], label: .red))
        XCTAssertTrue(freshConflicts.isEmpty)

        let app = SidecarAppValues(rating: 2, flag: .pick, tagNames: ["Hero"], label: .none)
        let (planned, conflicts) = SidecarImporter.plan(path: "/a.png", sidecar: sidecar, app: app)
        XCTAssertNil(planned.rating)
        XCTAssertNil(planned.tagNames)
        XCTAssertEqual(planned.label, .red)
        XCTAssertEqual(Set(conflicts), ["rating", "keywords"])
    }
}

/// Real files in a temp folder.
final class SidecarFileTests: XCTestCase {
    private var directory: URL!
    private var trash: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SidecarTests-\(UUID().uuidString)", isDirectory: true)
        trash = directory.appendingPathComponent("FakeTrash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func touch(_ name: String, contents: String = "x") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// Moves to a folder in the temp dir instead of the user's Trash.
    private var follower: SidecarFollower {
        let trash = trash!
        return SidecarFollower(trash: { url in
            let destination = trash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        })
    }

    func testLocatorConventionAndBasenameCollisions() throws {
        let png = try touch("IMG_1.png")
        XCTAssertEqual(SidecarLocator.sidecarURL(for: png).lastPathComponent, "IMG_1.xmp")
        _ = try touch("IMG_1.jpg")
        XCTAssertEqual(SidecarLocator.sidecarURL(for: png).lastPathComponent, "IMG_1.png.xmp", "shared basename: full name")
        XCTAssertNil(SidecarLocator.existingSidecar(for: png))
        _ = try touch("IMG_1.png.xmp")
        XCTAssertEqual(SidecarLocator.existingSidecar(for: png)?.lastPathComponent, "IMG_1.png.xmp")
        XCTAssertFalse(SidecarLocator.supportsSidecar("IMG_1.xmp"))
        XCTAssertTrue(SidecarLocator.supportsSidecar("clip.mov"))
    }

    func testWriterUpdatesInPlaceAndNeverTouchesTheOriginal() throws {
        let image = try touch("shot.png", contents: "original bytes")
        let state = SidecarSyncState(url: directory.appendingPathComponent("state.json"))
        var curation = SidecarFileCuration(path: image.path, rating: 0, flag: .unflagged, tagNames: [], label: .none, prompt: "a fox")
        XCTAssertNil(try SidecarWriter.write(curation, force: false, state: state), "no curation, no sidecar")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("shot.xmp").path))

        curation.rating = 3
        curation.tagNames = ["Hero"]
        let sidecar = try XCTUnwrap(SidecarWriter.write(curation, force: false, state: state))
        XCTAssertEqual(sidecar.lastPathComponent, "shot.xmp")
        XCTAssertEqual(try String(contentsOf: image), "original bytes")
        XCTAssertTrue(state.isUnchanged(sidecar), "our own write isn't re-imported")
        XCTAssertNil(try SidecarWriter.write(curation, force: true, state: state), "unchanged values: no rewrite")

        curation.label = .green
        XCTAssertNotNil(try SidecarWriter.write(curation, force: false, state: state))
        let values = try XCTUnwrap(XMPSidecarCodec.parse(Data(contentsOf: sidecar)))
        XCTAssertEqual(values.rating, 3)
        XCTAssertEqual(values.finderLabel, .green)
        XCTAssertEqual(values.descriptionText, "a fox")
    }

    func testSidecarFollowsRenameAndMove() throws {
        let image = try touch("a.png")
        let sidecar = try touch("a.xmp", contents: XMPSidecarCodecTests.lightroomSidecar)

        // Rename (the file moves first, then the migration hook runs).
        let renamed = directory.appendingPathComponent("b.png")
        try FileManager.default.moveItem(at: image, to: renamed)
        let moved = try XCTUnwrap(follower.fileDidMove(from: image, to: renamed))
        XCTAssertEqual(moved.lastPathComponent, "b.xmp")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
        XCTAssertEqual(try String(contentsOf: moved), XMPSidecarCodecTests.lightroomSidecar)

        // Move into a folder where the basename is shared with another file.
        let folder = directory.appendingPathComponent("sub", isDirectory: true)
        _ = try touch("sub/b.jpg")
        let destination = folder.appendingPathComponent("b.png")
        try FileManager.default.moveItem(at: renamed, to: destination)
        XCTAssertEqual(follower.fileDidMove(from: renamed, to: destination)?.lastPathComponent, "b.png.xmp")

        // Undo (move back) brings it home under the convention again.
        try FileManager.default.moveItem(at: destination, to: renamed)
        XCTAssertEqual(follower.fileDidMove(from: destination, to: renamed)?.lastPathComponent, "b.xmp")
    }

    func testSidecarIsNotMovedWhenAmbiguousOrOccupied() throws {
        let png = try touch("c.png")
        _ = try touch("c.jpg")
        let shared = try touch("c.xmp") // belongs to c.jpg as far as anyone can tell
        let renamed = directory.appendingPathComponent("d.png")
        try FileManager.default.moveItem(at: png, to: renamed)
        XCTAssertNil(follower.fileDidMove(from: png, to: renamed))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.path))
    }

    func testSidecarGoesToTrashAndComesBackWithUndo() throws {
        let image = try touch("e.png")
        _ = try touch("e.xmp", contents: "<sidecar/>")
        // The view model trashes the file first, then asks for the sidecar.
        let trashedImage = trash.appendingPathComponent("e.png")
        try FileManager.default.moveItem(at: image, to: trashedImage)
        let record = try XCTUnwrap(follower.fileWasTrashed(image))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("e.xmp").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.trashedURL.path))

        // Undo: the file comes back (here under another name), then its sidecar.
        let restoredImage = directory.appendingPathComponent("e 2.png")
        try FileManager.default.moveItem(at: trashedImage, to: restoredImage)
        let restored = try XCTUnwrap(follower.restore(record, besideFileAt: restoredImage))
        XCTAssertEqual(restored.lastPathComponent, "e 2.xmp")
        XCTAssertEqual(try String(contentsOf: restored), "<sidecar/>")
    }
}
