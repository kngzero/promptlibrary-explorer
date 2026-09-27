import AppKit
import AVFoundation
import Foundation

/// Pure peak math, separated from AVFoundation so it can be tested directly.
enum WaveformMath {
    /// Absolute peak of each block of `blockFrames` frames of interleaved Float32 samples,
    /// taking the loudest channel. A final partial block is included.
    static func blockPeaks(interleaved samples: UnsafeBufferPointer<Float>, channels: Int, blockFrames: Int) -> [Float] {
        let channels = max(channels, 1)
        let blockFrames = max(blockFrames, 1)
        let frameCount = samples.count / channels
        guard frameCount > 0 else { return [] }
        var peaks: [Float] = []
        peaks.reserveCapacity(frameCount / blockFrames + 1)
        var frame = 0
        while frame < frameCount {
            let end = min(frame + blockFrames, frameCount)
            var peak: Float = 0
            for i in (frame * channels)..<(end * channels) {
                let value = abs(samples[i])
                if value > peak { peak = value }
            }
            peaks.append(peak)
            frame = end
        }
        return peaks
    }

    /// Reduces `peaks` to exactly `count` buckets (max of each bucket). Fewer peaks than
    /// buckets are stretched (each bucket takes the peak under it).
    static func downsample(_ peaks: [Float], to count: Int) -> [Float] {
        guard count > 0 else { return [] }
        guard !peaks.isEmpty else { return Array(repeating: 0, count: count) }
        var out = [Float](repeating: 0, count: count)
        let n = peaks.count
        for bucket in 0..<count {
            let lower = bucket * n / count
            let upper = max((bucket + 1) * n / count, lower + 1)
            var peak: Float = 0
            for i in lower..<min(upper, n) where peaks[i] > peak { peak = peaks[i] }
            out[bucket] = min(peak, 1)
        }
        return out
    }

    /// Scales so the loudest bucket is 1 (quiet files still read as a waveform).
    /// Silence stays silence.
    static func normalized(_ peaks: [Float]) -> [Float] {
        guard let maxPeak = peaks.max(), maxPeak > 0.0001 else { return peaks }
        return peaks.map { $0 / maxPeak }
    }

    static func encode(_ peaks: [Float]) -> Data {
        peaks.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func decode(_ data: Data) -> [Float]? {
        guard !data.isEmpty, data.count % MemoryLayout<Float>.size == 0 else { return nil }
        return data.withUnsafeBytes { raw in Array(raw.bindMemory(to: Float.self)) }
    }
}

/// Downsampled peak arrays for audio files (AVAssetReader → Float32 PCM → peaks), cached in
/// memory and on disk (ThumbnailService's cache, keyed by path + mtime + size). Raw, not
/// normalized: callers normalize for display.
enum MediaWaveformService {
    static let thumbnailBucketCount = 48
    static let playerBucketCount = 600

    final class Box: @unchecked Sendable {
        let peaks: [Float]
        init(_ peaks: [Float]) { self.peaks = peaks }
    }

    nonisolated(unsafe) private static let memory: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 400
        return cache
    }()

    /// Peaks for `url` in `bucketCount` buckets, or nil (no audio track, unreadable, cancelled).
    static func peaks(for url: URL, bucketCount: Int) async -> [Float]? {
        let variant = "peaks1-\(bucketCount)"
        let key = await Task.detached(priority: .utility) {
            ThumbnailService.mediaCacheKey(for: url, variant: variant)
        }.value
        guard let key else { return nil }
        if let cached = memory.object(forKey: key as NSString) { return cached.peaks }

        let stored = await Task.detached(priority: .utility) {
            ThumbnailService.loadMediaCacheData(key: key, ext: "peaks").flatMap(WaveformMath.decode)
        }.value
        if let stored, stored.count == bucketCount {
            memory.setObject(Box(stored), forKey: key as NSString)
            return stored
        }
        guard !Task.isCancelled else { return nil }

        let peaks: [Float]? = try? await MediaWaveformLimiter.run {
            try await extractPeaks(from: url, bucketCount: bucketCount)
        }
        guard let peaks, !Task.isCancelled else { return nil }
        memory.setObject(Box(peaks), forKey: key as NSString)
        ThumbnailService.storeMediaCacheData(WaveformMath.encode(peaks), key: key, ext: "peaks")
        return peaks
    }

