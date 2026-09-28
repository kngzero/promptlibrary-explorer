# App Color Reference

This document lists the design tokens defined in `PromptLibraryExplorer/App/Theme.swift`: colours (decorative and text-safe), appearance modes, corner radii, spacing and fonts. Views should use these tokens rather than literals.

## Dynamic Theme Tokens

| Token | Purpose | Dark Mode | Light Mode |
| --- | --- | --- | --- |
| `appBackground` | Main app background | `#171717` | `#E8E8E8` |
| `appSurface` | Inset panel and tile surface | `#101010` | `#EFEFEF` |
| `appElevatedSurface` | Buttons and elevated controls (neutral) | `#262626` | `#D9D9D9` |
| `appAccent` | Primary accent (fuchsia on dark, deeper magenta on light) | `#D946EF` | `#A726BD` |
| `appAccentHover` | Accent hover state | `#F0ABFC` | `#8E1F9F` |
| `appThumb` | Scrollbar thumb | `#3F3F46` | `#C0C0B9` |
| `appMuted` | Secondary and muted text | `#A1A1AA` | `#5E5E55` |
| `appPrimaryText` | Primary text | `#FFFFFF` | `#121212` |
| `appHover` | Hover highlight | `rgba(255, 255, 255, 0.06)` | `rgba(0, 0, 0, 0.05)` |
| `appSelected` | Selected item fill | `rgba(217, 70, 239, 0.18)` | `rgba(167, 38, 189, 0.18)` |
| `appBorder` | Standard border and separator | `rgba(255, 255, 255, 0.08)` | `rgba(0, 0, 0, 0.08)` |
| `appControlBorder` | Stronger control border | `rgba(255, 255, 255, 0.16)` | `rgba(0, 0, 0, 0.14)` |
| `appSuccess` | Success state | `#22C55E` | `#16A34A` |
| `appError` | Error state | `#EF4444` | `#DC2626` |
| `appSidebarBackground` | Sidebar and detail-heavy panel background (neutral dark) | `#1E1E1E` | `#E1E1DE` |
| `appCanvasBackground` | Lightbox / fullscreen canvas background | `#000000` | `#F7F7F7` |
| `appOverlaySurface` | Floating overlay surface | `rgba(0, 0, 0, 0.62)` | `rgba(255, 255, 255, 0.90)` |
| `appOverlayStroke` | Overlay border | `rgba(255, 255, 255, 0.12)` | `rgba(0, 0, 0, 0.08)` |
| `appOverlayDivider` | Overlay divider line | `rgba(255, 255, 255, 0.14)` | `rgba(0, 0, 0, 0.12)` |
| `appOverlayActiveFill` | Active overlay fill | `rgba(255, 255, 255, 0.14)` | `rgba(0, 0, 0, 0.08)` |
| `appShadowColor` | Shadow color | `rgba(0, 0, 0, 0.25)` | `rgba(0, 0, 0, 0.12)` |
| `appOnAccent` | Text on a solid `appAccent` fill (small badges, e.g. the header filter count) | `#1A0620` | `#FFFFFF` |
| `appDisabledText` | Label of a disabled filled button (on `appElevatedSurface`) | `#A1A1AA` | `#5E5E55` |

## Appearance Modes

`AppAppearanceMode` has three cases: `.system` (follows macOS), `.dark` and `.light`. `preferredColorScheme` returns `nil` for `.system`; `colorScheme` is an alias kept for existing call sites. `resolvedColorScheme` resolves `.system` against `NSApp.effectiveAppearance`, and `applyToApp()` also sets the AppKit appearance so switching back to System releases a previously forced window. Every palette colour is a dynamic `NSColor` keyed on the effective appearance, so `.system` needs no extra handling. The stored default remains Dark.

## Decorative Colours (fills, dots, strokes)

These do not switch between dark and light mode. Use them for fills, tints and strokes, not for text or thin glyphs on light surfaces.

| Token | Purpose | Value |
| --- | --- | --- |
| `segmentFullPrompt` | Analysis segment | `#8FA3CC` |
| `segmentBrief` | Analysis segment | `#99CC99` |
| `segmentSubject` | Analysis segment | `#D9A673` |
| `segmentAction` | Analysis segment | `#D98080` |
| `segmentPlace` | Analysis segment | `#8CBFBF` |
| `segmentStyle` | Analysis segment | `#BF8CCC` |
| `segmentLighting` | Analysis segment | `#E6D973` |
| `segmentCamera` | Analysis segment | `#80A6D9` |
| `segmentPalette` | Analysis segment | `#CC8CA6` |
| `segmentMood` | Analysis segment | `#A6CC8C` |
| `badgePlib` | `.plib` preview badge fill | `#D900D9` |
| `badgeAoe` | `.aoe` preview badge fill | `#8B5CF6` |
| `badgeMood` | `.mlmboard` (Mood board) preview badge fill | `#CA8A04` |
| `badgeStory` | `.stry` / `.mlseq` (Story project) preview badge fill | `#6366F1` |
| `badgePng` | PNG badge fill | `#06B6D4` |
| `badgeJpg` | JPEG badge fill | `#F97316` |
| `badgeWebp` | WebP badge fill | `#22C55E` |
| `badgeGif` | GIF badge fill | `#EC4899` |
| `badgeVideo` | Video badge fill | `#EF4444` |
| `badgeAudio` | Audio badge fill | `#A755F5` |
| `badgeImage` | Other image badge fill | `#3B82F6` |
| `badgeFile` | Generic file badge fill | `#6B7280` |
| `favoriteGold` | Favourite pin fill | `#FACC15` |

