import XCTest
@testable import PromptLibraryExplorer

final class AudioMetadataTests: TempDirectoryTestCase {
    /// A fresh parser per read so the in-memory cache never masks a rewrite.
    private func read(_ url: URL) async -> AudioMetadataParser.Metadata {
        await AudioMetadataParser().parse(at: url)
    }

    // MARK: WAV

    func testWAVInfoRoundTripKeepsAudioAndUnknownItems() async throws {
        let audio = WAVFixture.audioBytes(1000)
        let original = WAVFixture.riff([
            WAVFixture.fmt,
            WAVFixture.info([("INAM", "Old Title"), ("IENG", "Some Engineer"), ("ICMT", "old comment")]),
            WAVFixture.chunk("data", audio),
        ])
        let url = try writeFile("tone.wav", original)

        let before = await read(url)
        XCTAssertEqual(before.tags.title, "Old Title")
        XCTAssertEqual(before.tags.comment, "old comment")

        var tags = AudioTagMetadata()
        tags.title = "New Title"
        tags.artist = "Ärtist"
        tags.date = "2026"
        try AudioMetadataWriter.write(tags, to: url)

        let after = await read(url)
        XCTAssertEqual(after.tags.title, "New Title")
        XCTAssertEqual(after.tags.artist, "Ärtist")
        XCTAssertEqual(after.tags.date, "2026")
        XCTAssertEqual(after.tags.comment, "", "empty comment removes the old one")

        let written = try Data(contentsOf: url)
        let chunks = WAVFixture.chunks(written)
        XCTAssertEqual(chunks.map(\.id), ["fmt ", "LIST", "data"], "INFO stays where it was")
        XCTAssertEqual(chunks.first { $0.id == "data" }?.payload, audio)
        XCTAssertEqual(chunks.first { $0.id == "fmt " }?.payload, WAVFixture.chunks(original).first?.payload)
        let items = WAVFixture.infoItems(try XCTUnwrap(chunks.first { $0.id == "LIST" }))
        XCTAssertTrue(items.contains { $0.id == "IENG" && $0.payload == Data("Some Engineer\0".utf8) })
        XCTAssertTrue(items.contains { $0.id == "ISFT" })

        // RIFF size is consistent.
        let riffSize = Int(written[4]) | Int(written[5]) << 8 | Int(written[6]) << 16 | Int(written[7]) << 24
        XCTAssertEqual(riffSize, written.count - 8)
    }

    func testWAVWithoutInfoGetsListBeforeData() async throws {
        let audio = WAVFixture.audioBytes(64)
        let url = try writeFile("plain.wav", WAVFixture.riff([WAVFixture.fmt, WAVFixture.chunk("data", audio)]))
        var tags = AudioTagMetadata()
        tags.title = "Fresh"
        try AudioMetadataWriter.write(tags, to: url)
        let chunks = WAVFixture.chunks(try Data(contentsOf: url))
        XCTAssertEqual(chunks.map(\.id), ["fmt ", "LIST", "data"])
        XCTAssertEqual(chunks.last?.payload, audio)
        let title = await read(url).tags.title
        XCTAssertEqual(title, "Fresh")
    }

    func testWAVOversizedFinalDataChunkKeepsAudioBytes() async throws {
        let audio = WAVFixture.audioBytes(1001) // odd, no pad byte
        var data = WAVFixture.riff([WAVFixture.fmt], declaredSize: 0xFFFF_FFFF)
        data.append(WAVFixture.chunk("data", audio, declaredSize: 0xFFFF_FFFF))
        let url = try writeFile("stream.wav", data)

        var tags = AudioTagMetadata()
        tags.title = "Streamed"
        try AudioMetadataWriter.write(tags, to: url)

        let written = try Data(contentsOf: url)
        let chunks = WAVFixture.chunks(written)
        let dataChunk = try XCTUnwrap(chunks.first { $0.id == "data" })
        XCTAssertEqual(dataChunk.payload, audio)
        let declared = Int(written[dataChunk.payload.startIndex - 4]) | Int(written[dataChunk.payload.startIndex - 3]) << 8
            | Int(written[dataChunk.payload.startIndex - 2]) << 16 | Int(written[dataChunk.payload.startIndex - 1]) << 24
        XCTAssertEqual(declared, audio.count, "data size is fixed to the real length")
        let title = await read(url).tags.title
        XCTAssertEqual(title, "Streamed")
    }

