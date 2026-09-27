import AppKit
import Quartz

/// Shared checks for app-wide `NSEvent` local key monitors. A local monitor sees every
/// key event in the app — including keys aimed at sheets, save panels, and text fields —
/// before those views do, so monitors must stand down in these situations.
enum ModalKeyGuard {
    /// The browser window hosting `MainContentView`, recorded by
    /// `WindowTitleConfigurator` when that view lands in its window. Weak, so a
    /// closed window doesn't linger.
    @MainActor static weak var mainBrowserWindow: NSWindow?

    /// True when some other window of ours (Settings, an auxiliary window, a
    /// popover) is key: the main window's monitors must leave its keys alone.
    /// False while nothing is recorded yet, so a missing registration never
    /// disables the keyboard.
    @MainActor static var isAuxiliaryWindowKey: Bool {
        guard let mainBrowserWindow, let keyWindow = NSApp.keyWindow else { return false }
        return keyWindow !== mainBrowserWindow
    }

    /// Everything the main window's key monitors stand down for: modals,
    /// sheets, Quick Look, and any key window that isn't the browser window.
    @MainActor static var shouldMainWindowMonitorStandDown: Bool {
        isModalPresentationActive || isAuxiliaryWindowKey
    }

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
    /// a text field is being edited, a window other than the browser window is key
    /// (Settings…), or the event targets a different window (a panel).
    @MainActor
    static func shouldIgnore(_ event: NSEvent, ownerWindow: NSWindow? = nil) -> Bool {
        if shouldMainWindowMonitorStandDown || isTextInputFocused { return true }
        if let ownerWindow, let eventWindow = event.window, eventWindow !== ownerWindow {
            return true
        }
        return false
    }
}
