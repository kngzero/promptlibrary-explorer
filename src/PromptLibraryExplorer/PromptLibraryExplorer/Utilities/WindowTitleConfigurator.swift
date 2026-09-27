import AppKit
import SwiftUI

/// Hides the title of the main browser window (the toolbar's principal item
/// carries the app identity), records the window for `ModalKeyGuard`, and sets
/// overflow priorities on the browser toolbar items.
struct WindowTitleConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onUpdate = configure(window:)
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        configure(window: nsView.window)
    }

    private func configure(window: NSWindow?) {
        guard let window else { return }
        ModalKeyGuard.mainBrowserWindow = window
        if !window.title.isEmpty { window.title = "" }
        if !window.subtitle.isEmpty { window.subtitle = "" }
        if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
        if let toolbar = window.toolbar {
            Self.applyVisibilityPriorities(to: toolbar)
        }
    }

    /// SwiftUI has no API for `NSToolbarItem.visibilityPriority`; without it the
    /// toolbar overflows from the trailing end, so search would vanish first.
    /// Item identifiers carry the ids from `BrowserToolbarItemID`.
    static func applyVisibilityPriorities(to toolbar: NSToolbar) {
        for item in toolbar.items {
            let identifier = item.itemIdentifier.rawValue
            let priority: NSToolbarItem.VisibilityPriority
            if BrowserToolbarItemID.highPriority.contains(where: { identifier.hasSuffix($0) }) {
                priority = .high
            } else if BrowserToolbarItemID.lowPriority.contains(where: { identifier.hasSuffix($0) }) {
                priority = .low
            } else {
                continue
            }
            if item.visibilityPriority != priority {
                item.visibilityPriority = priority
            }
        }
    }

    final class TrackingView: NSView {
        var onUpdate: ((NSWindow?) -> Void)?
        private var toolbarObserver: NSObjectProtocol?

        deinit {
            if let toolbarObserver { NotificationCenter.default.removeObserver(toolbarObserver) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onUpdate?(window)
            observeToolbarItems()
        }

        override func layout() {
            super.layout()
            onUpdate?(window)
        }

        /// Items can be (re)created after layout — customization, the lightbox
        /// hiding/showing the toolbar — so re-apply priorities as they're added.
        private func observeToolbarItems() {
            if let toolbarObserver { NotificationCenter.default.removeObserver(toolbarObserver) }
            toolbarObserver = nil
            guard window != nil else { return }
            toolbarObserver = NotificationCenter.default.addObserver(
                forName: NSToolbar.willAddItemNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let toolbar = note.object as? NSToolbar, toolbar === self?.window?.toolbar else { return }
                // The item isn't in `items` until the add completes.
                DispatchQueue.main.async {
                    WindowTitleConfigurator.applyVisibilityPriorities(to: toolbar)
                }
            }
        }
    }
}