    func testWAVTruncatedNonDataChunkThrowsAndLeavesFile() throws {
        var data = WAVFixture.riff([WAVFixture.fmt, WAVFixture.chunk("data", WAVFixture.audioBytes(100))])
        data.append(Data("LIST".utf8))
        data.append(littleEndian(500)) // claims 500 bytes, only 10 follow
        data.append(Data("INFOabcdef".utf8))
        let url = try writeFile("trunc.wav", data)

        var tags = AudioTagMetadata()
        tags.title = "x"
        XCTAssertThrowsError(try AudioMetadataWriter.write(tags, to: url))
        assertFileUnchanged(url, data)
    }

    func testWAVGarbledChunkIDThrowsAndLeavesFile() throws {
        var data = WAVFixture.riff([WAVFixture.fmt])
        data.append(Data([0x00, 0xFF, 0x01, 0x02]))
        data.append(littleEndian(4))
        data.append(Data([1, 2, 3, 4]))
        data.append(WAVFixture.chunk("data", WAVFixture.audioBytes(20)))
        let url = try writeFile("garbled.wav", data)

        var tags = AudioTagMetadata()
        tags.title = "x"
        XCTAssertThrowsError(try AudioMetadataWriter.write(tags, to: url))
        assertFileUnchanged(url, data)
    }

    func testWAVWithoutDataChunkThrows() throws {
        let data = WAVFixture.riff([WAVFixture.fmt])
        let url = try writeFile("nodata.wav", data)
        var tags = AudioTagMetadata()
        tags.title = "x"
        XCTAssertThrowsError(try AudioMetadataWriter.write(tags, to: url))
        assertFileUnchanged(url, data)
    }

    func testNotAWAVThrows() throws {
        let data = Data("RIFX0000AVI garbage".utf8)
        let url = try writeFile("fake.wav", data)
        var tags = AudioTagMetadata()
        tags.title = "x"
        XCTAssertThrowsError(try AudioMetadataWriter.write(tags, to: url))
        assertFileUnchanged(url, data)
    }

    // MARK: MP3

    private func apicPayload() -> Data {
        var p = Data([0])
        p.append(Data("image/png".utf8))
        p.append(0)
        p.append(3) // front cover
        p.append(Data("cover".utf8))
        p.append(0)
        p.append(Data((0..<300).map { UInt8(truncatingIfNeeded: $0 * 7) }))
        return p
    }

    private func txxxPayload() -> Data {
        var p = Data([0])
        p.append(Data("REPLAYGAIN_TRACK_GAIN".utf8))
        p.append(0)
        p.append(Data("-6.5 dB".utf8))
        return p
    }

    private func itunNormPayload() -> Data {
        var p = Data([0])
        p.append(Data("eng".utf8))
        p.append(Data("iTunNORM".utf8))
        p.append(0)
        p.append(Data(" 000001F4 00000200 00001234 00001111".utf8))
        return p
    }

