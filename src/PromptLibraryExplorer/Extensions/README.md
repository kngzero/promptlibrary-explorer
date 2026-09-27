# Quick Look extensions

Two app extensions embedded in `PromptLibrary Explorer.app/Contents/PlugIns/`:

| Bundle | Id | Extension point | Principal class |
|---|---|---|---|
| `PLXQuickLookPreview.appex` | `com.artofficial.promptlibrary-explorer.quicklook-preview` | `com.apple.quicklook.preview` (data-based, `QLIsDataBasedPreview = YES`) | `PLXPreviewProvider` (`QLPreviewProvider`) |
| `PLXQuickLookThumbnail.appex` | `com.artofficial.promptlibrary-explorer.quicklook-thumbnail` | `com.apple.quicklook.thumbnail` | `PLXThumbnailProvider` (`QLThumbnailProvider`) |

Both handle `com.artofficial.mood.mlmboard`, `com.artofficial.story.project`,
`com.artofficial.story.mlseq`, `com.artofficial.plib`, `com.artofficial.aoe`
(declared by the host app's `Resources/Info.plist`).

- **Thumbnail**: Mood board → `ArtOfficialRenderer.renderMoodboard`; Story → contact sheet of
  the first project with shots; `.plib`/`.aoe` → first embedded image with a two-line
  prompt caption (≥ 256 px), or a text card when there is no decodable image. Rendered at
  `maximumSize × scale` px and replied with `QLThumbnailReply(contextSize:drawing:)`.
- **Preview**: self-contained HTML (`QLPreviewReply(dataOfContentType: .html, …)`),
  images embedded as `data:` URIs, a CSP that blocks everything but inline styles and
  `data:` images, light/dark via `prefers-color-scheme`. Mood: board + title/subtitle +
  stats + palette swatches. Story: every project, contact sheet, info, scene/shot outline
  with thumbnails (≤ 240 thumbs per preview). `.plib`/`.aoe`: images, prompt, generation
  info, analysis, reference images.

## Layout

```
Extensions/
  Shared/                    target PLXQuickLookSupport (pure, AppKit-free, unit-tested)
    PreviewHTML.swift          HTML builder (pure string transform)
    PreviewModels.swift        view models
    PreviewContentFactory.swift  file -> models -> HTML (renders images)
    ThumbnailRenderer.swift    file -> CGImage
    PromptFileDetails.swift    lenient generation-info / analysis reader for plib/aoe
    PreviewImageEncoder.swift  CGImage -> JPEG/PNG data URI
  EntryShim/                 target PLXExtensionEntry (C, see below)
  PLXQuickLookPreview/       executable target + Info.plist + .entitlements
  PLXQuickLookThumbnail/     executable target + Info.plist + .entitlements
Tests/PLXQuickLookSupportTests/
```

## Building (the SwiftPM appex technique)

SwiftPM cannot produce `.appex` bundles, so each extension is an ordinary
`.executableTarget` that `scripts/package_app.sh` wraps into a bundle:

1. **Compile/link flags** (`Package.swift`):
   - Swift: `-application-extension` (only extension-safe API) and `-parse-as-library`.
   - Linker: `-Xlinker -application_extension -Xlinker -e -Xlinker _NSExtensionMain`
     — the entry point is Foundation's `NSExtensionMain`, exactly like an Xcode appex.
     It reads `NSExtensionPrincipalClass` from Info.plist and instantiates it through the
     ObjC runtime, so each provider class carries a fixed name: `@objc(PLXPreviewProvider)`,
     `@objc(PLXThumbnailProvider)`.
   - `.linkedFramework("QuickLookUI")` / `.linkedFramework("QuickLookThumbnailing")`.
2. **No Swift `main`.** SwiftPM links every executable with `-alias _<Target>_main _main`,
   so that symbol must exist — but if Swift defines it (`main.swift`, `@main`, or even an
   `@_cdecl("<Target>_main")` function) the compiler emits a `__swift5_entry` section, and
   ExtensionFoundation (`-[_EXRunningExtension _startWithArguments:count:]`) calls that
   "Swift main" from inside `NSExtensionMain` (the ExtensionKit `@main` convention). Our
   main called `NSExtensionMain` again → infinite recursion → SIGSEGV. The fix is the tiny
   C target `EntryShim/` that defines `PLXQuickLookPreview_main` / `PLXQuickLookThumbnail_main`
   (C emits no `__swift5_entry`). Check with
   `otool -l <exe> | grep __swift5_entry` — must print nothing.
3. **Bundle assembly** (`scripts/package_app.sh`):
   ```
   PLX<Name>.appex/Contents/Info.plist      <- Extensions/<Name>/Info.plist (CFBundlePackageType XPC!)
   PLX<Name>.appex/Contents/MacOS/<Name>    <- .build/release/<Name>
   ```
   Each appex is signed with its entitlements before the app
   (`codesign --force --sign - --entitlements Extensions/<Name>/<Name>.entitlements --generate-entitlement-der`).
   Entitlements: `com.apple.security.app-sandbox` (Quick Look only loads sandboxed
   extensions) + `com.apple.security.files.user-selected.read-only`. Quick Look grants
   read access to the previewed file itself; images a `.plib` references by path outside
   that file are not readable in the sandbox and are skipped (counted as "not shown").
4. After LaunchServices registration the script runs `pluginkit -a` on each appex and
   `qlmanage -r` / `qlmanage -r cache`.

Build just the extensions while iterating:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --product PLXQuickLookThumbnail
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter PLXQuickLookSupportTests
```

## Registering, verifying, debugging

```sh
scripts/package_app.sh                                   # builds + embeds + signs + registers
pluginkit -mAvvv -p com.apple.quicklook.preview   | grep -A3 artofficial
pluginkit -mAvvv -p com.apple.quicklook.thumbnail | grep -A3 artofficial
pluginkit -a "PromptLibrary Explorer.app/Contents/PlugIns/PLXQuickLookThumbnail.appex"   # force (re)registration
pluginkit -e use -i com.artofficial.promptlibrary-explorer.quicklook-thumbnail           # enable if disabled

# Sample files + what the renderers draw (no Quick Look involved):
PLX_FIXTURE_DIR=/tmp/plx swift test --filter testExportFixtures
# Thumbnails through the real Quick Look pipeline (headless, writes PNGs):
qlmanage -r cache; qlmanage -t -x -s 512 -o /tmp/plx/out /tmp/plx/Sample.*
qlmanage -m plugins          # legacy .qlgenerator list only; appex providers don't show here

log show --last 5m --style compact --predicate 'process CONTAINS "PLXQuickLook"'
log show --last 5m --info --predicate 'process == "com.apple.quicklook.ThumbnailsAgent"'
ls ~/Library/Logs/DiagnosticReports | grep PLXQuickLook   # crash reports
```

Notes:
- `qlmanage -p` opens a preview window, and `qlmanage -p -o <dir>` crashes inside qlmanage
  (`EXConcreteExtension makeExtensionContextAndXPCConnectionForRequest` nil key) for
  app-extension previews, so preview HTML is verified with unit tests /
  `testExportFixtures` (`*.html` files) instead; open the real preview with Space in Finder.
- System Settings ▸ General ▸ Login Items & Extensions ▸ Quick Look lists both extensions
  and can disable them.
- Registration follows the app's path: after moving the app (e.g. to /Applications),
  run `lsregister -f` on it (or `scripts/package_app.sh`) and `pluginkit -a` again, and
  delete stale copies so pluginkit doesn't elect an old one.
- `com.artofficial.plib` / `.aoe` conform to `public.json`, so Apple's Text thumbnail
  extension is a fallback candidate. If a type keeps getting the plain-text thumbnail
  after registration, `com.apple.quicklook.ThumbnailsAgent` is still using a stale choice;
  it re-evaluates after `killall com.apple.quicklook.ThumbnailsAgent` (relaunched on
  demand) or a logout.