`Color.segment(forAnalysisKey:)` maps a prompt-analysis key (`fullPrompt`, `subject`, `lighting`, ...) to its segment colour.

## Text-safe Variants

Same hue, adjusted per mode so text and thin glyphs reach at least 4.5:1 against `appCanvasBackground`, `appSurface`, `appBackground` and `appSidebarBackground`. Use these whenever a decorative colour is drawn as text or an icon. `Color.segmentText(forAnalysisKey:)` is the text-safe counterpart of `segment(forAnalysisKey:)`.

| Token | Dark Mode | Light Mode |
| --- | --- | --- |
| `favoriteGoldText` | `#FACC15` | `#7A5A00` |
| `segmentFullPromptText` | `#8FA3CC` | `#3D5A8C` |
| `segmentBriefText` | `#99CC99` | `#2F6B2F` |
| `segmentSubjectText` | `#D9A673` | `#85501F` |
| `segmentActionText` | `#D98080` | `#A33A3A` |
| `segmentPlaceText` | `#8CBFBF` | `#2B6363` |
| `segmentStyleText` | `#BF8CCC` | `#7A3D8A` |
| `segmentLightingText` | `#E6D973` | `#6E5F00` |
| `segmentCameraText` | `#80A6D9` | `#2F5A99` |
| `segmentPaletteText` | `#CC8CA6` | `#8C3D5A` |
| `segmentMoodText` | `#A6CC8C` | `#426B2C` |
| `badgePlibText` | `#E860E8` | `#A000A0` |
| `badgeAoeText` | `#A388F9` | `#6A3CD6` |
| `badgeMoodText` | `#EAB308` | `#7A5C00` |
| `badgeStoryText` | `#8B8FF8` | `#3F42C9` |
| `badgePngText` | `#06B6D4` | `#0B6A7B` |
| `badgeJpgText` | `#F97316` | `#A84600` |
| `badgeWebpText` | `#22C55E` | `#18733A` |
| `badgeGifText` | `#F06AAA` | `#B0215F` |
| `badgeVideoText` | `#F06060` | `#BD2525` |
| `badgeAudioText` | `#B77AF7` | `#7B32C2` |
| `badgeImageText` | `#5B9AF8` | `#2356C2` |
| `badgeFileText` | `#9CA3AF` | `#525862` |

White (`#FFFFFF`) remains as the glyph colour on the solid file-type preview badges (`PreviewBadgeView` in `ContentBrowserView.swift`, which uses the `badge*` tokens above), on tag pills, on the compact star badge and on `AppPrimaryButtonStyle`'s default label.

## Corner Radius (`AppRadius`)

| Token | Value |
| --- | --- |
| `xs` | 4 |
| `sm` | 6 |
| `md` | 8 |
| `lg` | 12 |
| `xl` | 16 |
| `xxl` | 20 |

Radii that scale with a view (for example `side * 0.18` on preview badges) stay as expressions.

## Spacing (`AppSpacing`)

| Token | Value |
| --- | --- |
| `xxs` | 2 |
| `xs` | 4 |
| `sm` | 6 |
| `md` | 8 |
| `lg` | 12 |
| `xl` | 16 |
| `xxl` | 24 |
| `xxxl` | 32 |

Paddings and spacings that fall between steps (5, 7, 10, 14, 18, 20, 22, 28) are still literals where rounding them would visibly shift layout.

## Fonts

| Token | Definition |
| --- | --- |
| `appLargeTitle` | 20 semibold |
| `appTitle` | 14 semibold |
| `appHeadline` | 13 semibold |
| `appBody` | 13 regular |
| `appCallout` | 12 regular |
| `appCalloutEmphasis` | 12 semibold |
| `appCaption` | 11 regular |
| `appCaptionEmphasis` | 11 semibold |
| `appFootnote` | 10 regular |
| `appMicro` | 9 semibold (badges) |
| `appMono` | 12 monospaced |
| `appIcon(_ size:, weight:)` | Point-size sizing for SF Symbols and off-scale text |

## Buttons

`AppPrimaryButtonStyle` (in `Views/Shared/ButtonStyles.swift`) is the one filled call-to-action style: `appAccent` fill with white label by default (`tint` / `foreground` are configurable), and a disabled state of `appElevatedSurface` fill with `appDisabledText` label. `SettingsFilledButton` wraps it. Use it in place of `.borderedProminent` + `.tint(.appAccent)`.

## Notes

- `appSelected` is derived from `appAccent.opacity(0.18)`.
- Several views apply additional opacity to these base colours at the call site. This file lists the base tokens rather than every per-view opacity variation.
- No current dynamic theme token relies on `ThemePalette`'s automatic light-mode inversion fallback; each mode-specific token is explicitly defined.
