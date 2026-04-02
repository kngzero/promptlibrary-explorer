import AppKit
import SwiftUI

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
        window.title = ""
        window.subtitle = ""
        window.titleVisibility = .hidden
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
    }
}
