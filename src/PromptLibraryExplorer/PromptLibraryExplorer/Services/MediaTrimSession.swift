import AppKit
import AVFoundation
import Foundation
import Observation

/// One open Trim page (video or audio): the player, the in / out range, the
/// playhead and the export options. `MediaController.trimSession` owns it; the
/// page (`MediaTrimPageView`) and the key monitor drive it.
///
/// Scrubbing is real time: seeks chase the pointer (a new seek starts as soon
/// as the previous one lands, always to the latest position), so frames keep
/// up while dragging. Scrubbing audio plays a short burst at each position.
@MainActor @Observable
final class MediaTrimSession: Identifiable {
    let id = UUID()
    let url: URL
    let startTime: Double

    let player = AVPlayer()
    private(set) var info: MediaFrameExtractor.VideoInfo?
    private(set) var loadError: String?
    var range = MediaTrimRange(duration: 0)
    private(set) var playhead: Double = 0
    private(set) var isPlaying = false
    private(set) var strip: MediaScrubStripService.Strip?
    private(set) var waveform: [Float] = []
    var options = MediaClipExportOptions()
    var saveNextToOriginal = true

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var seekInFlight = false
    @ObservationIgnored private var pendingSeek: Double?
    @ObservationIgnored private var burstEnd: DispatchWorkItem?

    init(url: URL, startTime: Double = 0) {
        self.url = url
        self.startTime = startTime
    }

    var name: String { url.lastPathComponent }
    /// No video track: trim the audio.
    var isAudioOnly: Bool { info.map { !$0.hasVideo } ?? FileHelpers.isAudioFile(url.lastPathComponent) }
    var canExport: Bool { (info.map { $0.hasVideo || $0.hasAudio } ?? false) && range.length > 0 }

    /// One frame for video (from its frame rate), a tenth of a second for audio.
    var nudgeStep: Double {
        guard let info, info.hasVideo, info.nominalFrameRate > 0 else { return 0.1 }
        return 1 / Double(info.nominalFrameRate)
    }

    // MARK: Loading

    func load() async {
        guard info == nil, loadError == nil else { return }
        do {
            let loaded = try await MediaFrameExtractor.info(for: url)
            guard loaded.hasVideo || loaded.hasAudio else {
                loadError = "\(url.lastPathComponent) has no video or audio track."
                return
            }
            if !loaded.hasVideo { options.format = .m4a }
            info = loaded
            range = MediaTrimRange(duration: loaded.duration)
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            player.actionAtItemEnd = .pause
            startObserving()
            seek(to: min(max(startTime, 0), loaded.duration))
            if loaded.hasVideo {
                strip = await MediaScrubStripService.strip(for: url)
            } else {
                let peaks = await MediaWaveformService.peaks(for: url, bucketCount: MediaWaveformService.playerBucketCount)
                waveform = WaveformMath.normalized(peaks ?? [])
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func startObserving() {
        let interval = CMTime(seconds: 1.0 / 30, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let seconds = time.seconds.isFinite ? time.seconds : 0
            MainActor.assumeIsolated {
                guard let self else { return }
                let playing = self.player.timeControlStatus == .playing
                self.isPlaying = playing && self.burstEnd == nil
                // While a seek is chasing the pointer, the playhead follows the pointer.
                guard !self.seekInFlight else { return }
                self.playhead = seconds
                // Preview loops inside the range.
                if self.isPlaying, seconds >= self.range.end - 0.01 {
                    self.seek(to: self.range.start)
                    self.player.play()
                }
            }
        }
    }

    // MARK: Transport

    /// Moves the playhead (and the picture) to `seconds`; `pause` stops playback first.
    func seek(to seconds: Double, pause: Bool = false) {
        if pause { stopBurst(); player.pause() }
        let clamped = min(max(seconds, 0), range.duration > 0 ? range.duration : seconds)
        playhead = clamped
        pendingSeek = clamped
        chase()
    }

    /// Real-time scrub from the timeline: chases the pointer; audio plays a short
    /// burst at each position while paused.
    func scrub(to seconds: Double) {
        let wasPlaying = isPlaying
        seek(to: seconds)
        if isAudioOnly, !wasPlaying { playBurst() }
    }

    func togglePlay() {
        stopBurst()
        if player.timeControlStatus == .playing {
            player.pause()
            isPlaying = false
        } else {
            seek(to: range.playbackStart(from: playhead))
            player.play()
            isPlaying = true
        }
    }

    func nudge(by steps: Int) {
        seek(to: playhead + Double(steps) * nudgeStep, pause: true)
    }

    func setIn() { range.setStart(playhead) }
    func setOut() { range.setEnd(playhead) }

    /// One seek at a time, always to the newest position (exact frames).
    private func chase() {
        guard !seekInFlight, let target = pendingSeek else { return }
        pendingSeek = nil
        seekInFlight = true
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.seekInFlight = false
                self.chase()
            }
        }
    }

    private func playBurst() {
        burstEnd?.cancel()
        player.play()
        let end = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.player.pause()
            self.burstEnd = nil
        }
        burstEnd = end
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: end)
    }

    private func stopBurst() {
        burstEnd?.cancel()
        burstEnd = nil
    }

    // MARK: Export

    /// Next to the original, or through a save panel; nil when the panel was cancelled.
    func exportDestination() -> URL? {
        let media = MediaController.shared
        let suggested = media.defaultTrimDestination(for: url, format: options.format)
        if saveNextToOriginal { return suggested }
        let panel = NSSavePanel()
        panel.title = isAudioOnly ? "Export Audio" : "Export Clip"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [options.format.contentType]
        panel.directoryURL = url.deletingLastPathComponent()
        panel.nameFieldStringValue = suggested.lastPathComponent
        guard panel.runModal() == .OK, let chosen = panel.url else { return nil }
        return chosen
    }

    func tearDown() {
        stopBurst()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}
