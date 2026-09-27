import AVFoundation
import SwiftUI

/// The slideshow's content: the slide (with the chosen transition), an
/// optional caption, and controls that appear when the mouse moves.
struct SlideshowView: View {
    @Bindable var model: SlideshowModel
    @State private var optionsOpen = false

    private var background: Color { Color(white: model.options.background.whiteLevel) }

    var body: some View {
        ZStack {
            background.ignoresSafeArea()

            if let displayed = model.displayed {
                slide(displayed)
                    .id(displayed.id)
                    .transition(transition)
            } else if model.slides.isEmpty {
                Text("Nothing to show — turn on Include Videos, or choose other files.")
                    .font(.appBody)
                    .foregroundStyle(Color.appMuted)
            } else {
                ProgressView().controlSize(.small)
            }

            VStack(spacing: AppSpacing.lg) {
                Spacer()
                if model.options.showsCaption, !model.captionLines.isEmpty || model.captionRating != nil {
                    caption
                }
                if model.controlsVisible || optionsOpen {
                    controls
                        .transition(.opacity)
                }
            }
            .padding(.bottom, AppSpacing.xxl * 2)
            .padding(.horizontal, AppSpacing.xxl)

            if model.reachedEnd {
                endCard
            }
        }
        .animation(animation, value: model.displayed?.id)
        .animation(.easeInOut(duration: 0.2), value: model.controlsVisible)
        .environment(\.colorScheme, .dark)
        .onChange(of: optionsOpen) { _, open in model.isInteractingWithControls = open }
    }

    // MARK: Slide

    @ViewBuilder
    private func slide(_ displayed: SlideshowModel.Displayed) -> some View {
        if displayed.isVideo {
            SlideshowVideoSurface(player: model.player)
        } else if let image = displayed.image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(displayed.entry.name)
        } else {
            VStack(spacing: AppSpacing.md) {
                Image(systemName: "photo")
                    .font(.appIcon(40))
                    .foregroundStyle(Color.appMuted)
                Text("\"\(displayed.entry.name)\" can't be shown")
                    .font(.appBody)
                    .foregroundStyle(Color.appMuted)
            }
        }
    }

    private var transition: AnyTransition {
        switch model.options.transition {
        case .none: return .identity
        case .crossfade: return .opacity
        case .slide:
            let forward = model.direction >= 0
            return .asymmetric(
                insertion: .move(edge: forward ? .trailing : .leading),
                removal: .move(edge: forward ? .leading : .trailing)
            )
        }
    }

    private var animation: Animation? {
        switch model.options.transition {
        case .none: return nil
        case .crossfade: return .easeInOut(duration: 0.6)
        case .slide: return .easeInOut(duration: 0.45)
        }
    }

    // MARK: Caption

    private var caption: some View {
        VStack(spacing: AppSpacing.xs) {
            ForEach(Array(model.captionLines.enumerated()), id: \.offset) { index, line in
                Text(line)
                    .font(index == 0 && model.options.showFileName ? .appHeadline : .appCallout)
                    .foregroundStyle(Color.appPrimaryText.opacity(index == 0 ? 1 : 0.85))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            if let rating = model.captionRating {
                if rating > 0 {
                    StarRatingView(rating: rating, size: 12, fillColor: .favoriteGold)
                } else {
                    Text("Unrated")
                        .font(.appCaption)
                        .foregroundStyle(Color.appMuted)
                }
            }
        }
        .padding(.horizontal, AppSpacing.xl)
        .padding(.vertical, AppSpacing.md)
        .frame(maxWidth: 820)
        .background(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous).fill(Color.appOverlaySurface))
        .accessibilityElement(children: .combine)
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: AppSpacing.md) {
            controlButton("backward.end.fill", label: "Previous (←)") { model.previous() }
            controlButton(model.isPlaying ? "pause.fill" : "play.fill", label: model.isPlaying ? "Pause (Space)" : "Play (Space)") {
                model.togglePlay()
            }
            controlButton("forward.end.fill", label: "Next (→)") { model.next() }

            Text(model.sequence.positionText)
                .font(.appCalloutEmphasis)
                .foregroundStyle(Color.appPrimaryText)
                .monospacedDigit()
                .frame(minWidth: 56)

            Rectangle()
                .fill(Color.appOverlayDivider)
                .frame(width: 1, height: 18)

            Button {
                optionsOpen.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.appHeadline)
                    .foregroundStyle(Color.appPrimaryText)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(AppAdaptiveButtonStyle())
            .help("Slideshow Options")
            .accessibilityLabel("Slideshow Options")
            .popover(isPresented: $optionsOpen, arrowEdge: .top) {
                SlideshowOptionsView(options: $model.options)
            }

            controlButton("xmark", label: "End Slideshow (Esc)") { model.close() }
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.sm)
        .background(Capsule().fill(Color.appOverlaySurface))
        .overlay(Capsule().strokeBorder(Color.appOverlayStroke, lineWidth: 1))
        .shadow(color: Color.appShadowColor, radius: 14, y: 6)
        .onHover { model.isInteractingWithControls = $0 || optionsOpen }
    }

    private func controlButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.appHeadline)
                .foregroundStyle(Color.appPrimaryText)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(AppAdaptiveButtonStyle())
        .help(label)
        .accessibilityLabel(label)
    }

    private var endCard: some View {
        VStack(spacing: AppSpacing.lg) {
            Text("End of Slideshow")
                .font(.appLargeTitle)
                .foregroundStyle(Color.appPrimaryText)
            HStack(spacing: AppSpacing.md) {
                Button("Play Again") { model.restart() }
                    .buttonStyle(AppPrimaryButtonStyle())
                Button("Close") { model.close() }
                    .buttonStyle(AppLabeledButtonStyle())
            }
        }
        .padding(AppSpacing.xxl)
        .background(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous).fill(Color.appOverlaySurface))
    }
}

