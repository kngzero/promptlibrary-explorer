import CoreGraphics
import Foundation

// Pure models behind Compare Images (2–4 images side by side with synced zoom
// and pan, or an A/B wipe of two). Everything here is geometry and state; the
// views in Views/Compare only draw it.
//
// Coordinates: viewport points with the origin top-left, y down. Image
// positions are *normalized* (0…1 across the image's own width / height), so
// a pan in one pane maps onto every other pane even when the images have
// different pixel sizes (a master and its 2× upscale line up).
//
// HARD RULE (user decision): comparing is for looking. Nothing here marks,
// ranks or offers any file for deletion; there is no trash affordance.

// MARK: - Modes

enum CompareMode: String, CaseIterable, Identifiable, Sendable {
    case sideBySide
    case wipe

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sideBySide: return "Side by Side"
        case .wipe: return "A/B Wipe"
        }
    }

    var systemImage: String {
        switch self {
        case .sideBySide: return "rectangle.split.2x1"
        case .wipe: return "slider.horizontal.below.rectangle"
        }
    }
}

/// How zoom levels relate between images of different pixel sizes.
enum CompareFraming: String, CaseIterable, Identifiable, Sendable {
    /// Every image shows the same part of the picture at the same size on
    /// screen (a 1024 px master and its 4096 px upscale line up). The zoom
    /// percentage is image A's; each info bar shows its own.
    case matched
    /// 100 % means one image pixel per screen pixel for every image.
    case actualPixels

    var id: String { rawValue }

    var title: String {
        switch self {
        case .matched: return "Same Framing"
        case .actualPixels: return "Actual Pixels"
        }
    }
}

enum CompareWipeOrientation: String, CaseIterable, Identifiable, Sendable {
    /// A vertical divider: A on the left, B on the right.
    case vertical
    /// A horizontal divider: A on top, B below.
    case horizontal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .vertical: return "Left | Right"
        case .horizontal: return "Top / Bottom"
        }
    }
}

/// The shared zoom. `.scale` is native-relative: 1 = 100 % (one image pixel
/// per screen pixel), in image A's terms when the framing is matched.
enum CompareZoom: Equatable, Sendable {
    case fit
    case scale(Double)

    static let minimumScale = 0.05
    static let maximumScale = 8.0

    static func clamped(_ scale: Double) -> CompareZoom {
        .scale(min(max(scale, minimumScale), maximumScale))
    }
}

/// Toolbar zoom levels.
enum CompareZoomPreset: String, CaseIterable, Identifiable, Sendable {
    case fit, p50, p100, p200, p400

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fit: return "Fit"
        case .p50: return "50%"
        case .p100: return "100%"
        case .p200: return "200%"
        case .p400: return "400%"
        }
    }

    var zoom: CompareZoom {
        switch self {
        case .fit: return .fit
        case .p50: return .scale(0.5)
        case .p100: return .scale(1)
        case .p200: return .scale(2)
        case .p400: return .scale(4)
        }
    }

    /// The preset matching `zoom`, if any.
    static func matching(_ zoom: CompareZoom) -> CompareZoomPreset? {
        allCases.first { preset in
            switch (preset.zoom, zoom) {
            case (.fit, .fit): return true
            case let (.scale(a), .scale(b)): return abs(a - b) < 0.0005
            default: return false
            }
        }
    }
}

// MARK: - Geometry

enum CompareGeometry {
    /// Points per image pixel that fit `image` (pixels) in `viewport` (points).
    static func fitScale(image: CGSize, viewport: CGSize) -> CGFloat {
        guard image.width > 0, image.height > 0, viewport.width > 0, viewport.height > 0 else { return 0 }
        return min(viewport.width / image.width, viewport.height / image.height)
    }

    /// Native-relative zoom of pane `image` (1 = 100 %).
    ///
    /// - `reference`: image A's pixel size (matched framing scales every
    ///   pane so it spans what A spans).
    static func paneZoom(
        _ zoom: CompareZoom,
        image: CGSize,
        viewport: CGSize,
        backingScale: CGFloat,
        framing: CompareFraming,
        reference: CGSize
    ) -> Double {
        switch zoom {
        case .fit:
            return Double(fitScale(image: image, viewport: viewport) * backingScale)
        case let .scale(scale):
            guard framing == .matched, image.width > 0, reference.width > 0 else { return scale }
            return scale * Double(reference.width / image.width)
        }
    }

