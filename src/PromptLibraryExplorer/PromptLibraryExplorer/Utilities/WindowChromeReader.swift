import AppKit
import SwiftUI

/// Reads the current window chrome height so app content can stay below the titlebar region.
struct WindowChromeReader: NSViewRepresentable {
    @Binding var topInset: CGFloat

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onUpdate = { window in
            updateInset(from: window)
        }
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        updateInset(from: nsView.window)
    }

    private func updateInset(from window: NSWindow?) {
        guard let window else { return }

        let inset = max(0, window.frame.height - window.contentLayoutRect.height)
        guard abs(topInset - inset) > 0.5 else { return }

        DispatchQueue.main.async {
            topInset = inset
        }
    }

    final class TrackingView: NSView {
        var onUpdate: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onUpdate?(window)
        }

        override func layout() {
            super.layout()
            onUpdate?(window)
        }

        override func viewDidEndLiveResize() {
            super.viewDidEndLiveResize()
            onUpdate?(window)
        }
    }
}
