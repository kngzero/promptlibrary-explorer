import AppKit
import Foundation
import Observation

/// State for the viewing tools: the Compare page, the Similar Images page's
/// inline compare, the lightbox loupe and histogram toggles, and the
/// slideshow window. Kept out of `ExplorerViewModel`; the glue lives in
/// `ExplorerViewModel+Viewing.swift`.
@MainActor @Observable
final class ViewingController {
    static let shared = ViewingController()

    // MARK: Compare

    /// The Compare page (a full page over the browser and details panel, like
    /// the Similar Images page); nil = not showing.
    private(set) var comparePage: CompareCanvasModel?

    /// The Similar Images page shows its group in the synced compare instead
    /// of the side-by-side cards. Not persisted.
    var similarPageCompare = false

    func showComparePage(paths: [String]) {
        guard (CompareEligibility.minimumCount...CompareEligibility.maximumCount).contains(paths.count) else { return }
        if let comparePage, comparePage.paths == paths { return }
        comparePage = CompareCanvasModel(paths: paths)
    }

    func closeComparePage() {
        comparePage?.cancelLoads()
        comparePage = nil
    }

    // MARK: Lightbox loupe & histogram (persisted)

    var loupeEnabled: Bool {
        didSet { defaults.set(loupeEnabled, forKey: Keys.loupe) }
    }

    /// 2 or 4 screen pixels per image pixel (the menus offer only those).
    var loupeMagnification: Int {
        didSet { defaults.set(loupeMagnification, forKey: Keys.loupeMagnification) }
    }

    /// Nearest-neighbour (crisp pixels) instead of smooth magnification.
    var loupeNearestNeighbour: Bool {
        didSet { defaults.set(loupeNearestNeighbour, forKey: Keys.loupeNearest) }
    }

    var histogramEnabled: Bool {
        didSet { defaults.set(histogramEnabled, forKey: Keys.histogram) }
    }

    static let loupeMagnifications = [2, 4]

    /// Pointer over the lightbox viewport (its local coordinates), nil when
    /// outside. Only written while the loupe is on.
    private(set) var lightboxPointer: CGPoint?

    func updateLightboxPointer(_ point: CGPoint?) {
        guard loupeEnabled || lightboxPointer != nil else { return }
        let next = loupeEnabled ? point : nil
        if next != lightboxPointer { lightboxPointer = next }
    }

    // MARK: Slideshow

    var slideshowOptions: SlideshowOptions {
        didSet { slideshowOptions.save(to: defaults) }
    }

    /// True while the slideshow window is up.
    private(set) var isSlideshowRunning = false
    @ObservationIgnored private var slideshowWindowController: SlideshowWindowController?

    func startSlideshow(slides: [FileEntry], start: Int, on screen: NSScreen?, rating: @escaping (String) -> Int = { _ in 0 }) {
        guard !slides.isEmpty else { return }
        slideshowWindowController?.close()
        let model = SlideshowModel(
            slides: slides,
            start: start,
            options: slideshowOptions,
            seed: UInt64.random(in: 1...UInt64.max),
            rating: rating
        )
        model.onOptionsChanged = { [weak self] options in self?.slideshowOptions = options }
        let controller = SlideshowWindowController(model: model, screen: screen)
        controller.onClose = { [weak self] in
            self?.slideshowWindowController = nil
            self?.isSlideshowRunning = false
        }
        slideshowWindowController = controller
        isSlideshowRunning = true
        controller.show()
    }

    func endSlideshow() {
        slideshowWindowController?.close()
    }

    // MARK: Init

    @ObservationIgnored private let defaults: UserDefaults

    private enum Keys {
        static let loupe = "viewing.loupe.enabled"
        static let loupeMagnification = "viewing.loupe.magnification"
        static let loupeNearest = "viewing.loupe.nearest"
        static let histogram = "viewing.histogram.enabled"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loupeEnabled = defaults.bool(forKey: Keys.loupe)
        let magnification = defaults.integer(forKey: Keys.loupeMagnification)
        loupeMagnification = Self.loupeMagnifications.contains(magnification) ? magnification : 2
        loupeNearestNeighbour = defaults.object(forKey: Keys.loupeNearest) as? Bool ?? true
        histogramEnabled = defaults.bool(forKey: Keys.histogram)
        slideshowOptions = SlideshowOptions.load(from: defaults)
    }
}
