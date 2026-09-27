import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PromptLibraryExplorer

/// 16-bit PCM WAV writer for waveform tests (known amplitude and length).
enum SineWAVFixture {
    /// `segments`: (seconds, amplitude 0…1, frequency Hz). Mono unless `channels` > 1
    /// (every channel carries the same signal scaled by `channelGains`).
    static func data(
        sampleRate: Int = 8000,
        channels: Int = 1,
        channelGains: [Double]? = nil,
        segments: [(seconds: Double, amplitude: Double, frequency: Double)]
    ) -> Data {
        let gains = channelGains ?? Array(repeating: 1, count: channels)
        var samples = Data()
        var phaseIndex = 0
        for segment in segments {
            let frames = Int(segment.seconds * Double(sampleRate))
            for _ in 0..<frames {
                let value = sin(2 * .pi * segment.frequency * Double(phaseIndex) / Double(sampleRate)) * segment.amplitude
                for channel in 0..<channels {
                    let sample = Int16(max(min(value * gains[channel], 1), -1) * Double(Int16.max))
                    withUnsafeBytes(of: sample.littleEndian) { samples.append(contentsOf: $0) }
                }
                phaseIndex += 1
            }
        }
        func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        var out = Data("RIFF".utf8)
        out.append(le32(UInt32(36 + samples.count)))
        out.append(Data("WAVE".utf8))
        out.append(Data("fmt ".utf8))
        out.append(le32(16))
        out.append(le16(1))                                 // PCM
        out.append(le16(UInt16(channels)))
        out.append(le32(UInt32(sampleRate)))
        out.append(le32(UInt32(sampleRate * channels * 2))) // byte rate
        out.append(le16(UInt16(channels * 2)))              // block align
        out.append(le16(16))                                // bits per sample
        out.append(Data("data".utf8))
        out.append(le32(UInt32(samples.count)))
        out.append(samples)
        return out
    }
}

final class MediaTimeMathTests: XCTestCase {
    func testHoverPositionMapsToFrameIndex() {
        XCTAssertEqual(MediaTimeMath.frameIndex(forX: 0, width: 120, frameCount: 12), 0)
        XCTAssertEqual(MediaTimeMath.frameIndex(forX: 9.9, width: 120, frameCount: 12), 0)
        XCTAssertEqual(MediaTimeMath.frameIndex(forX: 10, width: 120, frameCount: 12), 1)
        XCTAssertEqual(MediaTimeMath.frameIndex(forX: 60, width: 120, frameCount: 12), 6)
        XCTAssertEqual(MediaTimeMath.frameIndex(forX: 119.9, width: 120, frameCount: 12), 11)
        // The right edge and beyond clamp to the last frame, negatives to the first.
        XCTAssertEqual(MediaTimeMath.frameIndex(forX: 120, width: 120, frameCount: 12), 11)
        XCTAssertEqual(MediaTimeMath.frameIndex(forX: 500, width: 120, frameCount: 12), 11)
        XCTAssertEqual(MediaTimeMath.frameIndex(forX: -4, width: 120, frameCount: 12), 0)
        // Degenerate inputs.
        XCTAssertEqual(MediaTimeMath.frameIndex(forX: 50, width: 0, frameCount: 12), 0)
        XCTAssertEqual(MediaTimeMath.frameIndex(forX: 50, width: 100, frameCount: 0), 0)
        XCTAssertEqual(MediaTimeMath.fraction(forX: 30, width: 120), 0.25, accuracy: 1e-9)
    }

    func testStripTimesAreSegmentCentres() {
        let times = MediaTimeMath.stripTimes(duration: 12, count: 12)
        XCTAssertEqual(times.count, 12)
        XCTAssertEqual(times.first!, 0.5, accuracy: 1e-9)
        XCTAssertEqual(times.last!, 11.5, accuracy: 1e-9)
        // A hover over frame i shows the frame sampled in the middle of segment i.
        let index = MediaTimeMath.frameIndex(forX: 75, width: 120, frameCount: 12)
        XCTAssertEqual(times[index], 7.5, accuracy: 1e-9)
        // Unknown / zero duration: every frame at 0.
        XCTAssertEqual(MediaTimeMath.stripTimes(duration: 0, count: 3), [0, 0, 0])
        XCTAssertEqual(MediaTimeMath.stripTimes(duration: .nan, count: 2), [0, 0])
        XCTAssertEqual(MediaTimeMath.stripTimes(duration: 5, count: 0), [])
    }

