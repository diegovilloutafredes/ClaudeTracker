# App Icon Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the full-bleed square app icon with the approved "Bolt + Gauge" design (proper macOS squircle geometry), generated programmatically, after bumping CI to macOS 26 / Xcode 26.5.

**Architecture:** Two independent commits land in order: (1) a CI pin bump in both GitHub Actions workflows; (2) a new `scripts/generate-appicon.swift` CoreGraphics script that draws the icon in a 100-unit design space (matching the approved SVG mockup) and writes all 10 PNGs into the existing `AppIcon.appiconset`. The PNGs stay committed; the script is regeneration tooling, not a build step. `Contents.json` is untouched.

**Tech Stack:** GitHub Actions (macos-26 runner), Swift script (AppKit/CoreGraphics/ImageIO — no dependencies), existing Makefile (`make run`).

**Design spec:** `docs/superpowers/specs/2026-06-04-app-icon-refresh-design.md`

---

### Task 1: CI bump to macos-26 / Xcode 26.5

**Files:**
- Modify: `.github/workflows/build.yml:11` and `:17`
- Modify: `.github/workflows/release.yml:10` and `:18`

**Why first:** the spec requires CI green on the bump before the icon lands, and the bump unlocks the future Icon Composer `.icon` path.

- [ ] **Step 1: Edit `build.yml`**

Change line 11:
```yaml
    runs-on: macos-26
```
(was `runs-on: macos-15`)

