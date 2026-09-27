import AppKit
import AVFoundation
import Observation

/// Drives one slideshow: the play order, the timer, image loading (screen
/// sized, the next slide preloaded), inline video that advances when it
/// ends, captions and the auto-hiding controls.
@MainActor @Observable
final class SlideshowModel {
    /// Every candidate slide (videos included); `slides` is what plays.
    let allSlides: [FileEntry]
    private(set) var slides: [FileEntry]
    private(set) var sequence: SlideshowSequence
    private(set) var isPlaying = true
    /// Stopped on the last slide (no loop).
    private(set) var reachedEnd = false
    /// What's on screen. `id` changes per slide shown, for the transition.
    private(set) var displayed: Displayed?
    private(set) var prompts: [String: String] = [:]
    var controlsVisible = true
    /// The options popover (or the pointer over the controls) keeps them up.
    var isInteractingWithControls = false {
        didSet { scheduleControlsHide() }
    }
    /// Direction of the last move, for the slide transition.
    private(set) var direction = 1

    var options: SlideshowOptions {
        didSet { optionsDidChange(from: oldValue) }
    }

    let player = AVPlayer()
    @ObservationIgnored var onOptionsChanged: ((SlideshowOptions) -> Void)?
    @ObservationIgnored var onClose: (() -> Void)?
    @ObservationIgnored let rating: (String) -> Int
    /// Longest screen edge in pixels (what images are decoded to).
    @ObservationIgnored var screenPixelSize: CGFloat = 2560

    struct Displayed: Equatable {
        let id: Int
        let entry: FileEntry
        let image: NSImage?
        var isVideo: Bool { FileHelpers.isVideoFile(entry.name) }

        static func == (lhs: Displayed, rhs: Displayed) -> Bool { lhs.id == rhs.id }
    }

    @ObservationIgnored private var seed: UInt64
    @ObservationIgnored private var displayCounter = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var endObserver: NSObjectProtocol?

    init(slides: [FileEntry], start: Int, options: SlideshowOptions, seed: UInt64, rating: @escaping (String) -> Int = { _ in 0 }) {
        allSlides = slides
        self.options = options
        self.seed = seed
        self.rating = rating
        let startPath = slides.indices.contains(start) ? slides[start].path : nil
        let playing = slides.filter { SlideshowEligibility.isEligible($0, includeVideos: options.includeVideos) }
        self.slides = playing
        let startIndex = startPath.flatMap { path in playing.firstIndex { $0.path == path } } ?? 0
        sequence = SlideshowSequence(count: playing.count, start: startIndex, shuffle: options.shuffle, loop: options.loop, seed: seed)
    }

    var currentEntry: FileEntry? {
        sequence.current.flatMap { slides.indices.contains($0) ? slides[$0] : nil }
    }

    // MARK: Lifecycle