    func testTimecodes() {
        XCTAssertEqual(MediaTimeMath.fileTimecode(12.9), "00m12s")
        XCTAssertEqual(MediaTimeMath.fileTimecode(75), "01m15s")
        XCTAssertEqual(MediaTimeMath.fileTimecode(3723), "01h02m03s")
        XCTAssertEqual(MediaTimeMath.fileTimecode(-3), "00m00s")
        XCTAssertEqual(MediaTimeMath.displayTimecode(12.34), "0:12.3")
        XCTAssertEqual(MediaTimeMath.displayTimecode(3723, showsTenths: false), "1:02:03")
    }

    func testTrimRangeMath() {
        var range = MediaTrimRange(duration: 10)
        XCTAssertTrue(range.isFullClip)
        XCTAssertEqual(range.length, 10)

        range.setStart(2)
        range.setEnd(6.5)
        XCTAssertEqual(range.start, 2)
        XCTAssertEqual(range.end, 6.5)
        XCTAssertEqual(range.length, 4.5, accuracy: 1e-9)
        XCTAssertFalse(range.isFullClip)
        XCTAssertEqual(range.timeRange.start.seconds, 2, accuracy: 0.002)
        XCTAssertEqual(range.timeRange.duration.seconds, 4.5, accuracy: 0.002)

        // The in point can't pass the out point (a minimum length is kept), and vice versa.
        range.setStart(9)
        XCTAssertEqual(range.start, 6.5 - MediaTrimRange.minimumLength, accuracy: 1e-9)
        range.setEnd(0)
        XCTAssertEqual(range.end, range.start + MediaTrimRange.minimumLength, accuracy: 1e-9)

        // Clamped to the clip.
        range.setStart(-5)
        XCTAssertEqual(range.start, 0)
        range.setEnd(99)
        XCTAssertEqual(range.end, 10)

        // Fractions across the timeline.
        range.setStart(fraction: 0.25)
        range.setEnd(fraction: 0.75)
        XCTAssertEqual(range.start, 2.5, accuracy: 1e-9)
        XCTAssertEqual(range.end, 7.5, accuracy: 1e-9)
        XCTAssertEqual(range.startFraction, 0.25, accuracy: 1e-9)

        // Preview resumes inside the range, else from the in point.
        XCTAssertEqual(range.playbackStart(from: 4), 4)
        XCTAssertEqual(range.playbackStart(from: 1), 2.5)
        XCTAssertEqual(range.playbackStart(from: 7.5), 2.5)

        // A clip shorter than the minimum is kept whole.
        let tiny = MediaTrimRange(start: 0, end: 0.05, duration: 0.05)
        XCTAssertEqual(tiny.start, 0)
        XCTAssertEqual(tiny.end, 0.05, accuracy: 1e-9)
        XCTAssertEqual(MediaTrimRange(duration: .nan).duration, 0)
    }

    func testGIFFrameTimes() {
        let times = MediaTimeMath.gifFrameTimes(start: 1, length: 2, fps: 10)
        XCTAssertEqual(times.count, 20)
        XCTAssertEqual(times.first!, 1, accuracy: 1e-9)
        XCTAssertEqual(times[1] - times[0], 0.1, accuracy: 1e-9)
        XCTAssertEqual(MediaTimeMath.gifFrameTimes(start: 0, length: 0.01, fps: 10).count, 1)
        XCTAssertEqual(MediaTimeMath.gifFrameTimes(start: 0, length: 600, fps: 30, maxFrames: 100).count, 100)
    }

    func testExportNamesAndCollisions() {
        XCTAssertEqual(MediaExportNaming.frameFileName(videoName: "clip.mov", seconds: 12.4, fileExtension: "png"), "clip @ 00m12s.png")
        XCTAssertEqual(MediaExportNaming.trimFileName(videoName: "clip.mov", fileExtension: "mp4"), "clip (trim).mp4")
        XCTAssertEqual(MediaExportNaming.trimFileName(videoName: "clip.mov", fileExtension: "gif"), "clip.gif")
        XCTAssertEqual(MediaExportNaming.stripFileName(videoName: "a.b.mp4", fileExtension: "jpg"), "a.b strip.jpg")

        let dir = URL(fileURLWithPath: "/tmp/media-naming", isDirectory: true)
        var taken: Set<String> = []
        let exists: (URL) -> Bool = { taken.contains($0.lastPathComponent) }
        XCTAssertEqual(MediaExportNaming.uniqueURL(for: "clip (trim).mp4", in: dir, exists: exists).lastPathComponent, "clip (trim).mp4")
        taken = ["clip (trim).mp4", "clip (trim) 2.mp4"]
        XCTAssertEqual(MediaExportNaming.uniqueURL(for: "clip (trim).mp4", in: dir, exists: exists).lastPathComponent, "clip (trim) 3.mp4")

        // The source is never returned, even if the check says it's free.
        let source = dir.appendingPathComponent("clip.mp4")
        let url = MediaExportNaming.uniqueURL(for: "clip.mp4", in: dir, avoiding: source, exists: { _ in false })
        XCTAssertEqual(url.lastPathComponent, "clip 2.mp4")
        XCTAssertTrue(MediaExportNaming.isSameFile(dir.appendingPathComponent("./clip.mp4"), source))
    }
}

