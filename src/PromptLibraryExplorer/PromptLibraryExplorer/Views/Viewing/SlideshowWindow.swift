import AppKit
import SwiftUI

/// A borderless window covering the screen the browser is on, with the Dock
/// and menu bar hidden while it's up. It handles its own keys (←/→ previous
/// / next, Space play / pause, Esc end) in `sendEvent`, before any view sees
/// them. The main window's key monitors stand down while it is key
/// (`ModalKeyGuard.isAuxiliaryWindowKey`), so none of these keys reach the
/// browser or the lightbox.
@MainActor
final class SlideshowWindowController {
    let model: SlideshowModel
    var onClose: (() -> Void)?

    private var window: SlideshowWindow?
    private var savedPresentationOptions: NSApplication.PresentationOptions = []
    private var isClosing = false

    init(model: SlideshowModel, screen: NSScreen?) {
        self.model = model
        let screen = screen ?? NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        model.screenPixelSize = max(frame.width, frame.height) * (screen?.backingScaleFactor ?? 2)

        let window = SlideshowWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.hasShadow = false
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        window.title = "Slideshow"
        window.setFrame(frame, display: false)

        let hosting = NSHostingView(rootView: SlideshowView(model: model))
        hosting.frame = CGRect(origin: .zero, size: frame.size)
        hosting.autoresizingMask = [.width, .height]
        let container = SlideshowContainerView(frame: CGRect(origin: .zero, size: frame.size))
        container.addSubview(hosting)
        container.onMouseMoved = { [weak model] in model?.pointerMoved() }
        window.contentView = container
        window.onKey = { [weak model] action in model?.perform(action) }
        window.onCloseRequest = { [weak self] in self?.close() }
        self.window = window

        model.onClose = { [weak self] in self?.close() }
    }

    func show() {
        guard let window else { return }
        savedPresentationOptions = NSApp.presentationOptions
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(window.contentView)
        NSApp.activate(ignoringOtherApps: true)
        model.begin()
    }

    func close() {
        guard !isClosing else { return }
        isClosing = true
        model.end()
        NSApp.presentationOptions = savedPresentationOptions
        NSCursor.setHiddenUntilMouseMoves(false)
        window?.orderOut(nil)
        window?.close()
        window = nil
        ModalKeyGuard.mainBrowserWindow?.makeKeyAndOrderFront(nil)
        onClose?()
    }
}

final class SlideshowWindow: NSWindow {
    var onKey: ((SlideshowKeyAction) -> Void)?
    var onCloseRequest: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if let action = SlideshowKeyAction.action(keyCode: event.keyCode, hasModifiers: !modifiers.isEmpty) {
                // A held arrow steps once per press, not a flood of slides.
                if !event.isARepeat || action == .previous || action == .next { onKey?(action) }
                return
            }
        }
        super.sendEvent(event)
    }

    /// File ▸ Close (⌘W) ends the slideshow (a borderless window has no close button).
    override func performClose(_ sender: Any?) {
        onCloseRequest?()
    }

    override func cancelOperation(_ sender: Any?) {
        onCloseRequest?()
    }
}

/// Takes the window's mouse-moved events (controls auto-hide) and swallows
/// unhandled keys so they don't beep.
final class SlideshowContainerView: NSView {
    var onMouseMoved: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        onMouseMoved?()
        super.mouseMoved(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // Keys the slideshow doesn't use (the window handled its own already).
    }
}
