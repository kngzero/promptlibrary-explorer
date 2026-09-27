import AppKit
import Quartz

/// Drives the shared `QLPreviewPanel` for the current selection.
///
/// QLPreviewPanel finds its controller through the responder chain, so the
/// controller inserts itself right after the main window in that chain
/// (`window.nextResponder`) the first time it is shown.
@MainActor
final class QuickLookController: NSResponder, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookController()

    private var urls: [URL] = []
    private weak var hostWindow: NSWindow?

    private override init() {
        super.init()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// True while the panel is on screen.
    static var isPanelVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    /// True while the panel is the key window (it owns the keyboard then).
    static var isPanelKey: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isKeyWindow
    }

    /// Shows `urls` (starting at `index`), or closes the panel when it is
    /// already showing — ⌘Y toggles, like Finder.
    func toggle(urls: [URL], startingAt index: Int = 0) {
        if Self.isPanelVisible {
            close()
            return
        }
        show(urls: urls, startingAt: index)
    }

    func show(urls: [URL], startingAt index: Int = 0) {
        guard !urls.isEmpty else { return }
        self.urls = urls
        attachToResponderChain()

        let panel = QLPreviewPanel.shared()!
        if panel.dataSource === self {
            panel.reloadData()
        }
        panel.makeKeyAndOrderFront(nil)
        panel.currentPreviewItemIndex = max(0, min(index, urls.count - 1))
        prepareEditedPreviews()
    }

    /// Updates the items while the panel is open (e.g. selection moved).
    func update(urls: [URL]) {
        guard Self.isPanelVisible, !urls.isEmpty, urls != self.urls else { return }
        self.urls = urls
        QLPreviewPanel.shared().reloadData()
        prepareEditedPreviews()
    }

    /// Edited images show their edit: a rendered stand-in file (EditPreviewFiles),
    /// made off the main actor; the panel reloads once they exist.
    private func prepareEditedPreviews() {
        let pending = urls.compactMap { url -> (URL, EditRecipe)? in
            guard let recipe = EditRecipeIndex.shared.recipe(for: url),
                  EditPreviewFiles.existing(for: url, recipe: recipe) == nil
            else { return nil }
            return (url, recipe)
        }
        guard !pending.isEmpty else { return }
        Task {
            let made = await Task.detached(priority: .userInitiated) {
                pending.reduce(0) { count, item in EditPreviewFiles.prepare(for: item.0, recipe: item.1) == nil ? count : count + 1 }
            }.value
            if made > 0, Self.isPanelVisible { QLPreviewPanel.shared().reloadData() }
        }
    }

    func close() {
        guard QLPreviewPanel.sharedPreviewPanelExists() else { return }
        QLPreviewPanel.shared().orderOut(nil)
    }

    private func attachToResponderChain() {
        guard let window = NSApp.mainWindow ?? NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) else {
            return
        }
        if hostWindow === window, window.nextResponder === self { return }
        // Detach from a previous window first.
        if let previous = hostWindow, previous.nextResponder === self {
            previous.nextResponder = nextResponder
        }
        nextResponder = window.nextResponder
        window.nextResponder = self
        hostWindow = window
    }

    // MARK: QLPreviewPanelController (informal protocol)

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        true
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    // MARK: QLPreviewPanelDataSource

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated {
            guard index >= 0, index < urls.count else { return nil }
            let url = urls[index]
            if let recipe = EditRecipeIndex.shared.recipe(for: url),
               let edited = EditPreviewFiles.existing(for: url, recipe: recipe) {
                return edited as NSURL
            }
            return url as NSURL
        }
    }
}
