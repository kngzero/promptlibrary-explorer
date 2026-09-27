import AVFoundation
import Combine
import SwiftUI

/// A styled audio player UI for the lightbox, showing waveform icon, playback controls,
/// a seek slider, and time labels.
struct AudioPlayerView: View {
    let player: AVPlayer
    let fileName: String

    @State private var isPlaying = false
    @State private var currentTime: TimeInterval = 0
    @State private var duration: TimeInterval = 0
    @State private var isSeeking = false
    @State private var timeObserver: Any?

    var body: some View {
        VStack(spacing: AppSpacing.xxl) {
            // Album art placeholder
            ZStack {
                RoundedRectangle(cornerRadius: AppRadius.xxl, style: .continuous)
                    .fill(Color.badgeAudio.opacity(0.15))
                    .frame(width: 180, height: 180)

                Image(systemName: "waveform")
                    .font(.appIcon(64, weight: .light))
                    .foregroundStyle(Color.badgeAudioText)
            }

            // File name
            Text(fileName)
                .font(.appIcon(15, weight: .semibold))
                .foregroundStyle(Color.appPrimaryText)
                .lineLimit(2)
                .multilineTextAlignment(.center)

            // Time + seek bar
            VStack(spacing: AppSpacing.xs) {
                Slider(
                    value: Binding(
                        get: { duration > 0 ? currentTime / duration : 0 },
                        set: { newValue in
                            isSeeking = true
                            currentTime = newValue * duration
                        }
                    ),
                    in: 0...1,
                    onEditingChanged: { editing in
                        if !editing {
                            let target = CMTime(seconds: currentTime, preferredTimescale: 600)
                            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
                            isSeeking = false
                        }
                    }
                )
                .tint(Color.badgeAudio)
                .accessibilityLabel("Playback Position")
                .accessibilityValue("\(formatTime(currentTime)) of \(formatTime(duration))")

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
        .onReceive(player.publisher(for: \.currentItem)) { _ in
            currentTime = 0
            updateDuration()
        }
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
