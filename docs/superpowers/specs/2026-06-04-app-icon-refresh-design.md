# App Icon Refresh — Design

**Date:** 2026-06-04
**Status:** Approved (brainstormed via visual companion session)

## Problem

The current app icon has four defects:

1. **Wrong canvas geometry.** It is a full-bleed, hard-cornered square. macOS does not mask app icons — the artwork itself must be a rounded rectangle with transparent margins (Apple grid: ~824 pt squircle inside a 1024 pt canvas). In the Dock it sits as a square block among squircles; on macOS 26 the system forces legacy icons into its Liquid Glass frame, cropping the corner-hugging elements.
2. **Weak at small sizes.** At 16/32 px the bottom slider and top dot vanish and the four thin bars blur together.
3. **Redundant elements.** The gradient slider repeats what the bars already communicate; the floating dot reads as noise.
4. **No identity link.** Nothing connects the icon to Claude (beyond a tiny coral dot) or to the app's own menu-bar identity (the ⚡ bolt + urgency color).

## Chosen design: "Bolt + Gauge" (A1, bolt at 85%)

Selected from three directions (bolt+gauge / rebuilt bar chart / ring meter), then refined across two iteration rounds in the visual companion.

### Visual spec

- **Canvas:** standard macOS icon grid. Squircle occupies ~82% of the canvas (824/1024), corner radius ~23% of the squircle side, transparent margins all around.
- **Background:** vertical gradient `#23283A` (top) → `#13161F` (bottom).
- **Gauge:** 270° arc (opening at the bottom), centered.
  - Track: white at 12% opacity.
  - Fill: 72% of the arc length in the app's urgency gradient — green `#2ECC71` → yellow `#F1C40F` (45%) → orange `#E67E22` (75%) → red `#E74C3C`.
  - Rounded caps; stroke width ≈ 9% of icon width.
- **Bolt:** the menu-bar ⚡ lightning shape, filled with a Claude-coral vertical gradient `#E8917A` → `#D97757`, centered within the gauge, scaled to 85% of the gauge's inner span.
- **Small sizes (16/32 px):** gauge stroke gets a slight thickness boost for legibility (size-specific variant, same design).

Reference geometry (from the approved SVG mockup, 100-unit viewBox):
- Squircle: `x=9 y=9 w=82 h=82 rx=19`
- Gauge arc: center (50, 50), radius 31.5, from 135° to 45° (through the top), dash 72/100
- Bolt path: `M 54 26 L 36 54 L 47 54 L 42 76 L 62 46 L 50 46 Z`, scaled 0.85 around (49, 51), translated so its center sits at (50, 51)

## Asset generation

- New script `scripts/generate-appicon.swift`, run manually via `swift scripts/generate-appicon.swift`.
- Draws the icon with CoreGraphics and writes all 10 PNGs (16/32/128/256/512 at @1x and @2x) into the existing `ClaudeTracker/Assets.xcassets/AppIcon.appiconset/`.
- No new dependencies. The design lives in the repo as code; future tweaks are parameter changes.
- PNGs remain committed. The script is regeneration tooling, **not** a build step — `Contents.json` and the build pipeline are untouched.

## CI bump (separate commit, lands first)

Both workflows (`.github/workflows/build.yml`, `.github/workflows/release.yml`):

- `runs-on: macos-15` → `runs-on: macos-26`
- `xcode-select -s /Applications/Xcode_16.app` → `/Applications/Xcode_26.5.app` (pinned to match local Xcode 26.5; the macos-26 image default is 26.4.1)
- `SWIFT_STRICT_CONCURRENCY=minimal` stays (set in the Makefile).

Rationale: the original `Xcode_16.app` pin resolved to Xcode 16.0 — the *oldest* version on the macos-15 image — and was a determinism pin from the first workflow commit, not a workaround. Explicit pins are kept (no `macos-latest`) so release builds stay reproducible; a rotated-off Xcode version fails loudly at the `xcode-select` step.

This bump also unlocks the Icon Composer `.icon` path for the future (see Out of scope).

## Verification

1. CI green on the bump commit (both workflows) before the icon lands.
2. `make run` — confirm the new icon in the Dock, Finder, and Cmd+Tab.
3. Check 16/32 px renders in Finder list view.
4. Docs updated: `CLAUDE.md` (icon + script entry); README if it displays the icon.

## Out of scope

- **Icon Composer `.icon` (Liquid Glass layered format):** deliberate follow-up, not part of this change. The CI bump removes the blocker; authoring background/gauge/bolt as separate layers for native macOS 26 rendering can land later.
- Menu bar icon, popover UI — unchanged.
- Anthropic's literal starburst logo is intentionally **not** used (trademark caution for a third-party open-source app); only the coral palette references Claude.
