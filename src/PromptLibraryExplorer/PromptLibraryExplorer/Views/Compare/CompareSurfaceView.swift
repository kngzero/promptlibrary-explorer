import AppKit
import QuartzCore
import SwiftUI

/// One drawn image of a compare surface: where it goes (viewport points, y
/// down), the part of the viewport it's clipped to, and its filter.
struct CompareSurfaceLayer: Equatable {
    var image: CGImage?
    var rect: CGRect
    /// nil = the whole viewport.
    var clip: CGRect?
    var nearestNeighbour: Bool

    static func == (lhs: CompareSurfaceLayer, rhs: CompareSurfaceLayer) -> Bool {
        lhs.image === rhs.image && lhs.rect == rhs.rect && lhs.clip == rhs.clip && lhs.nearestNeighbour == rhs.nearestNeighbour
    }
}

/// Pointer input from a surface, in its viewport points (y down).
enum CompareSurfaceEvent {
    case zoom(factor: CGFloat, anchor: CGPoint)
    case pan(CGSize)
    case doubleClick(CGPoint)
    /// The wipe divider was dragged to this point.
    case divider(CGPoint)
}

/// Draws a pane (or the wipe) with Core Animation layers — only the visible
/// part of a huge image is composited — and turns pinch, scroll, drag and
/// double-click into `CompareSurfaceEvent`s. Pure display; all geometry
/// comes from `CompareViewState`.
struct CompareSurface: NSViewRepresentable {
    var layers: [CompareSurfaceLayer]
    /// Wipe divider (0…1) and orientation; nil for a plain pane.
    var divider: (position: CGFloat, orientation: CompareWipeOrientation)?
    var canPan: Bool
    var onEvent: (CompareSurfaceEvent) -> Void

    func makeNSView(context: Context) -> CompareSurfaceNSView {
        let view = CompareSurfaceNSView()
        view.onEvent = onEvent
        return view
    }

    func updateNSView(_ view: CompareSurfaceNSView, context: Context) {
        view.onEvent = onEvent
        view.canPan = canPan
        view.apply(layers: layers, divider: divider)
    }
}

final class CompareSurfaceNSView: NSView {
    var onEvent: ((CompareSurfaceEvent) -> Void)?
    var canPan = false {
        didSet { if canPan != oldValue { window?.invalidateCursorRects(for: self) } }
    }

    private var clipLayers: [CALayer] = []
    private var imageLayers: [CALayer] = []
    private var currentLayers: [CompareSurfaceLayer] = []
    private var divider: (position: CGFloat, orientation: CompareWipeOrientation)?
    private var appliedImages: [CGImage?] = []
    private var lastDragPoint: CGPoint?
    private var isDraggingDivider = false
    private var pushedCursor = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Layers

    func apply(layers: [CompareSurfaceLayer], divider: (position: CGFloat, orientation: CompareWipeOrientation)?) {
        let dividerChanged = self.divider?.position != divider?.position || self.divider?.orientation != divider?.orientation
        self.divider = divider
        guard layers != currentLayers || dividerChanged else { return }
        currentLayers = layers
        layoutImageLayers()
        if dividerChanged { window?.invalidateCursorRects(for: self) }
    }

    override func layout() {
        super.layout()
        layoutImageLayers()
    }

