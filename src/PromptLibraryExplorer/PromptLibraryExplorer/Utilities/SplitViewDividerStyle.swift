import AppKit
import SwiftUI

/// A ViewModifier that customizes the NSSplitView divider appearance
/// to show a visible vertical line and resize cursor on hover.
struct SplitViewDividerStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onAppear {
                // After a short delay (to let the window assemble), style all NSSplitViews
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    styleSplitViews()
                }
            }
    }

    private func styleSplitViews() {
        for window in NSApplication.shared.windows {
            findAndStyleSplitViews(in: window.contentView)
        }
    }

    private func findAndStyleSplitViews(in view: NSView?) {
        guard let view else { return }
        if let splitView = view as? NSSplitView {
            splitView.dividerStyle = .thin
        }
        for subview in view.subviews {
            findAndStyleSplitViews(in: subview)
        }
    }
}

extension View {
    func styledSplitViewDividers() -> some View {
        modifier(SplitViewDividerStyle())
    }
}
