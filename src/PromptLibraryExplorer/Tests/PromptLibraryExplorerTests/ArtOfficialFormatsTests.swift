import CoreGraphics
import XCTest
@testable import ArtOfficialFormats

// MARK: - Mood boards

final class MoodboardFormatTests: XCTestCase {
    func testCurrentBoardRoundTrip() throws {
        let dir = try AOFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let images = [
            MoodboardDraft.Image(name: "red.png", data: AOFixtures.png(rgb: (220, 30, 30)), mimeType: "image/png"),
            MoodboardDraft.Image(name: "green \"quoted\".png", data: AOFixtures.png(rgb: (30, 200, 30)), mimeType: "image/png"),
            MoodboardDraft.Image(name: "blue.jpg", data: AOFixtures.encode(AOFixtures.image(width: 40, height: 20, rgb: (20, 20, 220)), type: "public.jpeg"), mimeType: "image/jpeg"),
        ]
        let draft = MoodboardDraft(title: "Spring Line", subtitle: "Campaign\nDraft", images: images,
                                   palette: ["#ffeedd", "#112233"], layoutMode: .mosaic, columns: 3)
        let url = dir.appendingPathComponent("board.mlmboard")
        try MoodboardWriter.write(draft, to: url)

        let board = try MoodboardReader.read(from: url)
        XCTAssertFalse(board.isLegacyArchive)
        XCTAssertEqual(board.title, "Spring Line")
        XCTAssertEqual(board.subtitle, "Campaign\nDraft")
        XCTAssertEqual(board.layoutMode, .mosaic)
        XCTAssertEqual(board.columns, 3)
        XCTAssertEqual(board.palette, ["#FFEEDD", "#112233"])
        XCTAssertEqual(board.backgroundHex, "#FFEEDD")
        XCTAssertEqual(board.textHex, "#112233")
        XCTAssertEqual(board.gap, 12)
        XCTAssertEqual(board.padding, 32)
        XCTAssertTrue(board.rounded)
        XCTAssertEqual(board.assets.count, 3)
        XCTAssertEqual(board.assets.map(\.name), images.map(\.name))
        XCTAssertEqual(board.tiles.count, 3)
        XCTAssertGreaterThan(board.sourceByteCount, 0)
        for (asset, original) in zip(board.assets, images) {
            XCTAssertEqual(asset.image.sourceKind, .dataURL)
            XCTAssertEqual(asset.image.mimeType, original.mimeType)
            XCTAssertEqual(asset.image.data(), original.data)
        }
        for (tile, asset) in zip(board.tiles, board.assets) {
            XCTAssertEqual(tile.colSpan, 1)
            XCTAssertEqual(tile.rowSpan, 1)
            XCTAssertEqual(tile.assetId, asset.id)
        }
        XCTAssertNotNil(board.assets[2].image.cgImage(maxPixelSize: 16))
        XCTAssertEqual(board.assets[2].image.pixelSize(), CGSize(width: 40, height: 20))

        // Shape check against the web ProjectState / Mac WebProjectFile expectations.
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(Set(root.keys), ["assets", "canvasItems", "layoutMode", "layoutOptions", "branding"])
        let asset0 = try XCTUnwrap((root["assets"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(asset0.keys), ["id", "url", "name", "type"])
        XCTAssertEqual(asset0["type"] as? String, "image")
        XCTAssertEqual((root["branding"] as? [String: Any])?["font"] as? String, "font-inter")
        let decoded = try JSONDecoder().decode(MacMoodWebProjectFile.self, from: Data(contentsOf: url))
        XCTAssertEqual(decoded.layoutOptions?.columns, 3)
        XCTAssertEqual(decoded.canvasItems?.count, 3)
    }

    func testMacExtensionKeysAreRead() throws {
        let png = AOFixtures.png()
        let json: [String: Any] = [
            "assets": [
                ["id": "a", "url": AOFixtures.dataURL(png), "name": "A", "type": "image"],
                ["id": "logo", "url": AOFixtures.dataURL(png), "name": "Logo", "type": "logo"],
                ["id": "broken", "name": "No URL"],
            ],
            "canvasItems": [
                ["id": "1", "type": "image", "assetId": "a", "colSpan": 2, "rowSpan": 2, "position": ["x": 0.2, "y": -5], "zoom": 1.4, "caption": "Hero"],
                ["id": "2", "type": "text", "text": "Hello", "colSpan": 1, "rowSpan": 1, "fontWeight": "bold", "textColor": "#fff", "backgroundColor": "#000"],
                ["id": "3", "type": "color", "hex": "#abc", "colSpan": 1, "rowSpan": 1],
                ["id": "4", "type": "image", "assetId": "missing", "colSpan": 1, "rowSpan": 1],
                "not an object",
            ],
            "layoutMode": "mosaic",
            "boardMode": "infinite",
            "layoutOptions": ["columns": 5, "gap": 20, "canvasWidth": 1080, "canvasHeight": 1350, "freeformSnap": true],
            "branding": ["title": "T", "subtitle": "S", "hideTitle": true, "palette": ["#111111"],
                         "logo": ["assetId": "logo", "scale": 0.2, "position": "top-left"]],
        ]
        let board = try MoodboardReader.read(data: AOFixtures.json(json))
        XCTAssertEqual(board.boardMode, .infinite)
        XCTAssertTrue(board.hideTitle)
        XCTAssertEqual(board.canvasWidth, 1080)
        XCTAssertEqual(board.aspectRatioValue ?? 0, 1080.0 / 1350.0, accuracy: 0.0001)
        XCTAssertEqual(board.assets.count, 2, "asset without url is skipped")
        XCTAssertEqual(board.tiles.count, 3, "tile with unknown asset and non-object are skipped")
        XCTAssertEqual(board.tiles[0].caption, "Hero")
        guard case .image(_, let pan, let zoom) = board.tiles[0].content else { return XCTFail() }
        XCTAssertEqual(pan.x, 0.2, accuracy: 1e-9)
        XCTAssertEqual(pan.y, 0, "|y| > 2 is a legacy pixel offset and resets")
        XCTAssertEqual(zoom, 1.4, accuracy: 1e-9)
        guard case .text(let text, let fg, let bg, _, _, let bold) = board.tiles[1].content else { return XCTFail() }
        XCTAssertEqual(text, "Hello"); XCTAssertEqual(fg, "#FFFFFF"); XCTAssertEqual(bg, "#000000"); XCTAssertTrue(bold)
        guard case .color(let hex) = board.tiles[2].content else { return XCTFail() }
        XCTAssertEqual(hex, "#AABBCC")
        XCTAssertEqual(board.logoAsset?.id, "logo")
        XCTAssertEqual(board.logo?.position, "top-left")
    }

    func testMacNativeProjectStateJSON() throws {
        let png = AOFixtures.png()
        let json: [String: Any] = [
            "assets": [["id": "U1", "name": "n", "kind": "image", "filename": "n.png", "imageData": png.base64EncodedString(),
                        "symbolName": "photo", "gradientStartHex": "#000", "gradientEndHex": "#000"]],
            "canvasItems": [["id": "C1", "kind": "image", "assetID": "U1", "colSpan": 1, "rowSpan": 1, "positionX": 0.1]],
            "layoutMode": "grid",
            "layoutOptions": ["columns": 2],
            "branding": ["font": "playfair", "title": "Native", "subtitle": "", "palette": [], "logoAssetID": "U1", "logoScale": 0.3],
        ]
        let board = try MoodboardReader.read(data: AOFixtures.json(json))
        XCTAssertEqual(board.assets.first?.image.data(), png)
        XCTAssertEqual(board.assets.first?.image.mimeType, "image/png")
        XCTAssertEqual(board.tiles.first?.assetId, "U1")
        XCTAssertEqual(board.font, "font-playfair")
        XCTAssertEqual(board.logo?.assetId, "U1")
        XCTAssertEqual(board.title, "Native")
    }

    func testLegacyZipBoard() throws {
        let pngA = AOFixtures.png(rgb: (255, 0, 0))
        let pngB = AOFixtures.png(rgb: (0, 0, 255))
        let meta: [String: Any] = [
            "board": [
                "items": [
                    ["id": "i1", "assetId": "a1", "colSpan": 2, "rowSpan": 1, "crop": ["x": 75, "y": 25, "zoom": 1.5]],
                    ["id": "i2", "type": "image", "assetId": "b2"],
                    ["id": "i3", "type": "image", "assetId": "evil"],
                    ["id": "i4", "type": "color", "hex": "#123456", "colSpan": 1, "rowSpan": 2],
                ],
                "layoutMode": "square",
                "columns": 3,
                "gap": 8,
                "rounded": false,
                "shadow": false,
                "showSafeMargin": true,
                "title": "Old Board",
                "description": "Old Project",
                "bg": "#fafafa",
                "logo": ["assetId": "b2", "scale": 0.25, "position": "top-right"],
            ],
            "assets": [
                ["id": "a1", "name": "photo.png", "fileName": "a1.png", "type": "image"],
                ["id": "b2", "name": "root.png", "file": "b2.png"],
                ["id": "evil", "name": "evil", "fileName": "../evil.png"],
                ["id": "big", "name": "big", "fileName": "big.bin"],
            ],
        ]
        let zipData = AOFixtures.zip([
            .init(name: "meta.json", data: AOFixtures.json(meta), deflate: true, dataDescriptor: true),
            .init(name: "assets/a1.png", data: pngA),
            .init(name: "b2.png", data: pngB, deflate: true),
            .init(name: "../evil.png", data: pngA),
            .init(name: "/abs/evil.png", data: pngA),
            .init(name: "big.bin", data: Data(repeating: 0, count: 1000), deflate: true,
                  declaredUncompressedSize: UInt32(100 * 1024 * 1024)),
        ])
        XCTAssertTrue(ZipArchive.isZip(zipData))
        let archive = try ZipArchive(data: zipData)
        XCTAssertEqual(Set(archive.entries.map(\.name)), ["meta.json", "assets/a1.png", "b2.png"])
        XCTAssertTrue(archive.rejectedEntryNames.contains("../evil.png"))
        XCTAssertTrue(archive.rejectedEntryNames.contains("/abs/evil.png"))
        XCTAssertTrue(archive.rejectedEntryNames.contains("big.bin"), "entry declaring > 64 MB must be rejected")

        let dir = try AOFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("legacy.mlmboard")
        try zipData.write(to: url)
        let board = try MoodboardReader.read(from: url)
        XCTAssertTrue(board.isLegacyArchive)
        XCTAssertEqual(board.title, "Old Board")
        XCTAssertEqual(board.subtitle, "Old Project")
        XCTAssertEqual(board.backgroundHex, "#FAFAFA")
        XCTAssertEqual(board.layoutMode, .grid, "'square' maps to grid")
        XCTAssertEqual(board.columns, 3)
        XCTAssertEqual(board.gap, 8)
        XCTAssertFalse(board.rounded)
        XCTAssertFalse(board.shadow)
        XCTAssertEqual(board.safeMargin, 40, "showSafeMargin without a value falls back to 40")
        XCTAssertEqual(board.padding, 32, "web default")
        XCTAssertEqual(board.assets.map(\.id), ["a1", "b2"], "traversal + missing assets are ignored")
        XCTAssertEqual(board.assets[0].image.sourceKind, .archiveEntry)
        XCTAssertEqual(board.assets[0].image.mimeType, "image/png")
        XCTAssertEqual(board.assets[0].image.data(), pngA)
        XCTAssertEqual(board.assets[1].image.data(), pngB, "deflated root-level fallback")
        XCTAssertEqual(board.assets[1].kind, .logo, "no type + referenced by board.logo -> logo")
        XCTAssertEqual(board.logo?.assetId, "b2")
        XCTAssertEqual(board.tiles.count, 3)
        guard case .image(let id, let pan, let zoom) = board.tiles[0].content else { return XCTFail() }
        XCTAssertEqual(id, "a1")
        XCTAssertEqual(pan.x, 0.25, accuracy: 1e-9)
        XCTAssertEqual(pan.y, -0.25, accuracy: 1e-9)
        XCTAssertEqual(zoom, 1.5, accuracy: 1e-9)
        XCTAssertEqual(board.tiles[0].colSpan, 2)
        XCTAssertEqual(board.tiles[2].rowSpan, 2)
        XCTAssertNotNil(ArtOfficialRenderer.renderMoodboard(board, maxPixelSize: 200))
    }

    func testZipFailsGracefully() {
        XCTAssertThrowsError(try MoodboardReader.read(data: Data([0x50, 0x4B, 0x03, 0x04, 1, 2, 3])))
        XCTAssertThrowsError(try MoodboardReader.read(data: Data("not json".utf8)))
        XCTAssertThrowsError(try MoodboardReader.read(data: Data()))
        // Too many entries declared.
        let many = AOFixtures.zip([.init(name: "meta.json", data: Data("{}".utf8))], declaredEntryCount: 2001)
        XCTAssertThrowsError(try ZipArchive(data: many))
        // No meta.json.
        let noMeta = AOFixtures.zip([.init(name: "assets/x.png", data: AOFixtures.png())])
        XCTAssertThrowsError(try MoodboardReader.read(data: noMeta))
        // Truncated archive: every prefix must either throw or parse, never crash.
        let good = AOFixtures.zip([.init(name: "meta.json", data: Data("{\"board\":{}}".utf8), deflate: true)])
        for n in stride(from: 0, to: good.count, by: 3) {
            _ = try? MoodboardReader.read(data: good.prefix(n))
        }
        // Corrupt deflate payload with correct headers -> extract returns nil.
        var corrupt = AOFixtures.zip([.init(name: "x.bin", data: Data(repeating: 7, count: 500), deflate: true)])
        corrupt[40] ^= 0xFF; corrupt[41] ^= 0xFF
        if let archive = try? ZipArchive(data: corrupt), let entry = archive.entries.first {
            let out = archive.extract(entry)
            XCTAssertTrue(out == nil || out?.count == 500)
        }
        XCTAssertNil(ZipArchive.sanitizedPath("a/../../b"))
        XCTAssertNil(ZipArchive.sanitizedPath("C:/x"))
        XCTAssertNil(ZipArchive.sanitizedPath("a\\b"))
        XCTAssertEqual(ZipArchive.sanitizedPath("./assets//a.png"), "assets/a.png")
    }

    func testPaletteExtraction() {
        let redBlue = AOFixtures.image(width: 40, height: 40, rgb: (255, 0, 0), split: (0, 0, 255))
        let palette = MoodboardPalette.extract(from: [redBlue], count: 2)
        XCTAssertEqual(Set(palette), ["#FF0000", "#0000FF"])
        XCTAssertEqual(palette.first, "#FF0000", "sorted light -> dark")
        let five = MoodboardPalette.extract(from: [redBlue, AOFixtures.image(width: 10, height: 10, rgb: (255, 255, 255))], count: 5)
        XCTAssertLessThanOrEqual(five.count, 5)
        XCTAssertEqual(five.first, "#FFFFFF")
        XCTAssertTrue(five.allSatisfy { $0.count == 7 && $0.hasPrefix("#") })
        XCTAssertEqual(MoodboardPalette.extract(from: [], count: 4), [])
        XCTAssertEqual(MoodboardPalette.extract(from: [redBlue], count: 2), palette, "deterministic")
    }
}

// MARK: - Story

final class StoryFormatTests: XCTestCase {
    func testWebMlseqMultiProjectWithOrphans() throws {
        let png = AOFixtures.png()
        let json: [String: Any] = [
            "projects": [
                ["id": "p2", "index": 1, "title": "Second", "code": "SEC", "status": "Active", "aspectRatio": "2.39:1",
                 "dates": ["start": "2026-01-02", "end": "2026-02-03"], "cover_image": "img_cover1"],
                ["id": "p1", "index": 0, "title": "First", "code": "FST", "status": "Planning", "aspectRatio": "4:3",
                 "cover_image": "", "logline": "A tale", "production_notes": "notes!"],
                ["title": "no id — skipped"],
            ],
            "scenes": [
                ["id": "s2", "project_id": "p1", "index": 1, "name": "Beta", "number": 2, "location": "Beach", "int_ext": "EXT", "day_night": "NIGHT", "priority": 1, "est_duration_sec": 30, "notes": ""],
                ["id": "s1", "project_id": "p1", "index": 0, "name": "Alpha", "number": 1, "location": "Kitchen", "int_ext": "INT", "day_night": "DAY", "priority": 1, "est_duration_sec": 20, "notes": "scene note"],
                ["id": "s3", "project_id": "p2", "index": 0, "name": "Gamma", "number": 1, "location": "", "int_ext": "INT", "day_night": "DAY", "priority": 1, "est_duration_sec": 45, "notes": ""],
                ["id": "sX", "project_id": "ghost", "index": 0, "name": "Orphan scene", "number": 9],
            ],
            "shots": [
                ["id": "h2", "scene_id": "s1", "index": 1, "thumb": "https://example.invalid/x.png", "type": ["CU"], "name": "Close", "description": "face", "detailed_notes": "", "est_duration_sec": 4, "status": "Ready", "tags": ["hero"]],
                ["id": "h1", "scene_id": "s1", "index": 0, "thumb": AOFixtures.dataURL(png), "type": ["WS"], "name": "Wide", "description": "room", "detailed_notes": "dn", "est_duration_sec": 6, "status": "Planned", "tags": [],
                 "takes": [["id": "t1", "imageId": "img_take", "label": "Take 1"]]],
                ["id": "h3", "scene_id": "missing", "index": 0, "thumb": "img_abc", "name": "Lost", "est_duration_sec": "7"],
                ["id": "h4", "scene_id": "s2", "index": 0, "name": "Bad types", "type": "WS|MS", "est_duration_sec": NSNull()],
            ],
            "shotTypePresets": ["WS", "CU"],
        ]
        let doc = try StoryReader.read(data: AOFixtures.json(json))
        XCTAssertEqual(doc.projects.map(\.id), ["p1", "p2", "unassigned"])
        let p1 = doc.projects[0]
        XCTAssertEqual(p1.title, "First")
        XCTAssertEqual(p1.aspectRatio, "4:3")
        XCTAssertEqual(p1.aspectRatioValue, 4.0 / 3.0, accuracy: 1e-9)
        XCTAssertNil(p1.coverImage, "empty cover string -> nil")
        XCTAssertEqual(p1.productionNotes, "notes!")
        XCTAssertEqual(p1.scenes.map(\.id), ["s1", "s2"], "ordered by index")
        XCTAssertEqual(p1.scenes[0].shots.map(\.id), ["h1", "h2"])
        XCTAssertEqual(p1.scenes[0].slugline, "INT. KITCHEN - DAY")
        let h1 = p1.scenes[0].shots[0]
        XCTAssertEqual(h1.types, ["WS"])
        XCTAssertEqual(h1.detailedNotes, "dn")
        XCTAssertEqual(h1.thumb?.sourceKind, .dataURL)
        XCTAssertEqual(h1.thumb?.data(), png)
        XCTAssertEqual(h1.takes.first?.image?.sourceKind, .unresolvedReference)
        let h2 = p1.scenes[0].shots[1]
        XCTAssertEqual(h2.thumb?.sourceKind, .remoteURL)
        XCTAssertNil(h2.thumb?.data())
        XCTAssertEqual(p1.scenes[1].shots.first?.types, ["WS", "MS"])
        XCTAssertEqual(p1.scenes[1].shots.first?.estDurationSec, 5, "null duration -> Mac default 5")
        XCTAssertEqual(p1.estimatedDurationSec, 6 + 4 + 5)

        let p2 = doc.projects[1]
        XCTAssertEqual(p2.coverImage?.sourceKind, .unresolvedReference)
        XCTAssertEqual(p2.coverImage?.reference, "img_cover1")
        XCTAssertEqual(p2.dateStart, "2026-01-02")
        XCTAssertEqual(p2.estimatedDurationSec, 45, "scene without shots contributes its estimate")

        let un = doc.projects[2]
        XCTAssertTrue(un.isUnassigned)
        XCTAssertEqual(un.scenes.map(\.name), ["Orphan scene", "Unassigned"])
        XCTAssertEqual(un.scenes.last?.shots.map(\.id), ["h3"])
        XCTAssertEqual(un.scenes.last?.shots.first?.estDurationSec, 7, "numeric strings are accepted")
        XCTAssertTrue(un.scenes.last?.isUnassigned ?? false)

        let search = ArtOfficialSearchText.story(doc)
        XCTAssertEqual(search.title, "First")
        for term in ["A tale", "Kitchen", "Close", "face", "hero", "scene note", "Gamma", "Lost"] {
            XCTAssertTrue(search.body.contains(term), term)
        }
    }

    func testMacStryWithExtensionKeysAndSingleProjectOrphans() throws {
        let png = AOFixtures.png()
        let json: [String: Any] = [
            "projects": [["id": "proj_A", "index": 0, "title": "Mac Film", "code": "MF", "status": "Active",
                          "dates": ["start": "2026-03-01", "end": "2026-03-09"], "cover_image": AOFixtures.dataURL(png),
                          "aspect_ratio": "1:1", "audio_tracks": "[]", "audio_track_count": 3, "director": "Dee"]],
            "scenes": [["id": "scn_1", "project_id": "proj_A", "index": 0, "name": "Open", "number": 1, "location": "Street",
                        "int_ext": "EXT", "day_night": "NIGHT", "priority": 2, "est_duration_sec": 12, "notes": ""]],
            "shots": [
                ["id": "sht_1", "scene_id": "scn_1", "index": 0, "type": [], "name": "One", "description": "d", "detailed_notes": "",
                 "est_duration_sec": 3, "status": "Planned", "tags": ["t1", "t2"], "takes": [], "video_ref": "clip.mov"],
                ["id": "sht_orphan", "index": 0, "name": "Orphan"],
            ],
            "shot_templates": [],
            "audio_assets": [["id": "audio_1", "name": "Score", "file_path": "/x.wav", "bookmark": "AAAA", "project_id": "proj_A"]],
            "assembly_clips": [["id": "c1", "asset_id": "audio_1", "start_time": 0, "trim_start": 0, "trim_end": 0, "track": 0]],
            "assembly_comments": [["id": "cm", "timestamp": 1, "text": "hi", "created_at": "2026-03-01T00:00:00Z"]],
            "asset_lists": [["id": "alist_1", "project_id": "proj_A", "index": 0, "name": "Characters"]],
            "project_assets": [["id": "asset_1", "list_id": "alist_1", "index": 0, "name": "Hero Girl", "description": "lead",
                                "scene_ids": ["scn_1"], "thumb": "img_q"]],
            "scripts": [["id": "script_1", "project_id": "proj_A", "index": 0, "name": "Draft", "filename": "draft.fountain",
                         "content": "INT. STREET - NIGHT\n\nShe runs.", "added_at": "2026-03-01T00:00:00Z"]],
        ]
        let doc = try StoryReader.read(data: AOFixtures.json(json))
        XCTAssertEqual(doc.projects.count, 1, "single project absorbs orphans")
        let p = doc.projects[0]
        XCTAssertEqual(p.aspectRatio, "1:1")
        XCTAssertEqual(p.director, "Dee")
        XCTAssertEqual(p.coverImage?.data(), png)
        XCTAssertEqual(p.scenes.map(\.name), ["Open", "Unassigned"])
        XCTAssertEqual(p.scenes[1].shots.map(\.id), ["sht_orphan"])
        XCTAssertEqual(p.scenes[0].shots[0].videoRef, "clip.mov")
        XCTAssertEqual(p.scripts.first?.filename, "draft.fountain")
        XCTAssertEqual(p.assetLists.first?.assets.first?.name, "Hero Girl")
        XCTAssertEqual(p.assetLists.first?.assets.first?.thumb?.sourceKind, .unresolvedReference)
        let search = ArtOfficialSearchText.story(p).body
        XCTAssertTrue(search.contains("She runs."))
        XCTAssertTrue(search.contains("Hero Girl"))
        XCTAssertTrue(search.contains("t2"))

        XCTAssertThrowsError(try StoryReader.read(data: Data("{\"foo\": 1}".utf8)))
        XCTAssertThrowsError(try StoryReader.read(data: Data("[1,2]".utf8)))
    }

    func testStoryWriterRoundTripAndMacCompatibility() throws {
        let dir = try AOFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let big = AOFixtures.encode(AOFixtures.image(width: 2000, height: 1000, rgb: (10, 120, 200)), type: "public.png")
        let draft = StoryDraft(title: "Prompt Board", logline: "From the library", shots: [
            .init(name: "a.png", imageData: big, description: "a cinematic \"wide\" shot", tags: ["sunset", "wide"]),
            .init(name: "b.png", imageData: Data("garbage".utf8), description: "no image", tags: []),
            .init(name: "c.png", imageData: nil, description: "", tags: ["x"], types: ["CU"], estDurationSec: 8),
        ])
        let url = dir.appendingPathComponent("out.stry")
        try StoryWriter.write(draft, to: url)
        let data = try Data(contentsOf: url)

        // Must satisfy Story for Mac's strict Codable decode (ProjectIO.decode).
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        let mac = try dec.decode(MacStoryAppStateDTO.self, from: data)
        XCTAssertEqual(mac.projects.count, 1)
        XCTAssertEqual(mac.scenes.count, 1)
        XCTAssertEqual(mac.shots.count, 3)
        XCTAssertTrue(mac.projects[0].id.hasPrefix("proj_"))
        XCTAssertTrue(mac.scenes[0].id.hasPrefix("scn_"))
        XCTAssertTrue(mac.shots.allSatisfy { $0.id.hasPrefix("sht_") && $0.sceneId == mac.scenes[0].id })
        XCTAssertEqual(mac.scenes[0].projectId, mac.projects[0].id)
        XCTAssertEqual(mac.projects[0].aspectRatio, "16:9")
        XCTAssertEqual(mac.projects[0].code, "PB")
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        XCTAssertNotNil(mac.projects[0].dates?.start.flatMap(df.date(from:)))
        XCTAssertTrue(mac.shots[0].thumb?.hasPrefix("data:image/jpeg;base64,") ?? false)
        XCTAssertEqual(mac.shots[1].thumb, "")
        // Web validation: top-level arrays.
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["projects", "scenes", "shots", "scripts", "asset_lists", "project_assets"] {
            XCTAssertNotNil(root[key] as? [Any], key)
        }
        XCTAssertNil(root["shotTypePresets"], "omitted so the web app keeps its default presets")

        let doc = try StoryReader.read(from: url)
        let p = try XCTUnwrap(doc.projects.first)
        XCTAssertEqual(p.title, "Prompt Board")
        XCTAssertEqual(p.logline, "From the library")
        XCTAssertEqual(p.scenes.count, 1)
        let shots = p.scenes[0].shots
        XCTAssertEqual(shots.map(\.name), ["a.png", "b.png", "c.png"])
        XCTAssertEqual(shots[0].description, "a cinematic \"wide\" shot")
        XCTAssertEqual(shots[0].tags, ["sunset", "wide"])
        XCTAssertEqual(shots[2].types, ["CU"])
        XCTAssertEqual(shots[2].estDurationSec, 8)
        XCTAssertNil(shots[1].thumb)
        let size = try XCTUnwrap(shots[0].thumb?.pixelSize())
        XCTAssertEqual(max(size.width, size.height), CGFloat(StoryWriter.maxThumbPixelSize))
        XCTAssertEqual(shots[0].thumb?.mimeType, "image/jpeg")
        XCTAssertEqual(p.estimatedDurationSec, 5 + 5 + 8)
    }
}

// MARK: - Images, rendering, detection, previews

final class ArtOfficialImageAndRenderTests: XCTestCase {
    func testDataURLDecoding() {
        let png = AOFixtures.png()
        let b64 = png.base64EncodedString()
        XCTAssertEqual(EmbeddedImage.parse(AOFixtures.dataURL(png))?.data(), png)
        // Line-wrapped base64 and URL-safe alphabet are tolerated.
        let wrapped = stride(from: 0, to: b64.count, by: 60).map { i -> String in
            let s = b64.index(b64.startIndex, offsetBy: i)
            return String(b64[s..<(b64.index(s, offsetBy: 60, limitedBy: b64.endIndex) ?? b64.endIndex)])
        }.joined(separator: "\n")
        XCTAssertEqual(EmbeddedImage.parse("data:image/png;base64,\(wrapped)")?.data(), png)
        let urlSafe = b64.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(EmbeddedImage.dataURL("data:image/png;base64,\(urlSafe)")?.data(), png)
        // Malformed.
        let bad = EmbeddedImage.dataURL("data:image/png;base64,@@@not*base64!!")
        XCTAssertNotNil(bad)
        XCTAssertNil(bad?.data())
        XCTAssertNil(bad?.cgImage(maxPixelSize: 64))
        XCTAssertNil(EmbeddedImage.dataURL("data:image/png;base64"), "no comma")
        XCTAssertNil(EmbeddedImage.dataURL("data:image/png;base64,A")?.data())
        let notImage = EmbeddedImage.dataURL("data:image/png;base64,\(Data("hello".utf8).base64EncodedString())")
        XCTAssertNotNil(notImage?.data())
        XCTAssertNil(notImage?.cgImage(maxPixelSize: 64), "valid base64 but not an image")
        // Non-base64 (percent-encoded) data URL.
        let svg = EmbeddedImage.dataURL("data:image/svg+xml;utf8,%3Csvg%3E%3C/svg%3E")
        XCTAssertEqual(svg?.mimeType, "image/svg+xml")
        XCTAssertEqual(svg.flatMap { $0.data() }.map { String(decoding: $0, as: UTF8.self) }, "<svg></svg>")
        // Bare base64 and thumbnails.
        let bare = EmbeddedImage.parse(b64)
        XCTAssertEqual(bare?.sourceKind, .base64)
        let thumb = bare?.cgImage(maxPixelSize: 8)
        XCTAssertEqual(thumb.map { max($0.width, $0.height) }, 8)
        XCTAssertNil(EmbeddedImage.parse("   "))
    }

    func testRemoteAndReferenceImagesAreNeverFetched() {
        for s in ["https://127.0.0.1:1/never.png", "http://example.invalid/a.jpg", "blob:https://x/y"] {
            let img = EmbeddedImage.parse(s)
            XCTAssertEqual(img?.sourceKind, .remoteURL, s)
            XCTAssertEqual(img?.reference, s)
            XCTAssertFalse(img?.isResolvable ?? true)
            XCTAssertNil(img?.data())
            XCTAssertNil(img?.cgImage(maxPixelSize: 32))
        }
        let ref = EmbeddedImage.parse("img_1712345_abc")
        XCTAssertEqual(ref?.sourceKind, .unresolvedReference)
        XCTAssertNil(ref?.data())
        XCTAssertFalse(ref?.isResolvable ?? true)
    }

    func testFileAndRelativeImages() throws {
        let dir = try AOFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = AOFixtures.png()
        try png.write(to: dir.appendingPathComponent("pic.png"))
        XCTAssertEqual(EmbeddedImage.parse(dir.appendingPathComponent("pic.png").path)?.data(), png)
        XCTAssertEqual(EmbeddedImage.parse("pic.png", relativeTo: dir)?.data(), png)
        XCTAssertEqual(EmbeddedImage.parse("pic.png", relativeTo: dir)?.mimeType, "image/png")
        XCTAssertNil(EmbeddedImage.parse("../pic.png", relativeTo: dir)?.data())
    }

    func testMoodboardRendering() throws {
        let images = (0..<14).map { i in
            MoodboardDraft.Image(name: "\(i).png", data: AOFixtures.png(width: 30 + i, height: 20, rgb: (UInt8(i * 15), 80, 160)), mimeType: "image/png")
        }
        for mode in Moodboard.LayoutMode.allCases {
            let draft = MoodboardDraft(title: "Render", images: images, layoutMode: mode, columns: 4)
            let board = try MoodboardReader.read(data: MoodboardWriter.encode(draft))
            let image = try XCTUnwrap(ArtOfficialRenderer.renderMoodboard(board, maxPixelSize: 512), "\(mode)")
            XCTAssertEqual(max(image.width, image.height), 512)
        }
        // No images at all: colour tiles, empty board, fixed aspect, undecodable asset.
        var board = Moodboard()
        board.aspectRatio = "16:9"
        board.tiles = [MoodboardTile(id: "c", colSpan: 2, content: .color(hex: "#FF8800")),
                       MoodboardTile(id: "t", content: .text("Words", textHex: nil, backgroundHex: "#EEEEEE", fontSize: 20, alignment: "center", bold: true))]
        board.assets = [MoodboardAsset(id: "x", name: "x", kind: .image, image: EmbeddedImage.parse("img_nope")!)]
        board.tiles.append(MoodboardTile(id: "i", content: .image(assetId: "x", pan: .zero, zoom: 1)))
        let colorOnly = try XCTUnwrap(ArtOfficialRenderer.renderMoodboard(board, maxPixelSize: 300))
        XCTAssertEqual(colorOnly.width, 300)
        XCTAssertEqual(colorOnly.height, 169)
        let empty = try XCTUnwrap(ArtOfficialRenderer.renderMoodboard(Moodboard(), maxPixelSize: 256))
        XCTAssertEqual(max(empty.width, empty.height), 256)
        XCTAssertNil(ArtOfficialRenderer.renderMoodboard(Moodboard(), maxPixelSize: 0))
        // Deterministic output.
        let a = ArtOfficialRenderer.renderMoodboard(board, maxPixelSize: 120)!
        let b = ArtOfficialRenderer.renderMoodboard(board, maxPixelSize: 120)!
        XCTAssertEqual(a.dataProvider?.data as Data?, b.dataProvider?.data as Data?)
    }

    func testStoryRendering() throws {
        let png = AOFixtures.png(width: 64, height: 36)
        let shots = (0..<11).map { i in
            StoryShot(id: "s\(i)", index: i, name: "Shot \(i)", description: "desc \(i)",
                      thumb: i % 3 == 0 ? nil : (i % 3 == 1 ? EmbeddedImage(data: png, mimeType: "image/png") : EmbeddedImage.parse("img_x")))
        }
        var project = StoryProject(id: "p", title: "A Very Long Project Title That Should Truncate Nicely In The Band",
                                   code: "AVL", logline: "Logline", scenes: [StoryScene(id: "sc", name: "One", shots: shots)])
        for count in [0, 1, 3, 11] {
            project.scenes[0].shots = Array(shots.prefix(count))
            let sheet = try XCTUnwrap(ArtOfficialRenderer.renderStoryContactSheet(project, maxPixelSize: 400))
            XCTAssertEqual(max(sheet.width, sheet.height), 400)
        }
        project.coverImage = EmbeddedImage(data: png, mimeType: "image/png")
        let cover = try XCTUnwrap(ArtOfficialRenderer.renderStoryContactSheet(project, maxPixelSize: 333))
        XCTAssertEqual(cover.width, 333)
        project.scenes[0].shots = shots
        for shot in shots.prefix(3) {
            let frame = try XCTUnwrap(ArtOfficialRenderer.renderStoryShot(shot, project: project, maxPixelSize: 640))
            XCTAssertEqual(frame.width, 640)
            XCTAssertGreaterThan(frame.width, frame.height)
        }
        XCTAssertNotNil(ArtOfficialRenderer.renderStoryShot(shots[1], project: nil, maxPixelSize: 100))
    }

    func testFileKindDetection() {
        XCTAssertEqual(ArtOfficialFileKind.detect(url: URL(fileURLWithPath: "/a/b.MLMBOARD")), .moodboard)
        XCTAssertEqual(ArtOfficialFileKind.detect(url: URL(fileURLWithPath: "/a/b.stry")), .story)
        XCTAssertEqual(ArtOfficialFileKind.detect(url: URL(fileURLWithPath: "/a/b.mlseq")), .storyLegacy)
        XCTAssertEqual(ArtOfficialFileKind.detect(url: URL(fileURLWithPath: "/a/b.plib")), .promptLibrary)
        XCTAssertEqual(ArtOfficialFileKind.detect(url: URL(fileURLWithPath: "/a/b.aoe")), .elements)
        XCTAssertNil(ArtOfficialFileKind.detect(url: URL(fileURLWithPath: "/a/b.png")))
        XCTAssertEqual(ArtOfficialFileKind.moodboard.typeIdentifier, "com.artofficial.mood.mlmboard")
        XCTAssertEqual(ArtOfficialFileKind.story.typeIdentifier, "com.artofficial.story.project")
        XCTAssertEqual(ArtOfficialFileKind.storyLegacy.typeIdentifier, "com.artofficial.story.mlseq")
        XCTAssertEqual(ArtOfficialFileKind.promptLibrary.typeIdentifier, "com.artofficial.plib")
        XCTAssertEqual(ArtOfficialFileKind.elements.typeIdentifier, "com.artofficial.aoe")
        XCTAssertEqual(ArtOfficialTypeIdentifiers.all.count, 5)
    }

    func testPlibAndAoePreviews() throws {
        let dir = try AOFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = AOFixtures.png()
        try png.write(to: dir.appendingPathComponent("side.png"))
        let plib: [String: Any] = [
            "prompt": "a cat astronaut", "images": [AOFixtures.dataURL(png), "side.png", png.base64EncodedString()],
            "referenceImages": ["https://example.invalid/ref.png"],
            "generationInfo": ["model": "Imagen", "aspectRatio": "1:1", "timestamp": "x", "numberOfImages": 1],
        ]
        let plibURL = dir.appendingPathComponent("Cat.plib")
        try AOFixtures.json(plib).write(to: plibURL)
        let p = try XCTUnwrap(PlibPreview.read(from: plibURL))
        XCTAssertEqual(p.title, "Cat")
        XCTAssertEqual(p.prompt, "a cat astronaut")
        XCTAssertEqual(p.model, "Imagen")
        XCTAssertEqual(p.images.map(\.sourceKind), [.dataURL, .file, .base64])
        XCTAssertTrue(p.images.allSatisfy { $0.data() == png })
        XCTAssertEqual(p.referenceImages.first?.sourceKind, .remoteURL)
        XCTAssertNil(PlibPreview.read(data: Data("{}".utf8), fileURL: nil))
        XCTAssertNil(PlibPreview.read(data: Data("nope".utf8), fileURL: nil))

        let aoe: [String: Any] = [
            "timestamp": 1_700_000_000_000, "model": "Elements",
            "image": ["previewUrl": "https://example.invalid/p.png", "base64": png.base64EncodedString(), "mimeType": "image/png"],
            "analysis": ["full_prompt": "", "short_description": "short one"],
        ]
        let a = try XCTUnwrap(AoePreview.read(data: AOFixtures.json(aoe), fileURL: URL(fileURLWithPath: "/x/Snap.aoe")))
        XCTAssertEqual(a.title, "Snap")
        XCTAssertEqual(a.prompt, "short one")
        XCTAssertEqual(a.images.first?.sourceKind, .base64, "remote previewUrl ignored in favour of base64")
        XCTAssertEqual(a.images.first?.data(), png)
        XCTAssertEqual(a.images.first?.mimeType, "image/png")
    }

    func testMoodboardSearchText() throws {
        var board = try MoodboardReader.read(data: MoodboardWriter.encode(MoodboardDraft(
            title: "Autumn", subtitle: "Client X",
            images: [.init(name: "leaf.png", data: AOFixtures.png(), mimeType: "image/png")])))
        board.tiles.append(MoodboardTile(id: "t", caption: "cap", content: .text("warm tones", textHex: nil, backgroundHex: nil, fontSize: nil, alignment: nil, bold: false)))
        let s = ArtOfficialSearchText.moodboard(board)
        XCTAssertEqual(s.title, "Autumn")
        for term in ["Client X", "leaf.png", "warm tones", "cap", "#FFFFFF"] { XCTAssertTrue(s.body.contains(term), term) }
    }
}

// MARK: - Mirrors of the owner apps' strict Codable decoders

/// Subset of Story for Mac's `AppStateDTO` (ProjectIO.swift) with the same
/// non-optional requirements, decoded with `convertFromSnakeCase`.
private struct MacStoryAppStateDTO: Decodable {
    struct Dates: Decodable { var start: String?; var end: String? }
    struct Project: Decodable {
        var id: String; var index: Int?; var title: String?; var code: String?; var status: String?
        var dates: Dates?; var coverImage: String?; var aspectRatio: String?; var logline: String?
    }
    struct Scene: Decodable {
        var id: String; var projectId: String?; var index: Int?; var name: String?; var number: Int?
        var location: String?; var intExt: String?; var dayNight: String?; var priority: Int?
        var estDurationSec: Int?; var notes: String?
    }
    struct Take: Decodable { var id: String; var imageId: String?; var label: String? }
    struct Shot: Decodable {
        var id: String; var sceneId: String?; var index: Int?; var thumb: String?; var type: [String]?
        var name: String?; var description: String?; var detailedNotes: String?; var estDurationSec: Int?
        var status: String?; var tags: [String]?; var takes: [Take]?; var videoRef: String?
    }
    struct IDOnly: Decodable { var id: String }
    var projects: [Project]
    var scenes: [Scene]
    var shots: [Shot]
    var shotTypePresets: [String]?
    var shotTemplates: [IDOnly]?
    var audioAssets: [IDOnly]?
    var assemblyClips: [IDOnly]?
    var assemblyComments: [IDOnly]?
    var assetLists: [IDOnly]?
    var projectAssets: [IDOnly]?
    var scripts: [IDOnly]?
}

/// Subset of Mac Mood's `WebProjectFile` (ProjectFileCodec.swift): Int-typed layout options.
private struct MacMoodWebProjectFile: Decodable {
    struct Asset: Decodable { var id: String; var url: String?; var name: String?; var type: String? }
    struct Item: Decodable {
        struct Position: Decodable { var x: Double; var y: Double }
        var id: String?; var type: String?; var assetId: String?; var colSpan: Int?; var rowSpan: Int?
        var position: Position?; var zoom: Double?
    }
    struct Layout: Decodable {
        var zoom: Int?; var columns: Int?; var gap: Int?; var boardPadding: Int?; var roundedCorners: Bool?
        var softShadow: Bool?; var safeMargin: Int?; var aspectRatio: String?; var imageBorder: Bool?
        var imageBorderWidth: Int?; var imageBorderColor: String?
    }
    struct Branding: Decodable {
        var font: String?; var palette: [String]?; var customPalette: [String]?; var backgroundColor: String?
        var textColor: String?; var title: String?; var subtitle: String?
    }
    var assets: [Asset]?
    var canvasItems: [Item]?
    var layoutMode: String?
    var layoutOptions: Layout?
    var branding: Branding?
}
