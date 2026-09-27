# Roadmap: Art Official file types + media management

Status: plan only, nothing implemented yet. Written 2026-09-27.

Part 1 covers recognising the other Art Official document types (Mood boards and Story projects, plus BrandGuide as an optional extra). Part 2 lists media-management features that would make the app useful beyond prompt browsing. At the end is a suggested order.

---

## Part 1 — Recognise Mood and Story files

### What exists today

The explorer understands two Art Official formats: `.plib` (Prompt Library) and `.aoe` (Art Official Elements, also written by Stack). Both are JSON, parsed by `PlibParser` / `AoeParser` into a `PromptEntry`. Each gets its own badge, thumbnail, detail panel and search indexing.

### The new formats

| | Mood board | Story project | BrandGuide (optional) |
|---|---|---|---|
| Extension | `.mlmboard` | `.stry` (legacy `.mlseq`) | `.brandguide` |
| UTType | `com.artofficial.mood.mlmboard` | `com.artofficial.story.project` / `com.artofficial.story.mlseq` | `com.brandguide.project` |
| Owner app bundle ID | `com.artofficial.mood` | `com.artofficial.story` | `com.brandguide.app` |
| Container | JSON, images inline as base64 data URLs. **Legacy:** ZIP (`PK\x03\x04`) holding `meta.json` + `assets/` | JSON with snake_case keys (web `AppState` shape). Mac-only extra keys are optional | JSON |
| Spec / source | `apps/mood/MLM_BOARD_FORMAT.md`, `mood/macos/Sources/Mood/ProjectFileCodec.swift` | `apps/story/mac/Story/ProjectIO.swift` (`AppStateDTO` and friends) | `apps/brandkit/src/Sources/BrandGuide/Models/BrandGuideFile.swift` |

**Mood board contents:**
- `assets[]` (id, name, `url` = data URL, type image/logo)
- `canvasItems[]`: image tiles (assetId, colSpan/rowSpan, pan/zoom) and colour tiles (hex)
- `layoutMode`: auto, grid or mosaic
- `layoutOptions`: columns, gap, padding, corners, shadow, aspect ratio
- `branding`: title, subtitle, palette, background, logo, font

**Story project contents:**
- `projects[]`: title, code, status, dates, `cover_image`, aspect ratio, logline, director, producer, notes
- `scenes[]`: name, number, location, int/ext, day/night, estimated duration, notes
- `shots[]`: `thumb`, type, name, description, detailed notes, tags, takes, estimated duration, `video_ref`
- also: templates, audio assets and clips, comments, asset lists, project assets, and `scripts[]` (Fountain text)

### What the explorer should show

**Mood board (`.mlmboard`)**
- **Grid tile:** a rendered miniature of the board. Lay the first ~9 canvas items out in the board's column grid with its background colour, then add a strip of palette swatches. For legacy ZIP boards, use the same renderer on the extracted assets.
- **Badge:** new `badgeMood` token plus a text-safe variant.
- **Details panel:**
  - title and subtitle
  - layout mode and columns
  - asset and tile counts
  - palette swatches (click to copy the hex, or copy the whole palette as HEX, CSS or JSON)
  - a thumbnail list of the embedded images with their names
- **Lightbox:** the full board rendered at window size, with ←/→ to step through its images.
- **Actions:**
  - *Open in Mood* (`NSWorkspace.open(_:withApplicationAt:)` using the bundle ID)
  - *Extract images…* (writes the embedded assets out to a folder)
  - *Copy palette*
  - *Export board as PNG*
- **Search/index:** title, subtitle, asset names and palette hex values, so colour search works (see Part 2).

**Story project (`.stry` / `.mlseq`)**
- **Grid tile:** the project `cover_image` if there is one, otherwise a 2×2 contact sheet of the first shot thumbnails.
- **Badge:** new `badgeStory` token.
- **Details panel:**
  - project title, code, status, logline, director/producer, aspect ratio, dates
  - counts of scenes, shots and scripts, and total estimated runtime
  - a scene → shot outline with thumbnails and shot descriptions
- **Lightbox:** a storyboard strip. ←/→ steps shot by shot, each showing its thumbnail, shot type, description and notes.
- **Actions:**
  - *Open in Story*
  - *Export storyboard contact sheet (PDF/PNG)*
  - *Copy shot list* as text or CSV
  - *Extract shot thumbnails…*
- **Search/index:** logline, scene names, locations, shot names, descriptions, notes and tags, plus Fountain script text. Shot descriptions work like prompts, so they belong in the same full-text index.

**Multi-project files:** one `.stry` can hold several projects. Show the first project by default, with a project picker in the details panel.

### Implementation outline

