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
            title: "File And App",
            description: "Menu commands available from the main app window.",
            items: [
                HelpShortcutItem(id: "open-folder", keys: ["Cmd", "O"], description: "Open a new root folder."),
                HelpShortcutItem(id: "new-folder", keys: ["Cmd", "Shift", "N"], description: "Create a new folder inside the current folder."),
                HelpShortcutItem(id: "trash", keys: ["Cmd", "Delete"], description: "Move the selected items to the Trash (undoable)."),
                HelpShortcutItem(id: "reveal", keys: ["Cmd", "Option", "R"], description: "Reveal the selection in Finder."),
                HelpShortcutItem(id: "settings", keys: ["Cmd", ","], description: "Open Settings."),
                HelpShortcutItem(id: "undo", keys: ["Cmd", "Z"], description: "Undo the last folder action such as move, rename, batch rename, or trash."),
                HelpShortcutItem(id: "redo", keys: ["Cmd", "Shift", "Z"], description: "Redo the last undone folder action.")
            ]
        ),
        HelpShortcutGroup(
            id: "edit",
            title: "Edit And Search",
            description: "Copying prompts and finding files.",
            items: [
                HelpShortcutItem(id: "copy-prompt", keys: ["Cmd", "Shift", "C"], description: "Copy the prompts of the selected files. Edit > Copy Prompt As offers other formats."),
                HelpShortcutItem(id: "copy-path", keys: ["Cmd", "Option", "C"], description: "Copy the paths of the selected items."),
                HelpShortcutItem(id: "search", keys: ["Cmd", "F"], description: "Focus the search field."),
                HelpShortcutItem(id: "library-search", keys: ["Cmd", "Shift", "F"], description: "Search prompts across the whole library.")
            ]
        ),
        HelpShortcutGroup(
            id: "view",
            title: "View",
            description: "Layout, grouping and previews.",
            items: [
                HelpShortcutItem(id: "view-grid", keys: ["Cmd", "1"], description: "Show the folder as a grid."),
                HelpShortcutItem(id: "view-list", keys: ["Cmd", "2"], description: "Show the folder as a list."),
                HelpShortcutItem(id: "quick-look", keys: ["Cmd", "Y"], description: "Quick Look the selection. Press again to close."),
                HelpShortcutItem(id: "compare-prompts", keys: ["Cmd", "D"], description: "Compare the prompts of the two selected files."),
                HelpShortcutItem(id: "refresh", keys: ["Cmd", "R"], description: "Refresh the current folder and sidebar.")
            ]
        ),
        HelpShortcutGroup(
            id: "go",
            title: "Go",
            description: "Moving between folders.",
            items: [
                HelpShortcutItem(id: "nav-back", keys: ["Cmd", "["], description: "Go back to the previously visited folder. Cmd and ← also works."),
                HelpShortcutItem(id: "nav-forward", keys: ["Cmd", "]"], description: "Go forward again after going back. Cmd and → also works."),
                HelpShortcutItem(id: "nav-up", keys: ["Cmd", "↑"], description: "Go to the enclosing folder (or leave a collection)."),
                HelpShortcutItem(id: "nav-drop-breadcrumb", keys: ["Drag", "→ Breadcrumbs"], description: "Drop a folder (from the grid or Finder) on the breadcrumb bar to open it. Drop a file to open its folder with the file selected. Nothing is moved or copied."),
                HelpShortcutItem(id: "command-palette", keys: ["Cmd", "K"], description: "Open or close the command palette for folders, files, smart folders, tags, and actions.")
            ]
        ),
        HelpShortcutGroup(
            id: "content",
            title: "Explorer Content Grid",
            description: "Shortcuts when the content pane is active.",
            items: [
                HelpShortcutItem(id: "content-arrows", keys: ["←", "→", "↑", "↓"], description: "Move selection through the grid. Left from the first column returns to the sidebar."),
                HelpShortcutItem(id: "content-extend", keys: ["Shift", "Arrows"], description: "Extend the selection from the anchor item."),
                HelpShortcutItem(id: "content-select-all", keys: ["Cmd", "A"], description: "Select every item in the folder (or collection). In a text field it selects the text instead."),
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
                HelpShortcutItem(id: "lightbox-close-space", keys: ["Space"], description: "Play or pause video and audio; otherwise close the lightbox."),
                HelpShortcutItem(id: "lightbox-nav", keys: ["←", "→"], description: "Move to the previous or next previewable item.")
            ]
        ),
        HelpShortcutGroup(
            id: "culling",
            title: "Culling: Flags, Ratings And Labels",
            description: "Bare keys (no modifier) in the grid or list act on the whole selection; in the lightbox they act on the item shown. They never fire while you type in a text field. Every change can be undone with Cmd Z. The Cull menu lists the same actions, plus Select Rejects and Move Rejects to Trash…",
            items: [
                HelpShortcutItem(id: "cull-pick", keys: ["P"], description: "Flag as a pick."),
                HelpShortcutItem(id: "cull-reject", keys: ["X"], description: "Flag as a reject. Rejects are dimmed in the grid; Filter ▸ Flag ▸ Hide Rejects hides them."),
                HelpShortcutItem(id: "cull-unflag", keys: ["U"], description: "Remove the pick or reject flag."),
                HelpShortcutItem(id: "cull-rate", keys: ["0 – 5"], description: "Set the star rating (0 clears it)."),
                HelpShortcutItem(id: "cull-label", keys: ["6", "7", "8", "9"], description: "Set the Finder colour label: 6 Red, 7 Yellow, 8 Green, 9 Blue. Other colours (and None) are in the Cull menu, the context menu and the details panel. Labels are Finder's own, so Finder shows them too."),
                HelpShortcutItem(id: "cull-mode", keys: ["Cull", "▸ Culling Mode"], description: "Shows the culling bar in the lightbox (flag, stars, label, position) and flashes each change. Also toggled from the flag button beside the lightbox's close button."),
                HelpShortcutItem(id: "cull-advance", keys: ["Cull", "▸ Auto-advance"], description: "In Culling Mode, move to the next item after each flag, rating or label key.")
            ]
        ),
        HelpShortcutGroup(
            id: "dialogs",
            title: "Dialogs, Palette And Inline Rename",
            description: "Shortcuts used in modal windows, the command palette, and inline editing.",
            items: [
                HelpShortcutItem(id: "rename-save", keys: ["Return"], description: "Save an inline rename."),
                HelpShortcutItem(id: "rename-cancel", keys: ["Esc"], description: "Cancel an inline rename."),
                HelpShortcutItem(id: "palette-close", keys: ["Esc"], description: "Close the command palette."),
                HelpShortcutItem(id: "settings-cancel", keys: ["Esc"], description: "Close Settings."),
                HelpShortcutItem(id: "settings-close", keys: ["Return"], description: "Close Settings (Done)."),
                HelpShortcutItem(id: "comparison-close", keys: ["Esc"], description: "Close the AoE comparison or prompt diff window.")
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
