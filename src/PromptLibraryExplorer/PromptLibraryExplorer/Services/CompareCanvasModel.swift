import AppKit
import Foundation
import Observation

/// One comparison: its files, the shared zoom / pan / wipe state, and the
/// decoded images. Images are decoded at the resolution the screen needs
/// (a downsample at Fit, up to the native pixels only when zoomed to 100 %
/// or more), off the main actor, and upgraded as the zoom grows.
@MainActor @Observable
final class CompareCanvasModel: Identifiable {
    let id = UUID()
    let paths: [String]
    private(set) var items: [CompareItem]
    var state = CompareViewState()
    /// Decoded image and its long edge (pixels), per path.
    private(set) var images: [String: DecodedImage] = [:]
    /// Screen scale of the window showing the comparison.
    var backingScale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2
    /// Size of one pane (side by side) or of the whole wipe, as last laid
    /// out; the toolbar's zoom levels act around its centre.
    var paneViewport: CGSize = .zero

    struct DecodedImage {
        let image: CGImage
        let longEdge: CGFloat
    }

    @ObservationIgnored private var loads: [String: (task: Task<Void, Never>, longEdge: CGFloat)] = [:]
    @ObservationIgnored private var infoTask: Task<Void, Never>?

    init(paths: [String]) {
        self.paths = paths
        items = paths.map { CompareItem(path: $0) }
        state.normalizeWipe(count: paths.count)
        infoTask = Task { [weak self] in await self?.loadInfo() }
    }

    private func loadInfo() async {
        for (index, path) in paths.enumerated() {
            let info = await ViewingImageLoader.info(forPath: path)
            guard !Task.isCancelled else { return }
            items[index].pixelSize = info.pixelSize
            items[index].fileSize = info.fileSize
        }
    }

    func cancelLoads() {
        infoTask?.cancel()
        for load in loads.values { load.task.cancel() }
        loads = [:]
    }

    // MARK: Geometry helpers

    /// Image A: the reference for matched framing (side by side: the first file).
    var referenceIndex: Int { state.mode == .wipe ? state.wipeA : 0 }

    var referenceSize: CGSize {
        items.indices.contains(referenceIndex) ? (items[referenceIndex].pixelSize ?? .zero) : .zero
    }

    func pane(_ index: Int, viewport: CGSize) -> CompareViewState.Pane? {
        guard items.indices.contains(index), let size = items[index].pixelSize, size.width > 0 else { return nil }
        return CompareViewState.Pane(image: size, viewport: viewport)
    }

    func paneZoom(_ index: Int, viewport: CGSize) -> Double? {
        pane(index, viewport: viewport).map { state.paneZoom($0, reference: referenceSize, backingScale: backingScale) }
    }

    /// "100%" for an info bar.
    func zoomText(_ index: Int, viewport: CGSize) -> String {
        guard let zoom = paneZoom(index, viewport: viewport) else { return "—" }
        return "\(Int((zoom * 100).rounded()))%"
    }

    // MARK: Interactions (from a pane)

    func zoom(by factor: CGFloat, anchor: CGPoint, pane index: Int, viewport: CGSize) {
        guard let pane = pane(index, viewport: viewport) else { return }
        state.zoom(by: factor, anchor: anchor, in: pane, reference: referenceSize, backingScale: backingScale)
    }

    func pan(by delta: CGSize, pane index: Int, viewport: CGSize) {
        guard let pane = pane(index, viewport: viewport) else { return }
        state.pan(by: delta, in: pane, reference: referenceSize, backingScale: backingScale)
    }

    func toggleFitActual(at point: CGPoint, pane index: Int, viewport: CGSize) {
        guard let pane = pane(index, viewport: viewport) else { return }
        state.toggleFitActual(at: point, in: pane, reference: referenceSize, backingScale: backingScale)
    }

    /// Toolbar zoom level, around the centre of `viewport` (pane A's).
    func applyPreset(_ preset: CompareZoomPreset, viewport: CGSize) {
        guard let pane = pane(referenceIndex, viewport: viewport) else {
            state.zoom = preset.zoom
            return
        }
        state.setZoom(preset.zoom, in: pane, reference: referenceSize, backingScale: backingScale)
    }

    // MARK: Decoding

    func image(for index: Int) -> CGImage? {
        guard items.indices.contains(index) else { return nil }
        return images[items[index].path]?.image
    }

    /// Makes sure pane `index` has (or is loading) enough pixels for its zoom.
    func ensureResolution(for index: Int, viewport: CGSize) {
        guard items.indices.contains(index), viewport.width > 0, viewport.height > 0,
              let native = items[index].pixelSize, native.width > 0,
              let zoom = paneZoom(index, viewport: viewport)
        else { return }
        let path = items[index].path
        let nativeLong = max(native.width, native.height)
        let needed = CompareGeometry.decodeLongEdge(paneZoom: zoom, nativeLongEdge: nativeLong)
        if let have = images[path]?.longEdge, have >= needed - 1 { return }
        if let loading = loads[path], loading.longEdge >= needed - 1 { return }
        loads[path]?.task.cancel()
        let task = Task { [weak self] in
            let image = await ViewingImageLoader.decode(path: path, maxPixelSize: needed)
            guard !Task.isCancelled, let self else { return }
            self.loads[path] = nil
            guard let image else { return }
            let longEdge = CGFloat(max(image.width, image.height))
            // Never swap a sharper image for a smaller one.
            if let current = self.images[path], current.longEdge > longEdge { return }
            self.images[path] = DecodedImage(image: image, longEdge: max(longEdge, needed == nativeLong ? nativeLong : longEdge))
        }
        loads[path] = (task, needed)
    }
}
