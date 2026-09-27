import AppKit
import Quartz

/// Shared checks for app-wide `NSEvent` local key monitors. A local monitor sees every
/// key event in the app — including keys aimed at sheets, save panels, and text fields —
/// before those views do, so monitors must stand down in these situations.
enum ModalKeyGuard {
    /// True while a modal session (e.g. `NSSavePanel.runModal()`), a sheet, or a window
    /// with an attached sheet owns the keyboard.
    static var isModalPresentationActive: Bool {
        if NSApp.modalWindow != nil { return true }
        // The Quick Look panel handles its own keys (arrows, Space, Esc).
        if isQuickLookPanelKey { return true }
        guard let keyWindow = NSApp.keyWindow else { return false }
        return keyWindow.isSheet || keyWindow.attachedSheet != nil
    }

    /// True while the Quick Look panel is the key window.
    static var isQuickLookPanelKey: Bool {
        guard let keyWindow = NSApp.keyWindow else { return false }
        return keyWindow is QLPreviewPanel
    }

    /// True when the key window's first responder is an editable text view
    /// (an `NSTextView`/`NSText`, the shared field editor, or an editable `NSTextField`).
    /// Read-only selectable text doesn't count, so it doesn't swallow navigation keys.
    static var isTextInputFocused: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        if let text = responder as? NSText {
            return text.isFieldEditor || text.isEditable
        }
        if let field = responder as? NSTextField {
            return field.isEditable
        }
        return false
    }

    /// True when a key monitor should ignore `event` entirely: something modal is up,
    /// a text field is being edited, or the event targets a different window (a panel).
    static func shouldIgnore(_ event: NSEvent, ownerWindow: NSWindow? = nil) -> Bool {
        if isModalPresentationActive || isTextInputFocused { return true }
        if let ownerWindow, let eventWindow = event.window, eventWindow !== ownerWindow {
            return true
        }
        return false
    }
}
