import AVFoundation
import Combine
import SwiftUI

/// A styled audio player UI for the lightbox and details panel: a scrubbable waveform
/// (click to seek, drag to select a region, loop the region), playback controls and
/// time labels.
struct AudioPlayerView: View {
    let player: AVPlayer
    let fileName: String

    @State private var isPlaying = false
    @State private var currentTime: TimeInterval = 0
    @State private var duration: TimeInterval = 0
    @State private var isSeeking = false
    @State private var timeObserver: Any?
    /// The playing file (for the waveform); follows `player.currentItem`.
    @State private var audioURL: URL?
    /// Waveform region (seconds) and whether playback loops inside it.
    @State private var selection: ClosedRange<Double>?
    @State private var loopsSelection = false
    @State private var lastObservedTime: TimeInterval = 0

    var body: some View {
        VStack(spacing: AppSpacing.xl) {
            // Album art placeholder
            ZStack {
                RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                    .fill(Color.badgeAudio.opacity(0.15))
                    .frame(width: 72, height: 72)

                Image(systemName: "waveform")
                    .font(.appIcon(30, weight: .light))
                    .foregroundStyle(Color.badgeAudioText)
            }

            // File name
            Text(fileName)
                .font(.appIcon(15, weight: .semibold))
                .foregroundStyle(Color.appPrimaryText)
                .lineLimit(2)
                .multilineTextAlignment(.center)

            // Waveform: click to seek, drag to select a region.
            ScrubbableWaveformView(
                url: audioURL,
                currentTime: currentTime,
                duration: duration,
                selection: $selection,
                onSeek: { seek(to: $0) }
            )
            .frame(height: 88)
            .onChange(of: selection) { _, newValue in
                if newValue == nil { loopsSelection = false }
            }

            // Time labels (the waveform above is the seek bar)
            VStack(spacing: AppSpacing.xs) {
                HStack {
                    Text(formatTime(currentTime))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.appMuted)
                    Spacer()
                    Text(formatTime(duration))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.appMuted)
                }
            }

            // Playback controls
            HStack(spacing: AppSpacing.xxxl) {
                Button {
                    skipBackward()
                } label: {
                    Image(systemName: "gobackward.10")
                        .font(.appIcon(22))
                        .foregroundStyle(Color.appPrimaryText)
                }
                .buttonStyle(AppAdaptiveButtonStyle())
                .help("Skip Back 10 Seconds")
                .accessibilityLabel("Skip Back 10 Seconds")

                Button {
                    togglePlayback()
                } label: {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.appIcon(48))
                        .foregroundStyle(Color.badgeAudioText)
                }
                .buttonStyle(AppAdaptiveButtonStyle())
                .help(isPlaying ? "Pause" : "Play")
                .accessibilityLabel(isPlaying ? "Pause" : "Play")

                Button {
                    skipForward()
                } label: {
                    Image(systemName: "goforward.10")
                        .font(.appIcon(22))
                        .foregroundStyle(Color.appPrimaryText)
                }
                .buttonStyle(AppAdaptiveButtonStyle())
                .help("Skip Forward 10 Seconds")
                .accessibilityLabel("Skip Forward 10 Seconds")
            }

            selectionControls
        }
        .padding(AppSpacing.xxxl)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                .fill(Color.appElevatedSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                        .strokeBorder(Color.appControlBorder, lineWidth: 1)
                )
        )
        .onAppear {
            startObserving()
        }
        .onDisappear {
            stopObserving()
        }
        // AVPlayer isn't observable by SwiftUI, so `onChange(of: player.currentItem)`
        // never fires. KVO the current item instead.
        .onReceive(player.publisher(for: \.currentItem)) { item in
            currentTime = 0
            selection = nil
            loopsSelection = false
            audioURL = (item?.asset as? AVURLAsset)?.url
            updateDuration()
        }
        // The item ends before a region at the very end loops: start the region again.
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { note in
            guard let item = note.object as? AVPlayerItem, item === player.currentItem,
                  loopsSelection, let selection else { return }
            seek(to: selection.lowerBound)
            player.play()
        }
    }

    /// Loop Selection and Clear Selection, shown once a region is selected.
    @ViewBuilder
    private var selectionControls: some View {
        HStack(spacing: AppSpacing.md) {
            if let selection {
                Text("\(MediaTimeMath.displayTimecode(selection.lowerBound)) – \(MediaTimeMath.displayTimecode(selection.upperBound))")
                    .font(.appMono)
                    .foregroundStyle(Color.appMuted)
            } else {
                Text("Drag across the waveform to select a region")
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
            }
            Spacer(minLength: 0)
            Button {
                loopsSelection.toggle()
                if loopsSelection, let selection {
                    if !(selection.lowerBound...selection.upperBound).contains(currentTime) {
                        seek(to: selection.lowerBound)
                    }
                    player.play()
                }
            } label: {
                Image(systemName: "repeat")
                    .font(.appIcon(13, weight: .medium))
            }
            .buttonStyle(AppIconButtonStyle(restingForeground: loopsSelection ? Color.badgeAudioText : Color.appMuted))
            .disabled(selection == nil)
            .help(loopsSelection ? "Stop Looping the Selection" : "Loop the Selection")
            .accessibilityLabel("Loop Selection")
            .accessibilityValue(loopsSelection ? "On" : "Off")

            Button {
                selection = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.appIcon(12, weight: .medium))
            }
            .buttonStyle(AppIconButtonStyle(restingForeground: Color.appMuted))
            .disabled(selection == nil)
            .help("Clear Selection")
            .accessibilityLabel("Clear Selection")
        }
    }

    private func seek(to seconds: TimeInterval) {
        currentTime = seconds
        lastObservedTime = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func togglePlayback() {
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
    }

    private func skipBackward() {
        let target = max(currentTime - 10, 0)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    private func skipForward() {
        var target = currentTime + 10
        // Only clamp once the duration is actually known; clamping to 0 would rewind.
        if duration.isFinite, duration > 0 {
            target = min(target, duration)
        }
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    private func startObserving() {
        updateDuration()

        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            if !isSeeking {
                currentTime = time.seconds.isNaN ? 0 : time.seconds
            }
            // Loop inside the selected region: crossing its end jumps back to its start.
            let now = time.seconds.isNaN ? 0 : time.seconds
            if loopsSelection, let selection, player.timeControlStatus == .playing,
               lastObservedTime < selection.upperBound, now >= selection.upperBound
            {
                seek(to: selection.lowerBound)
            } else {
                lastObservedTime = now
            }
            isPlaying = player.timeControlStatus == .playing
            // Fallback in case the async duration load hasn't landed yet.
            if duration <= 0,
               let itemDuration = player.currentItem?.duration.seconds,
               itemDuration.isFinite, itemDuration > 0
            {
                duration = itemDuration
            }
        }
    }

    private func stopObserving() {
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
            timeObserver = nil
        }
    }

    private func updateDuration() {
        guard let item = player.currentItem else {
            duration = 0
            return
        }

        duration = 0
        Task {
            if let dur = try? await item.asset.load(.duration) {
                let seconds = dur.seconds
                if seconds.isFinite && seconds > 0 {
                    await MainActor.run {
                        // Ignore a late result for an item that has since been replaced.
                        if player.currentItem === item {
                            duration = seconds
                        }
                    }
                }
            }
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        guard !time.isNaN && time.isFinite else { return "0:00" }
        let totalSeconds = Int(time)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