    func begin() {
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let item = note.object as? AVPlayerItem, item === self.player.currentItem else { return }
                self.videoDidEnd()
            }
        }
        showCurrent()
        scheduleControlsHide()
    }

    func end() {
        loadTask?.cancel()
        timerTask?.cancel()
        hideTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }

    func close() {
        onClose?()
    }

    // MARK: Controls

    func perform(_ action: SlideshowKeyAction) {
        pointerMoved()
        switch action {
        case .previous: previous()
        case .next: next()
        case .playPause: togglePlay()
        case .close: close()
        }
    }

    func next() {
        direction = 1
        if sequence.advance() == nil {
            finish()
            return
        }
        reachedEnd = false
        showCurrent()
    }

    func previous() {
        direction = -1
        guard sequence.goBack() != nil else { return }
        reachedEnd = false
        showCurrent()
    }

    func togglePlay() {
        if reachedEnd {
            restart()
            return
        }
        isPlaying.toggle()
        if isPlaying {
            if displayed?.isVideo == true { player.play() } else { startTimer() }
        } else {
            timerTask?.cancel()
            player.pause()
        }
    }

    func restart() {
        sequence.restart()
        reachedEnd = false
        isPlaying = true
        direction = 1
        showCurrent()
    }

    private func finish() {
        reachedEnd = true
        isPlaying = false
        timerTask?.cancel()
        controlsVisible = true
    }

    /// Mouse moved: show the controls, hide them again after a pause.
    func pointerMoved() {
        if !controlsVisible { controlsVisible = true }
        scheduleControlsHide()
    }

    private func scheduleControlsHide() {
        hideTask?.cancel()
        guard !isInteractingWithControls, !reachedEnd else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, let self, !self.isInteractingWithControls, !self.reachedEnd else { return }
            self.controlsVisible = false
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    // MARK: Showing slides

    private func showCurrent() {
        timerTask?.cancel()
        loadTask?.cancel()
        guard let entry = currentEntry else {
            displayed = nil
            return
        }
        if options.showPromptExcerpt { loadPrompt(for: entry.path) }
        if FileHelpers.isVideoFile(entry.name) {
            present(entry: entry, image: nil)
            player.replaceCurrentItem(with: AVPlayerItem(url: entry.url))
            if isPlaying { player.play() }
            preloadNext()
            return
        }
        player.pause()
        player.replaceCurrentItem(with: nil)
        let size = screenPixelSize
        loadTask = Task { [weak self] in
            let image = await ThumbnailService.shared.previewImage(for: entry.url, maxPixelSize: size)
            guard !Task.isCancelled, let self else { return }
            self.present(entry: entry, image: image)
            if self.isPlaying { self.startTimer() }
            self.preloadNext()
        }
    }

    private func present(entry: FileEntry, image: NSImage?) {
        displayCounter += 1
        displayed = Displayed(id: displayCounter, entry: entry, image: image)
    }

    private func preloadNext() {
        var lookahead = sequence
        guard let index = lookahead.advance(), slides.indices.contains(index) else { return }
        let entry = slides[index]
        guard !FileHelpers.isVideoFile(entry.name) else { return }
        let size = screenPixelSize
        Task { _ = await ThumbnailService.shared.previewImage(for: entry.url, maxPixelSize: size) }
        if options.showPromptExcerpt { loadPrompt(for: entry.path) }
    }

    private func startTimer() {
        timerTask?.cancel()
        let interval = options.clampedInterval
        timerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled, let self, self.isPlaying else { return }
            self.next()
        }
    }

    private func videoDidEnd() {
        guard isPlaying else { return }
        next()
    }

    private func loadPrompt(for path: String) {
        guard prompts[path] == nil else { return }
        prompts[path] = ""
        Task { [weak self] in
            let prompt = await SimilarImagesModel.readPrompt(atPath: path)
            self?.prompts[path] = prompt
        }
    }

    // MARK: Options

    private func optionsDidChange(from old: SlideshowOptions) {
        onOptionsChanged?(options)
        if old.shuffle != options.shuffle || old.loop != options.loop || old.includeVideos != options.includeVideos {
            rebuildSequence()
        } else if old.interval != options.interval, isPlaying, displayed?.isVideo == false {
            startTimer()
        }
        if options.showPromptExcerpt, !old.showPromptExcerpt, let entry = currentEntry {
            loadPrompt(for: entry.path)
        }
    }

    /// New order (current slide first), e.g. after toggling shuffle.
    private func rebuildSequence() {
        let currentPath = currentEntry?.path
        slides = allSlides.filter { SlideshowEligibility.isEligible($0, includeVideos: options.includeVideos) }
        seed = seed &+ 1
        let start = currentPath.flatMap { path in slides.firstIndex { $0.path == path } } ?? 0
        sequence = SlideshowSequence(count: slides.count, start: start, shuffle: options.shuffle, loop: options.loop, seed: seed)
        if currentEntry?.path != currentPath { showCurrent() }
        if slides.isEmpty { displayed = nil }
    }

    // MARK: Caption

    var captionLines: [String] {
        guard let entry = displayed?.entry else { return [] }
        var lines: [String] = []
        if options.showFileName { lines.append(entry.name) }
        if options.showPromptExcerpt, let prompt = prompts[entry.path], !prompt.isEmpty {
            lines.append(SlideshowEligibility.promptExcerpt(prompt))
        }
        return lines
    }

    var captionRating: Int? {
        guard options.showRating, let entry = displayed?.entry else { return nil }
        return rating(entry.path)
    }
}
