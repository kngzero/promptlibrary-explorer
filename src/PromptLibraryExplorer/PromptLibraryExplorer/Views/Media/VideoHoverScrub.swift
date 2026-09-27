import SwiftUI

/// Hover scrubbing for a video tile: moving the pointer across it shows the frame at that
/// relative time, with a thin progress hairline; leaving shows the poster again.
///
/// The frame strip (~12 frames) is generated on the first hover that dwells briefly (a
/// quick sweep across the grid starts nothing), off the main actor, and cached in memory
/// and on disk. Only hover is observed — `FileDragSource` still owns clicks and drags, and
/// the overlay never takes hits.
struct VideoHoverScrubModifier: ViewModifier {
    let url: URL
    let isVideo: Bool
    var hairlineHeight: CGFloat = 2
    var cornerRadius: CGFloat = AppRadius.sm

    @State private var hoverX: CGFloat?
    @State private var width: CGFloat = 0
    @State private var strip: MediaScrubStripService.Strip?
    @State private var loadTask: Task<Void, Never>?

    /// A hover must rest this long before a strip is generated.
    private static let dwell: Duration = .milliseconds(140)

    private var isEnabled: Bool {
        isVideo && MediaController.shared.hoverScrubEnabled
    }

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .overlay { scrubOverlay }
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { width = proxy.size.width }
                            .onChange(of: proxy.size.width) { _, newWidth in width = newWidth }
                    }
                }
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case let .active(location):
                        hoverX = location.x
                        beginLoadingIfNeeded()
                    case .ended:
                        hoverX = nil
                        if strip == nil {
                            loadTask?.cancel()
                            loadTask = nil
                        }
                    }
                }
                .onChange(of: url) { _, _ in
                    loadTask?.cancel()
                    loadTask = nil
                    strip = nil
                }
                .onDisappear {
                    loadTask?.cancel()
                    loadTask = nil
                }
        } else {
            content
        }
    }

    @ViewBuilder
    private var scrubOverlay: some View {
        if let hoverX, width > 0 {
            let fraction = MediaTimeMath.fraction(forX: hoverX, width: width)
            ZStack(alignment: .bottomLeading) {
                if let strip, !strip.frames.isEmpty {
                    let index = MediaTimeMath.frameIndex(forX: hoverX, width: width, frameCount: strip.frames.count)
                    Image(nsImage: strip.frames[index])
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                }
                GeometryReader { proxy in
                    Rectangle()
                        .fill(Color.appAccent)
                        .frame(width: max(proxy.size.width * fraction, 1), height: hairlineHeight)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func beginLoadingIfNeeded() {
        guard strip == nil, loadTask == nil else { return }
        if let cached = MediaScrubStripService.cachedStrip(for: url) {
            strip = cached
            return
        }
        let url = url
        loadTask = Task {
            try? await Task.sleep(for: Self.dwell)
            guard !Task.isCancelled else { return }
            let loaded = await MediaScrubStripService.strip(for: url)
            guard !Task.isCancelled else { return }
            strip = loaded
            // Keep the task handle when nothing loaded (no video track): don't retry per move.
            if loaded != nil { loadTask = nil }
        }
    }
}

extension View {
    /// Adds hover scrubbing when `isVideo` and Settings ▸ Appearance allows it.
    func videoHoverScrub(url: URL, isVideo: Bool, hairlineHeight: CGFloat = 2, cornerRadius: CGFloat = AppRadius.sm) -> some View {
        modifier(VideoHoverScrubModifier(url: url, isVideo: isVideo, hairlineHeight: hairlineHeight, cornerRadius: cornerRadius))
    }
}
