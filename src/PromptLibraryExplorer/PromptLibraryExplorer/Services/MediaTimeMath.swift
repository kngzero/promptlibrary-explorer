import CoreMedia
import Foundation

/// Pure time / naming math for the video & audio tools (hover scrub, frame export,
/// trim, GIF). No AVFoundation work here, so it's all unit-testable.
enum MediaTimeMath {
    /// Frames in a hover-scrub strip.
    static let scrubFrameCount = 12

    /// Relative position (0…1) of `x` across a view `width` wide.
    static func fraction(forX x: CGFloat, width: CGFloat) -> Double {
        guard width > 0, x.isFinite else { return 0 }
        return Double(min(max(x / width, 0), 1))
    }

    /// Which of `frameCount` strip frames to show for a hover at `x` across `width`.
    /// The strip divides the tile into equal columns; the right edge maps to the last frame.
    static func frameIndex(forX x: CGFloat, width: CGFloat, frameCount: Int) -> Int {
        guard frameCount > 0 else { return 0 }
        let index = Int(fraction(forX: x, width: width) * Double(frameCount))
        return min(max(index, 0), frameCount - 1)
    }

    /// Sample times (seconds) for a strip of `count` frames over `duration`: the centre
    /// of each equal segment, so the first frame isn't a black lead-in and the last isn't
    /// past the end. Tiny / unknown durations give time 0 for every frame.
    static func stripTimes(duration: Double, count: Int) -> [Double] {
        guard count > 0 else { return [] }
        guard duration.isFinite, duration > 0 else { return Array(repeating: 0, count: count) }
        return (0..<count).map { index in
            (Double(index) + 0.5) / Double(count) * duration
        }
    }

    /// The media time for a relative position, clamped inside the clip.
    static func time(forFraction fraction: Double, duration: Double) -> Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        return min(max(fraction, 0), 1) * duration
    }

    /// GIF frame times from `start` for `length` seconds at `fps`. Always at least one frame;
    /// capped at `maxFrames` (the fps is effectively lowered for very long ranges).
    static func gifFrameTimes(start: Double, length: Double, fps: Int, maxFrames: Int = 1500) -> [Double] {
        let fps = max(fps, 1)
        guard length.isFinite, length > 0 else { return [max(start, 0)] }
        var count = Int((length * Double(fps)).rounded(.down))
        count = min(max(count, 1), maxFrames)
        let step = length / Double(count)
        return (0..<count).map { max(start, 0) + Double($0) * step }
    }

    /// Timecode for file names: `00m12s`, or `01h02m03s` past an hour.
    static func fileTimecode(_ seconds: Double) -> String {
        let total = max(Int((seconds.isFinite ? seconds : 0).rounded(.down)), 0)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%02dh%02dm%02ds", hours, minutes, secs)
        }
        return String(format: "%02dm%02ds", minutes, secs)
    }

    /// Timecode for display: `0:12.3`, `1:02:03.0`.
    static func displayTimecode(_ seconds: Double, showsTenths: Bool = true) -> String {
        let value = max(seconds.isFinite ? seconds : 0, 0)
        let total = Int(value.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        let tenths = Int(((value - Double(total)) * 10).rounded(.down)) % 10
        let base = hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
        return showsTenths ? "\(base).\(tenths)" : base
    }
}

/// An in/out range over a clip, kept valid (inside the clip, at least `minimumLength` long).
struct MediaTrimRange: Equatable {
    static let minimumLength: Double = 0.1

    private(set) var start: Double
    private(set) var end: Double
    let duration: Double

    init(duration: Double) {
        let duration = duration.isFinite ? max(duration, 0) : 0
        self.duration = duration
        start = 0
        end = duration
    }

    init(start: Double, end: Double, duration: Double) {
        self.init(duration: duration)
        setEnd(end)
        setStart(start)
    }

    var length: Double { max(end - start, 0) }

    /// The whole clip is selected (nothing trimmed).
    var isFullClip: Bool { start <= 0.0005 && end >= duration - 0.0005 }

    /// Room for a valid range at all (a clip shorter than the minimum can only be kept whole).
    private var minimum: Double { min(Self.minimumLength, duration) }

    /// Moves the in point, keeping it before the out point by at least the minimum length.
    mutating func setStart(_ value: Double) {
        let value = value.isFinite ? value : 0
        start = min(max(value, 0), max(end - minimum, 0))
    }

    /// Moves the out point, keeping it after the in point by at least the minimum length.
    mutating func setEnd(_ value: Double) {
        let value = value.isFinite ? value : duration
        end = max(min(value, duration), min(start + minimum, duration))
    }

    /// Sets the in / out point from a relative position across the timeline.
    mutating func setStart(fraction: Double) { setStart(MediaTimeMath.time(forFraction: fraction, duration: duration)) }
    mutating func setEnd(fraction: Double) { setEnd(MediaTimeMath.time(forFraction: fraction, duration: duration)) }

    var startFraction: Double { duration > 0 ? start / duration : 0 }
    var endFraction: Double { duration > 0 ? end / duration : 1 }

    /// For AVAssetExportSession.timeRange / AVPlayer boundaries.
    var timeRange: CMTimeRange {
        CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            end: CMTime(seconds: end, preferredTimescale: 600)
        )
    }

    /// Where playback of the range should resume: `time` if it's inside, else the in point.
    func playbackStart(from time: Double) -> Double {
        (time >= start && time < end - 0.05) ? time : start
    }
}

/// Output names for frames and clips. Never returns an existing file or the source.
enum MediaExportNaming {
    /// `<video> @ 00m12s.png`
    static func frameFileName(videoName: String, seconds: Double, fileExtension: String) -> String {
        "\(baseName(videoName)) @ \(MediaTimeMath.fileTimecode(seconds)).\(fileExtension)"
    }

    /// `<video> strip.png`
    static func stripFileName(videoName: String, fileExtension: String) -> String {
        "\(baseName(videoName)) strip.\(fileExtension)"
    }

    /// `<video> (trim).mp4`, or `<video>.gif` for GIFs.
    static func trimFileName(videoName: String, fileExtension: String) -> String {
        let base = baseName(videoName)
        return fileExtension.lowercased() == "gif" ? "\(base).gif" : "\(base) (trim).\(fileExtension)"
    }

    static func baseName(_ fileName: String) -> String {
        let base = (fileName as NSString).deletingPathExtension
        return base.isEmpty ? fileName : base
    }

    /// `name` inside `directory`, or `name 2`, `name 3`… when taken. `source` (the file
    /// being exported from) is always treated as taken, so it can never be overwritten.
    static func uniqueURL(
        for fileName: String,
        in directory: URL,
        avoiding source: URL? = nil,
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        let ext = (fileName as NSString).pathExtension
        let base = (fileName as NSString).deletingPathExtension
        let sourcePath = source?.standardizedFileURL.path
        func candidate(_ index: Int) -> URL {
            let name = index <= 1 ? base : "\(base) \(index)"
            let file = ext.isEmpty ? name : "\(name).\(ext)"
            return directory.appendingPathComponent(file)
        }
        var index = 1
        while index < 10_000 {
            let url = candidate(index)
            if url.standardizedFileURL.path != sourcePath, !exists(url) { return url }
            index += 1
        }
        return candidate(Int.random(in: 10_000...99_999))
    }

    /// True if writing to `destination` would replace `source`.
    static func isSameFile(_ destination: URL, _ source: URL) -> Bool {
        destination.standardizedFileURL.resolvingSymlinksInPath().path
            == source.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