final class MediaWaveformTests: TempDirectoryTestCase {
    func testPeakMathOnBuffers() {
        let samples: [Float] = [0.1, -0.2, 0.9, -0.3, /* block 2 */ 0.05, -0.5, 0.2, 0.1, /* partial */ -0.7]
        // Stereo interleaved: frames (0.1,-0.2) (0.9,-0.3) | (0.05,-0.5) (0.2,0.1) | (-0.7) partial frame dropped.
        let stereo = samples.withUnsafeBufferPointer { WaveformMath.blockPeaks(interleaved: $0, channels: 2, blockFrames: 2) }
        XCTAssertEqual(stereo, [0.9, 0.5])
        let mono = samples.withUnsafeBufferPointer { WaveformMath.blockPeaks(interleaved: $0, channels: 1, blockFrames: 4) }
        XCTAssertEqual(mono, [0.9, 0.5, 0.7])

        XCTAssertEqual(WaveformMath.downsample([0.1, 0.4, 0.2, 0.8], to: 2), [0.4, 0.8])
        XCTAssertEqual(WaveformMath.downsample([0.3], to: 3), [0.3, 0.3, 0.3])
        XCTAssertEqual(WaveformMath.downsample([], to: 2), [0, 0])
        XCTAssertEqual(WaveformMath.normalized([0.25, 0.5]), [0.5, 1])
        XCTAssertEqual(WaveformMath.normalized([0, 0]), [0, 0])
        XCTAssertEqual(WaveformMath.decode(WaveformMath.encode([0.25, 1])), [0.25, 1])
    }

    func testPeaksFromSineWAVMatchAmplitudeAndLength() async throws {
        // 2 s: first second a 0.5-amplitude sine, second second a 0.25-amplitude sine.
        let url = try writeFile("tone.wav", SineWAVFixture.data(segments: [
            (seconds: 1, amplitude: 0.5, frequency: 220),
            (seconds: 1, amplitude: 0.25, frequency: 440),
        ]))
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        XCTAssertEqual(duration, 2, accuracy: 0.01)

        let peaks = try await MediaWaveformService.extractPeaks(from: url, bucketCount: 20)
        XCTAssertEqual(peaks.count, 20)
        // Buckets clear of the boundary carry each half's amplitude.
        for peak in peaks[0..<9] { XCTAssertEqual(peak, 0.5, accuracy: 0.02) }
        for peak in peaks[11..<20] { XCTAssertEqual(peak, 0.25, accuracy: 0.02) }
    }

    func testStereoPeaksTakeTheLoudestChannelAndSilenceStaysFlat() async throws {
        let url = try writeFile("stereo.wav", SineWAVFixture.data(
            channels: 2, channelGains: [0.2, 1],
            segments: [(seconds: 0.5, amplitude: 0.8, frequency: 300), (seconds: 0.5, amplitude: 0, frequency: 300)]
        ))
        let peaks = try await MediaWaveformService.extractPeaks(from: url, bucketCount: 10)
        XCTAssertEqual(peaks.count, 10)
        for peak in peaks[0..<4] { XCTAssertEqual(peak, 0.8, accuracy: 0.02) }
        for peak in peaks[6..<10] { XCTAssertEqual(peak, 0, accuracy: 0.001) }
    }

    func testVideoWithoutAudioHasNoPeaks() async throws {
        let url = tempDir.appendingPathComponent("silent.mov")
        try await VideoFixture.write(to: url, frames: 5) { _ in (10, 20, 30) }
        do {
            _ = try await MediaWaveformService.extractPeaks(from: url, bucketCount: 8)
            XCTFail("expected no audio track")
        } catch {
            XCTAssertTrue(error is MediaToolError, "\(error)")
        }
        let cached = await MediaWaveformService.peaks(for: url, bucketCount: 8)
        XCTAssertNil(cached)
    }