    /// Converts a pane's native-relative zoom back to the shared zoom value
    /// (the inverse of `paneZoom` for `.scale`).
    static func sharedScale(fromPaneZoom paneZoom: Double, image: CGSize, framing: CompareFraming, reference: CGSize) -> Double {
        guard framing == .matched, image.width > 0, reference.width > 0 else { return paneZoom }
        return paneZoom * Double(image.width / reference.width)
    }

    /// Points per image pixel for a native-relative zoom.
    static func pointsPerPixel(paneZoom: Double, backingScale: CGFloat) -> CGFloat {
        CGFloat(paneZoom) / max(backingScale, 0.5)
    }

    /// Where the image is drawn in the viewport: `center` (normalized image
    /// point) sits at the viewport's centre.
    static func imageRect(scale: CGFloat, image: CGSize, viewport: CGSize, center: CGPoint) -> CGRect {
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(
            x: viewport.width / 2 - center.x * size.width,
            y: viewport.height / 2 - center.y * size.height,
            width: size.width,
            height: size.height
        )
    }

    /// The normalized image point under `viewPoint`.
    static func normalizedPoint(viewPoint: CGPoint, imageRect: CGRect) -> CGPoint {
        guard imageRect.width > 0, imageRect.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(
            x: (viewPoint.x - imageRect.minX) / imageRect.width,
            y: (viewPoint.y - imageRect.minY) / imageRect.height
        )
    }

    /// The new centre that keeps the image point under `anchor` fixed while
    /// the scale changes from `oldScale` to `newScale`.
    static func centerKeepingAnchor(
        _ anchor: CGPoint,
        center: CGPoint,
        oldScale: CGFloat,
        newScale: CGFloat,
        image: CGSize,
        viewport: CGSize
    ) -> CGPoint {
        guard oldScale > 0, newScale > 0, image.width > 0, image.height > 0 else { return center }
        let oldRect = imageRect(scale: oldScale, image: image, viewport: viewport, center: center)
        let point = normalizedPoint(viewPoint: anchor, imageRect: oldRect)
        let newWidth = image.width * newScale
        let newHeight = image.height * newScale
        // viewport/2 - c' * newSize + point * newSize = anchor
        return CGPoint(
            x: point.x - (anchor.x - viewport.width / 2) / newWidth,
            y: point.y - (anchor.y - viewport.height / 2) / newHeight
        )
    }

    /// The new centre after dragging the content by `delta` points in a pane
    /// drawn at `scale`.
    static func centerAfterPan(_ delta: CGSize, center: CGPoint, scale: CGFloat, image: CGSize) -> CGPoint {
        guard scale > 0, image.width > 0, image.height > 0 else { return center }
        return CGPoint(
            x: center.x - delta.width / (image.width * scale),
            y: center.y - delta.height / (image.height * scale)
        )
    }

    /// Keeps the picture covering the viewport where it's larger than it, and
    /// centred where it's smaller.
    static func clampedCenter(_ center: CGPoint, scale: CGFloat, image: CGSize, viewport: CGSize) -> CGPoint {
        func clamp(_ value: CGFloat, content: CGFloat, view: CGFloat) -> CGFloat {
            guard content > view, content > 0 else { return 0.5 }
            let half = view / 2 / content
            return min(max(value, half), 1 - half)
        }
        return CGPoint(
            x: clamp(center.x, content: image.width * scale, view: viewport.width),
            y: clamp(center.y, content: image.height * scale, view: viewport.height)
        )
    }

    /// The offset (points, from the centred position) of the same content in
    /// another pane. Offsets map through normalized image coordinates, so the
    /// same part of the picture is centred in both.
    static func mappedOffset(
        _ offset: CGSize,
        fromScale: CGFloat,
        fromImage: CGSize,
        toScale: CGFloat,
        toImage: CGSize
    ) -> CGSize {
        guard fromScale > 0, fromImage.width > 0, fromImage.height > 0 else { return .zero }
        let normalized = CGSize(
            width: offset.width / (fromImage.width * fromScale),
            height: offset.height / (fromImage.height * fromScale)
        )
        return CGSize(
            width: normalized.width * toImage.width * toScale,
            height: normalized.height * toImage.height * toScale
        )
    }

