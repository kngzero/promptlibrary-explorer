import AppKit
import SwiftUI

/// Monitors keyboard events at the NSEvent level (window-wide),
/// bypassing SwiftUI's focus system which is unreliable for custom views.
struct KeyboardMonitorView: NSViewRepresentable {
    let onKeyDown: (NSEvent) -> Bool  // return true if handled

    func makeNSView(context: Context) -> KeyCatcherView {
        let view = KeyCatcherView()
        view.onKeyDown = onKeyDown
        // Ensure this view can become first responder
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: KeyCatcherView, context: Context) {
        nsView.onKeyDown = onKeyDown
    }

    class KeyCatcherView: NSView {
        var onKeyDown: ((NSEvent) -> Bool)?

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            if let handler = onKeyDown, handler(event) {
                return  // consumed
            }
            super.keyDown(with: event)
        }

        // Prevent beep on unhandled keys
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if let handler = onKeyDown, handler(event) {
                return true
            }
            return super.performKeyEquivalent(with: event)
        }
    }
}

/// A view modifier that installs a global local event monitor for a specific event mask.
/// This catches events even when SwiftUI focus is elsewhere.
struct GlobalEventHandler: ViewModifier {
    let eventMask: NSEvent.EventTypeMask
    let handler: (NSEvent) -> Bool
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                monitor = NSEvent.addLocalMonitorForEvents(matching: eventMask) { event in
                    if handler(event) {
                        return nil  // consumed, don't propagate
                    }
                    return event  // pass through
                }
            }
            .onDisappear {
                if let monitor {
                    NSEvent.removeMonitor(monitor)
                }
                monitor = nil
            }
    }
}

extension View {
    /// Installs a local key event monitor on the entire window.
    func onGlobalKeyDown(_ handler: @escaping (NSEvent) -> Bool) -> some View {
        modifier(GlobalEventHandler(eventMask: .keyDown, handler: handler))
    }

    /// Installs a local scroll-wheel event monitor on the entire window.
    func onGlobalScrollWheel(_ handler: @escaping (NSEvent) -> Bool) -> some View {
        modifier(GlobalEventHandler(eventMask: .scrollWheel, handler: handler))
    }
}

// Key code constants for readability
enum KeyCode: UInt16 {
    case escape = 53
    case returnKey = 36
    case space = 49
    case forwardDelete = 117
    case leftArrow = 123
    case rightArrow = 124
    case downArrow = 125
    case upArrow = 126
    case tab = 48
    case delete = 51
    case f = 3
    case z = 6
}
