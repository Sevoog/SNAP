// make_icon.swift
// SNAP: Draws the app icon (brushed-steel Ethernet port) at every size
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md
//
// The icon is drawn from code on Apple's 1024-point icon grid, anti-aliased,
// with transparent corners around the rounded tile. The 16 and 32 pixel files
// use a simplified version (steel frame, dark opening, four contacts) so they
// stay sharp. Not part of the app build; run it when the icon changes.
//
//   swift scripts/make_icon.swift [output-folder]
//
// The output folder defaults to SNAP/Assets.xcassets/AppIcon.appiconset.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

func hex(_ v: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
            blue: CGFloat(v & 0xff) / 255, alpha: a)
}
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

/// Device pixels per design unit; shadows and blurs ignore the CTM, so they scale by hand.
var unit: CGFloat = 1

func gradient(_ c: CGContext, clip: CGPath, _ stops: [(CGFloat, CGColor)], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: sRGB, colors: stops.map { $0.1 } as CFArray, locations: stops.map { $0.0 })!
    c.saveGState(); c.addPath(clip); c.clip()
    c.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    c.restoreGState()
}

func rrect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat, continuous: Bool = false) -> CGPath {
    let rect = CGRect(x: x, y: y, width: w, height: h)
    if continuous { return RoundedRectangle(cornerRadius: r, style: .continuous).path(in: rect).cgPath }
    return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
}

func fill(_ c: CGContext, _ p: CGPath, _ color: CGColor) { c.addPath(p); c.setFillColor(color); c.fillPath() }

func stroke(_ c: CGContext, _ p: CGPath, _ color: CGColor, _ w: CGFloat) {
    c.addPath(p); c.setStrokeColor(color); c.setLineWidth(w); c.strokePath()
}

func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) -> CGPath {
    let p = CGMutablePath(); p.move(to: CGPoint(x: x1, y: y1)); p.addLine(to: CGPoint(x: x2, y: y2)); return p
}

func polygon(_ pts: [(CGFloat, CGFloat)]) -> CGPath {
    let p = CGMutablePath(); p.addLines(between: pts.map { CGPoint(x: $0.0, y: $0.1) }); p.closeSubpath(); return p
}

/// A polygon with its corners rounded outward, like an SVG fill plus a round-join stroke.
func roundedOutset(_ p: CGPath, _ width: CGFloat) -> CGPath {
    p.union(p.copy(strokingWithWidth: width, lineCap: .butt, lineJoin: .round, miterLimit: 10))
}

func withShadow(_ c: CGContext, dy: CGFloat, blur: CGFloat, _ color: CGColor, _ draw: () -> Void) {
    c.saveGState()
    // Bitmap space is y-up, so a downward design offset is negative here.
    c.setShadow(offset: CGSize(width: 0, height: -dy * unit), blur: blur * unit, color: color)
    draw()
    c.restoreGState()
}

let tilePath = rrect(100, 100, 824, 824, 185, continuous: true)

func drawTile(_ c: CGContext, shadow: Bool) {
    if shadow { withShadow(c, dy: 10, blur: 24, hex(0, 0.35)) { fill(c, tilePath, hex(0x30333b)) } }
    gradient(c, clip: tilePath, [(0, hex(0x30333b)), (1, hex(0x0c0d10))], from: CGPoint(x: 100, y: 100), to: CGPoint(x: 924, y: 924))
}

let jack = polygon([(282, 300), (742, 300), (742, 640), (597, 640), (597, 720), (427, 720), (427, 640), (282, 640)])