Change line 17 (the `Select Xcode` step's `run`):
```yaml
        run: sudo xcode-select -s /Applications/Xcode_26.5.app/Contents/Developer
```
(was `/Applications/Xcode_16.app/Contents/Developer`)

- [ ] **Step 2: Edit `release.yml`**

Change line 10:
```yaml
    runs-on: macos-26
```

Change line 18 (the `Select Xcode` step's `run`):
```yaml
        run: sudo xcode-select -s /Applications/Xcode_26.5.app/Contents/Developer
```

Do NOT touch anything else in either workflow — signing, lint, packaging steps stay as-is. `SWIFT_STRICT_CONCURRENCY=minimal` lives in the Makefile and is unaffected.

- [ ] **Step 3: Commit and push**

```bash
git add .github/workflows/build.yml .github/workflows/release.yml
git commit -m "CI: bump runners to macos-26, Xcode 16.0 -> 26.5"
git push
```

Note: per user preference, NO `Co-Authored-By` trailer on any commit in this plan.

- [ ] **Step 4: Verify the Build workflow passes on the new runner**

```bash
gh run watch $(gh run list --workflow=Build --limit 1 --json databaseId --jq '.[0].databaseId')
```

Expected: run completes with `✓` (build + test jobs green).

Caveat: `release.yml` only triggers on `v*` tags, so it cannot be exercised now. The change is identical (same two lines), and the next `make tag` release validates it. If the Build run FAILS at the `Select Xcode` step with "no such file", check available versions at https://github.com/actions/runner-images/blob/main/images/macos/macos-26-Readme.md and adjust the pin (e.g. `Xcode_26.4.1.app`) — do not fall back to Xcode 16.

### Task 2: Icon generation script + regenerated PNGs

**Files:**
- Create: `scripts/generate-appicon.swift`
- Regenerate (overwrite): all 10 PNGs in `ClaudeTracker/Assets.xcassets/AppIcon.appiconset/` (`icon_16x16.png` … `icon_512x512@2x.png`)
- Do NOT modify: `ClaudeTracker/Assets.xcassets/AppIcon.appiconset/Contents.json`

- [ ] **Step 1: Create `scripts/generate-appicon.swift`**

The geometry constants come from the approved mockup (100-unit viewBox, y-down). The CG context is flipped so design coordinates can be used verbatim. Gradient strokes are done by clipping to the stroked path outline (CG has no native gradient stroke).

```swift
#!/usr/bin/env swift
//
//  generate-appicon.swift
//  Regenerates all AppIcon.appiconset PNGs ("Bolt + Gauge" design).
//  Design spec: docs/superpowers/specs/2026-06-04-app-icon-refresh-design.md
//
//  Run from the repo root:  swift scripts/generate-appicon.swift
//
import AppKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - Output set (matches Contents.json)

let outputs: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

let appiconsetPath = "ClaudeTracker/Assets.xcassets/AppIcon.appiconset"

// MARK: - Colors & gradients

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

func gradient(_ stops: [(CGFloat, UInt32)]) -> CGGradient {
    CGGradient(colorsSpace: srgb,
               colors: stops.map { color($0.1) } as CFArray,
               locations: stops.map(\.0))!
}

let backgroundGradient = gradient([(0, 0x23283A), (1, 0x13161F)])
let urgencyGradient = gradient([(0, 0x2ECC71), (0.45, 0xF1C40F), (0.75, 0xE67E22), (1, 0xE74C3C)])
let coralGradient = gradient([(0, 0xE8917A), (1, 0xD97757)])

// MARK: - Geometry (100-unit design space, y-down)

let gaugeCenter = CGPoint(x: 50, y: 50)
let gaugeRadius: CGFloat = 31.5
let gaugeStartDeg: CGFloat = 135          // bottom-left, sweeping through the top
let gaugeSweepDeg: CGFloat = 270
let gaugeFillFraction: CGFloat = 0.72

func deg(_ d: CGFloat) -> CGFloat { d * .pi / 180 }

/// 270° gauge arc (or a leading fraction of it), y-down space.
func gaugeArc(fraction: CGFloat) -> CGPath {
    let path = CGMutablePath()
    path.addArc(center: gaugeCenter, radius: gaugeRadius,
                startAngle: deg(gaugeStartDeg),
                endAngle: deg(gaugeStartDeg + gaugeSweepDeg * fraction),
                clockwise: false)  // increasing angle = visually clockwise in y-down space
    return path
}

/// Menu-bar bolt shape, scaled to 85% around its center, centered at (50, 51).
func boltPath() -> CGPath {
    let pts: [CGPoint] = [
        CGPoint(x: 54, y: 26), CGPoint(x: 36, y: 54), CGPoint(x: 47, y: 54),
        CGPoint(x: 42, y: 76), CGPoint(x: 62, y: 46), CGPoint(x: 50, y: 46),
    ]
    // Equivalent to SVG: translate(50 51) scale(0.85) translate(-49 -51)
    let t = CGAffineTransform(translationX: 50, y: 51)
        .scaledBy(x: 0.85, y: 0.85)
        .translatedBy(x: -49, y: -51)
    let path = CGMutablePath()
    path.addLines(between: pts, transform: t)
    path.closeSubpath()
    return path
}

// MARK: - Drawing helpers

func fillWithGradient(_ ctx: CGContext, path: CGPath, gradient: CGGradient,
                      from: CGPoint, to: CGPoint) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(gradient, start: from, end: to,
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

func strokeWithGradient(_ ctx: CGContext, path: CGPath, width: CGFloat,
                        gradient: CGGradient, from: CGPoint, to: CGPoint) {
    let stroked = path.copy(strokingWithWidth: width, lineCap: .round,
                            lineJoin: .round, miterLimit: 10)
    fillWithGradient(ctx, path: stroked, gradient: gradient, from: from, to: to)
}

// MARK: - Render

func renderIcon(px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px,
                        bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Flip so the 100-unit design space is y-down (like the SVG mockup).
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: CGFloat(px) / 100, y: -CGFloat(px) / 100)
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // Background squircle (~82% of canvas) with vertical gradient.
    let squircle = CGPath(roundedRect: CGRect(x: 9, y: 9, width: 82, height: 82),
                          cornerWidth: 19, cornerHeight: 19, transform: nil)
    fillWithGradient(ctx, path: squircle, gradient: backgroundGradient,
                     from: CGPoint(x: 50, y: 9), to: CGPoint(x: 50, y: 91))

    // Slight stroke boost at tiny sizes for legibility (16/32 px outputs).
    let gaugeWidth: CGFloat = px <= 32 ? 11.5 : 9

    // Gauge track: full 270° arc, white @ 12%.
    ctx.saveGState()
    ctx.addPath(gaugeArc(fraction: 1))
    ctx.setStrokeColor(color(0xFFFFFF, 0.12))
    ctx.setLineWidth(gaugeWidth)
    ctx.setLineCap(.round)
    ctx.strokePath()
    ctx.restoreGState()

    // Gauge fill: leading 72% of the arc, urgency gradient left -> right.
    strokeWithGradient(ctx, path: gaugeArc(fraction: gaugeFillFraction),
                       width: gaugeWidth, gradient: urgencyGradient,
                       from: CGPoint(x: 18.5, y: 50), to: CGPoint(x: 81.5, y: 50))

    // Coral bolt, vertical gradient.
    fillWithGradient(ctx, path: boltPath(), gradient: coralGradient,
                     from: CGPoint(x: 50, y: 26), to: CGPoint(x: 50, y: 76))

    return ctx.makeImage()!
}

// MARK: - Main

let fm = FileManager.default
guard fm.fileExists(atPath: appiconsetPath) else {
    fputs("error: \(appiconsetPath) not found — run from the repo root\n", stderr)
    exit(1)
}

for (name, px) in outputs {
    let url = URL(fileURLWithPath: "\(appiconsetPath)/\(name)")
    let image = renderIcon(px: px)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                     UTType.png.identifier as CFString, 1, nil) else {
        fputs("error: cannot create \(url.path)\n", stderr)
        exit(1)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        fputs("error: failed writing \(url.path)\n", stderr)
        exit(1)
    }
    print("wrote \(name) (\(px)x\(px))")
}
print("done — \(outputs.count) PNGs regenerated")
```

- [ ] **Step 2: Run the script**

```bash
cd /Users/diegovillouta/iOS/Apps/Personal/ClaudeTracker
swift scripts/generate-appicon.swift
```

Expected output: ten `wrote icon_…` lines ending with `done — 10 PNGs regenerated`.

- [ ] **Step 3: Verify dimensions and alpha**

```bash
for f in ClaudeTracker/Assets.xcassets/AppIcon.appiconset/icon_*.png; do
  sips -g pixelWidth -g pixelHeight -g hasAlpha "$f" | tr '\n' ' '; echo "$f"
done
```

Expected: sizes 16/32/32/64/128/256/256/512/512/1024 matching each filename's nominal size × scale, and `hasAlpha: yes` on every file (transparent squircle margins).

Then visually inspect `icon_512x512.png` (Read tool / Quick Look): dark squircle with transparent corners, 270° gauge (white track, green→red fill ending upper-right at 72%), centered coral bolt. Compare against the approved mockup.

- [ ] **Step 4: Verify the asset catalog still compiles**

```bash
make build
```

Expected: `BUILD SUCCEEDED` (this also regenerates the xcodeproj via XcodeGen; the icon set compiles with actool).

- [ ] **Step 5: Commit**

```bash
git add scripts/generate-appicon.swift ClaudeTracker/Assets.xcassets/AppIcon.appiconset/
git commit -m "Redesign app icon: bolt + gauge on macOS squircle, generated by script"
```

### Task 3: Install and visually verify

**Files:** none (verification only)

- [ ] **Step 1: Build, install, launch**

```bash
make run
```

Expected: app builds, old `/Applications/ClaudeTracker.app` is deleted, new one installed and launched (the Makefile handles the delete-first requirement).

- [ ] **Step 2: Visual checks (user-facing)**

- Dock / Cmd+Tab: squircle shape consistent with neighboring icons, no square block.
- Finder list view (16 px) and icon view: gauge + bolt still legible.
- macOS 26 Liquid Glass wrapper: icon sits correctly inside the system frame, no clipped elements.

If anything looks off (e.g. bolt too small at 16 px, gauge too thin), adjust the constants at the top of `scripts/generate-appicon.swift` (`gaugeFillFraction`, stroke widths, bolt scale in `boltPath()`), re-run the script, and repeat from Task 2 Step 2.

- [ ] **Step 3: Push**

```bash
git push
```

Then confirm CI green:

```bash
gh run watch $(gh run list --workflow=Build --limit 1 --json databaseId --jq '.[0].databaseId')
```

Expected: `✓` build + test.

### Task 4: Documentation updates

**Files:**
- Modify: `CLAUDE.md` (ClaudeTracker project root — Build & Deploy section)
- Check: `README.md` (only update if it shows/describes the icon)

- [ ] **Step 1: Add the script to CLAUDE.md's Makefile/tooling documentation**

In `/Users/diegovillouta/iOS/Apps/Personal/ClaudeTracker/CLAUDE.md`, after the Makefile targets table in **Build & Deploy**, add:

```markdown
The app icon is generated by `scripts/generate-appicon.swift` (run `swift scripts/generate-appicon.swift` from the repo root) — it redraws the "bolt + gauge" design with CoreGraphics and overwrites all 10 PNGs in `AppIcon.appiconset/`. The PNGs are committed; the script is regeneration tooling, not a build step. Design spec: `docs/superpowers/specs/2026-06-04-app-icon-refresh-design.md`.
```

- [ ] **Step 2: Check README**

```bash
grep -in "icon" README.md
```

If the README displays the app icon image or describes the old design, update the text/image reference to match the new design. If it only mentions "menu bar icon" (different thing), leave it untouched.

- [ ] **Step 3: Commit and push**

```bash
git add CLAUDE.md README.md
git commit -m "Document app icon generation script"
git push
```

---

## Self-review notes

- **Spec coverage:** geometry/colors (Task 2 Step 1 constants), 10-PNG regeneration (Task 2), small-size stroke boost (`px <= 32` branch), CI bump ordering (Task 1 before Task 2 commits), verification incl. `make run` + Finder small sizes (Task 3), docs (Task 4), Contents.json untouched (Task 2 file list). Out-of-scope items (Icon Composer, menu bar icon) have no tasks — correct.
- **TDD deviation (deliberate):** this change is CI config + asset generation; there is no unit-testable logic. Verification is command-based (script output, `sips`, `make build`, CI runs, visual inspection) instead of test-first.
- **No Co-Authored-By trailers** on any commit (user preference).