    func testWaveformThumbnailRenders() throws {
        let image = try XCTUnwrap(WaveformRenderer.thumbnail(peaks: [0, 0.5, 1, 0.5], pixelSize: 64))
        XCTAssertEqual(image.width, 64)
        XCTAssertEqual(image.height, 64)
    }
}

final class MediaGIFAndClipTests: TempDirectoryTestCase {
    private func gifFrames(_ url: URL) throws -> (count: Int, delays: [Double], loop: Int?, width: Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.gif.identifier)
        let count = CGImageSourceGetCount(source)
        var delays: [Double] = []
        for index in 0..<count {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? -1
            delays.append(delay)
        }
        let file = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let loop = (file?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFLoopCount] as? Int
        let width = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyPixelWidth] as? Int ?? 0
        return (count, delays, loop, width)
    }

    private func solidImage(_ gray: CGFloat, size: Int = 16) -> CGImage {
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return context.makeImage()!
    }

    func testGIFWriterWritesFramesWithDelay() throws {
        let url = tempDir.appendingPathComponent("frames.gif")
        let writer = try MediaGIFWriter(url: url, expectedFrameCount: 5, delay: 0.1, loopCount: 0)
        for index in 0..<5 { writer.add(solidImage(CGFloat(index) / 5)) }
        try writer.finalize()

        let read = try gifFrames(url)
        XCTAssertEqual(read.count, 5)
        for delay in read.delays { XCTAssertEqual(delay, 0.1, accuracy: 0.011) }
        XCTAssertEqual(read.loop, 0, "loops forever")
    }

    func testGIFExportFromVideoRange() async throws {
        let source = tempDir.appendingPathComponent("clip.mov")
        try await VideoFixture.write(to: source, width: 128, height: 96, frames: 30) { frame in (UInt8(frame * 8), 60, 120) }
        let range = MediaTrimRange(start: 0.5, end: 1.5, duration: 3)
        var options = MediaClipExportOptions()
        options.format = .gif
        options.gifFPS = 10
        options.gifMaxWidth = 64
        options.gifLoops = false
        let destination = tempDir.appendingPathComponent("clip.gif")
        try await MediaClipExporter.export(source: source, range: range, options: options, to: destination) { _ in }

        let read = try gifFrames(destination)
        XCTAssertEqual(read.count, 10, "1 s at 10 fps")
        for delay in read.delays { XCTAssertEqual(delay, 0.1, accuracy: 0.011) }
        XCTAssertEqual(read.width, 64, "scaled to the maximum width")
        XCTAssertNotEqual(read.loop, 0, "plays once")
        // The temporary file is gone and the source is untouched.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: tempDir.path).filter { $0.contains("partial") }
        XCTAssertEqual(leftovers, [])
    }

    func testMP4TrimExportHasTheRangeDurationAndNeverOverwritesTheSource() async throws {
        let source = tempDir.appendingPathComponent("take.mov")
        try await VideoFixture.write(to: source, frames: 30) { frame in (UInt8(frame * 8), 0, 0) }
        let sourceData = try Data(contentsOf: source)
        let range = MediaTrimRange(start: 1, end: 2, duration: 3)

        let destination = MediaExportNaming.uniqueURL(
            for: MediaExportNaming.trimFileName(videoName: source.lastPathComponent, fileExtension: "mp4"),
            in: tempDir, avoiding: source
        )
        XCTAssertEqual(destination.lastPathComponent, "take (trim).mp4")
        try await MediaClipExporter.export(source: source, range: range, options: MediaClipExportOptions(), to: destination) { _ in }
        let duration = try await AVURLAsset(url: destination).load(.duration).seconds
        XCTAssertEqual(duration, 1, accuracy: 0.25)

        // Writing onto the source is refused before anything happens.
        do {
            try await MediaClipExporter.export(source: source, range: range, options: MediaClipExportOptions(), to: source) { _ in }
            XCTFail("expected a refusal")
        } catch MediaToolError.wouldOverwriteSource {
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(try Data(contentsOf: source), sourceData)

        // A second trim gets a numbered name.
        let second = MediaExportNaming.uniqueURL(for: "take (trim).mp4", in: tempDir, avoiding: source)
        XCTAssertEqual(second.lastPathComponent, "take (trim) 2.mp4")
    }

    func testPassthroughOnlyWhenCodecMatches() {
        XCTAssertEqual(MediaClipExporter.preset(for: .h264, sourceCodec: kCMVideoCodecType_H264, passthroughCompatible: true), AVAssetExportPresetPassthrough)
        XCTAssertEqual(MediaClipExporter.preset(for: .h264, sourceCodec: kCMVideoCodecType_H264, passthroughCompatible: false), AVAssetExportPresetHighestQuality)
        XCTAssertEqual(MediaClipExporter.preset(for: .hevc, sourceCodec: kCMVideoCodecType_H264, passthroughCompatible: true), AVAssetExportPresetHEVCHighestQuality)
        XCTAssertEqual(MediaClipExporter.preset(for: .hevc, sourceCodec: kCMVideoCodecType_HEVC, passthroughCompatible: true), AVAssetExportPresetPassthrough)
        XCTAssertEqual(MediaClipExporter.gifFrameSize(natural: CGSize(width: 1920, height: 1080), maxWidth: 480), CGSize(width: 480, height: 270))
        XCTAssertEqual(MediaClipExporter.gifFrameSize(natural: CGSize(width: 200, height: 100), maxWidth: 480), CGSize(width: 200, height: 100))
    }
}

