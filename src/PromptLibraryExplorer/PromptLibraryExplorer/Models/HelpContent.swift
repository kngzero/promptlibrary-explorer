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
            id: "timeline-map",
            extensionLabel: "Timeline & Map",
            title: "Timeline, Map and Capture Dates",
            description: "View ▸ Timeline and View ▸ Map (also in the command palette) turn the main window into a page, like Similar Images: the sidebar stays, and the browser and details panel make way. Done, Esc or View ▸ Show Browser returns to the browser exactly as you left it. Nothing on these pages marks or deletes a file.",
            highlights: [
                "Every file gets one date: its capture date when the file has one (EXIF date taken, the QuickTime creation date of a video, a PNG time chunk, or a timestamp a generator wrote), else its creation date, else its modification date. The details panel's Date row says which it is — Captured, Created or Modified — and hovering it names the source.",
                "Timeline: This Folder (the browser's listing, with its filters and search) or Whole Library (every indexed file, with the filters). Years, Months or Days (or pinch) set the grouping; headers stay on top while you scroll and show how many files each period has and how many are placed by file date. The bar on the right shows files per month: click or drag it to jump.",
                "Click a thumbnail to select it, double-click (or Space) to open the lightbox, where ← / → step through that day. ← / → move the selection, ↑ / ↓ jump a period, P X U 0–9 flag, rate or label it. Right-click for the usual item menu. A header's grid button shows that period in the browser.",
                "Map: files with a location, clustered by zoom level; each badge shows the newest file and the count. Click a cluster to list its files beside the map, double-click it to zoom in; Show in Browser opens them as a listing. Most AI images have no location — photos and phone videos usually do.",
                "Privacy: locations are read from the files only (EXIF GPS, QuickTime ISO 6709). The map downloads its tiles from Apple; nothing else is sent unless you click Look Up Place Names, which asks Apple for the names of the places in view one at a time and remembers them.",
                "Dates and locations are stored in the library index. Files indexed before this existed are read in the background when a page opens (the Dating… progress in the page's bar and in the indexing status popover, with Stop and Resume). Online-only cloud files are skipped rather than downloaded.",
                "In the browser, Sort By ▸ Capture Date and Group By ▸ Month / Year use the same date. Right-click an image or video for Show in Timeline or Show on Map (they open with This Folder, at the file)."
            ]
        ),
        HelpFileTypeDescription(
            id: "version-stacks",
            extensionLabel: "Stacks",
            title: "Version Stacks",
            description: "Variants of one image — re-rolls with the same seed and prompt, numbered copies, upscales — can sit behind one cover tile. Turn it on per folder or collection with View ▸ Stack Variants (also in the context menu's Stack submenu); it's off until you do.",
            highlights: [
                "Automatic stacks group files in the listing with the same seed and prompt; names that differ only by a variant suffix (name_1, name (2), name copy, name-upscaled, name@2x, name-v2); ComfyUI-style counters (ComfyUI_00012_) when the prompt matches; and upscales — the same picture (visual index signature), the same aspect ratio, a larger pixel size.",
                "A stack tile shows the cover with stacked edges and a count badge; click the badge's chevron (or View ▸ Stacks ▸ Expand Stack, or the details panel's Expand) to list every variant inline right after the cover, marked with an accent rail. Expand All / Collapse All are in View ▸ Stacks.",
                "Selecting a collapsed stack selects its cover only: ratings, flags, labels, tags, drags, exports and every other action apply to the cover. Expand the stack to act on the other variants.",
                "Opening a collapsed stack in the lightbox expands it, so the arrow keys walk through its variants; closing the lightbox collapses it again (unless you ended on another variant).",
                "The cover is the one you chose (Set as Cover), otherwise the most recently modified file — never the largest. It's only what the tile shows: nothing about stacks marks, ranks or suggests any file for deletion.",
                "Stack Selected makes a manual stack of the selection (turning Stack Variants on); Unstack breaks a stack up and keeps its files out of automatic stacks; Remove from Stack takes the selected variant out. Manual stacks, covers and these choices are curation data: they're in backups, exports and the library data file that syncs between Macs."
            ]
        ),
        HelpFileTypeDescription(
            id: "image-text",
            extensionLabel: "Text & Tags",
            title: "Text in Images and Suggested Tags",
            description: "After the visual index, a background pass reads the text visible in each image (Vision text recognition, accurate, with language correction) and classifies what the image shows. It runs at low priority on a reduced-size copy, follows the visual index's Pause and Stop, and stays on this Mac. Settings ▸ Search Index has the switches, counts, Re-analyse and Reset.",
            highlights: [
                "Search: choose the Text in Image search mode to match only recognised text; All includes it too, and Find in Library… matches it across the library. Prompt search stays prompt-only, so watermarks and the garbled lettering image models paint don't pollute it.",
                "The details panel's Text in Image card shows what was read, with Copy. Images not analysed yet have an Analyse Now button.",
                "Smart folders can require \u{201C}Text in image contains …\u{201D} or \u{201C}Has text in image\u{201D}.",
                "Suggested tags (under the file's tags in the details panel) come from confident, specific classification labels (generic ones like \u{201C}structure\u{201D} or \u{201C}people\u{201D} are left out), the main colour family and the generation model. Click a chip to add that tag, or Add All.",
                "Library ▸ Apply Suggested Tags… (and the context menu) reviews suggestions for the whole selection with a checkbox each; nothing is added until you press Apply and confirm. Suggestions only ever add tags — they never remove any — and are never applied on their own."
            ]
        ),
        HelpFileTypeDescription(
            id: "curation-data",
            extensionLabel: "Your Data",
            title: "Backups, Export and Sync Between Macs",
            description: "Ratings, flags, tags, favorites, custom orders, smart folders, collections and sets, snippets, version stacks and recent folders are backed up, can be exported and imported, and sync between Macs through your library folder. Settings ▸ Data has every control.",
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
        ),
        HelpFileTypeDescription(
            id: "spotlight-automation",
            extensionLabel: "System",
            title: "Spotlight, Shortcuts and promptlibrary:// Links",
            description: "Find library files from Spotlight by their prompt, tags, model or rating, and drive the app from Shortcuts, scripts and links. Settings ▸ Integrations has the controls.",
            highlights: [
                "Spotlight (on by default): every file in the library search index is added to Spotlight with its name, a prompt excerpt, the full prompt text, its tags, model, sampler, rating, pixel size and a small thumbnail. Choosing a result opens the app on the file's folder with the file selected. New, re-indexed, moved and trashed files update Spotlight as the search index changes; rating and tag changes update just those files. Rebuild Spotlight Index replaces everything; Remove from Spotlight takes every item out and turns the option off. Files are never modified.",
                "Shortcuts actions (under PromptLibrary Explorer in the Shortcuts app): Search Library (a query in, matching files out), Add Files to Collection (creates it if needed), Export with Preset (one of your export presets; a Destination Folder is needed when the preset asks each time), Strip AI Metadata (the Export for Sharing preset), Open Folder in PromptLibrary and Get Prompt of File. Exports never replace existing files and never touch the originals. Siri / Spotlight phrases such as \u{201C}Search PromptLibrary Explorer\u{201D} run them too.",
                "Links, for Shortcuts' Open URL, Terminal's open or any note: promptlibrary://open?path=~/Pictures/Renders opens a folder (a file opens its folder with the file selected); promptlibrary://search?q=cinematic%20portrait runs Find in Library; promptlibrary://collection?name=Portfolio opens a collection. Paths may start with ~; spaces are %20. Links only navigate: nothing reachable from a link changes, exports or deletes files."
            ]
        ),
        HelpFileTypeDescription(
            id: "cloud-files",
            extensionLabel: "Cloud",
            title: "Online-Only Cloud Files (Dropbox, iCloud Drive, Google Drive)",
            description: "Files your cloud provider keeps online only are shown but never downloaded behind your back.",
            highlights: [
                "Online-only files (not downloaded to this Mac) show a cloud badge and a cloud placeholder instead of a thumbnail. Thumbnails, prompt parsing, library and visual indexing, hover scrubbing and waveforms skip them, so browsing a big Dropbox folder never starts hundreds of downloads. Their names stay searchable; their prompts are indexed once they're downloaded.",
                "Right-click ▸ Download (or File ▸ Download from Cloud) fetches the selected online-only files; the tiles fill in when each one arrives. Make Available Offline… downloads them and shows them in Finder, where Dropbox and Google Drive's \u{201C}Make Available Offline\u{201D} or iCloud Drive's \u{201C}Keep Downloaded\u{201D} keeps them on this Mac (only the provider can pin files).",
                "The lightbox shows \u{201C}Download to View\u{201D} for an online-only file. With \u{201C}Download files automatically when opened\u{201D} (Settings ▸ Integrations, on by default) opening one in the lightbox downloads it straight away; this only applies to files you open yourself."
            ]
        ),
        HelpFileTypeDescription(
            id: "prompt-lineage-builder",
            extensionLabel: "Prompts",
            title: "Prompt Lineage and the Prompt Builder",
            description: "See how a prompt evolved across related files, and compose new prompts from your own text, snippets and phrases already in your library.",
            highlights: [
                "Show Prompt Lineage (context menu, Library menu, the details panel's Prompt Tools): select two or more related files, or use a Similar Images group. The chain runs oldest first by file date; each step shows its thumbnail, the prompt with added words underlined in green and removed words struck through in red, and the seed / steps / CFG / sampler / model / size changes since the step before. Negative prompts can be shown too.",
                "Library ▸ Prompt Builder… starts empty; Open in Prompt Builder (context menu, details panel, a lineage step's menu) starts from a file's prompt, negative prompt and parameters.",
                "Add snippets (filter by category; click or drag into the prompt) or search the library index for a word and click a phrase that contains it. Every comma-separated phrase gets a weight chip: − / + write Stable Diffusion's (phrase:1.2) syntax; Reset Weights removes them.",
                "The preview shows the prompt as Plain Text, Midjourney, Stable Diffusion, DALL-E or JSON (Midjourney and DALL-E leave SD weights out). Copy any format, Save as Snippet (category Builder), or Send to Generator."
            ]
        ),
        HelpFileTypeDescription(
            id: "send-to-generator",
            extensionLabel: "Generators",
            title: "Re-run in ComfyUI and Send to A1111 / Forge",
            description: "Send a file's prompt and settings back to a generator running on this Mac or your network. Settings ▸ Generators holds the server addresses (ComfyUI http://127.0.0.1:8188, Automatic1111 / Forge http://127.0.0.1:7860) and Test Connection.",
            highlights: [
                "Re-run in ComfyUI queues the file's embedded ComfyUI API graph as-is, or with a new random seed and/or an edited positive prompt (the text of the encoder feeding the sampler's positive input). You get the queued prompt id. A file that only carries the UI workflow can't be queued directly: copy the workflow JSON and queue it in ComfyUI.",
                "Send to A1111 / Forge posts the prompt, negative prompt, steps, CFG, sampler, seed and size to txt2img (start the server with --api). Images are saved into an \"A1111 Output\" folder beside the source file (or a folder you choose); nothing is ever overwritten. A progress bar follows the server, and Cancel interrupts it.",
                "Use the file's model asks the server to switch to the file's checkpoint for that request and switch back afterwards.",
                "The app connects only to the addresses in Settings, only when you press Queue, Generate or Test Connection, and never in the background. Requests time out instead of hanging; errors explain what the server said."
            ]
        ),
        HelpFileTypeDescription(
            id: "prompt-statistics",
            extensionLabel: "Statistics",
            title: "Prompt Statistics",
            description: "Library ▸ Prompt Statistics… summarises This Folder (the current listing) or the Whole Library (from the search index; Library ▸ Reindex Library keeps it current).",
            highlights: [
                "Top words and two- or three-word phrases, counted once per file with common words left out. Click one to find it with Find in Library.",
                "Model usage by month (all models or one), sampler, steps and CFG distributions, and files per day over the last 60 days. Hover a bar for its numbers.",
                "Average rating and pick rate by model and by sampler, from your ratings and flags. Click a model or sampler to list its files in the browser.",
                "View ▸ Folder Statistics still shows file types and sizes for the folder."
            ]
        ),
        HelpFileTypeDescription(
            id: "image-editor",
            extensionLabel: "Edit",
            title: "Editing Images (Non-Destructive)",
            description: "Crop, straighten, rotate, flip and adjust images without ever changing the file. Edit ▸ Edit Image…, right-click ▸ Edit Image…, the details panel's Image Edits card or the lightbox's Edit button open the editor as a page over the browser (the sidebar stays).",
            highlights: [
                "Crop & Rotate: drag the corners, edges or the whole crop; pick an aspect ratio (Free, Original, 1:1, 4:5, 3:2, 16:9, 9:16, 2:3); a rule-of-thirds grid helps framing. Straighten (−45° to 45°) shows a finer grid while you drag and shrinks the crop so no empty corners appear. Rotate 90° left / right and flip horizontally / vertically.",
                "Adjust: exposure, contrast, saturation and temperature. Hold Compare to see the original; Revert to Original removes every edit.",
                "⌘Z / ⇧⌘Z undo and redo inside the editor. Done saves the edit as one step you can undo from Edit ▸ Undo; Cancel or Esc closes without saving (it asks first when you changed something).",
                "The original file is never modified. The edit is stored with your curation data, like ratings: it follows renames, moves and Trash / undo, is included in curation exports and backups, and syncs to your other Macs through the library data file.",
                "Edited images show their edit everywhere in the app: grid and list (with an edit badge), details panel (an Edited badge), lightbox (Show Original toggles back per file), Quick Look, Compare and the slideshow.",
                "Exports, contact sheets and Send to Mood / Story use the edited version. The export sheet's Use Edits / Export Original switch picks per export.",
                "Save Edited Copy… writes the edited image as a new file next to the original (\u{201C}Name (edited).png\u{201D}, never replacing anything). It keeps the original's prompt metadata unless you choose Strip AI metadata.",
                "Videos, audio, Mood boards, Story projects and .plib / .aoe snapshots can't be edited (the menu item says why)."
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
                HelpShortcutItem(id: "close-window", keys: ["Cmd", "W"], description: "Close the front window (Settings, a slideshow)."),
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
                HelpShortcutItem(id: "refresh", keys: ["Cmd", "R"], description: "Refresh the current folder and sidebar."),
                HelpShortcutItem(id: "toolbar", keys: ["Cmd", "Option", "T"], description: "Show or hide the toolbar. Right-click the toolbar to customise it.")
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
                HelpShortcutItem(id: "content-open", keys: ["Return"], description: "Open the selected folder, or open the selected file in the lightbox."),
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
            id: "timeline-map",
            title: "Timeline And Map Pages",
            description: "Keys while View ▸ Timeline or View ▸ Map is showing. They act on the page, never on the browser behind it.",
            items: [
                HelpShortcutItem(id: "timeline-move", keys: ["←", "→"], description: "Previous or next file (on the Map: in the selected cluster)."),
                HelpShortcutItem(id: "timeline-period", keys: ["↑", "↓"], description: "Timeline: previous or next period."),
                HelpShortcutItem(id: "timeline-open", keys: ["Space / Return"], description: "Open the selected file in the lightbox, walking its day (or its map cluster). Closing it returns to the page."),
                HelpShortcutItem(id: "timeline-cull", keys: ["P", "X", "U", "0 – 9"], description: "Flag, rate or label the selected file."),
                HelpShortcutItem(id: "timeline-more", keys: ["M"], description: "More Like This for the selected file (opens in the browser)."),
                HelpShortcutItem(id: "timeline-leave", keys: ["Esc"], description: "Back to the browser.")
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
                HelpShortcutItem(id: "lightbox-more-like-this", keys: ["M"], description: "More Like This for the item shown; the lightbox stays on it and ← / → step through the most similar files."),
                HelpShortcutItem(id: "lightbox-cull", keys: ["P", "X", "U", "0 – 9"], description: "Flag, rate or label the item shown (see Culling below)."),
                HelpShortcutItem(id: "lightbox-zoom", keys: ["Control", "= / −"], description: "Zoom in or out on an image. Scrolling pans a zoomed image.")
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
                HelpShortcutItem(id: "settings-cancel", keys: ["Esc"], description: "Close Settings (Cmd W does the same)."),
                HelpShortcutItem(id: "tour-keys", keys: ["←", "→", "Return", "Esc"], description: "Welcome tour: previous or next page, Return for the next page (or Done), Esc to skip."),
                HelpShortcutItem(id: "help-close", keys: ["Esc"], description: "Close Help."),
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

// MARK: - Sectioned reference (Help window)

/// The Help window's sections, in order.
enum HelpSectionID: String, CaseIterable, Identifiable, Sendable {
    case browse
    case prompts
    case cull
    case find
    case organise
    case media
    case export
    case dataSync
    case integrations
    case keyboard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .browse: return "Browse"
        case .prompts: return "Prompts"
        case .cull: return "Cull"
        case .find: return "Find"
        case .organise: return "Organise"
        case .media: return "Media"
        case .export: return "Export"
        case .dataSync: return "Data & Sync"
        case .integrations: return "Integrations"
        case .keyboard: return "Keyboard"
        }
    }

    var icon: String {
        switch self {
        case .browse: return "square.grid.2x2"
        case .prompts: return "text.quote"
        case .cull: return "flag.checkered"
        case .find: return "magnifyingglass"
        case .organise: return "rectangle.stack"
        case .media: return "film"
        case .export: return "square.and.arrow.up"
        case .dataSync: return "externaldrive.badge.checkmark"
        case .integrations: return "puzzlepiece.extension"
        case .keyboard: return "command"
        }
    }

    var blurb: String {
        switch self {
        case .browse: return "Opening a library, the grid, the details panel, the lightbox and the file types the app reads."
        case .prompts: return "Copying, comparing, building and re-running prompts."
        case .cull: return "Flags, ratings and colour labels, from the keyboard."
        case .find: return "Searching by name, prompt, text in the image, look and colour."
        case .organise: return "Collections, smart folders, tags, stacks and the ingest Inbox."
        case .media: return "Video and audio: scrubbing, frames, trimming and waveforms."
        case .export: return "Converted copies, presets, privacy and contact sheets."
        case .dataSync: return "Backups, the library sync file, Finder tags and XMP sidecars."
        case .integrations: return "Spotlight, Shortcuts, links, cloud files and generators."
        case .keyboard: return "Every keyboard shortcut, grouped by where it applies."
        }
    }
}

/// A direct entry point for a Help entry's "Show Me", a tip's action or a tour
/// page's "Try it". Each one is a real menu command or Settings page;
/// `ExplorerViewModel+Onboarding` performs them.
enum HelpCommand: String, CaseIterable, Identifiable, Sendable {
    case openFolder
    case welcomeTour
    case keyboardShortcuts
    case togglePreviewPane
    case compareImages
    case slideshow
    case batchRename
    case folderStatistics
    case cullingMode
    case focusSearch
    case findInLibrary
    case commandPalette
    case similarImages
    case moreLikeThis
    case similarPrompts
    case snippets
    case promptBuilder
    case promptStatistics
    case applySuggestedTags
    case reindexLibrary
    case newSmartFolder
    case stackVariants
    case showInbox
    case watchedFolders
    case sendToMood
    case export
    case exportForSharing
    case contactSheet
    case trimClip
    case writeXMPSidecars
    case appearanceSettings
    case exportSettings
    case dataSettings
    case integrationSettings
    case searchIndexSettings
    case generatorSettings
    case organizeSettings
    case storageSettings
    case fileOperationsSettings

    var id: String { rawValue }

    /// The menu path of the command, top menu first; the last element is the
    /// item's title exactly as the App file declares it. nil for Settings pages.
    var menuPath: [String]? {
        switch self {
        case .openFolder: return ["File", "Open Folder…"]
        case .welcomeTour: return ["Help", "Welcome Tour…"]
        case .keyboardShortcuts: return ["Help", "Keyboard Shortcuts"]
        case .togglePreviewPane: return ["View", "Hide Preview Pane"]
        case .compareImages: return ["View", "Compare Images"]
        case .slideshow: return ["View", "Start Slideshow"]
        case .batchRename: return ["File", "Batch Rename…"]
        case .folderStatistics: return ["View", "Folder Statistics"]
        case .cullingMode: return ["Cull", "Culling Mode"]
        case .focusSearch: return ["Edit", "Find"]
        case .findInLibrary: return ["Edit", "Find in Library…"]
        case .commandPalette: return ["Go", "Command Palette"]
        case .similarImages: return ["Library", "Similar Images"]
        case .moreLikeThis: return ["Library", "More Like This (M)"]
        case .similarPrompts: return ["Library", "Find Similar Prompts…"]
        case .snippets: return ["Library", "Prompt Snippets…"]
        case .promptBuilder: return ["Library", "Prompt Builder…"]
        case .promptStatistics: return ["Library", "Prompt Statistics…"]
        case .applySuggestedTags: return ["Library", "Apply Suggested Tags…"]
        case .reindexLibrary: return ["Library", "Reindex Library"]
        case .newSmartFolder: return ["View", "New Smart Folder..."]
        case .stackVariants: return ["View", "Stack Variants"]
        case .showInbox: return ["Library", "Show Inbox"]
        case .watchedFolders: return ["Library", "Watched Folders…"]
        case .sendToMood: return ["File", "Send to Mood…"]
        case .export: return ["File", "Export…"]
        case .exportForSharing: return ["File", "Export for Sharing (Strip AI Metadata)…"]
        case .contactSheet: return ["File", "Export Contact Sheet…"]
        case .trimClip: return ["File", "Trim & Export Clip…"]
        case .writeXMPSidecars: return ["Library", "Write XMP Sidecars Now"]
        case .generatorSettings: return ["Library", "Send to Generator", "Generator Settings…"]
        case .appearanceSettings, .exportSettings, .dataSettings, .integrationSettings,
             .searchIndexSettings, .organizeSettings, .storageSettings, .fileOperationsSettings:
            return nil
        }
    }

    /// The Settings page the command opens, for Settings commands.
    var settingsPage: SettingsPage? {
        switch self {
        case .appearanceSettings: return .appearance
        case .exportSettings: return .export
        case .dataSettings: return .data
        case .integrationSettings: return .integrations
        case .searchIndexSettings: return .libraryIndex
        case .generatorSettings: return .generators
        case .organizeSettings: return .organize
        case .storageSettings: return .storage
        case .fileOperationsSettings: return .fileOperations
        default: return nil
        }
    }

    /// "Library ▸ Similar Images", "Settings ▸ Data".
    var locationText: String {
        if let menuPath {
            return menuPath.map { $0.replacingOccurrences(of: "...", with: "…") }.joined(separator: " ▸ ")
        }
        return "Settings ▸ \(settingsPage?.title ?? "")"
    }

    /// Button title on a tip card or a tour page.
    var tryItTitle: String {
        switch self {
        case .openFolder: return "Open Folder…"
        case .welcomeTour: return "Take the Tour"
        case .keyboardShortcuts: return "Keyboard Shortcuts"
        case .togglePreviewPane: return "Toggle Details Panel"
        case .compareImages: return "Compare Now"
        case .slideshow: return "Start Slideshow"
        case .batchRename: return "Batch Rename…"
        case .folderStatistics: return "Folder Statistics"
        case .cullingMode: return "Turn On Culling Mode"
        case .focusSearch: return "Search This Folder"
        case .findInLibrary: return "Find in Library…"
        case .commandPalette: return "Open the Command Palette"
        case .similarImages: return "Show Similar Images"
        case .moreLikeThis: return "More Like This"
        case .similarPrompts: return "Find Similar Prompts…"
        case .snippets: return "Prompt Snippets…"
        case .promptBuilder: return "Open Prompt Builder"
        case .promptStatistics: return "Prompt Statistics…"
        case .applySuggestedTags: return "Apply Suggested Tags…"
        case .reindexLibrary: return "Reindex Library"
        case .newSmartFolder: return "New Smart Folder…"
        case .stackVariants: return "Stack Variants"
        case .showInbox: return "Show Inbox"
        case .watchedFolders: return "Watched Folders…"
        case .sendToMood: return "Send to Mood…"
        case .export: return "Export…"
        case .exportForSharing: return "Export for Sharing…"
        case .contactSheet: return "Contact Sheet…"
        case .trimClip: return "Trim & Export Clip…"
        case .writeXMPSidecars: return "Write XMP Sidecars"
        case .appearanceSettings, .exportSettings, .dataSettings, .integrationSettings,
             .searchIndexSettings, .generatorSettings, .organizeSettings, .storageSettings,
             .fileOperationsSettings:
            return "Open Settings ▸ \(settingsPage?.title ?? "")"
        }
    }
}

/// One feature in the Help reference.
struct HelpEntry: Identifiable, Sendable {
    let id: String
    let section: HelpSectionID
    let title: String
    /// Short chip beside the title (".plib", "⌘K", "Stacks").
    let label: String
    let summary: String
    let details: [String]
    /// Extra words people search with ("dedupe", "duplicates").
    var keywords: [String] = []
    var showMe: HelpCommand?
}

extension HelpContent {
    /// Every feature, in section order. Hand-written entries plus every
    /// `fileTypes` description (so a description added there shows up here too).
    static var referenceEntries: [HelpEntry] {
        let all = curatedEntries + fileTypes.map(entry(from:))
        return HelpSectionID.allCases.flatMap { section in all.filter { $0.section == section } }
    }

    static func entry(withID id: String) -> HelpEntry? {
        referenceEntries.first { $0.id == id }
    }

    /// Every "Show Me" in Help.
    static var showMeCommands: [HelpCommand] {
        referenceEntries.compactMap(\.showMe)
    }

    static func entry(from fileType: HelpFileTypeDescription) -> HelpEntry {
        HelpEntry(
            id: fileType.id,
            section: fileTypeSections[fileType.id] ?? .browse,
            title: fileType.title,
            label: fileType.extensionLabel,
            summary: fileType.description,
            details: fileType.highlights,
            keywords: fileTypeKeywords[fileType.id] ?? [],
            showMe: fileTypeShowMe[fileType.id]
        )
    }

    /// Which section each `fileTypes` description belongs to (unknown ids: Browse).
    static let fileTypeSections: [String: HelpSectionID] = [
        "aoe": .browse,
        "plib": .browse,
        "mlmboard": .browse,
        "stry": .browse,
        "viewing-tools": .browse,
        "send-to": .organise,
        "version-stacks": .organise,
        "ingest": .organise,
        "export": .export,
        "privacy-export": .export,
        "contact-sheet": .export,
        "video-audio-tools": .media,
        "visual-search": .find,
        "image-text": .find,
        "curation-data": .dataSync,
        "spotlight-automation": .integrations,
        "cloud-files": .integrations,
        "send-to-generator": .integrations,
        "prompt-lineage-builder": .prompts,
        "prompt-statistics": .prompts,
    ]

    static let fileTypeShowMe: [String: HelpCommand] = [
        "viewing-tools": .compareImages,
        "send-to": .sendToMood,
        "version-stacks": .stackVariants,
        "ingest": .watchedFolders,
        "export": .export,
        "privacy-export": .exportForSharing,
        "contact-sheet": .contactSheet,
        "video-audio-tools": .trimClip,
        "visual-search": .similarImages,
        "image-text": .searchIndexSettings,
        "curation-data": .dataSettings,
        "spotlight-automation": .integrationSettings,
        "cloud-files": .integrationSettings,
        "send-to-generator": .generatorSettings,
        "prompt-lineage-builder": .promptBuilder,
        "prompt-statistics": .promptStatistics,
    ]

    static let fileTypeKeywords: [String: [String]] = [
        "viewing-tools": ["compare", "loupe", "histogram", "slideshow", "zoom", "wipe", "side by side"],
        "visual-search": ["duplicates", "dedupe", "near duplicate", "similar", "colour", "color", "palette"],
        "version-stacks": ["variants", "re-roll", "upscale", "cover"],
        "image-text": ["ocr", "text recognition", "suggested tags", "classification"],
        "curation-data": ["backup", "restore", "sync", "dropbox", "finder tags", "xmp", "sidecar", "lightroom"],
        "ingest": ["watched folder", "inbox", "comfyui output", "downloads", "live updates"],
        "export": ["preset", "convert", "resize", "watermark", "jpeg", "png", "heic", "webp"],
        "privacy-export": ["strip", "metadata", "privacy", "share", "gps", "remove prompt"],
        "video-audio-tools": ["video", "audio", "scrub", "trim", "gif", "frame", "waveform", "clip"],
        "spotlight-automation": ["spotlight", "shortcuts", "siri", "url", "link", "automation"],
        "cloud-files": ["dropbox", "icloud", "google drive", "online only", "download"],
        "send-to-generator": ["comfyui", "a1111", "forge", "automatic1111", "re-run", "generate"],
        "prompt-lineage-builder": ["lineage", "builder", "weights", "compose", "history"],
        "prompt-statistics": ["statistics", "words", "models", "charts"],
        "send-to": ["mood board", "storyboard", "art official"],
    ]

    /// Features not described in `fileTypes`.
    static let curatedEntries: [HelpEntry] = [
        // Browse
        HelpEntry(
            id: "open-library",
            section: .browse,
            title: "Opening a Library Folder",
            label: "⌘O",
            summary: "Everything starts with a folder: File ▸ Open Folder… (⌘O), dropping a folder on the window or the Dock icon, or File ▸ Open Recent. Files stay where they are.",
            details: [
                "The sidebar shows the folder tree, Favorites (right-click ▸ Pin), the Inbox, recent folders, collections and smart folders.",
                "Drop a folder (or a file) on the breadcrumb bar to go to it; nothing is moved or copied.",
                "Go ▸ Back / Forward (⌘[ / ⌘]) and Enclosing Folder (⌘↑) move around; Delete goes up one folder from the grid.",
                "Help ▸ Welcome Tour… shows the short introduction again."
            ],
            keywords: ["start", "folder", "root", "recent", "drop", "favorites", "pin", "sidebar"],
            showMe: .openFolder
        ),
        HelpEntry(
            id: "grid-list",
            section: .browse,
            title: "Grid, List, Grouping and Sorting",
            label: "⌘1 ⌘2",
            summary: "View as Grid (⌘1) or List (⌘2); Group By and Sort By are in the View menu and the toolbar.",
            details: [
                "Sort by type, name, rating, flag, label, date modified, date created, size or a custom order of your own.",
                "The toolbar's Filter menu narrows the listing by type, minimum rating, flag (Hide Rejects), colour label and colour. Edit ▸ Clear All Filters resets them.",
                "Right-click the toolbar to customise it; View ▸ Status Bar shows counts and the indexing indicator.",
                "View ▸ Folder Statistics shows file types and sizes for the folder."
            ],
            keywords: ["view", "sort", "group", "filter", "toolbar", "status bar", "custom order"],
            showMe: .folderStatistics
        ),
        HelpEntry(
            id: "details-panel",
            section: .browse,
            title: "The Details Panel",
            label: "Details",
            summary: "Select a file to see its prompt, negative prompt, model, seed, sampler, steps and size, any structured analysis, and your rating, flag, label and tags.",
            details: [
                "Copy buttons copy each field; Edit ▸ Copy Prompt As… copies it in another format.",
                "Prompt Tools opens the Prompt Builder, Prompt Lineage and Send to Generator for the file.",
                "PNG and JPEG metadata can be edited (right-click ▸ Batch Edit Metadata for several files); the change is written into the file.",
                "View ▸ Hide Preview Pane hides the panel for a wider grid."
            ],
            keywords: ["metadata", "inspector", "prompt", "seed", "parameters", "preview pane", "edit metadata"],
            showMe: .togglePreviewPane
        ),
        HelpEntry(
            id: "lightbox",
            section: .browse,
            title: "The Lightbox and Quick Look",
            label: "Space",
            summary: "Space or Return opens the selected file large; ← / → move through the listing and Esc closes it. ⌘Y opens Quick Look instead.",
            details: [
                "Control = and Control − zoom an image; scroll to pan once zoomed.",
                "The culling keys, M (More Like This), the loupe and the histogram all work in the lightbox.",
                "Videos and audio play in place: Space plays and pauses.",
                "Mood boards and Story projects: ← / → step through their images or shots; ↑ / ↓ move to the next file."
            ],
            keywords: ["preview", "full screen", "zoom", "quick look", "viewer"]
        ),
        HelpEntry(
            id: "files-folders",
            section: .browse,
            title: "Renaming, Moving and the Trash",
            label: "Files",
            summary: "File ▸ New Folder (⇧⌘N), Rename, Batch Rename…, Move to Trash (⌘⌫) and Reveal in Finder (⌥⌘R). Moves, renames and trashing can be undone with ⌘Z.",
            details: [
                "Batch Rename uses tokens such as {name}, {date}, {model}, {seed} and {counter:3}, with a live preview.",
                "Drag files onto a sidebar folder to move them, or out to Finder and other apps to copy.",
                "Deleting is always your own action: nothing in the app marks or suggests files for deletion."
            ],
            keywords: ["rename", "batch rename", "trash", "delete", "move", "new folder", "undo"],
            showMe: .batchRename
        ),
        HelpEntry(
            id: "tips-tour",
            section: .browse,
            title: "Tips and the Welcome Tour",
            label: "Tips",
            summary: "Small tips appear once, when a feature first becomes useful. Help ▸ Welcome Tour… replays the introduction; Help ▸ Reset Tips shows every tip again.",
            details: [
                "Tips never appear while a sheet is open or while you type, and at most one a minute.",
                "Don't Show Tips on any tip (or Settings ▸ Appearance ▸ Tips) turns them off."
            ],
            keywords: ["onboarding", "tour", "tips", "introduction", "getting started"],
            showMe: .welcomeTour
        ),

        // Prompts
        HelpEntry(
            id: "prompts-copy",
            section: .prompts,
            title: "Copying Prompts",
            label: "⇧⌘C",
            summary: "Edit ▸ Copy Prompt (⇧⌘C) copies the prompts of the selection. Copy Prompt As offers other formats, and Copy Path (⌥⌘C) copies file paths.",
            details: [
                "Prompts are read from PNG text chunks (A1111 / Forge parameters, ComfyUI graphs), EXIF User Comment, image descriptions and XMP, and from .plib / .aoe snapshots.",
                "ComfyUI files carry their graph; the prompt is taken from the encoder feeding the sampler.",
                "Copy As formats: Plain Text, Midjourney, Stable Diffusion, DALL-E and JSON."
            ],
            keywords: ["copy", "clipboard", "midjourney", "stable diffusion", "json", "format", "copy as"],
            showMe: .promptBuilder
        ),
        HelpEntry(
            id: "compare-prompts",
            section: .prompts,
            title: "Compare Prompts",
            label: "⌘D",
            summary: "Select two files and choose View ▸ Compare Prompts (⌘D) to see a word-by-word diff of their prompts and settings.",
            details: [
                "Select two or more .aoe snapshots for View ▸ Compare Selected .aoe Files, which compares their analysis fields side by side."
            ],
            keywords: ["diff", "difference", "compare", "aoe"]
        ),
        HelpEntry(
            id: "snippets",
            section: .prompts,
            title: "Prompt Snippets",
            label: "Snippets",
            summary: "Library ▸ Prompt Snippets… keeps reusable phrases by category. The Prompt Builder inserts them with a click or a drag.",
            details: [
                "Snippets are part of your curation data: backed up, exported and synced like ratings and tags."
            ],
            keywords: ["phrases", "library", "reuse", "templates"],
            showMe: .snippets
        ),
        HelpEntry(
            id: "similar-prompts",
            section: .prompts,
            title: "Find Similar Prompts",
            label: "Prompts",
            summary: "Library ▸ Find Similar Prompts… groups files whose prompts are nearly the same, with a similarity slider, so you can see every render of an idea and make a collection from a group.",
            details: [
                "Results are for looking only: nothing is marked or suggested for removal."
            ],
            keywords: ["duplicates", "similar", "prompt", "groups"],
            showMe: .similarPrompts
        ),

        // Cull
        HelpEntry(
            id: "culling",
            section: .cull,
            title: "Flags, Ratings and Colour Labels",
            label: "P X U",
            summary: "Bare keys in the grid, list or lightbox: P pick, X reject, U unflag, 0–5 stars (0 clears), 6 Red, 7 Yellow, 8 Green, 9 Blue. Every change can be undone.",
            details: [
                "Cull ▸ Culling Mode shows the culling bar in the lightbox and flashes each change; Auto-advance moves to the next file after each key.",
                "Rejects are dimmed; the toolbar's Filter ▸ Flag ▸ Hide Rejects hides them.",
                "Cull ▸ Select Rejects selects them; Move Rejects to Trash… asks before moving anything.",
                "Labels are Finder's own colour labels, so Finder shows them too. Other colours are in the Cull menu, the context menu and the details panel."
            ],
            keywords: ["flag", "pick", "reject", "rating", "stars", "label", "colour label", "color", "culling mode", "auto advance"],
            showMe: .cullingMode
        ),

        // Find
        HelpEntry(
            id: "search-field",
            section: .find,
            title: "Searching the Folder",
            label: "⌘F",
            summary: "Edit ▸ Find (⌘F) focuses the toolbar search field. Its menu picks what to match: All, Filename, Prompt, or Text in Image.",
            details: [
                "Prompt matches only prompts (not text painted into the image); Text in Image matches only recognised text; All matches everything.",
                "Esc in the search field returns to the grid."
            ],
            keywords: ["search", "filter", "find", "filename", "search mode", "text in image"],
            showMe: .focusSearch
        ),
        HelpEntry(
            id: "library-search",
            section: .find,
            title: "Find in Library",
            label: "⇧⌘F",
            summary: "Edit ▸ Find in Library… (⇧⌘F) searches the prompts, names and recognised text of every file in the library at once, from a full-text index.",
            details: [
                "The index builds in the background when a folder opens and follows file changes; Library ▸ Reindex Library rebuilds it.",
                "Choose a result to go to its folder with the file selected.",
                "Spotlight finds the same files from anywhere on your Mac (Settings ▸ Integrations)."
            ],
            keywords: ["search", "library", "index", "full text", "spotlight", "all folders"],
            showMe: .findInLibrary
        ),
        HelpEntry(
            id: "command-palette",
            section: .find,
            title: "The Command Palette",
            label: "⌘K",
            summary: "Go ▸ Command Palette (⌘K) jumps to folders, smart folders, tags, files and actions by typing part of their name. Every Help topic is there too, as \u{201C}Help: …\u{201D}.",
            details: [
                "↑ / ↓ move the highlight, Return runs it, Esc closes the palette.",
                "Typing also searches file names and prompts across the library."
            ],
            keywords: ["palette", "quick open", "jump", "actions", "commands", "cmd k"],
            showMe: .commandPalette
        ),

        // Organise
        HelpEntry(
            id: "collections",
            section: .organise,
            title: "Collections and Collection Sets",
            label: "Collections",
            summary: "Collections gather files from any folder without moving them. File ▸ New Collection from Selection or the sidebar's + makes one; drag files onto a collection to add them.",
            details: [
                "Collection sets group collections (and other sets) in the sidebar: + ▸ New Collection Set…, then drag collections into it.",
                "A collection's context menu sends it to Mood or Story, exports it or makes a contact sheet.",
                "Go ▸ Collections opens one; Enclosing Folder (⌘↑) or its close button leaves it."
            ],
            keywords: ["collection", "set", "album", "group", "board"]
        ),
        HelpEntry(
            id: "smart-folders",
            section: .organise,
            title: "Smart Folders",
            label: "Smart",
            summary: "View ▸ New Smart Folder… saves a set of rules — text, file type, rating, flag, label, tags, model, date, dominant colour, text in image — as a live listing in the sidebar.",
            details: [
                "Smart folders update as files change; right-click one to edit or delete it."
            ],
            keywords: ["smart folder", "rules", "saved search", "query"],
            showMe: .newSmartFolder
        ),
        HelpEntry(
            id: "tags",
            section: .organise,
            title: "Tags and Favorites",
            label: "Tags",
            summary: "Right-click ▸ Tags adds tags; the sidebar and the command palette filter by them. Pin folders to Favorites from their context menu.",
            details: [
                "Tags are mirrored to Finder tags (Settings ▸ Data).",
                "Suggested tags under a file's tags come from what the image shows, its colour and its model; Library ▸ Apply Suggested Tags… reviews them for a selection. Nothing is applied without you."
            ],
            keywords: ["tag", "keywords", "favorites", "pin", "suggested tags"],
            showMe: .applySuggestedTags
        ),
        HelpEntry(
            id: "organize-folders",
            section: .organise,
            title: "Reorganising a Folder by Date",
            label: "Organize",
            summary: "Settings ▸ Organize reshapes the current folder into dated subfolders, or flattens it back out, with a preview first.",
            details: [
                "Moves can be undone with Edit ▸ Undo."
            ],
            keywords: ["organize", "dated folders", "flatten", "reorganise"],
            showMe: .organizeSettings
        ),

        // Data & Sync
        HelpEntry(
            id: "storage",
            section: .dataSync,
            title: "Caches and Storage",
            label: "Storage",
            summary: "Settings ▸ Storage shows the space used by thumbnails and parsed metadata and clears it. Clearing caches never touches your files or your curation data.",
            details: [],
            keywords: ["cache", "thumbnails", "disk space", "clear"],
            showMe: .storageSettings
        ),
        HelpEntry(
            id: "undo",
            section: .dataSync,
            title: "Undo and File Safety",
            label: "⌘Z",
            summary: "Edit ▸ Undo (⌘Z) reverses moves, renames, batch renames, trashing and culling changes; Redo is ⇧⌘Z. Settings ▸ File Operations sets what happens when names collide.",
            details: [
                "Exports, frames and clips are always written as new files; originals are never overwritten.",
                "Delete Permanently (⇧Delete) always asks first."
            ],
            keywords: ["undo", "redo", "safety", "collision", "overwrite"],
            showMe: .fileOperationsSettings
        ),

        // Integrations
        HelpEntry(
            id: "quick-look-finder",
            section: .integrations,
            title: "Finder Quick Look",
            label: "Finder",
            summary: "The app adds Quick Look previews and thumbnails for .plib, .aoe, Mood and Story files, so Finder can show them too.",
            details: [],
            keywords: ["finder", "quick look", "thumbnail", "preview extension"]
        ),
    ]
}

/// Filters the Help reference by a search query (every word must match).
enum HelpSearch {
    /// Lowercased, accent-folded, with ⌘ ⇧ ⌥ spelled out so "⌘K" finds "Cmd K".
    static func normalized(_ text: String) -> String {
        text
            .replacingOccurrences(of: "⌘", with: " cmd ")
            .replacingOccurrences(of: "⇧", with: " shift ")
            .replacingOccurrences(of: "⌥", with: " option ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "colour", with: "color")
    }

    static func tokens(_ query: String) -> [String] {
        normalized(query)
            .split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map(String.init)
    }

    static func haystack(_ entry: HelpEntry) -> String {
        normalized(([entry.title, entry.label, entry.summary, entry.section.title, entry.showMe?.locationText ?? ""]
            + entry.details + entry.keywords).joined(separator: " "))
    }

    static func matches(_ entry: HelpEntry, query: String) -> Bool {
        let words = tokens(query)
        guard !words.isEmpty else { return true }
        let text = haystack(entry)
        return words.allSatisfy { text.contains($0) }
    }

    /// Matching entries, in their original order.
    static func filter(_ entries: [HelpEntry], query: String) -> [HelpEntry] {
        entries.filter { matches($0, query: query) }
    }

    /// Shortcut groups with only their matching items (a matching group title keeps
    /// the whole group); groups with nothing left are dropped.
    static func filter(_ groups: [HelpShortcutGroup], query: String) -> [HelpShortcutGroup] {
        let words = tokens(query)
        guard !words.isEmpty else { return groups }
        return groups.compactMap { group in
            let groupText = normalized(group.title + " " + group.description)
            if words.allSatisfy({ groupText.contains($0) }) { return group }
            let items = group.items.filter { item in
                let text = normalized((item.keys + [item.description, group.title]).joined(separator: " "))
                return words.allSatisfy { text.contains($0) }
            }
            return items.isEmpty ? nil : HelpShortcutGroup(id: group.id, title: group.title, description: group.description, items: items)
        }
    }
}