func drawM1(_ c: CGContext) {
    drawTile(c, shadow: true)
    fill(c, CGPath(ellipseIn: CGRect(x: 212, y: 130, width: 600, height: 140), transform: nil), hex(0xffffff, 0.06))

    // Steel shield with a soft drop shadow, beveled edge, and brushed lines.
    let shield = rrect(206, 226, 612, 566, 52)
    withShadow(c, dy: 40, blur: 44, hex(0, 0.55)) { fill(c, shield, hex(0x9a9da4)) }
    gradient(c, clip: shield, [(0, hex(0xfbfbfc)), (0.45, hex(0xd5d7db)), (1, hex(0x9a9da4))],
             from: CGPoint(x: 0, y: 226), to: CGPoint(x: 0, y: 792))
    stroke(c, rrect(212, 232, 600, 554, 47), hex(0xffffff, 0.55), 5)
    for i in 0..<9 { stroke(c, line(240, 256 + CGFloat(i) * 62, 784, 256 + CGFloat(i) * 62), hex(0xffffff, 0.07), 3) }

    // The jack opening, with a rim shadow and a back wall for depth.
    fill(c, roundedOutset(jack, 44), hex(0, 0.35))
    gradient(c, clip: roundedOutset(jack, 30), [(0, hex(0x000000)), (1, hex(0x1b1b1e))],
             from: CGPoint(x: 0, y: 285), to: CGPoint(x: 0, y: 735))
    gradient(c, clip: rrect(334, 352, 356, 236, 10), [(0, hex(0x141416)), (1, hex(0x26262a))],
             from: CGPoint(x: 0, y: 352), to: CGPoint(x: 0, y: 588))
    for (a, b, x, y) in [(267, 285, 334, 352), (757, 285, 690, 352), (267, 655, 334, 588), (757, 655, 690, 588)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
        stroke(c, line(a, b, x, y), hex(0x2e2e33), 5)
    }

    // Grounding tabs on the shield above the opening.
    for x in [352, 602] as [CGFloat] {
        fill(c, rrect(x, 262, 70, 30, 8), hex(0x9a9da4))
        fill(c, rrect(x, 262, 70, 10, 5), hex(0xffffff, 0.5))
    }

    // Eight angled gold contacts.
    c.setLineCap(.round)
    for i in 0..<8 {
        let x = 362 + CGFloat(i) * 43
        let wire = line(x, 362, x + 10, 470).copy(strokingWithWidth: 20, lineCap: .round, lineJoin: .round, miterLimit: 10)
        gradient(c, clip: wire, [(0, hex(0xFFF0C2)), (0.5, hex(0xF2BE4E)), (1, hex(0xB87814))],
                 from: CGPoint(x: 0, y: 352), to: CGPoint(x: 0, y: 480))
        stroke(c, line(x - 4, 366, x + 4, 452), hex(0xffffff, 0.55), 5)
    }

    // Recessed link lights: green and SNAP orange.
    for (lx, color, core) in [(CGFloat(330), hex(0x34C759), hex(0xC8FFD4)), (CGFloat(694), hex(0xFF9500), hex(0xFFD9A0))] {
        fill(c, rrect(lx - 40, 688, 80, 48, 14), hex(0x141416))
        withShadow(c, dy: 0, blur: 24, color) { fill(c, rrect(lx - 30, 697, 60, 30, 10), color) }
        fill(c, rrect(lx - 27, 699, 54, 26, 9), color)
        fill(c, rrect(lx - 20, 702, 30, 8, 4), core)
    }
}

func drawSmall(_ c: CGContext) {
    drawTile(c, shadow: false)
    gradient(c, clip: rrect(180, 200, 664, 624, 60), [(0, hex(0xfbfbfc)), (1, hex(0x9a9da4))],
             from: CGPoint(x: 0, y: 200), to: CGPoint(x: 0, y: 824))
    let opening = polygon([(272, 290), (752, 290), (752, 640), (612, 640), (612, 740), (412, 740), (412, 640), (272, 640)])
    fill(c, roundedOutset(opening, 36), hex(0x0a0a0b))
    for i in 0..<4 {
        gradient(c, clip: rrect(338 + CGFloat(i) * 96, 330, 58, 170, 20), [(0, hex(0xFFE7A6)), (1, hex(0xD4931A))],
                 from: CGPoint(x: 0, y: 330), to: CGPoint(x: 0, y: 500))
    }
}

func render(px: Int, small: Bool, to url: URL) {
    let c = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.setShouldAntialias(true); c.setAllowsAntialiasing(true); c.interpolationQuality = .high
    unit = CGFloat(px) / 1024
    // Flip to a top-left origin and scale the 1024 design grid to the target size.
    c.translateBy(x: 0, y: CGFloat(px)); c.scaleBy(x: unit, y: -unit)
    small ? drawSmall(c) : drawM1(c)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, c.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(dest))
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1
              ? CommandLine.arguments[1] : "SNAP/Assets.xcassets/AppIcon.appiconset")
// filename -> pixel size. 16 and 32 px use the simplified art.
let files: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32), ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256), ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512), ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in files { render(px: px, small: px <= 32, to: out.appendingPathComponent(name)) }
print("wrote \(files.count) files to \(out.path)")
