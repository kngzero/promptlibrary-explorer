import AppKit
import SwiftUI

/// AppKit-backed drag source so a grid cell can drag out every selected file,
/// not just the one under the cursor.
///
/// SwiftUI's `onDrag` vends a single `NSItemProvider`, which means a multi-file
/// drag to Finder silently loses the rest of the selection. This overlay owns
/// the plain left mouse button (click, double-click, drag) and passes
/// everything else — right-click, control-click, hover — through to SwiftUI.
struct FileDragSource: NSViewRepresentable {
    /// Resolved when the drag actually begins, so the selection is current.
    let dragURLs: () -> [URL]
    let isSelected: () -> Bool
    let onSelect: (EventModifiers) -> Void
    let onDoubleClick: () -> Void
    /// What other apps are offered — copy leaves the file in place, move gives it away.
    let externalOperation: () -> ExternalDragOperation
    /// Called once the drag finishes, with the operation the receiver actually performed.
    let onDragEnded: (NSDragOperation) -> Void
    /// A region (in this overlay's SwiftUI coordinates, top-left origin) whose
    /// clicks go to the SwiftUI content underneath, e.g. clickable rating stars.
    var passthroughRect: CGRect? = nil

    func makeNSView(context: Context) -> FileDragSourceNSView {
        let view = FileDragSourceNSView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: FileDragSourceNSView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: FileDragSourceNSView) {
        view.dragURLs = dragURLs
        view.isSelected = isSelected
        view.onSelect = onSelect
        view.onDoubleClick = onDoubleClick
        view.externalOperation = externalOperation
        view.onDragEnded = onDragEnded
        view.passthroughRect = passthroughRect
    }
}

final class FileDragSourceNSView: NSView, NSDraggingSource {
    var dragURLs: () -> [URL] = { [] }
    var isSelected: () -> Bool = { false }
    var onSelect: (EventModifiers) -> Void = { _ in }
    var onDoubleClick: () -> Void = {}
    var externalOperation: () -> ExternalDragOperation = { .copy }
    var onDragEnded: (NSDragOperation) -> Void = { _ in }
    var passthroughRect: CGRect?

    private var mouseDownLocation: NSPoint?
    private var pendingSelectionCollapse = false
    private var isDragging = false

    private let dragThreshold: CGFloat = 4
    private let dragImageSide: CGFloat = 64

    override var acceptsFirstResponder: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Claim only plain left-button events; let SwiftUI keep context menus,
    /// hover and everything else it already handles.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent else { return nil }
        switch event.type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
            guard !event.modifierFlags.contains(.control) else { return nil }
            if let passthroughRect, !isDragging {
                let local = convert(point, from: superview)
                let topLeft = CGPoint(x: local.x, y: isFlipped ? local.y : bounds.height - local.y)
                if passthroughRect.contains(topLeft) { return nil }
            }
            return super.hitTest(point)
        default:
            return nil
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            mouseDownLocation = nil
            pendingSelectionCollapse = false
            onDoubleClick()
            return
        }

        mouseDownLocation = event.locationInWindow
        isDragging = false

        let modifiers = Self.eventModifiers(from: event)
        if modifiers.isEmpty, isSelected() {
            // Leave a multi-selection intact so it can be dragged as a group;
            // collapse to this item on mouse up if no drag happens.
            pendingSelectionCollapse = true
        } else {
            pendingSelectionCollapse = false
            onSelect(modifiers)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isDragging, let start = mouseDownLocation else { return }
        let location = event.locationInWindow
        guard hypot(location.x - start.x, location.y - start.y) >= dragThreshold else { return }

        pendingSelectionCollapse = false
        beginDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        let shouldCollapse = pendingSelectionCollapse && !isDragging
        mouseDownLocation = nil
        pendingSelectionCollapse = false
        if shouldCollapse {
            onSelect([])
        }
    }

    private func beginDrag(with event: NSEvent) {
        let urls = dragURLs()
        guard !urls.isEmpty else { return }

        let origin = convert(event.locationInWindow, from: nil)
        let side = dragImageSide
        let draggingItems: [NSDraggingItem] = urls.enumerated().map { offset, url in
            let draggingItem = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: side, height: side)
            let cascade = CGFloat(min(offset, 5)) * 4
            let frame = NSRect(
                x: origin.x - side / 2 + cascade,
                y: origin.y - side / 2 - cascade,
                width: side,
                height: side
            )
            draggingItem.setDraggingFrame(frame, contents: icon)
            return draggingItem
        }

        let session = beginDraggingSession(with: draggingItems, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = urls.count > 1 ? .stack : .default
        isDragging = true
    }

    private static func eventModifiers(from event: NSEvent) -> EventModifiers {
        var modifiers: EventModifiers = []
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
        return modifiers
    }

    // MARK: - NSDraggingSource

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        // Inside the app the drop targets decide (reorder moves, folders copy).
        // Outside, the preference decides what other apps are allowed to do.
        context == .outsideApplication ? externalOperation().dragOperation : [.copy, .move]
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        isDragging = false
        mouseDownLocation = nil
        pendingSelectionCollapse = false
        onDragEnded(operation)
    }
}
