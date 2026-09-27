import AVFoundation
import XCTest
@testable import PromptLibraryExplorer

final class ExportMediaTests: TempDirectoryTestCase {
    /// A two-frame H.264 .mov carrying a description / comment, like ComfyUI video nodes write.
    private func makeMovie(at url: URL, comment: String) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let description = AVMutableMetadataItem()
        description.keySpace = .quickTimeMetadata
        description.key = AVMetadataKey.quickTimeMetadataKeyDescription as NSString
        description.value = comment as NSString
        let commentItem = AVMutableMetadataItem()
        commentItem.keySpace = .quickTimeMetadata
        commentItem.key = AVMetadataKey.quickTimeMetadataKeyComment as NSString
        commentItem.value = comment as NSString
        writer.metadata = [description, commentItem]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<2 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
    }

    private func metadataValues(_ url: URL) async throws -> [String] {
        let items = try await AVURLAsset(url: url).load(.metadata)
        var values: [String] = []
        for item in items {
            if let value = try? await item.load(.stringValue) { values.append(value) }
        }
        return values
    }

    func testStripRemovesMovieMetadataWithoutReencoding() async throws {
        let source = tempDir.appendingPathComponent("clip.mov")
        try await makeMovie(at: source, comment: "secret video prompt")
        let before = try await metadataValues(source)
        XCTAssertTrue(before.contains("secret video prompt"), "fixture carries metadata: \(before)")

        let temp = tempDir.appendingPathComponent("out.mov")
        let note = try await ExportEngine.exportMedia(source: source, to: temp, strip: true)
        XCTAssertNil(note)
        let after = try await metadataValues(temp)
        XCTAssertFalse(after.contains("secret video prompt"), "metadata left: \(after)")
        let duration = try await AVURLAsset(url: temp).load(.duration)
        XCTAssertGreaterThan(duration.seconds, 0)
    }

    func testUnsupportedContainersAreCopiedAndSaySo() async throws {
        let source = try writeFile("sound.wav", WAVFixture.riff([WAVFixture.chunk("data", WAVFixture.audioBytes(16))]))
        let temp = tempDir.appendingPathComponent("out.wav")
        let note = try await ExportEngine.exportMedia(source: source, to: temp, strip: true)
        XCTAssertNotNil(note)
        XCTAssertEqual(try Data(contentsOf: temp), try Data(contentsOf: source))
    }
}