    /// Longest edge (pixels) to decode for a pane: what the screen shows at
    /// this zoom, never more than the native size, in 512 px steps so small
    /// zoom changes don't reload.
    static func decodeLongEdge(paneZoom: Double, nativeLongEdge: CGFloat) -> CGFloat {
        guard nativeLongEdge > 0 else { return 0 }
        let needed = nativeLongEdge * CGFloat(min(max(paneZoom, 0), 1))
        let stepped = (max(needed, 256) / 512).rounded(.up) * 512
        return min(nativeLongEdge, stepped)
    }

    /// Grid for 2–4 panes: 2 → 2 × 1, 3 → 3 × 1, 4 → 2 × 2 (or 4 × 1 when very wide).
    static func paneGrid(count: Int, size: CGSize) -> (columns: Int, rows: Int) {
        switch count {
        case ...1: return (1, 1)
        case 2: return (2, 1)
        case 3: return (3, 1)
        default:
            let wide = size.height > 0 && size.width / size.height > 3.2
            return wide ? (4, 1) : (2, 2)
        }
    }
}

// MARK: - Shared view state

/// Zoom, pan, mode and wipe state shared by every pane of one comparison.
struct CompareViewState: Equatable, Sendable {
    var mode: CompareMode = .sideBySide
    var framing: CompareFraming = .matched
    var zoom: CompareZoom = .fit
    /// Normalized image point at the centre of every pane.
    var center = CGPoint(x: 0.5, y: 0.5)
    var wipeOrientation: CompareWipeOrientation = .vertical
    /// Divider position, 0…1 across the viewport.
    var wipePosition: CGFloat = 0.5
    /// Indices (into the comparison's items) shown as A and B in the wipe.
    var wipeA = 0
    var wipeB = 1

    /// One pane's inputs.
    struct Pane: Equatable, Sendable {
        var image: CGSize
        var viewport: CGSize
    }

    // MARK: Per-pane values

    func paneZoom(_ pane: Pane, reference: CGSize, backingScale: CGFloat) -> Double {
        CompareGeometry.paneZoom(zoom, image: pane.image, viewport: pane.viewport, backingScale: backingScale, framing: framing, reference: reference)
    }

    func scale(_ pane: Pane, reference: CGSize, backingScale: CGFloat) -> CGFloat {
        CompareGeometry.pointsPerPixel(paneZoom: paneZoom(pane, reference: reference, backingScale: backingScale), backingScale: backingScale)
    }

    func imageRect(_ pane: Pane, reference: CGSize, backingScale: CGFloat) -> CGRect {
        let scale = scale(pane, reference: reference, backingScale: backingScale)
        let center = zoom == .fit ? CGPoint(x: 0.5, y: 0.5) : center
        return CompareGeometry.imageRect(scale: scale, image: pane.image, viewport: pane.viewport, center: center)
    }

    /// Nearest-neighbour magnification from 200 % on, so pixels stay crisp.
    func usesNearestNeighbour(_ pane: Pane, reference: CGSize, backingScale: CGFloat) -> Bool {
        paneZoom(pane, reference: reference, backingScale: backingScale) >= 1.999
    }

    // MARK: Interactions (the pane under the pointer drives)

    /// Multiplies the zoom by `factor` around `anchor` in `pane`.
    mutating func zoom(by factor: CGFloat, anchor: CGPoint, in pane: Pane, reference: CGSize, backingScale: CGFloat) {
        guard factor > 0, factor.isFinite else { return }
        let oldPaneZoom = paneZoom(pane, reference: reference, backingScale: backingScale)
        let oldShared = CompareGeometry.sharedScale(fromPaneZoom: oldPaneZoom, image: pane.image, framing: framing, reference: reference)
        let newZoom = CompareZoom.clamped(oldShared * Double(factor))
        setZoom(newZoom, anchor: anchor, in: pane, reference: reference, backingScale: backingScale)
    }

