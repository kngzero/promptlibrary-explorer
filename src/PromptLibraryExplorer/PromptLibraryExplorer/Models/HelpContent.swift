import Foundation

struct HelpFileTypeDescription: Identifiable {
    let id: String
    let extensionLabel: String
    let title: String
    let description: String
    let highlights: [String]
}

struct HelpShortcutItem: Identifiable {
    let id: String
    let keys: [String]
    let description: String
}

struct HelpShortcutGroup: Identifiable {
    let id: String
    let title: String
    let description: String
    let items: [HelpShortcutItem]
}

struct HelpDeveloperResource {
    let title: String
    let description: String
    let buttonTitle: String
    let urlString: String
}

enum HelpContent {
    static let fileTypes: [HelpFileTypeDescription] = [
        HelpFileTypeDescription(
            id: "aoe",
            extensionLabel: ".aoe",
            title: "Art Official Elements Snapshot",
            description: "A JSON snapshot used by Art Official Elements. The app reads one generated image, recovered prompt text, model and timestamp metadata, and structured prompt-analysis fields.",
            highlights: [
                "Contains a single generated image preview.",
                "Can include analysis segments like subject, style, lighting, palette, and mood.",
                "Used by the explorer, details panel, and AoE comparison view."
            ]
        ),
        HelpFileTypeDescription(
            id: "plib",
            extensionLabel: ".plib",
            title: "Prompt Library Snapshot",
            description: "A JSON prompt snapshot that stores prompt text, generation metadata, one or more generated images, optional reference images, and optional analysis data.",
            highlights: [
                "Can contain multiple generated images.",
                "May include reference images resolved from base64, absolute paths, or relative paths.",
                "Supports prompt, blind prompt, hint, and analysis metadata."
            ]
        )
    ]

    static let shortcutGroups: [HelpShortcutGroup] = [
        HelpShortcutGroup(
            id: "app",
            title: "App And Global",
            description: "Commands available from the main app window.",
            items: [
                HelpShortcutItem(id: "open-folder", keys: ["Cmd", "O"], description: "Open a new root folder."),
                HelpShortcutItem(id: "settings", keys: ["Cmd", ","], description: "Open Maintenance Tools."),
                HelpShortcutItem(id: "refresh", keys: ["Cmd", "R"], description: "Refresh the current folder and sidebar."),
                HelpShortcutItem(id: "search", keys: ["Cmd", "F"], description: "Focus the search field."),
                HelpShortcutItem(id: "undo", keys: ["Cmd", "Z"], description: "Undo the last folder action such as move, rename, or trash."),
                HelpShortcutItem(id: "redo", keys: ["Cmd", "Shift", "Z"], description: "Redo the last undone folder action.")
            ]
        ),
        HelpShortcutGroup(
            id: "content",
            title: "Explorer Content Grid",
            description: "Shortcuts when the content pane is active.",
            items: [
                HelpShortcutItem(id: "content-arrows", keys: ["←", "→", "↑", "↓"], description: "Move selection through the grid. Left from the first column returns to the sidebar."),
                HelpShortcutItem(id: "content-open", keys: ["Return"], description: "Open the selected folder or preview the selected file."),
                HelpShortcutItem(id: "content-preview", keys: ["Space"], description: "Open the selected previewable item in the lightbox."),
                HelpShortcutItem(id: "content-parent", keys: ["Delete / Backspace"], description: "Navigate up one folder."),
                HelpShortcutItem(id: "content-delete", keys: ["Shift", "Delete"], description: "Open permanent delete confirmation for the current selection."),
                HelpShortcutItem(id: "content-clear", keys: ["Esc"], description: "Clear the current content selection.")
            ]
        ),
        HelpShortcutGroup(
            id: "sidebar",
            title: "Sidebar Folder Tree",
            description: "Shortcuts when the sidebar is active.",
            items: [
                HelpShortcutItem(id: "sidebar-vertical", keys: ["↑", "↓"], description: "Move folder selection up or down."),
                HelpShortcutItem(id: "sidebar-left", keys: ["←"], description: "Select the parent folder."),
                HelpShortcutItem(id: "sidebar-right", keys: ["→"], description: "Move focus into the content pane or nearest first-column item."),
                HelpShortcutItem(id: "sidebar-space", keys: ["Space"], description: "Expand or collapse the selected folder.")
            ]
        ),
        HelpShortcutGroup(
            id: "lightbox",
            title: "Lightbox",
            description: "Navigation while a preview is open.",
            items: [
                HelpShortcutItem(id: "lightbox-close-esc", keys: ["Esc"], description: "Close the lightbox."),
                HelpShortcutItem(id: "lightbox-close-space", keys: ["Space"], description: "Close the lightbox."),
                HelpShortcutItem(id: "lightbox-nav", keys: ["←", "→"], description: "Move to the previous or next previewable item.")
            ]
        ),
        HelpShortcutGroup(
            id: "dialogs",
            title: "Dialogs And Inline Rename",
            description: "Shortcuts used in modal windows and inline editing.",
            items: [
                HelpShortcutItem(id: "rename-save", keys: ["Return"], description: "Save an inline rename."),
                HelpShortcutItem(id: "rename-cancel", keys: ["Esc"], description: "Cancel an inline rename."),
                HelpShortcutItem(id: "settings-cancel", keys: ["Esc"], description: "Cancel and close the Maintenance Tools window."),
                HelpShortcutItem(id: "settings-close", keys: ["Return"], description: "Close the Maintenance Tools window."),
                HelpShortcutItem(id: "comparison-close", keys: ["Esc"], description: "Close the AoE comparison window.")
            ]
        )
    ]

    static let developerResource = HelpDeveloperResource(
        title: "Art Official",
        description: "PromptLibrary Explorer is developed by Art Official. Visit the developer site for the broader product and brand ecosystem.",
        buttonTitle: "Visit artofficial.world",
        urlString: "https://artofficial.world"
    )
}
