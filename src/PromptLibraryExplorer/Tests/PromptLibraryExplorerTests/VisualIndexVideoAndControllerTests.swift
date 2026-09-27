import AVFoundation
import CoreVideo
import XCTest
@testable import PromptLibraryExplorer

enum VideoFixture {
    /// Writes an H.264 .mov whose frame `i` is filled with `color(i)` (RGB 0…255).
    static func write(
        to url: URL,
        width: Int = 128,
        height: Int = 96,
        fps: Int32 = 10,
        frames: Int,
        color: (Int) -> (UInt8, UInt8, UInt8)
    ) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
            let pixelBuffer = try XCTUnwrap(buffer)
            let (r, g, b) = color(frame)
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            let base = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
            let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
            for y in 0..<height {
                for x in 0..<width {
                    let offset = y * rowBytes + x * 4
                    base[offset] = b; base[offset + 1] = g; base[offset + 2] = r; base[offset + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            XCTAssertTrue(adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(frame), timescale: fps)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: Int64(frames), timescale: fps))
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
    }
}

final class VisualIndexVideoTests: VisualIndexTestCase {

    private func nearestShare(_ colors: [DominantColor], to hex: String) -> Double {
        let target = OKLab(hex: hex)!
        return colors.filter { OKLab(hex: $0.hex)!.distance(to: target) < 0.08 }.reduce(0) { $0 + $1.weight }
    }

    func testVideoSignatureUsesMiddleFrame() async throws {
        // 3 s at 10 fps: blue until 1.2 s, red 1.2–1.8 s, green after — the middle is red.
        let url = library.appendingPathComponent("clip.mov")
        try await VideoFixture.write(to: url, frames: 30) { frame in
            frame < 12 ? (0, 0, 255) : frame < 18 ? (255, 0, 0) : (0, 200, 0)
        }
        await service.indexLibrary(root: library)
        let signatures = await service.signatures(forPaths: [url.path])
        let signature = try XCTUnwrap(signatures[url.path])
        XCTAssertTrue(signature.isVideo)
        XCTAssertEqual(signature.pixelWidth, 128)
        XCTAssertEqual(signature.pixelHeight, 96)
        XCTAssertGreaterThan(nearestShare(signature.dominantColors, to: "#FF0000"), 0.8, "\(signature.dominantColors)")

        let withoutVideos = await service.similarSets(in: .folder(library), strictness: 0, includeVideos: false)
        XCTAssertTrue(withoutVideos.isEmpty)
    }

    func testShortClipUsesFirstFrame() async throws {
        // 0.5 s: yellow first frame, then magenta.
        let url = library.appendingPathComponent("short.mov")
        try await VideoFixture.write(to: url, frames: 5) { frame in frame == 0 ? (255, 220, 0) : (255, 0, 255) }
        let extracted = await VisualSignatureExtractor.videoFrame(url: url)
        let frame = try XCTUnwrap(extracted)
        let colors = VisualSignatureExtractor.dominantColors(frame.image)
        XCTAssertGreaterThan(nearestShare(colors, to: "#FFDC00"), 0.8, "\(colors)")
    }

    func testDuplicateVideosFormExactSetAndCanBeExcluded() async throws {
        let a = library.appendingPathComponent("take.mov")
        try await VideoFixture.write(to: a, frames: 20) { frame in (UInt8(frame * 12), 40, 90) }
        try FileManager.default.copyItem(at: a, to: library.appendingPathComponent("take copy.mov"))
        try put("still.png", VisualFixture.png(VisualFixture.scene(seed: 55, width: 300, height: 200)))
        await service.indexLibrary(root: library)

        let sets = await service.similarSets(in: .folder(library), strictness: 0.5, includeVideos: true)
        XCTAssertEqual(sets.filter { $0.kind == .exact }.map(\.paths), [[path("take copy.mov"), path("take.mov")]])
        let noVideos = await service.similarSets(in: .folder(library), strictness: 0.5, includeVideos: false)
        XCTAssertTrue(noVideos.isEmpty)
    }
}

