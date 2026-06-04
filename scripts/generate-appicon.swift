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
