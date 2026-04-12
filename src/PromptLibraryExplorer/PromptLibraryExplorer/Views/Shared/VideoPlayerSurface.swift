import AVKit
import SwiftUI

struct VideoPlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    var allowsPictureInPicturePlayback: Bool = true
    var isPictureInPictureActive: Binding<Bool>? = nil

    func makeNSView(context: Context) -> ManagedVideoPlayerView {
        let view = ManagedVideoPlayerView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: ManagedVideoPlayerView, context: Context) {
        configure(nsView)
    }

    static func dismantleNSView(_ nsView: ManagedVideoPlayerView, coordinator: ()) {
        nsView.prepareForRemoval()
    }

    private func configure(_ view: ManagedVideoPlayerView) {
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.showsSharingServiceButton = false
        view.allowsPictureInPicturePlayback = allowsPictureInPicturePlayback
        view.onPictureInPictureActiveChange = { active in
            isPictureInPictureActive?.wrappedValue = active
        }

        if !view.isRetainedForPictureInPicture {
            view.player = player
        }
    }
}

final class ManagedVideoPlayerView: AVPlayerView, AVPlayerViewPictureInPictureDelegate {
    var onPictureInPictureActiveChange: ((Bool) -> Void)?
    private(set) var isPictureInPictureActive = false
    private(set) var isRetainedForPictureInPicture = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        pictureInPictureDelegate = self
    }

    func prepareForRemoval() {
        if isPictureInPictureActive {
            isRetainedForPictureInPicture = true
            PictureInPictureViewRetainer.shared.retain(self)
            onPictureInPictureActiveChange = nil
            return
        }

        tearDownPlayer()
    }

    private func tearDownPlayer() {
        player?.pause()
        player = nil
        pictureInPictureDelegate = nil
        onPictureInPictureActiveChange?(false)
        onPictureInPictureActiveChange = nil
    }

    func playerViewWillStartPicture(inPicture playerView: AVPlayerView) {
        isPictureInPictureActive = true
        onPictureInPictureActiveChange?(true)
    }

    func playerViewDidStartPicture(inPicture playerView: AVPlayerView) {
        isPictureInPictureActive = true
        onPictureInPictureActiveChange?(true)
    }

    func playerViewWillStopPicture(inPicture playerView: AVPlayerView) {
        isPictureInPictureActive = false
        onPictureInPictureActiveChange?(false)
    }

    func playerViewDidStopPicture(inPicture playerView: AVPlayerView) {
        isPictureInPictureActive = false
        onPictureInPictureActiveChange?(false)

        if isRetainedForPictureInPicture {
            isRetainedForPictureInPicture = false
            PictureInPictureViewRetainer.shared.release(self)
            tearDownPlayer()
            return
        }

        pictureInPictureDelegate = self
    }

    func playerViewShouldAutomaticallyDismissAtPicture(inPictureStart playerView: AVPlayerView) -> Bool {
        false
    }
}

private final class PictureInPictureViewRetainer {
    static let shared = PictureInPictureViewRetainer()

    private var retainedViews: [ObjectIdentifier: ManagedVideoPlayerView] = [:]

    private init() {}

    func retain(_ view: ManagedVideoPlayerView) {
        retainedViews[ObjectIdentifier(view)] = view
    }

    func release(_ view: ManagedVideoPlayerView) {
        retainedViews.removeValue(forKey: ObjectIdentifier(view))
    }
}
