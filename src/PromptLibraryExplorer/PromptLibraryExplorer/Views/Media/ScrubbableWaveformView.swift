import SwiftUI

/// A large waveform for the audio player: click to seek, drag to select a region.
/// Peaks come from `MediaWaveformService` (cached); played audio is tinted.
struct ScrubbableWaveformView: View {
    let url: URL?
    let currentTime: Double
    let duration: Double
    /// Selected region in seconds (nil = none).
    @Binding var selection: ClosedRange<Double>?
    let onSeek: (Double) -> Void

    @State private var peaks: [Float] = []
    @State private var isLoading = false
    @State private var dragStartFraction: Double?

    private static let clickSlop: CGFloat = 3

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                    .fill(Color.appSurface.opacity(0.6))

                if let selection, duration > 0 {
                    let x0 = size.width * selection.lowerBound / duration
                    let x1 = size.width * selection.upperBound / duration
                    Rectangle()
                        .fill(Color.badgeAudio.opacity(0.18))
                        .overlay(alignment: .leading) { Rectangle().fill(Color.badgeAudioText).frame(width: 1) }
                        .overlay(alignment: .trailing) { Rectangle().fill(Color.badgeAudioText).frame(width: 1) }
                        .frame(width: max(x1 - x0, 1))
                        .offset(x: x0)
                }

                waveformShape(size: size)

                if duration > 0 {
                    Rectangle()
                        .fill(Color.appPrimaryText)
                        .frame(width: 1.5)
                        .offset(x: min(max(size.width * currentTime / duration, 0), size.width) - 0.75)
                }

                if isLoading && peaks.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
            .contentShape(Rectangle())
            .gesture(scrubGesture(width: size.width))
        }
        .task(id: url) {
            await loadPeaks()
        }
        .accessibilityElement()
        .accessibilityLabel("Waveform")
        .accessibilityValue("\(MediaTimeMath.displayTimecode(currentTime, showsTenths: false)) of \(MediaTimeMath.displayTimecode(duration, showsTenths: false))")
        .accessibilityAdjustableAction { direction in
            let step = max(duration / 20, 1)
            switch direction {
            case .increment: onSeek(min(currentTime + step, duration))
            case .decrement: onSeek(max(currentTime - step, 0))
            @unknown default: break
            }
        }
        .help("Click to seek, drag to select a region")
    }

    @ViewBuilder
    private func waveformShape(size: CGSize) -> some View {
        let values = WaveformMath.normalized(peaks)
        let played = duration > 0 ? currentTime / duration : 0
        WaveformBars(values: values)
            .fill(Color.appMuted.opacity(0.55))
            .overlay {
                WaveformBars(values: values)
                    .fill(Color.badgeAudioText)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: size.width * min(max(played, 0), 1))
                    }
            }
            .padding(.vertical, AppSpacing.sm)
    }

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard width > 0, duration > 0 else { return }
                let start = MediaTimeMath.fraction(forX: value.startLocation.x, width: width)
                let now = MediaTimeMath.fraction(forX: value.location.x, width: width)
                if abs(value.translation.width) > Self.clickSlop {
                    dragStartFraction = start
                    let lower = min(start, now) * duration
                    let upper = max(start, now) * duration
                    selection = upper - lower >= MediaTrimRange.minimumLength ? lower...upper : nil
                }
            }
            .onEnded { value in
                guard width > 0, duration > 0 else { return }
                let now = MediaTimeMath.fraction(forX: value.location.x, width: width)
                if dragStartFraction == nil {
                    // A click: seek there.
                    onSeek(MediaTimeMath.time(forFraction: now, duration: duration))
                } else if let selection {
                    onSeek(selection.lowerBound)
                }
                dragStartFraction = nil
            }
    }

    private func loadPeaks() async {
        peaks = []
        guard let url else { return }
        isLoading = true
        let loaded = await MediaWaveformService.peaks(for: url, bucketCount: MediaWaveformService.playerBucketCount)
        guard !Task.isCancelled else { return }
        isLoading = false
        peaks = loaded ?? []
    }
}

/// Mirrored bars across the vertical middle, one per value (0…1).
struct WaveformBars: Shape {
    let values: [Float]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard !values.isEmpty, rect.width > 0 else {
            path.addRect(CGRect(x: rect.minX, y: rect.midY - 0.5, width: rect.width, height: 1))
            return path
        }
        // Group values so bars stay at least ~2 pt apart.
        let maxBars = max(Int(rect.width / 2.5), 1)
        let bars = values.count > maxBars ? WaveformMath.downsample(values, to: maxBars) : values
        let slot = rect.width / CGFloat(bars.count)
        let barWidth = max(slot * 0.7, 0.8)
        for (index, value) in bars.enumerated() {
            let height = max(CGFloat(value) * rect.height, 1)
            path.addRoundedRect(
                in: CGRect(x: rect.minX + CGFloat(index) * slot, y: rect.midY - height / 2, width: barWidth, height: height),
                cornerSize: CGSize(width: barWidth / 2, height: min(barWidth / 2, height / 2))
            )
        }
        return path
    }
}
