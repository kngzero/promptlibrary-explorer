# Changelog

Version numbers follow **MAJOR.FEATURE.FIXES** (`#.#.##`):

| Part | Bump when | Example |
|---|---|---|
| **MAJOR** | A big rewrite or a breaking change. | `1.11.01` → `2.0.00` |
| **FEATURE** | New features. Resets FIXES. | `1.11.01` → `1.12.00` |
| **FIXES** | Bug fixes and small improvements (two digits). | `1.11.01` → `1.11.02` |

Docs-only changes don't bump the version. The version lives in `src/PromptLibraryExplorer/Resources/Info.plist`; bump it with `src/PromptLibraryExplorer/scripts/bump_version.sh major|feature|fix`. The build number (`CFBundleVersion`) is the git commit count and is stamped in at packaging.

Versions before 1.11.01 were assigned retroactively to the commits on `app-overhaul-2026-09`.

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
