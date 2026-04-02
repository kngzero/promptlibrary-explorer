# App Color Reference

This document lists the current app color palette from `PromptLibraryExplorer/App/Theme.swift` plus the small set of direct color literals used outside the shared theme.

## Dynamic Theme Tokens

| Token | Purpose | Dark Mode | Light Mode |
| --- | --- | --- | --- |
| `appBackground` | Main app background | `#171717` | `#E8E8E8` |
| `appSurface` | Inset panel and tile surface | `#101010` | `#EFEFEF` |
| `appElevatedSurface` | Buttons and elevated controls | `#262630` | `#D9D9CF` |
| `appAccent` | Primary accent | `#D946EF` | `#D946EF` |
| `appAccentHover` | Accent hover state | `#F0ABFC` | `#F0ABFC` |
| `appThumb` | Scrollbar thumb | `#3F3F46` | `#C0C0B9` |
| `appMuted` | Secondary and muted text | `#A1A1AA` | `#5E5E55` |
| `appPrimaryText` | Primary text | `#FFFFFF` | `#121212` |
| `appHover` | Hover highlight | `rgba(255, 255, 255, 0.06)` | `rgba(0, 0, 0, 0.05)` |
| `appSelected` | Selected item fill | `rgba(217, 70, 239, 0.18)` | `rgba(217, 70, 239, 0.18)` |
| `appBorder` | Standard border and separator | `rgba(255, 255, 255, 0.08)` | `rgba(0, 0, 0, 0.08)` |
| `appControlBorder` | Stronger control border | `rgba(255, 255, 255, 0.16)` | `rgba(0, 0, 0, 0.14)` |
| `appSuccess` | Success state | `#22C55E` | `#16A34A` |
| `appError` | Error state | `#EF4444` | `#DC2626` |
| `appSidebarBackground` | Sidebar and detail-heavy panel background | `#1E1E21` | `#E1E1DE` |
| `appCanvasBackground` | Lightbox / fullscreen canvas background | `#000000` | `#F7F7F7` |
| `appOverlaySurface` | Floating overlay surface | `rgba(0, 0, 0, 0.62)` | `rgba(255, 255, 255, 0.90)` |
| `appOverlayStroke` | Overlay border | `rgba(255, 255, 255, 0.12)` | `rgba(0, 0, 0, 0.08)` |
| `appOverlayDivider` | Overlay divider line | `rgba(255, 255, 255, 0.14)` | `rgba(0, 0, 0, 0.12)` |
| `appOverlayActiveFill` | Active overlay fill | `rgba(255, 255, 255, 0.14)` | `rgba(0, 0, 0, 0.08)` |
| `appShadowColor` | Shadow color | `rgba(0, 0, 0, 0.25)` | `rgba(0, 0, 0, 0.12)` |

## Fixed Colors Used In Both Modes

These colors do not switch between dark and light mode.

| Token or Literal | Purpose | Value |
| --- | --- | --- |
| `segmentFullPrompt` | Analysis segment color | `#8FA3CC` |
| `segmentBrief` | Analysis segment color | `#99CC99` |
| `segmentSubject` | Analysis segment color | `#D9A673` |
| `segmentAction` | Analysis segment color | `#D98080` |
| `segmentPlace` | Analysis segment color | `#8CBFBF` |
| `segmentStyle` | Analysis segment color | `#BF8CCC` |
| `segmentLighting` | Analysis segment color | `#E6D973` |
| `segmentCamera` | Analysis segment color | `#80A6D9` |
| `segmentPalette` | Analysis segment color | `#CC8CA6` |
| `segmentMood` | Analysis segment color | `#A6CC8C` |
| Hardcoded preview badge magenta | `.plib` and `.aoe` preview badge fill in `ContentBrowserView.swift` | `#D900D9` |
| White text / icon color | Badge and pill foreground color in several views | `#FFFFFF` |

## Notes

- `appSelected` is derived from `appAccent.opacity(0.18)`.
- Several views apply additional opacity to these base colors at the call site. This file lists the base palette tokens and fixed literals rather than every per-view opacity variation.
- No current dynamic theme token relies on `ThemePalette`'s automatic light-mode inversion fallback; each mode-specific token is explicitly defined.
