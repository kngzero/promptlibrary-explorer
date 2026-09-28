# PromptLibrary Explorer

A native macOS app for browsing and curating AI-generated images, video and audio. It reads the prompts and generation settings embedded in the files. Made by **[ArtOfficial](https://artofficial.world)**.

PromptLibrary Explorer works like Finder for your generation folders:
- It reads embedded prompts from A1111/Forge, ComfyUI graphs, Midjourney-style descriptions, `.plib`, `.aoe`, Mood boards (`.mlmboard`) and Story projects (`.stry`).
- It lets you cull, organise, search and export without ever changing your originals.

Current version: see [CHANGELOG.md](CHANGELOG.md). Scheme: **MAJOR.FEATURE.FIXES**.

## Features

- **Browse:** grid and list views; details panel with prompt, negative prompt and parameters; lightbox with loupe; slideshow; Compare Images (synced zoom, A/B wipe); Timeline and Map pages.
- **Cull:** pick, reject and unflag (P / X / U), ratings (0–5), Finder colour labels (6–9), culling mode with auto-advance, version stacks.
- **Find:**
  - search by filename or prompt, and library-wide full-text search (⇧⌘F);
  - the command palette (⌘K);
  - Find Similar Images, More Like This (M) and colour search, all on-device with Vision;
  - text in images (OCR);
  - smart folders.
- **Organise:** collections and nested collection sets, tags (mirrored to Finder tags), batch rename templates, watched folders and an ingest inbox.
- **Prompts:** Copy As (Midjourney, SD, DALL-E, JSON), Prompt Lineage, Prompt Builder, snippets, re-run in ComfyUI or send to A1111/Forge (your own local servers only), prompt statistics.
- **Edit and export:**
  - a non-destructive editor (crop, straighten, rotate, flip, adjust);
  - export presets;
  - Export for Sharing, which strips AI metadata and leaves the pixels untouched;
  - watermarks and contact-sheet PDFs;
  - video frame export and trim to MP4 or GIF.
- **Art Official formats:** Mood and Story files render in the app; Send to Mood and Send to Story; Finder Quick Look previews and thumbnails for `.mlmboard`, `.stry`, `.plib` and `.aoe`.
- **Your data is safe and portable:**
  - automatic backups, plus export and import;
  - a per-library `.promptlibrary/curation.json` that syncs curation between Macs (e.g. via Dropbox);
  - optional XMP sidecars;
  - originals are never modified, and duplicate tools never suggest deleting anything.
- **System integration:** Spotlight, Shortcuts (App Intents), `promptlibrary://` links, and awareness of Dropbox and iCloud files that are online-only.

## Requirements

- macOS 14 Sonoma or later (developed on macOS 15). Apple Silicon recommended.
- To build: a full **Xcode** install. The package must be built with Xcode's toolchain; the standalone Command Line Tools can't link this SwiftPM manifest.

## Build, install and run

From `src/PromptLibraryExplorer`:

```bash
# Build release, assemble + sign the app bundle (incl. Quick Look extensions),
# install to /Applications, and keep a zipped copy in dist/:
./scripts/package_app.sh            # add --launch to (re)start the app
./scripts/package_app.sh --no-install   # build + zip only

# Tests (XCTest):
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

The app is ad-hoc signed for local use. It isn't notarized for distribution yet.

## Versioning

**MAJOR.FEATURE.FIXES** (`#.#.##`). A feature release bumps FEATURE and resets FIXES to `00`. A fix bumps FIXES. A major release is `X.0.00`.

```bash
./scripts/bump_version.sh fix        # 1.11.01 -> 1.11.02
./scripts/bump_version.sh feature    # 1.11.01 -> 1.12.00
./scripts/bump_version.sh show
```

The version lives in `Resources/Info.plist`. The build number is the git commit count, and packaging stamps it into the bundle together with the commit hash, which the About panel shows. Record each release in [CHANGELOG.md](CHANGELOG.md).

## Repository layout

```
src/PromptLibraryExplorer/
  Package.swift                 SwiftPM: app, ArtOfficialFormats library, Quick Look extensions, tests
  PromptLibraryExplorer/        the app (App/, Models/, Services/, ViewModels/, Views/, Utilities/)
  ArtOfficialFormats/           Mood / Story / .plib / .aoe readers, writers, renderers (no AppKit)
  Extensions/                   Quick Look preview + thumbnail extensions (see Extensions/README.md)
  Resources/                    Info.plist (source of truth), app icon
  Tests/                        XCTest suites
  scripts/                      package_app.sh, bump_version.sh
  ROADMAP_FORMATS_AND_MEDIA.md  roadmap and researched TODOs
  ACCOUNT_FUNCTIONALITY_PLAN.md Art Official account plan
  APP_COLORS.md                 design tokens
```

## Privacy

Everything runs on your Mac. The app only uses the network in these cases:
- MapKit map tiles on the Map page;
- place-name lookup, only when you click Look Up Place Names;
- the generator URLs you configure (ComfyUI, A1111/Forge), only when you send something.

Curation data lives in `~/Library/Application Support/PromptLibraryExplorer`, and in each library's `.promptlibrary/` folder if library sync is on.

---

© 2026 ArtOfficial · [artofficial.world](https://artofficial.world)