    /// Reads the first audio track as Float32 PCM and returns `bucketCount` absolute peaks
    /// (0…1). Runs on a background task; cancelling stops reading.
    static func extractPeaks(from url: URL, bucketCount: Int) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw MediaToolError.noAudioTrack
        }
        let duration = try await asset.load(.duration).seconds
        let descriptions = try await track.load(.formatDescriptions)
        var sampleRate = 44_100.0
        if let description = descriptions.first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
           asbd.mSampleRate > 0
        {
            sampleRate = asbd.mSampleRate
        }

        let work = Task.detached(priority: .utility) { () throws -> [Float] in
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw MediaToolError.noAudioTrack }
            reader.add(output)
            guard reader.startReading() else {
                throw reader.error ?? MediaToolError.noAudioTrack
            }
            defer { if reader.status == .reading { reader.cancelReading() } }

            // Block size so a typical file yields a few thousand blocks before bucketing.
            let estimatedFrames = duration.isFinite && duration > 0 ? duration * sampleRate : sampleRate * 60
            let blockFrames = max(Int(estimatedFrames / Double(max(bucketCount, 1) * 8)), 16)

            var blockPeaks: [Float] = []
            var carry: [Float] = []   // a partial block carried between buffers
            var channels = 1
            while let sampleBuffer = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                if let description = CMSampleBufferGetFormatDescription(sampleBuffer),
                   let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
                {
                    channels = max(Int(asbd.mChannelsPerFrame), 1)
                }
                guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
                var length = 0
                var pointer: UnsafeMutablePointer<Int8>?
                // Contiguous copy (the buffer may be non-contiguous).
                var contiguous: CMBlockBuffer? = block
                if !CMBlockBufferIsRangeContiguous(block, atOffset: 0, length: 0) {
                    var copy: CMBlockBuffer?
                    CMBlockBufferCreateContiguous(
                        allocator: kCFAllocatorDefault, sourceBuffer: block, blockAllocator: kCFAllocatorDefault,
                        customBlockSource: nil, offsetToData: 0, dataLength: 0, flags: 0, blockBufferOut: &copy
                    )
                    contiguous = copy
                }
                guard let contiguous,
                      CMBlockBufferGetDataPointer(contiguous, atOffset: 0, lengthAtOffsetOut: nil,
                                                  totalLengthOut: &length, dataPointerOut: &pointer) == kCMBlockBufferNoErr,
                      let pointer
                else { continue }
                let count = length / MemoryLayout<Float>.size
                pointer.withMemoryRebound(to: Float.self, capacity: count) { floats in
                    var samples = carry
                    samples.append(contentsOf: UnsafeBufferPointer(start: floats, count: count))
                    let whole = (samples.count / channels) / blockFrames * blockFrames * channels
                    samples.withUnsafeBufferPointer { all in
                        let head = UnsafeBufferPointer(rebasing: all[0..<whole])
                        blockPeaks += WaveformMath.blockPeaks(interleaved: head, channels: channels, blockFrames: blockFrames)
                    }
                    carry = Array(samples[whole...])
                }
            }
            try Task.checkCancellation()
            if reader.status == .failed { throw reader.error ?? MediaToolError.noAudioTrack }
            if !carry.isEmpty {
                carry.withUnsafeBufferPointer { tail in
                    blockPeaks += WaveformMath.blockPeaks(interleaved: tail, channels: channels, blockFrames: blockFrames)
                }
            }
            return WaveformMath.downsample(blockPeaks, to: bucketCount)
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }
}

/// The waveform limiter wrapped so call sites read naturally.
enum MediaWaveformLimiter {
    static func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await MediaWorkLimiter.waveforms.run(body)
    }
}

/// Draws peak arrays with CoreGraphics (safe off the main actor).
enum WaveformRenderer {
    /// The fixed waveform colour for tiles (the audio badge colour reads in both modes).
    static let tileColor = CGColor(red: 0xA7 / 255.0, green: 0x55 / 255.0, blue: 0xF5 / 255.0, alpha: 1)

    /// Square tile: mirrored rounded bars across the middle, on a transparent background.
    static func thumbnail(peaks: [Float], pixelSize: CGFloat) -> CGImage? {
        let side = Int(max(pixelSize, 16).rounded())
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let values = WaveformMath.normalized(peaks)
        guard !values.isEmpty else { return context.makeImage() }
        let inset = CGFloat(side) * 0.12
        let width = CGFloat(side) - inset * 2
        let maxHeight = CGFloat(side) * 0.52
        let slot = width / CGFloat(values.count)
        let barWidth = max(slot * 0.62, 1)
        let midY = CGFloat(side) / 2
        context.setFillColor(tileColor)
        for (index, value) in values.enumerated() {
            let height = max(CGFloat(value) * maxHeight, barWidth)
            let rect = CGRect(
                x: inset + CGFloat(index) * slot + (slot - barWidth) / 2,
                y: midY - height / 2,
                width: barWidth,
                height: height
            )
            context.addPath(CGPath(roundedRect: rect, cornerWidth: barWidth / 2, cornerHeight: min(barWidth / 2, height / 2), transform: nil))
        }
        context.fillPath()
        return context.makeImage()
    }
}
