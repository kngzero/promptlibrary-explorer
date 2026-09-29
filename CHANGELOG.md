# Changelog

Version numbers follow **MAJOR.FEATURE.FIXES** (`#.#.##`):

| Part | Bump when | Example |
|---|---|---|
| **MAJOR** | A big rewrite or a breaking change. | `1.11.01` → `2.0.00` |
| **FEATURE** | New features. Resets FIXES. | `1.11.01` → `1.12.00` |
| **FIXES** | Bug fixes and small improvements (two digits). | `1.11.01` → `1.11.02` |

Docs-only changes don't bump the version. The version lives in `src/PromptLibraryExplorer/Resources/Info.plist`; bump it with `src/PromptLibraryExplorer/scripts/bump_version.sh major|feature|fix`. The build number (`CFBundleVersion`) is the git commit count and is stamped in at packaging.

Versions before 1.11.01 were assigned retroactively to the commits on `app-overhaul-2026-09`.

## 1.15.00 — Trim page with real-time scrubbing
- **Trim is a full page**, like Crop & Adjust: it covers the browser and the details panel (the sidebar stays) with the player filling the page, the in / out handles over the frame strip (or waveform) below it, and Format and Save To in an inspector. Cancel and Export are in the header, with the export's progress and Cancel Export while it runs. It replaces the Trim sheet, and opens from Tools, the context menu, File ▸ Trim & Export Clip… and the lightbox's Trim… (which closes the lightbox).
- **Real-time scrubbing**: dragging a handle or the timeline chases the pointer — each seek starts the moment the previous one lands, always to the newest position — so frames keep up while you drag. Scrubbing audio plays a short burst at each position.
- Keys on the page: Space plays the range (looping), ← / → step one frame (a tenth of a second for audio; ⇧ for 10), I / O set the in and out points, Esc closes. The browser's keys don't reach the grid underneath.

## 1.14.01 — Shorter right-click menu
- For one file, the right-click menu leaves out what the details panel already has: Open In, Edit Image and the trim and frame tools (Tools), More Like This and Find Images Matching Palette (Dominant Colours), Copy Prompt and Copy As (Prompt), the prompt tools (Prompt Tools), and Flag, Rating, Label, Pin and Tags (Rating & Tags). With several files selected it keeps everything. Settings ▸ Appearance ▸ Right-Click Menu turns this off.
- Quick Look is no longer in the right-click menu (⌘Y and View ▸ Quick Look still work).
- More Like This left the Tools grid: it's already in Dominant Colours.

## 1.14.00 — Tools section; audio trim
- **Tools** replaces Image Edits in the details panel: a grid of tiles for the tools that fit the selected file.
  - Images: Crop & Adjust, and Save Edited Copy / Revert to Original once edited (the Edited badge and summary sit above the grid). Also Export… and More Like This.
  - Video: Trim Video, Save Middle Frame, More Like This.
  - Audio: Trim Audio.
  - PNG, JPEG, MP3 and WAV: Edit (or Add) Metadata / Audio Tags, which used to be a separate full-width button.
  - Every file: **Open With ›** pops up every app that opens it, the default first, then Other… to pick any app.
- **Trim & Export Audio…** (context menu, Tools ▸ Trim Audio): the trim sheet with in and out handles over the waveform, exported as M4A (AAC) next to the original ("song (trim).m4a") or wherever you choose. The original is never modified.
- **Rating & Tags** rows are all the same height (40 pt) with 12 pt between them.

## 1.13.02 — PSD histograms; details spacing
- **PSD histograms are right.** In a PSD, the channels after the colour channels are the flattened image's transparency only when the file says so. Otherwise they're saved selections or spot channels, and ImageIO still read the first one as transparency, hiding or fading the pixels it didn't cover. Of the 1,253 PSDs on this Mac, 9 have such channels; ImageIO counted 0 % of the pixels in two of them and about 20 % in four others. These PSDs are now read directly from their stored flattened image (RGB or grayscale, 8 or 16 bit), and the result matches the thumbnail Photoshop saved in each file. Other PSDs are read as before.
- Files that can't be read (including cloud files not downloaded yet) say "No histogram for this file" instead of loading forever.
- **Generation Info** boxes line up: Model and Aspect Ratio are the same height, top-aligned, with Timestamp across both, and one gap everywhere. The aspect ratio comes from the image's pixel size (the nearest common ratio within 1 %, such as 9:16), and falls back to the metadata's only when the size is unknown.
- More room between the rows of **Rating & Tags** and **File Info**.

## 1.13.01 — Rating & Tags section; File Name under the preview
- Rating, pin, flag, Finder label and tags are one collapsible **Rating & Tags** card in the details panel. Before, they were loose rows that couldn't be collapsed.
- **File Name** is the first card directly under the preview, and it no longer collapses. The lightbox's File Name card doesn't collapse either.
- The histogram is taller: 120 pt, up from 72.