    /// Sets the zoom keeping the image point under `anchor` (default: the
    /// viewport centre) where it is.
    mutating func setZoom(_ newZoom: CompareZoom, anchor: CGPoint? = nil, in pane: Pane, reference: CGSize, backingScale: CGFloat) {
        let oldScale = scale(pane, reference: reference, backingScale: backingScale)
        let oldCenter = zoom == .fit ? CGPoint(x: 0.5, y: 0.5) : center
        zoom = newZoom
        guard newZoom != .fit else {
            center = CGPoint(x: 0.5, y: 0.5)
            return
        }
        let newScale = scale(pane, reference: reference, backingScale: backingScale)
        let anchorPoint = anchor ?? CGPoint(x: pane.viewport.width / 2, y: pane.viewport.height / 2)
        let moved = CompareGeometry.centerKeepingAnchor(
            anchorPoint, center: oldCenter, oldScale: oldScale, newScale: newScale,
            image: pane.image, viewport: pane.viewport
        )
        center = CompareGeometry.clampedCenter(moved, scale: newScale, image: pane.image, viewport: pane.viewport)
    }

    /// Drags the content by `delta` points in `pane`; every pane follows.
    mutating func pan(by delta: CGSize, in pane: Pane, reference: CGSize, backingScale: CGFloat) {
        guard zoom != .fit else { return }
        let scale = scale(pane, reference: reference, backingScale: backingScale)
        let moved = CompareGeometry.centerAfterPan(delta, center: center, scale: scale, image: pane.image)
        center = CompareGeometry.clampedCenter(moved, scale: scale, image: pane.image, viewport: pane.viewport)
    }

    /// Double-click: from Fit (or anything under 100 %) to 100 % centred on
    /// the clicked point of `pane`; otherwise back to Fit.
    mutating func toggleFitActual(at point: CGPoint, in pane: Pane, reference: CGSize, backingScale: CGFloat) {
        let current = paneZoom(pane, reference: reference, backingScale: backingScale)
        if zoom == .fit || current < 0.999 {
            let rect = imageRect(pane, reference: reference, backingScale: backingScale)
            let clicked = CompareGeometry.normalizedPoint(viewPoint: point, imageRect: rect)
            let shared = CompareGeometry.sharedScale(fromPaneZoom: 1, image: pane.image, framing: framing, reference: reference)
            zoom = CompareZoom.clamped(shared)
            let newScale = scale(pane, reference: reference, backingScale: backingScale)
            let target = CGPoint(x: min(max(clicked.x, 0), 1), y: min(max(clicked.y, 0), 1))
            center = CompareGeometry.clampedCenter(target, scale: newScale, image: pane.image, viewport: pane.viewport)
        } else {
            zoom = .fit
            center = CGPoint(x: 0.5, y: 0.5)
        }
    }

    mutating func setWipePosition(_ position: CGFloat) {
        wipePosition = min(max(position, 0), 1)
    }

    mutating func swapWipe() {
        swap(&wipeA, &wipeB)
    }

    /// Keeps the wipe indices valid (and distinct) for `count` items.
    mutating func normalizeWipe(count: Int) {
        guard count >= 2 else {
            wipeA = 0
            wipeB = 0
            return
        }
        wipeA = min(max(wipeA, 0), count - 1)
        wipeB = min(max(wipeB, 0), count - 1)
        if wipeA == wipeB { wipeB = wipeA == 0 ? 1 : 0 }
    }
}

// MARK: - Wipe geometry

enum CompareWipeGeometry {
    /// B is drawn over A's rect, scaled so it spans the same width (same
    /// framing), with the same normalized point (`center`) at the viewport
    /// centre. Same aspect ratio → exactly A's rect.
    static func bRect(aRect: CGRect, bImage: CGSize, center: CGPoint) -> CGRect {
        guard bImage.width > 0, bImage.height > 0 else { return aRect }
        let width = aRect.width
        let height = width * bImage.height / bImage.width
        return CGRect(x: aRect.minX, y: aRect.minY + center.y * (aRect.height - height), width: width, height: height)
    }