1. **Parsers** (`Services/MoodboardParser.swift`, `Services/StoryParser.swift`):
   - Write them as actors backed by the same `LRUCache` and mtime/size check as `PlibParser`.
   - Decode leniently: every field optional, and a bad element is skipped rather than failing the whole file.
   - **Base64 cost:** moodboards can be tens of MB. Parse the JSON once, keep only the small data model, and decode an image only when a thumbnail or the lightbox needs it (for example, keep the data URL's byte range and decode on demand).
   - **Legacy ZIP:** unzip with `Compression`/`Archive` or a minimal ZIP reader. Guard against zip bombs (entry count and total size caps) and path traversal (ignore any `..` or absolute paths). Read `meta.json` and map it using the rules in the spec's "Key Differences" table, including the crop → position conversion.
   - **Remote images:** never fetch `http(s)` thumbnails, the same policy `AoeParser` has. Story `thumb` values of the form `img_*` refer to Mac-app storage, so show a placeholder for those.
2. **A document model:** `PromptEntry` has grown around prompts. Add `enum ArtOfficialDocument { case moodboard(Moodboard), story(StoryProject) }` and attach it to the entry, so the panel and lightbox can switch on it. Prompt-only screens then keep working unchanged.
3. **Type plumbing:**
   - `FileHelpers` (`isMoodboardFile`, `isStoryFile`, `describeFileType`, `filterType`)
   - `FileTypeFilter` and `SmartFolderFileType` get new cases, decoded leniently like the existing ones
   - sort/group type descriptors
   - status-bar counts
   - Theme badge tokens and `APP_COLORS.md`
4. **Thumbnails:** a `ThumbnailService` hook for the rendered board and contact-sheet images, with the same disk cache keyed by path + mtime + size.
5. **Search:** `LibraryIndexService` extraction maps these formats' text into `prompt` (the main descriptive text) plus new FTS columns `title` and `extra`. That needs a schema bump and a rebuild; the service already detects and rebuilds on schema changes.
6. **`Info.plist`:** declare these as **UTImportedTypeDeclarations**, because Mood and Story own them. Our own `.plib`/`.aoe` stay exported. Add `CFBundleDocumentTypes` with role Viewer and rank Alternate, so "Open With → PromptLibrary Explorer" works without taking over from the owner apps.
   - **Prerequisite:** the bundle's `Info.plist` is currently not in git (`*.app` is ignored). Keep a copy at `Resources/Info.plist` and have packaging copy it into the bundle.
7. **Tests:** fixtures for a current JSON board, a legacy ZIP board (including a traversal entry and an oversized entry), a web `.mlseq`, a Mac `.stry` with the extra keys, and a multi-project story. Assert on the counts, text, palette and thumbnails pulled out.

**Effort:** Mood about 2–3 days, Story about 2–3 days, BrandGuide about 1 day once the shared pieces exist.

### Open questions

- Does Mood for Mac write anything beyond the web spec, such as extra keys or a different asset encoding? `ProjectFileCodec.swift` is the reference to check.
- Story `img_*` thumbnail references: can they be resolved from anything outside the Mac app's SwiftData store? If not, those shots show a placeholder.
- Should Stack's `.aoe` exports and the plain `prompt-*.json` files from the Prompt app be recognised by their content (a JSON sniff), not just their extension?
- Should BrandGuide be included? It is branded `com.brandguide.*`, not `com.artofficial.*`.

---

## Part 2 — Media management features

These are ideas that build on what exists: collections and sets, smart folders, tags, ratings, the library index, similarity, batch rename and Quick Look. Effort is rough: S ≈ ≤1 day, M ≈ 2–4 days, L ≈ a week or more.

### A. Organise and cull

| Feature | Why | Effort |
|---|---|---|
| **Culling mode** in the lightbox: P = pick, X = reject, 1–5 rate, U = clear, auto-advance; plus "Show picks / hide rejects" filters | Generation produces lots of near-misses, and fast keyboard culling is the core photo-manager workflow | M |
| **Colour labels** (Finder's 7 colours) alongside tags | A quick visual status that isn't a rating | S |
| **Finder tag sync**: read and write macOS Finder tags ↔ app tags | Tags travel with the files and show in Finder and Spotlight | M |
| **XMP sidecar export/import** (rating, label, keywords, prompt as `dc:description`) | Interop with Lightroom, Bridge and Capture One without touching the original files | M |
| **Version stacks**: group variants (same seed/prompt, upscales, img2img lineage, `_1`/`_2` suffixes) behind one cover image | Keeps grids readable; expand a stack to compare its variants | M–L |
| **Watched folders** (FSEvents): the listing and library index update live when generators write files | No more manual refresh while generating | M |
| **Ingest / Inbox**: watch generator output folders, then on arrival optionally rename (templates), tag by model, drop exact duplicates and move into dated folders | Turns the app into the landing pad for new generations | M |

### B. Find

| Feature | Why | Effort |
|---|---|---|
| **Exact and visual duplicate finder** (file hash + perceptual dHash/pHash) across the library, with a "keep largest / keep best rated" resolver | Prompt similarity already exists; this catches identical or re-saved images whatever their metadata | M |
| **"More like this" visual search** using Vision `VNGenerateImageFeaturePrintRequest` (runs on the Mac, stored in the library DB) | Find visually similar images even with no prompt | M |
| **Colour search**: extract 5 dominant colours per image into the index; filter by swatch or by a Mood board's palette | Bridges straight into Mood | M |
| **Text in images** (Vision OCR) indexed for search | Posters, UI mocks and title cards become searchable | S–M |
| **Auto-tags** from Vision classification (subject, scene), offered as suggestions to accept | Folders without prompts still get searchable keywords | M |
| **Spotlight integration**: set `kMDItemFinderComment`/keywords, or ship an `mdimporter` for `.plib`/`.aoe`/`.mlmboard`/`.stry` | Prompts become searchable system-wide | M (L for the importer) |

### C. View and compare

| Feature | Why | Effort |
|---|---|---|
| **Visual compare**: 2–4 images side by side with synced zoom/pan, plus an A/B wipe slider | The existing compare is text-only; this compares the images themselves | M |
| **Loupe and pixel peeping**: 100%/200% loupe, histogram, optional metadata overlay in the lightbox | Judging upscales and artefacts | S–M |
| **Video tiles**: scrub by hovering, frame strip, "Save frame as PNG", trim and export to GIF/MP4 | AI video generation is growing and tiles are static today | M |
| **Audio tiles**: waveform thumbnails, loop a selection, BPM/key if cheap | Parity with the audio support that already exists | S–M |
| **Slideshow and presentation mode** (full screen, timing, shuffle, optional prompt caption) | Client reviews and moodboard-style showings | S |
| **Contact sheet / PDF export** of a selection or collection, with an optional prompt caption per image | Handing off to clients and printing | S–M |

### D. Export and share

| Feature | Why | Effort |
|---|---|---|
| **Export presets**: format (PNG, JPEG, WebP, HEIC), max size, quality, colour profile, filename template | Batch conversion without another tool | M |
| **Privacy export**: strip AI metadata (prompts, seeds, ComfyUI graphs) or keep only chosen fields | Sharing publicly without leaking workflows is a common need | S (reuses the writers) |
| **Watermark / signature overlay** on export | Portfolio and client proofs | S |
| **Send to Mood**: build a `.mlmboard` from a selection or collection (assets inline, auto-palette from the images) | Closes the loop between Art Official apps | M |
| **Send to Story**: make shots from a selection (thumbnail = image, description = prompt), then open Story | Storyboarding from generations | M |
| **Share extension / Services menu**: "Add to PromptLibrary collection" from Finder or other apps | Collect without switching apps | M |

### E. Prompt workflows (the app's core)

| Feature | Why | Effort |
|---|---|---|
| **Prompt lineage view** across a version stack: token-level diff chain from the first to the final prompt | Shows how a prompt evolved into the keeper | M |
| **Prompt builder**: combine snippets + library phrases, then copy in any format (the formats exist) | Turns snippets into a composition tool | M |
| **Send to generator**: "Open in ComfyUI" (POST the stored API graph to a local ComfyUI `/prompt`), A1111/Forge API txt2img with the stored parameters | Re-run or vary a keeper in one click | M |
| **Library statistics**: top tokens, model usage over time, ratings by model/sampler (extends `FolderStatisticsView`) | Learn which settings produce keepers | S–M |
| **Negative-prompt library** (a snippets category) with one-click append | Negatives get reused a lot | S |

### F. Ecosystem and scale

| Feature | Why | Effort |
|---|---|---|
| **Quick Look + Thumbnail extensions** for `.plib`/`.aoe`/`.mlmboard`/`.stry` | Finder's space bar and icons show real previews of every Art Official file, even without this app open. The single biggest ecosystem win | M–L |
| **App Intents / Shortcuts**: search the library, add to a collection, export with a preset, strip metadata | Automation for power users | M |
| **Cloud awareness** (Dropbox / iCloud placeholders): show offline status, "Download" on demand, never block on a placeholder | Most libraries live in Dropbox; opening a placeholder can freeze today | M |
| **Persistent metadata/thumbnail DB** for the whole library (extends the SQLite index) | Large folders open instantly; the index also powers the colour, visual and duplicate features | M |

---

## Suggested order

1. **Keep `Info.plist` in the repo** (S). Prerequisite for any new file types.
2. **Mood + Story recognition** (Part 1). Unifies the Art Official family inside the explorer.
3. **Quick Look + Thumbnail extensions** (F). Reuses the new parsers and renderers, and makes every Art Official file previewable in Finder.
4. **Culling mode + colour labels** (A). The highest day-to-day value for a generation-heavy workflow.
5. **Visual duplicates + "more like this" + colour search** (B). They share one Vision/feature-print pipeline stored in the library DB; colour search also feeds 6.
6. **Send to Mood / Send to Story** (D). Ecosystem round trip, using the same parsers in reverse.
7. **Privacy export + export presets** (D). Cheap once the writers exist, and very useful for sharing.
8. **Watched folders + Ingest inbox** (A). Makes the app the landing point for new generations.