## 1.13.00 — Collapsible details sections; histogram fix
- **The histogram is easy to find again.** It is the first section of the details panel for every image, and it now appears in the lightbox's details sidebar too; before, the lightbox's Histogram toggle drew nothing there. It starts expanded, and View ▸ Histogram (or the lightbox header's menu) expands or collapses it. Before, it only appeared after turning on View ▸ Histogram, which was off by default. Collapsed, it isn't computed.
- **Details sections collapse.** Click a section's title to collapse or expand it: Histogram, Prompt, Image Edits, Prompt Tools, ComfyUI Workflow, Generation Info, File Name, Dominant Colours, Stack, Text in Image, File Info, Embedded Metadata, Reference Images, and the Mood and Story sections. The browser's details panel and the lightbox's share the collapse state, and it's remembered between launches.

## 1.12.00 — Show in Folder on files
- Right-click a file in a collection, a More Like This or palette listing, or anywhere it isn't in its own folder ▸ **Show in Folder**. The browser opens the file's folder with the file selected and scrolled into view, as it already did from the Timeline and Map. It's hidden when you're already in the file's folder.
- Similar Images page: each file's hover buttons and right-click menu have Show in Folder too (it closes the page). Reveal in Finder there now uses the Timeline's Finder icon, so the two buttons look different.

## 1.11.03 — System appearance fix
- **System appearance works.** Switching from Dark (or Light) to System now follows the Mac's setting. Before, only AppKit-drawn parts changed and the rest stayed on the old scheme, because SwiftUI's `preferredColorScheme(nil)` leaves its own colour scheme on the last forced value. System now resolves to an explicit light or dark scheme from the Mac's appearance and updates when the Mac switches.

## 1.11.02 — Neutral sidebar and raised surfaces
- The dark sidebar is a neutral `#1E1E1E` (was the blue-tinted `#1E1E21`), and raised surfaces are neutral `#262626` / `#D9D9D9` (were `#262630` / `#D9D9DE`). These now match Mood and Story, per the suite design decision of 2026-09-28.

## 1.11.01 — Lightbox media fills the viewport
- Images and video fill the lightbox again. The previous/next arrows float over the media, fully inside its edge, with a stronger backdrop so they stay readable.

## 1.11.00 — About panel
- The About panel shows the version, build, "Made by ArtOfficial" with an artofficial.world link, and a copyright line.
- Help ▸ Visit artofficial.world.

## 1.10.02 — Histogram placement, Show in Folder
- The histogram moved from the lightbox overlay to the top of the details panel.
- Timeline and Map: Show in Folder and Reveal in Finder buttons, and Show in Folder in every item's context menu. Revealing a file scrolls the grid or list to it.

## 1.10.01 — Timeline fix
- Fixed duplicated and vanishing thumbnails while scrolling the Timeline. Rows had non-unique ids in a pinned lazy stack.

## 1.10.00 — Onboarding, editor, timeline and map
- Welcome tour, one-time contextual tips, and a searchable Help with Show Me actions.
- Non-destructive editor: crop, straighten, rotate, flip and basic adjustments. Edits are stored as curation data and originals are never modified.
- Timeline and Map pages, capture-date and GPS indexing, sort by capture date, and group by month or year.

## 1.9.00 — Prompt tools, organisation, system integration
- Prompt Lineage, Prompt Builder, re-run in ComfyUI or send to A1111/Forge, and prompt statistics.
- Version stacks (automatic and manual), text-in-image search (OCR), and suggested tags that are applied only after you confirm.
- Spotlight indexing, Shortcuts (App Intents), `promptlibrary://` links, and handling for cloud files that are online-only.

## 1.8.00 — Viewing, media, live folders
- Compare Images (synced zoom, A/B wipe), the lightbox loupe, and a slideshow.
- Video hover-scrubbing, frame export, and trim to MP4 or GIF. Audio waveforms.
- Live folder updates (FSEvents) and an ingest inbox with per-source rules.

## 1.7.00 — Curation safety, export, install
- Automatic backups and restore. A per-library `.promptlibrary/curation.json` that syncs curation data between Macs. Two-way Finder tag sync. Optional XMP sidecars.
- Export presets, Export for Sharing (strips AI metadata), watermarks, and contact-sheet PDFs.
- Installs to /Applications. Dropbox keeps only zipped builds.

## 1.6.00 — Similar Images page
- Similar Images became a full-page mode with a large side-by-side comparison. Fixed a duplicate window-title item in the toolbar.

## 1.5.00 — Visual search
- Find Similar Images (exact and visual; nothing is ever marked for deletion), More Like This, colour search, and a visual index with a status popover.

## 1.4.00 — Art Official formats in the app, Quick Look
- Mood (`.mlmboard`) and Story (`.stry`) files are fully supported. Send to Mood and Send to Story.
- Finder Quick Look previews and thumbnails for Art Official files.

## 1.3.00 — Formats library, culling
- Packaging script, and the shared ArtOfficialFormats library.
- Culling: pick and reject flags, Finder colour labels, P/X/U and 0–9 keys, culling mode.
- Fixed sidebar modals presenting several times.

## 1.2.01 — Toolbar customization
- The whole toolbar can be customized. Cleared stale test markers.

## 1.2.00 — Native toolbar and Settings window
- Native, customizable toolbar. Settings is a proper window.

## 1.1.01 — Review fixes and tests
- 18 code-review fixes, plus an XCTest suite (90 tests at the time).

## 1.1.00 — Overhaul
- Metadata data-loss fixes, a design system, menus, list view, library-wide search, collections, smart-folder rules, batch rename, snippets, and more.

## 1.0.00 — Native Swift app
- Rewrite as a native Swift/SwiftUI macOS app. The previous Tauri version is archived.