// MARK: - Options

struct SlideshowOptionsView: View {
    @Binding var options: SlideshowOptions

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            Text("Slideshow")
                .font(.appHeadline)
                .foregroundStyle(Color.appPrimaryText)

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                HStack {
                    Text("Interval")
                        .font(.appCalloutEmphasis)
                        .foregroundStyle(Color.appMuted)
                    Spacer()
                    Text("\(Int(options.clampedInterval)) s")
                        .font(.appCallout)
                        .foregroundStyle(Color.appPrimaryText)
                        .monospacedDigit()
                }
                Slider(value: $options.interval, in: SlideshowOptions.intervalRange, step: 1)
                    .tint(Color.appAccent)
                    .accessibilityLabel("Interval")
                    .accessibilityValue("\(Int(options.clampedInterval)) seconds")
            }

            row("Transition") {
                Picker("Transition", selection: $options.transition) {
                    ForEach(SlideshowTransition.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            row("Background") {
                Picker("Background", selection: $options.background) {
                    ForEach(SlideshowBackground.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }

            Divider().background(Color.appBorder)

            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                toggle("Shuffle", isOn: $options.shuffle)
                toggle("Loop", isOn: $options.loop)
                toggle("Include videos (play, then move on)", isOn: $options.includeVideos)
            }

            Divider().background(Color.appBorder)

            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                Text("Caption")
                    .font(.appCalloutEmphasis)
                    .foregroundStyle(Color.appMuted)
                toggle("File name", isOn: $options.showFileName)
                toggle("Prompt excerpt", isOn: $options.showPromptExcerpt)
                toggle("Rating", isOn: $options.showRating)
            }
        }
        .padding(AppSpacing.xl)
        .frame(width: 320)
    }

    private func row(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: AppSpacing.md) {
            Text(title)
                .font(.appCalloutEmphasis)
                .foregroundStyle(Color.appMuted)
                .frame(width: 80, alignment: .leading)
            content()
        }
    }

    private func toggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(Color.appAccent)
            .font(.appCallout)
    }
}

// MARK: - Video

/// A plain player layer (no controls: the slideshow's own bar drives it).
struct SlideshowVideoSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }

    final class PlayerLayerView: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            playerLayer.videoGravity = .resizeAspect
            layer?.addSublayer(playerLayer)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }
    }
}
