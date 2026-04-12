import AVFoundation
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
        VStack(spacing: 24) {
            // Album art placeholder
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.badgeAudio.opacity(0.15))
                    .frame(width: 180, height: 180)

                Image(systemName: "waveform")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(Color.badgeAudio)
            }

            // File name
            Text(fileName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.appPrimaryText)
                .lineLimit(2)
                .multilineTextAlignment(.center)

            // Time + seek bar
            VStack(spacing: 4) {
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
            HStack(spacing: 32) {
                Button {
                    skipBackward()
                } label: {
                    Image(systemName: "gobackward.10")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.appPrimaryText)
                }
                .buttonStyle(.plain)

                Button {
                    togglePlayback()
                } label: {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(Color.badgeAudio)
                }
                .buttonStyle(.plain)

                Button {
                    skipForward()
                } label: {
                    Image(systemName: "goforward.10")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.appPrimaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(32)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.appElevatedSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.appControlBorder, lineWidth: 1)
                )
        )
        .onAppear {
            startObserving()
        }
        .onDisappear {
            stopObserving()
        }
        .onChange(of: player.currentItem) { _, _ in
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
        let target = min(currentTime + 10, duration)
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

        Task {
            if let dur = try? await item.asset.load(.duration) {
                let seconds = dur.seconds
                if !seconds.isNaN && seconds > 0 {
                    await MainActor.run {
                        duration = seconds
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