final class MediaFrameTests: TempDirectoryTestCase {
    func testScrubStripFramesFollowTheClip() async throws {
        // 1.2 s at 10 fps; frame i is red with value i*20 so strip frames get brighter.
        let url = tempDir.appendingPathComponent("ramp.mov")
        try await VideoFixture.write(to: url, frames: 12) { frame in (UInt8(frame * 20), 0, 0) }
        let times = MediaTimeMath.stripTimes(duration: 1.2, count: 4)
        let frames = try await MediaFrameExtractor.frames(at: times, url: url, maxPixelSize: 64)
        XCTAssertEqual(frames.count, 4)
        let reds = try frames.map { try XCTUnwrap($0) }.map(averageRed)
        XCTAssertEqual(reds, reds.sorted(), "later strip frames come from later in the clip: \(reds)")
        XCTAssertGreaterThan(reds.last! - reds.first!, 80)
        // (MediaScrubStripService.strip itself isn't called on success here: it would
        // write into the real thumbnail disk cache.)
    }

    func testTinyClipAndFrameGrab() async throws {
        let url = tempDir.appendingPathComponent("one.mov")
        try await VideoFixture.write(to: url, frames: 1) { _ in (0, 200, 0) }
        let info = try await MediaFrameExtractor.info(for: url)
        XCTAssertTrue(info.hasVideo)
        XCTAssertFalse(info.hasAudio)
        XCTAssertEqual(info.codec, kCMVideoCodecType_H264)
        // Past-the-end and middle requests both give a frame.
        let late = try await MediaFrameExtractor.frame(at: 99, url: url)
        XCTAssertEqual(late.width, 128)
        let strip = try await MediaFrameExtractor.frames(at: MediaTimeMath.stripTimes(duration: info.duration, count: 12), url: url, maxPixelSize: 32)
        XCTAssertEqual(strip.compactMap { $0 }.count, 12)
    }

    func testAudioOnlyFileHasNoFrames() async throws {
        let url = try writeFile("tone.wav", SineWAVFixture.data(segments: [(seconds: 0.2, amplitude: 0.5, frequency: 220)]))
        do {
            _ = try await MediaFrameExtractor.frame(at: 0, url: url)
            XCTFail("expected no video track")
        } catch MediaToolError.noVideoTrack {
        }
        let strip = await MediaScrubStripService.strip(for: url)
        XCTAssertNil(strip)
    }

    func testContactStripLayout() throws {
        let context = CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let frame = context.makeImage()!
        let pairs = (0..<6).map { (image: frame, seconds: Double($0)) }
        let strip = try XCTUnwrap(MediaStripRenderer.contactStrip(frames: pairs, columns: 4, spacing: 8, captions: false))
        XCTAssertEqual(strip.width, 4 * 40 + 5 * 8)
        XCTAssertEqual(strip.height, 2 * 30 + 3 * 8)
        let joined = try XCTUnwrap(MediaStripRenderer.horizontalStrip([frame, frame, frame]))
        XCTAssertEqual(MediaStripRenderer.split(joined, count: 3).map(\.width), [40, 40, 40])
    }

    private func averageRed(_ image: CGImage) -> Double {
        let width = 8, height = 8
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var total = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) { total += Double(pixels[index]) }
        return total / Double(width * height)
    }
}