@MainActor
final class VisualIndexControllerTests: VisualIndexTestCase {
    nonisolated(unsafe) private var defaults: UserDefaults!
    nonisolated(unsafe) private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "VisualIndexControllerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try super.tearDownWithError()
    }

    private func waitUntil(timeout: TimeInterval = 20, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out"); return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testStartCompletesAndIsIdempotent() async throws {
        for index in 0..<4 {
            try put("f\(index).png", VisualFixture.png(VisualFixture.scene(seed: UInt64(500 + index), width: 200, height: 150)))
        }
        let controller = VisualIndexController(service: service, defaults: defaults)
        XCTAssertTrue(controller.isEnabled, "enabled by default")
        XCTAssertEqual(controller.state, .idle)
        controller.start(root: library)
        XCTAssertEqual(controller.state, .indexing)
        controller.start(root: library)   // no-op
        await controller.waitForRun()
        XCTAssertEqual(controller.state, .completed)
        XCTAssertNotNil(controller.lastCompleted)
        XCTAssertNil(controller.progress)
        let computed = await service.computedSignatureCount
        XCTAssertEqual(computed, 4)

        controller.start(root: library)   // just completed → throttled no-op
        XCTAssertEqual(controller.state, .completed)
    }

    func testPauseResumeDoesNotRecomputeFinishedFiles() async throws {
        let count = 60
        for index in 0..<count {
            try put(String(format: "p%03d.png", index), VisualFixture.png(VisualFixture.scene(seed: UInt64(600 + index), width: 256, height: 192)))
        }
        let controller = VisualIndexController(service: service, defaults: defaults)
        controller.start(root: library)
        try await waitUntil { (controller.progress?.done ?? 0) > 0 || controller.state == .completed }
        if controller.state == .completed { throw XCTSkip("finished before pause") }
        controller.pause()
        XCTAssertEqual(controller.state, .paused)
        await controller.waitForRun()
        let atPause = await service.computedSignatureCount

        controller.start(root: library)   // opening the root again doesn't override a pause
        XCTAssertEqual(controller.state, .paused)

        controller.resume()
        XCTAssertEqual(controller.state, .indexing)
        XCTAssertGreaterThanOrEqual(controller.progress?.done ?? 0, 1, "progress carries across the pause")
        await controller.waitForRun()
        XCTAssertEqual(controller.state, .completed)
        let total = await service.computedSignatureCount
        XCTAssertEqual(total, count, "files finished before the pause (\(atPause)) aren't recomputed")
    }

    func testStopPersistsAndBlocksAutomaticStart() async throws {
        try put("x.png", VisualFixture.png(VisualFixture.scene(seed: 700, width: 200, height: 150)))
        let controller = VisualIndexController(service: service, defaults: defaults)
        controller.stop()
        XCTAssertEqual(controller.state, .stopped)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(defaults.object(forKey: VisualIndexController.enabledKey) as? Bool, false)

        let relaunched = VisualIndexController(service: service, defaults: defaults)
        XCTAssertFalse(relaunched.isEnabled)
        relaunched.start(root: library)
        XCTAssertEqual(relaunched.state, .stopped)

        relaunched.isEnabled = true   // re-enabling indexes the current root
        XCTAssertEqual(relaunched.state, .indexing)
        await relaunched.waitForRun()
        XCTAssertEqual(relaunched.state, .completed)
    }

    func testInvalidateRemovesMissingAndRequeuesChanged() async throws {
        try put("keep.png", VisualFixture.png(VisualFixture.scene(seed: 800, width: 200, height: 150)))
        try put("gone.png", VisualFixture.png(VisualFixture.scene(seed: 801, width: 200, height: 150)))
        let controller = VisualIndexController(service: service, defaults: defaults)
        controller.start(root: library)
        await controller.waitForRun()

        try FileManager.default.removeItem(atPath: path("gone.png"))
        try put("new.png", VisualFixture.png(VisualFixture.scene(seed: 802, width: 200, height: 150)))
        controller.invalidate(paths: [path("gone.png"), path("new.png")])
        await controller.waitForMutations()
        var signatures = await service.signatures(forPaths: [path("keep.png"), path("gone.png"), path("new.png")])
        XCTAssertEqual(Set(signatures.keys), Set([path("keep.png"), path("new.png")]))

        try FileManager.default.moveItem(atPath: path("keep.png"), toPath: path("kept.png"))
        controller.moved(from: path("keep.png"), to: path("kept.png"))
        await controller.waitForMutations()
        signatures = await service.signatures(forPaths: [path("keep.png"), path("kept.png")])
        XCTAssertEqual(Array(signatures.keys), [path("kept.png")])
        var computed = await service.computedSignatureCount
        XCTAssertEqual(computed, 3, "a move doesn't recompute")

        // The app reports a rename as invalidate([old, new]).
        try FileManager.default.moveItem(atPath: path("kept.png"), toPath: path("Renamed.png"))
        controller.invalidate(paths: [path("kept.png"), path("Renamed.png")])
        await controller.waitForMutations()
        signatures = await service.signatures(forPaths: [path("kept.png"), path("Renamed.png")])
        XCTAssertEqual(Array(signatures.keys), [path("Renamed.png")])
        computed = await service.computedSignatureCount
        XCTAssertEqual(computed, 3, "a rename reported through invalidate doesn't recompute either")

        controller.invalidate(paths: [path("Renamed.png")])   // unchanged file
        await controller.waitForMutations()
        computed = await service.computedSignatureCount
        XCTAssertEqual(computed, 3)
    }

    func testReindexRecomputesEverything() async throws {
        try put("r1.png", VisualFixture.png(VisualFixture.scene(seed: 900, width: 200, height: 150)))
        try put("r2.png", VisualFixture.png(VisualFixture.scene(seed: 901, width: 200, height: 150)))
        let controller = VisualIndexController(service: service, defaults: defaults)
        controller.start(root: library)
        await controller.waitForRun()
        controller.reindex(root: library)
        await controller.waitForRun()
        XCTAssertEqual(controller.state, .completed)
        let computed = await service.computedSignatureCount
        XCTAssertEqual(computed, 4)
    }
}
