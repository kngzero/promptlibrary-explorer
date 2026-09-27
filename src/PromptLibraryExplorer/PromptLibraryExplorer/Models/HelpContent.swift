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
        ),
        HelpFileTypeDescription(
            id: "mlmboard",
            extensionLabel: ".mlmboard",
            title: "Mood Board",
            description: "A board made in Art Official Mood: embedded images, colour and text tiles, a layout (auto, grid or mosaic), and branding with a title, subtitle and palette. Older boards stored as ZIP archives are read too.",
            highlights: [
                "The grid tile and preview show the rendered board; the lightbox renders it at window size and ← / → step through its images.",
                "The details panel lists the layout, asset and tile counts, the palette (click a swatch to copy its hex, or copy the whole palette as HEX, CSS variables or JSON) and every embedded image.",
                "Open in Mood, Extract Images…, Export Board as PNG… and Copy Palette are in the context menu and the details panel.",
                "Title, subtitle, image names, captions and palette hex values are searchable."
            ]
        ),
        HelpFileTypeDescription(
            id: "stry",
            extensionLabel: ".stry / .mlseq",
            title: "Story Project",
            description: "A storyboard made in Art Official Story: one or more projects with scenes, shots (thumbnail, type, description, notes, tags, duration) and Fountain scripts. .mlseq is the older web format.",
            highlights: [
                "The grid tile shows the project cover or a contact sheet of the first shots.",
                "The details panel shows credits, dates, counts, estimated runtime, a scene → shot outline and the scripts; files with several projects get a project picker.",
                "In the lightbox, ← / → step shot by shot (\"Scene 1 · Shot 2\") with the shot's type, description and notes beside it.",
                "Open in Story, Extract Shot Thumbnails…, Export Contact Sheet… and Copy Shot List (text or CSV) are in the context menu and the details panel.",
                "Loglines, scene names, locations, shot descriptions, notes, tags and script text are searchable."
            ]
        ),
        HelpFileTypeDescription(
            id: "send-to",
            extensionLabel: "Send to",
            title: "Send to Mood / Send to Story",
            description: "File ▸ Send to Mood… or Send to Story… (also in the grid and collection context menus) builds a new board or storyboard from the selected images — or the whole folder or collection when nothing is selected — in display order.",
            highlights: [
                "Only images are sent; anything else is skipped and reported.",
                "Mood boards get the images (large ones scaled to 2560 px) and a palette taken from them, titled after the folder or collection.",
                "Story projects get one shot per image, named after the file, with the file's prompt as the description and its tags.",
                "When it's done you can open the new file in Mood or Story, or reveal it in Finder."
            ]
        ),
        HelpFileTypeDescription(
            id: "export",
            extensionLabel: "Export",
            title: "Export Presets",
            description: "File ▸ Export… (also Export With Preset, the grid's and collections' Export context menus, and the command palette) writes converted copies of the selection, or of the whole folder or collection when nothing is selected. Originals are never changed.",
            highlights: [
                "A preset sets the format (Keep Original, PNG, JPEG, HEIC, TIFF, and WebP where this Mac can write it), size (long edge, exact size cropped to fill, or a percentage), quality, colour profile (keep, sRGB or Display P3), metadata, file name, destination and what to do when a name is taken.",
                "Shipped presets: Web JPEG 2048, Full-res PNG, Instagram 1080, HEIC Archive and For Sharing. Edit them in the export sheet or in Settings ▸ Export; Save as New Preset keeps a variation.",
                "File names use the Batch Rename tokens ({name}, {date}, {model}, {seed}, {counter:3}…); the output format's extension is added. Destinations: ask each time, a fixed folder, or a subfolder next to each original. Replacing existing files asks first and moves the old files to the Trash; an original is never replaced.",
                "The sheet previews the count, an estimated total size and the first output names, then runs in the background with progress and Stop. The summary lists anything skipped and can reveal the new files in Finder.",
                "Videos and audio are copied; with “Remove metadata from videos and audio” MOV, MP4, M4V and M4A are re-wrapped without metadata (no re-encoding), other formats are copied and the summary says so. Mood boards, Story projects, .plib and .aoe files are skipped unless “Export rendered previews” is on.",
                "Watermark: text or an image (a PNG with transparency), in one of nine positions, with margin, size, opacity and an optional shadow. The preset editor shows a live preview."
            ]
        ),
        HelpFileTypeDescription(
            id: "privacy-export",
            extensionLabel: "Privacy",
            title: "Export for Sharing (Strip AI Metadata)",
            description: "File ▸ Export for Sharing (Strip AI Metadata)… exports copies without the generation data: prompts, negative prompts, seeds and parameters, ComfyUI workflow and prompt graphs, A1111 parameters, EXIF User Comment, image descriptions (EXIF, TIFF, XMP), IPTC AI prompt fields and GPS location.",
            highlights: [
                "When the format and size don't change, the pixels are untouched: PNGs are rebuilt chunk by chunk with the image data copied byte for byte, and JPEGs get a lossless metadata rewrite.",
                "Camera and lens data, rating, keywords and copyright are kept. The metadata policy in any preset can instead Strip All, or Keep Only the fields you tick (for example prompt and model but not the seed).",
                "Every exported image is re-read afterwards; if any prompt, seed, parameter, ComfyUI graph or GPS location is still there, that file isn't saved and the summary says why.",
                "Content Credentials (C2PA) in a PNG are left as they are. A JPEG's credentials don't survive the metadata rewrite, and a changed file's credentials no longer validate either way."
            ]
        ),
        HelpFileTypeDescription(
            id: "contact-sheet",
            extensionLabel: "PDF",
            title: "Contact Sheet",
            description: "File ▸ Export Contact Sheet… (also in the Export context menus) lays the selection, folder or collection out as a multi-page PDF for clients or printing.",
            highlights: [
                "Choose A4, US Letter or a custom size, portrait or landscape, the columns and rows, margins and spacing; the first page is previewed as you go.",
                "Captions can show the file name, the rating and flag, and a prompt excerpt. A header carries the title and date, and pages are numbered.",
                "Pages are drawn as a real PDF (text stays text), with each image downsampled to suit its cell; videos show a frame and Mood / Story files their rendered overview."
            ]
        ),
        HelpFileTypeDescription(
            id: "video-audio-tools",
            extensionLabel: "Video & Audio",
            title: "Hover Scrubbing, Frames, Trimming and Waveforms",
            description: "Tools for video and audio files in the grid, the list, the lightbox and the details panel. The original file is never modified or overwritten: everything is written as a new file.",
            highlights: [
                "Hover scrubbing: move the pointer across a video's tile (grid or list) to see the frame at that point, with a thin line for the position; leaving the tile shows the poster again. Settings ▸ Appearance turns it off.",
                "Frames: in the lightbox, Save Frame… saves the frame on screen at full resolution as PNG or JPEG (named like \"clip @ 00m12s.png\"), Copy Frame puts it on the clipboard, and Frame Strip… saves a contact strip of 4–24 evenly spaced frames with timecodes. Save Middle Frame (context menu, File menu) writes a PNG of each selected video's midpoint next to it.",
                "Trim & Export Clip… (lightbox Trim…, context menu, File menu): drag the in and out handles over the frame strip, play the range, then export as MP4 (H.264 or HEVC) or an animated GIF (5–30 fps, a maximum width, loop or play once). An MP4 whose codec matches the source is copied without re-encoding. Clips are saved next to the original as \"clip (trim).mp4\" / \"clip.gif\" (numbered if the name is taken) or wherever you choose; the export shows progress and can be cancelled.",
                "Audio files show their waveform as the thumbnail. The lightbox and details audio player shows a large waveform: click to seek, drag to select a region, then Loop plays just that region.",
                "Beat (BPM) and key detection aren't included."
            ]
        ),
        HelpFileTypeDescription(
            id: "visual-search",
            extensionLabel: "Visual Search",
            title: "Similar Images, More Like This and Colour Search",
            description: "A background visual index (images and videos — a frame from the middle of each clip) powers searching by look and by colour. It builds automatically when a folder opens; the indicator in the bottom status bar shows its progress, and clicking it gives Pause, Resume and Stop. Settings ▸ Search Index has the same controls and a full rebuild.",
            highlights: [
                "Library ▸ Similar Images (also in the command palette) turns the main window into the Similar Images page: the sidebar stays, and the browser and details panel make way for it. The left column lists the groups — exact copies (identical files, labelled Exact) and near-duplicates (labelled Similar) — in This Folder or the Whole Library, with a strictness slider, an Include Videos switch and Find. Drag the divider to resize it.",
                "Select a group to see its files large, side by side, in folder-then-name order, each with its folder, pixel size, file size, date, flag / rating / label and prompt. Hover a file (or right-click it) for Open in Lightbox, Reveal in Finder, More Like This, Copy Prompt and the Flag, Rating and Label menus; the group's header has Select in Browser, Add to Collection… and Open Group as Listing.",
                "Every file is kept: nothing in a group is marked, pre-selected, ranked or suggested for removal — a larger copy is often an upscale of the master — and the page has no delete button.",
                "Clicking a folder in the sidebar keeps the page (with This Folder it searches the new folder); a collection or smart folder shows in the browser. Done, Esc or View ▸ Show Browser returns to the browser exactly as you left it; results are remembered, so coming back is instant.",
                "More Like This (press M in the grid or lightbox, or use the context menu, the details panel or the Library menu) lists the files that look most like the selected one, most similar first, as \"Similar to <name>\". Library ▸ Visual Search Scope chooses This Folder or Whole Library for every visual search.",
                "A virtual listing works like a collection: its name and a close button replace the breadcrumbs; flags, ratings, labels, collections and Send to all work on it; Sort ▸ Similarity restores the ranking. Close it (or press Cmd ↑) to go back.",
                "Filter ▸ Colour… filters the listing by 1–3 colours (swatches, a hex value or the colour panel) with a tolerance; the active filter shows in the status bar. Find Matching ranks images by the palette instead.",
                "The details panel shows each image's dominant colours: click a swatch to filter by it. Find Images Matching Palette (context menu, details panel) searches with a Mood board's palette or an image's own colours.",
                "Group By ▸ Colour Family groups by the main colour's hue (Red … Pink, plus Neutral, Dark and Light); smart folders can require a dominant colour; Settings ▸ Appearance can show a thin colour strip on grid tiles."
            ]
        ),
        HelpFileTypeDescription(
            id: "viewing-tools",
            extensionLabel: "Viewing",
            title: "Compare Images, Loupe, Histogram and Slideshow",
            description: "Tools for looking closely. None of them changes, marks or deletes a file.",
            highlights: [
                "Compare Images (select 2 to 4 images or videos, then View ▸ Compare Images, the context menu or the command palette) opens a page over the browser and details panel; the sidebar stays. Side by Side shows every file with the same zoom and pan: pinch, the mouse wheel or Cmd-scroll zoom around the pointer, dragging (or a two-finger scroll) pans every pane together, and double-click switches between Fit and 100 %. The toolbar has Fit, 50, 100, 200 and 400 %.",
                "Same Framing (the default) lines up images of different sizes, so a master and its upscale show the same part of the picture; Actual Pixels makes 100 % one image pixel per screen pixel for each file. Each pane's bar shows its name, pixel size, file size and its own zoom, with Reveal in Finder, Copy Path and Copy Prompt. Videos compare as a frame.",
                "A/B Wipe shows two files in one view with a divider you drag; switch it to a horizontal divider, pick which files are A and B, or swap them. Images are decoded at the size the screen needs, and at full resolution only once you zoom to 100 % or more. Done, Esc or View ▸ Show Browser returns to the browser as you left it.",
                "On the Similar Images page, the group header's Compare button shows the group in the same synced compare instead of the cards (four files at a time; ← / → move through a larger group).",
                "In the lightbox, the magnifier button (or View ▸ Loupe) shows a loupe that follows the pointer at 2× or 4× the image's own pixels, with the pixel's position and RGB value; Crisp Pixels (View ▸ Loupe Magnification) shows hard pixel edges. The chart button (or View ▸ Histogram) shows the RGB and luminance histogram with shadow and highlight clipping.",
                "View ▸ Start Slideshow plays the selection (2 or more files), or else the whole folder, collection or listing in its current order and with its filters (hidden rejects stay hidden), full screen on the display the window is on. Move the mouse for the controls; the options set the interval (2–30 s), transition (none, crossfade, slide), shuffle, loop, background, caption (file name, prompt excerpt, rating) and whether videos play (the slideshow moves on when one ends)."
            ]
        ),
        HelpFileTypeDescription(
            id: "curation-data",
            extensionLabel: "Your Data",
            title: "Backups, Export and Sync Between Macs",
            description: "Ratings, flags, tags, favorites, custom orders, smart folders, collections and sets, snippets and recent folders are backed up, can be exported and imported, and sync between Macs through your library folder. Settings ▸ Data has every control.",
            highlights: [
                "Backups: one a day, plus one before every import, restore and app upgrade, in Application Support ▸ PromptLibraryExplorer ▸ Backups (14 daily and 8 weekly are kept). Choose an extra backup folder — for example in Dropbox — to keep copies off this Mac. Restore from Backup… lists them with their date and counts.",
                "Export Curation Data… writes everything to one JSON file (a documented format with both absolute and library-relative paths). Import… shows what would change per kind before anything happens; Merge keeps what you have and adds the export's data, Replace makes your data exactly the export. Undo Import puts back what you had.",
                "Sync between Macs (on by default): each library gets a hidden .promptlibrary/curation.json with its files' curation and library-relative paths, so it works where Dropbox lives at another path. Changes are written about two seconds after you make them and merged value by value when another Mac's changes arrive — the newest change wins, removals don't come back, simultaneous edits keep this Mac's value, and Dropbox conflicted copies are merged and removed.",
                "Finder tags (on by default): the app's tags are mirrored to Finder tags and Finder tags show up as app tags; removing one on either side removes it on the other. Finder's colour tags stay labels. Tag changes never alter file contents or modification dates.",
                "XMP sidecars (off by default): a Lightroom / Bridge style <name>.xmp next to each image, video or audio file holds its rating, label, tags, flag and prompts. Existing sidecars (including Lightroom's) fill in ratings, labels and keywords the app doesn't have yet. Sidecars move, rename and go to the Trash (and come back on undo) with their files; Library ▸ Write XMP Sidecars Now and the context menu write them on demand. Originals are never modified."
            ]
        ),
        HelpFileTypeDescription(
            id: "ingest",
            extensionLabel: "Ingest",
            title: "Live Folder Updates and the Ingest Inbox",
            description: "The open folder updates by itself when files change on disk, and watched folders (a ComfyUI output folder, Downloads…) feed new files into the sidebar's Inbox — optionally copied or moved into your library, renamed, tagged and collected on the way. Settings ▸ Ingest has every control.",
            highlights: [
                "Live updates (on by default): new, changed and removed files appear in the open folder within a second or two without reloading it — your selection and scroll position stay — and go straight into library search and the visual index. Files still being written (large PNGs, videos) are picked up once their size stops changing. The app's own data (.promptlibrary, XMP sidecars), temporary and partial-download files and Dropbox's cache are ignored.",
                "Watched folders: Settings ▸ Ingest ▸ Add Folder… Each folder has rules for NEW files (files already there are left alone unless you choose Process Existing Files): which types (images, videos, audio, Art Official documents), a minimum size and ignore patterns such as *_temp_*.",
                "What happens: Leave in Place (just show it in the Inbox), Copy or Move into a library folder, optionally into dated subfolders (yyyy/MM-dd makes 2026/09-27). A Batch Rename template ({date}_{model}_{counter:3}…) can rename files on the way; names are never overwritten. Moves and renames can be undone with Edit ▸ Undo.",
                "Tags and collections: add fixed tags, tag with the model name read from the file's generation data, and add new files to a collection.",
                "Duplicates are never copied twice and never deleted: when an identical file (same SHA-256) is already in the destination, the copy or move is skipped, the Inbox links the existing file, the new one is left where it is, and the log says so.",
                "The sidebar's Inbox shows files ingested in the last 7 days, with a badge for the new ones; click it (or a folder under it) for an Inbox listing, newest first. Mark All Seen clears the badge; Clear Inbox empties the list without touching files. Library ▸ Show Inbox, Mark Inbox as Seen and Ingest Log… do the same.",
                "Folders on external, network or Dropbox volumes work; a folder that disappears is marked Unavailable and picked up again when it comes back. With \u{201C}Process files added while the app was closed\u{201D} (on by default) files that arrived while the app wasn't running are processed at the next launch (\u{201C}N new files since last run\u{201D}).",
                "Activity shows in the status bar's indexing indicator; problems appear as a message and in the Ingest Log (the last 200 events)."
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
                HelpShortcutItem(id: "nav-up", keys: ["Cmd", "↑"], description: "Go to the enclosing folder (or leave a collection or a Similar to … listing)."),
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
                HelpShortcutItem(id: "content-clear", keys: ["Esc"], description: "Clear the current content selection."),
                HelpShortcutItem(id: "content-more-like-this", keys: ["M"], description: "More Like This: list the files that look most like the selected image or video (This Folder or Whole Library, per Library ▸ Visual Search Scope).")
            ]
        ),
        HelpShortcutGroup(
            id: "similar-images",
            title: "Similar Images Page",
            description: "Keys while Library ▸ Similar Images is showing. They act on the page, never on the browser behind it.",
            items: [
                HelpShortcutItem(id: "similar-groups", keys: ["↑", "↓"], description: "Previous or next group."),
                HelpShortcutItem(id: "similar-cards", keys: ["←", "→"], description: "Previous or next file in the group (the focused file has an accent ring)."),
                HelpShortcutItem(id: "similar-open", keys: ["Space / Return"], description: "Open the focused file in the lightbox; ← / → there step through the group. Closing it returns to the page."),
                HelpShortcutItem(id: "similar-more", keys: ["M"], description: "More Like This for the focused file (opens in the browser)."),
                HelpShortcutItem(id: "similar-cull", keys: ["P", "X", "U", "0 – 9"], description: "Flag, rate or label the focused file (with Culling Mode's auto-advance, focus moves to the next file)."),
                HelpShortcutItem(id: "similar-leave", keys: ["Esc"], description: "Back to the browser.")
            ]
        ),
        HelpShortcutGroup(
            id: "compare-slideshow",
            title: "Compare Images And Slideshow",
            description: "Keys on the Compare page and in a slideshow. Zoom, pan and the loupe use the mouse or trackpad; there are no new letter shortcuts.",
            items: [
                HelpShortcutItem(id: "compare-leave", keys: ["Esc"], description: "Leave the Compare page (back to the browser). Other bare keys do nothing there, so nothing reaches the browser behind it."),
                HelpShortcutItem(id: "compare-zoom", keys: ["Pinch / Cmd scroll"], description: "Zoom every pane around the pointer. Double-click switches between Fit and 100 %."),
                HelpShortcutItem(id: "slideshow-nav", keys: ["←", "→"], description: "Previous or next slide."),
                HelpShortcutItem(id: "slideshow-play", keys: ["Space"], description: "Pause or play (videos too)."),
                HelpShortcutItem(id: "slideshow-end", keys: ["Esc"], description: "End the slideshow. Cmd W does the same.")
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
                HelpShortcutItem(id: "lightbox-nav", keys: ["←", "→"], description: "Move to the previous or next previewable item. On a Mood board or Story project they step through its images or shots instead."),
                HelpShortcutItem(id: "lightbox-nav-files", keys: ["↑", "↓"], description: "Move to the previous or next previewable item, including from inside a Mood board or Story project. Option ← / Option → do the same."),
                HelpShortcutItem(id: "lightbox-doc-back", keys: ["Esc"], description: "While stepping through a Mood board or Story project, return to the whole board or contact sheet (press again to close)."),
                HelpShortcutItem(id: "lightbox-more-like-this", keys: ["M"], description: "More Like This for the item shown; the lightbox stays on it and ← / → step through the most similar files.")
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
