import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// Trim Video / Trim Audio (Tools, the context menu, File ▸ Trim & Export Clip…, the
/// lightbox's Trim…): a full page over the content browser and the details panel, like
/// the image editor. The player fills the page; below it the in / out handles sit over a
/// frame strip (or, for audio, the waveform), with real-time scrubbing. The inspector
/// holds the format and where to save. Video exports as MP4 (H.264 / HEVC; passthrough
/// when the codec already matches) or an animated GIF; audio as M4A. The original is
/// never modified or overwritten. Esc closes, Space plays the range, ← / → step, I / O
/// set the in and out points.
struct MediaTrimPageView: View {
    let session: MediaTrimSession

    private var media: MediaController { MediaController.shared }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.appBorder)
            if let loadError = session.loadError {
                FeatureEmptyState(systemImage: session.isAudioOnly ? "waveform" : "film", title: "Can't Trim This File", message: loadError) {
                    EmptyView()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let info = session.info {
                HStack(spacing: 0) {
                    VStack(spacing: AppSpacing.lg) {
                        stage(info: info)
                        MediaTrimTimeline(
                            range: Bindable(session).range,
                            playhead: session.playhead,
                            frames: session.strip?.frames ?? [],
                            waveform: session.waveform,
                            onScrub: { session.scrub(to: $0) }
                        )
                        .frame(height: info.hasVideo ? 64 : 120)
                        transportRow
                    }
                    .padding(AppSpacing.xl)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Rectangle().fill(Color.appBorder).frame(width: 1)
                    inspector(info: info)
                        .frame(width: 280)
                        .background(Color.appSurface.opacity(0.6))
                }
                .disabled(media.isExporting)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.appBackground)
        .task(id: session.id) { await session.load() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(session.isAudioOnly ? "Trim Audio" : "Trim Video")
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: AppSpacing.md) {
            Image(systemName: session.isAudioOnly ? "waveform" : "scissors")
                .font(.appIcon(15, weight: .semibold))
                .foregroundStyle(Color.appAccent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text(session.isAudioOnly ? "Trim Audio" : "Trim Video")
                    .font(.appTitle)
                    .foregroundStyle(Color.appPrimaryText)
                Text("\(session.name) · The original file is never changed")
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: AppSpacing.lg)
            if let job = media.exportJob {
                ProgressView(value: job.progress)
                    .tint(Color.appAccent)
                    .frame(width: 160)
                    .accessibilityLabel("Export Progress")
                Button("Cancel Export") { media.cancelExport() }
                    .buttonStyle(AppLabeledButtonStyle(height: 28, horizontalPadding: AppSpacing.lg))
            } else {
                // Esc is owned by the key monitor (no key equivalents here).
                Button("Cancel") { media.closeTrim() }
                    .buttonStyle(AppLabeledButtonStyle(height: 28, horizontalPadding: AppSpacing.lg))
                    .help("Close without exporting (Esc)")
                Button { export() } label: {
                    Text("Export")
                        .font(.appCalloutEmphasis)
                }
                .buttonStyle(AppPrimaryButtonStyle(verticalPadding: AppSpacing.xs))
                .disabled(!session.canExport)
                .help("Export the range as a new file")
            }
        }
        .padding(.horizontal, AppSpacing.xl)
        .padding(.vertical, AppSpacing.md)
        .background(Color.appSurface)
    }

    // MARK: Stage

    @ViewBuilder
    private func stage(info: MediaFrameExtractor.VideoInfo) -> some View {
        if info.hasVideo {
            MediaPlayerLayerView(player: session.player)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black, in: RoundedRectangle(cornerRadius: AppRadius.md))
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
        } else {
            VStack(spacing: AppSpacing.sm) {
                Image(systemName: "waveform")
                    .font(.appIcon(40, weight: .light))
                    .foregroundStyle(Color.appAccent)
                Text(MediaTimeMath.displayTimecode(session.playhead))
                    .font(.appIcon(28, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Color.appPrimaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.appCanvasBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: AppRadius.md))
        }
    }

    private var transportRow: some View {
        HStack(spacing: AppSpacing.md) {
            Button {
                session.togglePlay()
            } label: {
                Label(session.isPlaying ? "Pause" : "Play Range", systemImage: session.isPlaying ? "pause.fill" : "play.fill")
                    .font(.appCallout)
            }
            .buttonStyle(AppLabeledButtonStyle())
            .help(session.isPlaying ? "Pause (Space)" : "Play the selected range, looping (Space)")

            Button("Set In") { session.setIn() }
                .buttonStyle(AppLabeledButtonStyle())
                .help("Start at the playhead (I)")
            Button("Set Out") { session.setOut() }
                .buttonStyle(AppLabeledButtonStyle())
                .help("End at the playhead (O)")

            Spacer()

            VStack(alignment: .trailing, spacing: AppSpacing.xxs) {
                Text("\(MediaTimeMath.displayTimecode(session.range.start)) – \(MediaTimeMath.displayTimecode(session.range.end))")
                    .font(.appMono)
                    .foregroundStyle(Color.appPrimaryText)
                Text("Length \(MediaTimeMath.displayTimecode(session.range.length))")
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
            }
        }
    }

    // MARK: Inspector

    private func inspector(info: MediaFrameExtractor.VideoInfo) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.xl) {
                formatSection(info: info)
                Divider().background(Color.appBorder)
                destinationSection
                Divider().background(Color.appBorder)
                Text("Space plays the range · ← / → step (⇧ for 10) · I / O set the in and out points · Esc closes")
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(AppSpacing.xl)
        }
    }

    @ViewBuilder
    private func formatSection(info: MediaFrameExtractor.VideoInfo) -> some View {
        @Bindable var session = session
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("Format")
                .font(.appHeadline)
                .foregroundStyle(Color.appPrimaryText)
            if info.hasVideo {
                Picker("Format", selection: $session.options.format) {
                    ForEach(MediaClipExportOptions.Format.videoFormats) { format in
                        Text(format.title).tag(format)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .font(.appCallout)
            }

            if session.options.format == .m4a {
                Text("\(MediaClipExportOptions.Format.m4a.title), re-encoded at high quality.")
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
            } else if session.options.format == .gif {
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    HStack {
                        Text("Frame rate")
                        Spacer()
                        Text("\(session.options.gifFPS) fps")
                            .font(.appMono)
                            .foregroundStyle(Color.appMuted)
                    }
                    .font(.appCallout)
                    Slider(
                        value: Binding(get: { Double(session.options.gifFPS) }, set: { session.options.gifFPS = Int($0.rounded()) }),
                        in: Double(MediaClipExportOptions.gifFPSRange.lowerBound)...Double(MediaClipExportOptions.gifFPSRange.upperBound),
                        step: 1
                    )
                    .tint(Color.appAccent)
                    .accessibilityLabel("GIF Frame Rate")
                }
                Picker("Maximum width", selection: $session.options.gifMaxWidth) {
                    ForEach(MediaClipExportOptions.gifWidths, id: \.self) { width in
                        Text("\(width) px").tag(width)
                    }
                }
                .font(.appCallout)
                Toggle("Loop forever", isOn: $session.options.gifLoops)
                    .font(.appCallout)
                Text(gifSummary(info: info))
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(movieSummary(info: info))
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var destinationSection: some View {
        @Bindable var session = session
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("Save To")
                .font(.appHeadline)
                .foregroundStyle(Color.appPrimaryText)
            Picker("Save To", selection: $session.saveNextToOriginal) {
                Text("Next to the original").tag(true)
                Text("Choose when exporting…").tag(false)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .font(.appCallout)
            if session.saveNextToOriginal {
                Text(media.defaultTrimDestination(for: session.url, format: session.options.format).lastPathComponent)
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func movieSummary(info: MediaFrameExtractor.VideoInfo) -> String {
        let format = session.options.format
        let matches = (format == .h264 && info.codec == kCMVideoCodecType_H264)
            || (format == .hevc && info.codec == kCMVideoCodecType_HEVC)
        let codecNote = matches
            ? "The source already uses this codec, so the clip is copied without re-encoding when possible (cuts snap near keyframes)."
            : "The clip is re-encoded to \(format == .hevc ? "HEVC" : "H.264") at the highest quality."
        return codecNote + (info.hasAudio ? " Audio is kept." : "")
    }

    private func gifSummary(info: MediaFrameExtractor.VideoInfo) -> String {
        let range = session.range
        let frames = MediaTimeMath.gifFrameTimes(start: range.start, length: range.length, fps: session.options.gifFPS).count
        let size = MediaClipExporter.gifFrameSize(natural: info.naturalSize, maxWidth: session.options.gifMaxWidth)
        return "\(frames) frames at \(Int(size.width))×\(Int(size.height)). GIFs have no sound and grow quickly with length, size and frame rate."
    }

    // MARK: Export

    private func export() {
        if session.isPlaying { session.togglePlay() }
        guard let destination = session.exportDestination() else { return }
        media.startExport(source: session.url, range: session.range, options: session.options, destination: destination) { success in
            if success { media.closeTrim() }
        }
    }
}

// MARK: - Timeline

/// Frame strip (or, for audio, a waveform) with draggable in / out handles, a dimmed
/// outside region and a playhead. Dragging a handle moves that point (and shows its
/// frame); dragging elsewhere scrubs.
struct MediaTrimTimeline: View {
    @Binding var range: MediaTrimRange
    let playhead: Double
    let frames: [NSImage]
    /// Normalized peaks (0…1), drawn when there are no frames.
    var waveform: [Float] = []
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
                            .overlay { if !waveform.isEmpty { waveformBars } }
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

    private var waveformBars: some View {
        Canvas { context, size in
            let count = waveform.count
            guard count > 0 else { return }
            let step = size.width / CGFloat(count)
            let mid = size.height / 2
            var path = Path()
            for (index, peak) in waveform.enumerated() {
                let half = max(CGFloat(peak) * (size.height / 2 - 4), 0.5)
                path.addRect(CGRect(x: CGFloat(index) * step, y: mid - half, width: max(step - 0.5, 0.5), height: half * 2))
            }
            context.fill(path, with: .color(Color.appAccent.opacity(0.7)))
        }
        .accessibilityHidden(true)
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