    func testMP3TitleEditKeepsOtherFramesAndAudio() async throws {
        let apic = apicPayload(), txxx = txxxPayload(), comm = itunNormPayload()
        var body = Data()
        body.append(ID3Fixture.frameV23("TIT2", ID3Fixture.latin1Text("Old Title")))
        body.append(ID3Fixture.frameV23("APIC", apic))
        body.append(ID3Fixture.frameV23("TXXX", txxx))
        body.append(ID3Fixture.frameV23("COMM", comm))
        body.append(Data(count: 64)) // padding
        let audio = ID3Fixture.fakeAudio(2048)
        var original = ID3Fixture.tag(version: 3, body: body)
        original.append(audio)
        let url = try writeFile("song.mp3", original)

        let before = await read(url)
        XCTAssertEqual(before.tags.title, "Old Title")

        var tags = AudioTagMetadata()
        tags.title = "New Title"
        try AudioMetadataWriter.write(tags, to: url)

        let written = try Data(contentsOf: url)
        let tag = try XCTUnwrap(ID3Fixture.parse(written))
        XCTAssertEqual(tag.version, 3, "v2.3 tags keep their version")
        XCTAssertEqual(written.suffix(from: tag.tagEnd), audio, "audio bytes must be identical")
        XCTAssertEqual(written.count - tag.tagEnd, audio.count)

        func frame(_ id: String) -> ID3Fixture.Frame? { tag.frames.first { $0.id == id } }
        XCTAssertEqual(frame("APIC")?.payload, apic)
        XCTAssertEqual(frame("APIC")?.flags, Data([0, 0]))
        XCTAssertEqual(frame("TXXX")?.payload, txxx)
        XCTAssertEqual(frame("COMM")?.payload, comm, "described (iTunNORM) comments are kept")
        XCTAssertEqual(tag.frames.filter { $0.id == "TIT2" }.count, 1)
        XCTAssertEqual(frame("TIT2")?.payload, ID3Fixture.latin1Text("New Title"))

        let after = await read(url)
        XCTAssertEqual(after.tags.title, "New Title")
    }

    func testMP3CommentEditReplacesOnlyUndescribedComment() async throws {
        var plainComment = Data([0])
        plainComment.append(Data("eng".utf8))
        plainComment.append(0) // empty description
        plainComment.append(Data("old plain comment".utf8))
        var body = Data()
        body.append(ID3Fixture.frameV23("COMM", itunNormPayload()))
        body.append(ID3Fixture.frameV23("COMM", plainComment))
        var original = ID3Fixture.tag(version: 3, body: body)
        original.append(ID3Fixture.fakeAudio(100))
        let url = try writeFile("c.mp3", original)

        var tags = AudioTagMetadata()
        tags.comment = "new plain comment"
        try AudioMetadataWriter.write(tags, to: url)

        let comms = try XCTUnwrap(ID3Fixture.parse(try Data(contentsOf: url))).frames.filter { $0.id == "COMM" }
        XCTAssertEqual(comms.count, 2)
        XCTAssertTrue(comms.contains { $0.payload == itunNormPayload() })
        XCTAssertFalse(comms.contains { $0.payload == plainComment })
        let comment = await read(url).tags.comment
        XCTAssertEqual(comment, "new plain comment")
    }

    func testMP3WithoutTagGetsV24Tag() async throws {
        let audio = ID3Fixture.fakeAudio(500)
        let url = try writeFile("bare.mp3", audio)
        var tags = AudioTagMetadata()
        tags.title = "Tïtle"
        tags.artist = "Band"
        try AudioMetadataWriter.write(tags, to: url)
        let written = try Data(contentsOf: url)
        let tag = try XCTUnwrap(ID3Fixture.parse(written))
        XCTAssertEqual(tag.version, 4)
        XCTAssertEqual(written.suffix(from: tag.tagEnd), audio)
        let after = await read(url)
        XCTAssertEqual(after.tags.title, "Tïtle")
        XCTAssertEqual(after.tags.artist, "Band")
    }

    func testMP3TagLargerThanFileThrows() throws {
        var body = ID3Fixture.frameV23("TIT2", ID3Fixture.latin1Text("x"))
        body.append(Data(count: 10))
        var data = ID3Fixture.tag(version: 3, body: body)
        data.replaceSubrange(6..<10, with: ID3Fixture.syncsafe(100_000))
        let url = try writeFile("bad.mp3", data)
        var tags = AudioTagMetadata()
        tags.title = "y"
        XCTAssertThrowsError(try AudioMetadataWriter.write(tags, to: url))
        assertFileUnchanged(url, data)
    }

