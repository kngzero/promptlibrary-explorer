import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// Trim & Export Clip: in / out handles over a frame-strip timeline, preview playback of
/// the range, and export as MP4 (H.264 / HEVC; passthrough when the source already uses
/// that codec) or an animated GIF. The original is never modified or overwritten.
struct MediaTrimSheet: View {
    let request: MediaController.TrimRequest

    @Environment(\.dismiss) private var dismiss
    @State private var player = AVPlayer()
    @State private var info: MediaFrameExtractor.VideoInfo?
    @State private var loadError: String?
    @State private var range = MediaTrimRange(duration: 0)
    @State private var playhead: Double = 0
    @State private var isPlaying = false
    @State private var timeObserver: Any?
    @State private var strip: MediaScrubStripService.Strip?
    @State private var options = MediaClipExportOptions()
    @State private var saveNextToOriginal = true

    private var media: MediaController { MediaController.shared }
    private var url: URL { request.url }

    var body: some View {
        VStack(spacing: 0) {
            FeatureSheetHeader(
                title: "Trim & Export Clip",
                subtitle: url.lastPathComponent,
                systemImage: "timeline.selection",
                onClose: close
            )
            .disabled(media.isExporting)

            if let loadError {
                FeatureEmptyState(systemImage: "film", title: "Can't Trim This File", message: loadError)
            } else if let info {
                ScrollView {
                    VStack(alignment: .leading, spacing: AppSpacing.lg) {
                        MediaPlayerLayerView(player: player)
                            .frame(maxWidth: .infinity)
                            .frame(height: 280)
                            .background(Color.black, in: RoundedRectangle(cornerRadius: AppRadius.md))
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))

                        MediaTrimTimeline(
                            range: $range,
                            playhead: playhead,
                            frames: strip?.frames ?? [],
                            onScrub: { seek(to: $0, pause: true) }
                        )
                        .frame(height: 56)

                        transportRow
                        Divider().background(Color.appBorder)
                        formatSection(info: info)
                        destinationSection
                    }
                    .padding(AppSpacing.xl)
                }
                .disabled(media.isExporting)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            footer
        }
        .frame(width: 640, height: 720)
        .background(Color.appBackground)
        .task { await load() }
        .onDisappear { tearDown() }
    }

    // MARK: Sections

    private var transportRow: some View {
        HStack(spacing: AppSpacing.md) {
            Button {
                togglePreview()
            } label: {
                Label(isPlaying ? "Pause" : "Play Range", systemImage: isPlaying ? "pause.fill" : "play.fill")
                    .font(.appCallout)
            }
            .buttonStyle(AppLabeledButtonStyle())
            .help(isPlaying ? "Pause" : "Play the selected range (loops)")

            Button("Set In") { range.setStart(playhead) }
                .buttonStyle(AppLabeledButtonStyle())
                .help("Start the clip at the playhead")
            Button("Set Out") { range.setEnd(playhead) }
                .buttonStyle(AppLabeledButtonStyle())
                .help("End the clip at the playhead")

            Spacer()

            VStack(alignment: .trailing, spacing: AppSpacing.xxs) {
                Text("\(MediaTimeMath.displayTimecode(range.start)) – \(MediaTimeMath.displayTimecode(range.end))")
                    .font(.appMono)
                    .foregroundStyle(Color.appPrimaryText)
                Text("Length \(MediaTimeMath.displayTimecode(range.length))")
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
            }
        }
    }

    @ViewBuilder
    private func formatSection(info: MediaFrameExtractor.VideoInfo) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("Format")
                .font(.appHeadline)
                .foregroundStyle(Color.appPrimaryText)
            Picker("Format", selection: $options.format) {
                ForEach(MediaClipExportOptions.Format.allCases) { format in
                    Text(format.title).tag(format)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if options.format == .gif {
                HStack(spacing: AppSpacing.lg) {
                    Text("Frame rate")
                        .font(.appCallout)
                        .foregroundStyle(Color.appPrimaryText)
                    Slider(
                        value: Binding(get: { Double(options.gifFPS) }, set: { options.gifFPS = Int($0.rounded()) }),
                        in: Double(MediaClipExportOptions.gifFPSRange.lowerBound)...Double(MediaClipExportOptions.gifFPSRange.upperBound),
                        step: 1
                    )
                    .tint(Color.appAccent)
                    .accessibilityLabel("GIF Frame Rate")
                    Text("\(options.gifFPS) fps")
                        .font(.appMono)
                        .foregroundStyle(Color.appMuted)
                        .frame(width: 56, alignment: .trailing)
                }
                HStack(spacing: AppSpacing.lg) {
                    Picker("Maximum width", selection: $options.gifMaxWidth) {
                        ForEach(MediaClipExportOptions.gifWidths, id: \.self) { width in
                            Text("\(width) px").tag(width)
                        }
                    }
                    .frame(maxWidth: 260)
                    Toggle("Loop forever", isOn: $options.gifLoops)
                    Spacer()
                }
                .font(.appCallout)
                Text(gifSummary(info: info))
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
            } else {
                Text(movieSummary(info: info))
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
            }
        }
    }

    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("Save To")
                .font(.appHeadline)
                .foregroundStyle(Color.appPrimaryText)
            Picker("Save To", selection: $saveNextToOriginal) {
                Text("Next to the original").tag(true)
                Text("Choose when exporting…").tag(false)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .font(.appCallout)
            if saveNextToOriginal {
                Text(media.defaultTrimDestination(for: url, format: options.format).lastPathComponent)
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        FeatureSheetFooter {
            if let job = media.exportJob {
                ProgressView(value: job.progress)
                    .tint(Color.appAccent)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Export Progress")
                Text("Exporting \(job.destination.lastPathComponent)…")
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Cancel Export") { media.cancelExport() }
            } else {
                Spacer()
                Button("Export") { export() }
                    .buttonStyle(AppPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(info?.hasVideo != true || range.length <= 0)
            }
        }
    }

    private func movieSummary(info: MediaFrameExtractor.VideoInfo) -> String {
        let matches = (options.format == .h264 && info.codec == kCMVideoCodecType_H264)
            || (options.format == .hevc && info.codec == kCMVideoCodecType_HEVC)
        let codecNote = matches
            ? "The source already uses this codec, so the clip is copied without re-encoding when possible (cuts snap near keyframes)."
            : "The clip is re-encoded to \(options.format == .hevc ? "HEVC" : "H.264") at the highest quality."
        let audioNote = info.hasAudio ? " Audio is kept." : ""
        return codecNote + audioNote
    }

    private func gifSummary(info: MediaFrameExtractor.VideoInfo) -> String {
        let frames = MediaTimeMath.gifFrameTimes(start: range.start, length: range.length, fps: options.gifFPS).count
        let size = MediaClipExporter.gifFrameSize(natural: info.naturalSize, maxWidth: options.gifMaxWidth)
        return "\(frames) frames at \(Int(size.width))×\(Int(size.height)). GIFs have no sound and grow quickly with length, size and frame rate."
    }

    // MARK: Actions

    private func load() async {
        do {
            let loaded = try await MediaFrameExtractor.info(for: url)
            guard loaded.hasVideo else {
                loadError = "\(url.lastPathComponent) has no video track."
                return
            }
            info = loaded
            range = MediaTrimRange(duration: loaded.duration)
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            player.actionAtItemEnd = .pause
            startObserving()
            seek(to: min(max(request.startTime, 0), loaded.duration), pause: true)
            strip = await MediaScrubStripService.strip(for: url)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func startObserving() {
        let interval = CMTime(seconds: 1.0 / 30, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            let seconds = time.seconds.isFinite ? time.seconds : 0
            MainActor.assumeIsolated {
                playhead = seconds
                isPlaying = player.timeControlStatus == .playing
                // Preview loops inside the range.
                if isPlaying, seconds >= range.end - 0.01 {
                    seek(to: range.start, pause: false)
                }
            }
        }
    }

    private func seek(to seconds: Double, pause: Bool) {
        if pause { player.pause() }
        playhead = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func togglePreview() {
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            seek(to: range.playbackStart(from: playhead), pause: false)
            player.play()
        }
    }

    private func export() {
        player.pause()
        let destination: URL
        if saveNextToOriginal {
            destination = media.defaultTrimDestination(for: url, format: options.format)
        } else {
            let panel = NSSavePanel()
            panel.title = "Export Clip"
            panel.canCreateDirectories = true
            panel.allowedContentTypes = [options.format.contentType]
            panel.directoryURL = url.deletingLastPathComponent()
            panel.nameFieldStringValue = media.defaultTrimDestination(for: url, format: options.format).lastPathComponent
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            destination = chosen
        }
        media.startExport(source: url, range: range, options: options, destination: destination) { success in
            if success { close() }
        }
    }

    private func close() {
        guard !media.isExporting else { return }
        tearDown()
        dismiss()
    }

    private func tearDown() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}

// MARK: - Timeline

/// Frame strip with draggable in / out handles, a dimmed outside region and a playhead.
/// Dragging a handle moves that point (and shows its frame); dragging elsewhere scrubs.
struct MediaTrimTimeline: View {
    @Binding var range: MediaTrimRange
    let playhead: Double
    let frames: [NSImage]
    let onScrub: (Double) -> Void

    private enum DragTarget { case start, end, scrub }
    @State private var dragTarget: DragTarget?

    private let handleWidth: CGFloat = 10

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let x0 = width * range.startFraction
            let x1 = width * range.endFraction
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    if frames.isEmpty {
                        Rectangle().fill(Color.appSurface)
                    } else {
                        ForEach(frames.indices, id: \.self) { index in
                            Image(nsImage: frames[index])
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: width / CGFloat(frames.count), height: height)
                                .clipped()
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm))

                // Outside the range recedes.
                Rectangle().fill(Color.black.opacity(0.55)).frame(width: max(x0, 0))
                Rectangle().fill(Color.black.opacity(0.55)).frame(width: max(width - x1, 0)).offset(x: x1)

                // The kept range.
                RoundedRectangle(cornerRadius: AppRadius.xs)
                    .strokeBorder(Color.appAccent, lineWidth: 2)
                    .frame(width: max(x1 - x0, 2))
                    .offset(x: x0)

                handle(label: "In Point", value: range.start).offset(x: x0 - handleWidth / 2)
                handle(label: "Out Point", value: range.end).offset(x: x1 - handleWidth / 2)

                if range.duration > 0 {
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 2, height: height + 6)
                        .shadow(color: Color.black.opacity(0.5), radius: 1)
                        .offset(x: width * min(max(playhead / range.duration, 0), 1) - 1)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard width > 0 else { return }
                        if dragTarget == nil {
                            let startX = value.startLocation.x
                            if abs(startX - x0) <= handleWidth { dragTarget = .start }
                            else if abs(startX - x1) <= handleWidth { dragTarget = .end }
                            else { dragTarget = .scrub }
                        }
                        let fraction = MediaTimeMath.fraction(forX: value.location.x, width: width)
                        switch dragTarget {
                        case .start:
                            range.setStart(fraction: fraction)
                            onScrub(range.start)
                        case .end:
                            range.setEnd(fraction: fraction)
                            onScrub(range.end)
                        default:
                            onScrub(MediaTimeMath.time(forFraction: fraction, duration: range.duration))
                        }
                    }
                    .onEnded { _ in dragTarget = nil }
            )
        }
        .accessibilityElement(children: .contain)
        .help("Drag the handles to set the in and out points; drag elsewhere to scrub")
    }

    private func handle(label: String, value: Double) -> some View {
        RoundedRectangle(cornerRadius: AppRadius.xs)
            .fill(Color.appAccent)
            .frame(width: handleWidth)
            .overlay(
                Capsule().fill(Color.appOnAccent.opacity(0.8)).frame(width: 2, height: 16)
            )
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue(MediaTimeMath.displayTimecode(value))
            .accessibilityAdjustableAction { direction in
                let step = max(range.duration / 50, 0.1)
                let delta = direction == .increment ? step : -step
                if label == "In Point" { range.setStart(range.start + delta) } else { range.setEnd(range.end + delta) }
            }
    }
}

// MARK: - Player layer

/// A bare AVPlayerLayer (no transport controls: the trim sheet has its own).
struct MediaPlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerNSView {
        let view = PlayerLayerNSView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ nsView: PlayerLayerNSView, context: Context) {
        if nsView.playerLayer.player !== player { nsView.playerLayer.player = player }
    }

    static func dismantleNSView(_ nsView: PlayerLayerNSView, coordinator: ()) {
        nsView.playerLayer.player = nil
    }

    final class PlayerLayerNSView: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            playerLayer.videoGravity = .resizeAspect
            layer?.addSublayer(playerLayer)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }
    }
}