    /// y-down rect → this (unflipped) view's layer coordinates.
    private func layerRect(_ rect: CGRect, inHeight height: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    private func layoutImageLayers() {
        guard let root = layer else { return }
        while clipLayers.count < currentLayers.count {
            let clip = CALayer()
            clip.masksToBounds = true
            let image = CALayer()
            image.contentsGravity = .resize
            clip.addSublayer(image)
            root.addSublayer(clip)
            clipLayers.append(clip)
            imageLayers.append(image)
            appliedImages.append(nil)
        }
        while clipLayers.count > currentLayers.count {
            clipLayers.removeLast().removeFromSuperlayer()
            imageLayers.removeLast()
            appliedImages.removeLast()
        }
        let height = bounds.height
        let scale = window?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, spec) in currentLayers.enumerated() {
            let clipRect = spec.clip ?? CGRect(origin: .zero, size: bounds.size)
            let clip = clipLayers[index]
            clip.frame = layerRect(clipRect, inHeight: height)
            let relative = spec.rect.offsetBy(dx: -clipRect.minX, dy: -clipRect.minY)
            let imageLayer = imageLayers[index]
            imageLayer.frame = layerRect(relative, inHeight: clipRect.height)
            if appliedImages[index] !== spec.image {
                imageLayer.contents = spec.image
                appliedImages[index] = spec.image
            }
            imageLayer.contentsScale = scale
            imageLayer.magnificationFilter = spec.nearestNeighbour ? .nearest : .linear
            imageLayer.minificationFilter = .linear
        }
        CATransaction.commit()
    }

    // MARK: Cursor

    override func resetCursorRects() {
        super.resetCursorRects()
        if canPan { addCursorRect(bounds, cursor: .openHand) }
        if let divider {
            let rect: CGRect
            switch divider.orientation {
            case .vertical:
                let x = bounds.width * divider.position
                rect = CGRect(x: x - 8, y: 0, width: 16, height: bounds.height)
                addCursorRect(rect, cursor: .resizeLeftRight)
            case .horizontal:
                let y = bounds.height * (1 - divider.position)
                rect = CGRect(x: 0, y: y - 8, width: bounds.width, height: 16)
                addCursorRect(rect, cursor: .resizeUpDown)
            }
        }
    }

    // MARK: Events

    private func point(for event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        return CGPoint(x: local.x, y: bounds.height - local.y)
    }

    override func scrollWheel(with event: NSEvent) {
        let anchor = point(for: event)
        if event.hasPreciseScrollingDeltas, !event.modifierFlags.contains(.command) {
            // Trackpad two-finger scroll pans (content follows the fingers).
            guard canPan else { return }
            var dx = event.scrollingDeltaX
            var dy = event.scrollingDeltaY
            if abs(dx) < 0.001, event.modifierFlags.contains(.shift) {
                dx = dy
                dy = 0
            }
            onEvent?(.pan(CGSize(width: dx, height: dy)))
            return
        }
        // Mouse wheel (or ⌘-scroll): zoom around the pointer.
        let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.01 : 0.12
        let factor = exp(event.scrollingDeltaY * sensitivity)
        guard abs(factor - 1) > 0.0001 else { return }
        onEvent?(.zoom(factor: factor, anchor: anchor))
    }

    override func magnify(with event: NSEvent) {
        let factor = 1 + event.magnification
        guard factor > 0 else { return }
        onEvent?(.zoom(factor: factor, anchor: point(for: event)))
    }

    override func mouseDown(with event: NSEvent) {
        let location = point(for: event)
        if event.clickCount == 2 {
            isDraggingDivider = false
            lastDragPoint = nil
            onEvent?(.doubleClick(location))
            return
        }
        if let divider, CompareWipeGeometry.isOnDivider(location, viewport: bounds.size, position: divider.position, orientation: divider.orientation) {
            isDraggingDivider = true
            onEvent?(.divider(location))
            return
        }
        isDraggingDivider = false
        lastDragPoint = location
        if canPan {
            NSCursor.closedHand.push()
            pushedCursor = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let location = point(for: event)
        if isDraggingDivider {
            onEvent?(.divider(location))
            return
        }
        // Without a zoom to pan, dragging anywhere in the wipe moves the divider.
        if !canPan, divider != nil {
            onEvent?(.divider(location))
            return
        }
        guard canPan, let last = lastDragPoint else { return }
        lastDragPoint = location
        onEvent?(.pan(CGSize(width: location.x - last.x, height: location.y - last.y)))
    }

    override func mouseUp(with event: NSEvent) {
        if pushedCursor {
            NSCursor.pop()
            pushedCursor = false
        }
        lastDragPoint = nil
        isDraggingDivider = false
    }
}