    func testReadsID3v22() async throws {
        var body = Data()
        body.append(ID3Fixture.frameV22("TT2", ID3Fixture.latin1Text("Old School")))
        body.append(ID3Fixture.frameV22("TP1", ID3Fixture.latin1Text("Legacy Artist")))
        body.append(ID3Fixture.frameV22("TAL", ID3Fixture.latin1Text("Vintage")))
        var data = ID3Fixture.tag(version: 2, body: body)
        data.append(ID3Fixture.fakeAudio(64))
        let url = try writeFile("v22.mp3", data)

        let meta = await read(url)
        XCTAssertEqual(meta.tags.title, "Old School")
        XCTAssertEqual(meta.tags.artist, "Legacy Artist")
        XCTAssertEqual(meta.tags.album, "Vintage")
        XCTAssertTrue(meta.searchText.contains("Legacy Artist"))
    }

    func testWritingID3v22UpgradesToV23() async throws {
        var body = Data()
        body.append(ID3Fixture.frameV22("TT2", ID3Fixture.latin1Text("Old")))
        body.append(ID3Fixture.frameV22("TP1", ID3Fixture.latin1Text("Keep Me")))
        let audio = ID3Fixture.fakeAudio(64)
        var data = ID3Fixture.tag(version: 2, body: body)
        data.append(audio)
        let url = try writeFile("v22w.mp3", data)

        var tags = AudioTagMetadata()
        tags.title = "New"
        tags.artist = "Keep Me"
        try AudioMetadataWriter.write(tags, to: url)
        let written = try Data(contentsOf: url)
        let tag = try XCTUnwrap(ID3Fixture.parse(written))
        XCTAssertEqual(tag.version, 3)
        XCTAssertEqual(written.suffix(from: tag.tagEnd), audio)
        let meta = await read(url)
        XCTAssertEqual(meta.tags.title, "New")
        XCTAssertEqual(meta.tags.artist, "Keep Me")
    }

    func testExtendedHeaderIsSkipped() async throws {
        // v2.3 extended header: size (6, excluding itself), 2 flag bytes, 4-byte padding size.
        var body = Data()
        body.append(bigEndian(6))
        body.append(contentsOf: [0, 0])
        body.append(bigEndian(0))
        body.append(ID3Fixture.frameV23("TIT2", ID3Fixture.latin1Text("Behind Ext Header")))
        body.append(ID3Fixture.frameV23("TPE1", ID3Fixture.latin1Text("Ext Artist")))
        var data = ID3Fixture.tag(version: 3, flags: 0x40, body: body)
        let audio = ID3Fixture.fakeAudio(64)
        data.append(audio)
        let url = try writeFile("ext.mp3", data)

        let meta = await read(url)
        XCTAssertEqual(meta.tags.title, "Behind Ext Header")
        XCTAssertEqual(meta.tags.artist, "Ext Artist")

        // Rewriting drops the extended header but keeps frames and audio.
        var tags = AudioTagMetadata()
        tags.title = "Rewritten"
        tags.artist = "Ext Artist"
        try AudioMetadataWriter.write(tags, to: url)
        let written = try Data(contentsOf: url)
        let tag = try XCTUnwrap(ID3Fixture.parse(written))
        XCTAssertEqual(written.suffix(from: tag.tagEnd), audio)
        let rewritten = await read(url).tags.title
        XCTAssertEqual(rewritten, "Rewritten")
    }

    func testUnsupportedAudioFormatThrows() throws {
        let url = try writeFile("song.flac", Data([1, 2, 3]))
        XCTAssertThrowsError(try AudioMetadataWriter.write(AudioTagMetadata(), to: url))
    }
}