    /// The part of the viewport where B shows.
    static func bRegion(viewport: CGSize, position: CGFloat, orientation: CompareWipeOrientation) -> CGRect {
        let p = min(max(position, 0), 1)
        switch orientation {
        case .vertical:
            let x = viewport.width * p
            return CGRect(x: x, y: 0, width: viewport.width - x, height: viewport.height)
        case .horizontal:
            let y = viewport.height * p
            return CGRect(x: 0, y: y, width: viewport.width, height: viewport.height - y)
        }
    }

    /// Divider position (0…1) for a pointer location.
    static func position(for point: CGPoint, viewport: CGSize, orientation: CompareWipeOrientation) -> CGFloat {
        switch orientation {
        case .vertical: return viewport.width > 0 ? min(max(point.x / viewport.width, 0), 1) : 0.5
        case .horizontal: return viewport.height > 0 ? min(max(point.y / viewport.height, 0), 1) : 0.5
        }
    }

    /// True when `point` is within `tolerance` points of the divider.
    static func isOnDivider(_ point: CGPoint, viewport: CGSize, position: CGFloat, orientation: CompareWipeOrientation, tolerance: CGFloat = 10) -> Bool {
        switch orientation {
        case .vertical: return abs(point.x - viewport.width * position) <= tolerance
        case .horizontal: return abs(point.y - viewport.height * position) <= tolerance
        }
    }
}

// MARK: - Items and actions

/// One file in a comparison.
struct CompareItem: Identifiable, Equatable, Sendable {
    let path: String
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    /// Native pixel size (oriented), nil until read.
    var pixelSize: CGSize?
    var fileSize: Int64?
    var isVideo: Bool

    init(path: String, pixelSize: CGSize? = nil, fileSize: Int64? = nil, isVideo: Bool? = nil) {
        self.path = path
        self.pixelSize = pixelSize
        self.fileSize = fileSize
        self.isVideo = isVideo ?? FileHelpers.isVideoFile((path as NSString).lastPathComponent)
    }

    /// "4096 × 4096 px"
    var pixelText: String? {
        guard let pixelSize, pixelSize.width > 0 else { return nil }
        return "\(Int(pixelSize.width)) × \(Int(pixelSize.height)) px"
    }

    var fileSizeText: String? {
        fileSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    }
}

enum CompareEligibility {
    static let minimumCount = 2
    static let maximumCount = 4

    /// Images and videos (a video compares as its poster frame).
    static func isComparable(_ name: String) -> Bool {
        FileHelpers.isImageFile(name) || FileHelpers.isVideoFile(name)
    }

    /// The paths to compare when `entries` are the targets, or nil when they
    /// aren't 2–4 comparable files.
    static func paths(for entries: [FileEntry]) -> [String]? {
        let files = entries.filter { !$0.isDirectory }
        guard files.count == entries.count,
              (minimumCount...maximumCount).contains(files.count),
              files.allSatisfy({ isComparable($0.name) })
        else { return nil }
        return files.map(\.path)
    }

    /// Up to four paths of a larger set, as a page that contains `focused`.
    static func window(of paths: [String], containing focused: String?) -> (paths: [String], start: Int) {
        guard paths.count > maximumCount else { return (paths, 0) }
        let index = focused.flatMap { paths.firstIndex(of: $0) } ?? 0
        let start = min((index / maximumCount) * maximumCount, max(paths.count - maximumCount, 0))
        return (Array(paths[start..<min(start + maximumCount, paths.count)]), start)
    }
}

/// What each pane's menu offers. No deletion of any kind.
enum CompareImageAction: String, CaseIterable, Identifiable, Sendable {
    case revealInFinder
    case copyPath
    case copyPrompt

    var id: String { rawValue }

    var title: String {
        switch self {
        case .revealInFinder: return "Reveal in Finder"
        case .copyPath: return "Copy Path"
        case .copyPrompt: return "Copy Prompt"
        }
    }

    var systemImage: String {
        switch self {
        case .revealInFinder: return "folder"
        case .copyPath: return "link"
        case .copyPrompt: return "doc.on.doc"
        }
    }
}
