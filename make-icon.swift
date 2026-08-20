// Draws Statter.icns from scratch — no image assets in the repo.
//
//   swift make-icon.swift
//
// Colourless glass: a translucent plate with a lit top edge, and the same
// `memorychip` symbol the menu bar uses, cut into it in white. Everything is
// alpha and highlight, no hue, so the icon takes its colour from whatever
// wallpaper sits behind it.

import AppKit

let outputPath = "Statter.icns"
let iconsetPath = "Statter.iconset"

/// One icon face at `px` pixels square.
func drawIcon(px: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                              pixelsWide: Int(px), pixelsHigh: Int(px),
                              bitsPerSample: 8, samplesPerPixel: 4,
                              hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icons sit inset in their canvas rather than filling it edge to edge.
    let inset = px * 0.098
    let plate = NSRect(x: inset, y: inset, width: px - inset * 2, height: px - inset * 2)
    let corner = plate.width * 0.225
    let platePath = NSBezierPath(roundedRect: plate, xRadius: corner, yRadius: corner)

    let white = { (a: CGFloat) in NSColor(white: 1, alpha: a) }

    // A soft shadow is what separates glass from a hole in the screen.
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.shadowBlurRadius = px * 0.028
    shadow.shadowOffset = NSSize(width: 0, height: -px * 0.014)
    shadow.set()
    white(0.001).setFill()      // shadow needs something opaque-ish to cast from
    platePath.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    // The pane itself: brighter at the top, near-clear at the bottom, so it
    // reads as a lit sheet rather than a flat grey wash.
    NSGradient(colors: [white(0.30), white(0.13), white(0.18)],
               atLocations: [0, 0.55, 1],
               colorSpace: .deviceRGB)?.draw(in: platePath, angle: -90)

    NSGraphicsContext.current?.saveGraphicsState()
    platePath.addClip()

    // Specular sweep across the upper third.
    let sweep = NSBezierPath(ovalIn: NSRect(x: plate.minX - plate.width * 0.35,
                                            y: plate.midY + plate.height * 0.14,
                                            width: plate.width * 1.7,
                                            height: plate.height * 0.85))
    NSGradient(starting: white(0.26), ending: white(0.0))?.draw(in: sweep, angle: -90)

    // Inner shading along the bottom edge — the thickness of the glass.
    let bottomBand = NSRect(x: plate.minX, y: plate.minY,
                            width: plate.width, height: plate.height * 0.30)
    NSGradient(starting: NSColor(white: 0, alpha: 0.16),
               ending: NSColor(white: 0, alpha: 0))?.draw(in: bottomBand, angle: 90)

    NSGraphicsContext.current?.restoreGraphicsState()

    // Edge: bright where light lands on the top rim, faint underneath.
    NSGraphicsContext.current?.saveGraphicsState()
    let rimWidth = max(1, px * 0.008)
    let rim = NSBezierPath(roundedRect: plate.insetBy(dx: rimWidth / 2, dy: rimWidth / 2),
                           xRadius: corner, yRadius: corner)
    rim.lineWidth = rimWidth
    rim.setClip()
    NSGradient(colors: [white(0.55), white(0.16), white(0.34)],
               atLocations: [0, 0.5, 1],
               colorSpace: .deviceRGB)?.draw(in: plate, angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()
    NSGraphicsContext.current?.saveGraphicsState()
    rim.lineWidth = rimWidth
    white(0.001).setStroke()
    NSGraphicsContext.current?.restoreGraphicsState()

    // The chip mark. The pins thin out to nothing in the 16 and 32 pt faces,
    // so small sizes get a heavier weight to stay readable.
    let weight: NSFont.Weight = px <= 64 ? .bold : .medium
    let cfg = NSImage.SymbolConfiguration(pointSize: px * 0.42, weight: weight)
    if let symbol = NSImage(systemSymbolName: "memorychip", accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) {
        let s = symbol.size
        let box = NSRect(x: (px - s.width) / 2, y: (px - s.height) / 2 + px * 0.045,
                         width: s.width, height: s.height)
        // Etched: a dark offset copy underneath, white on top.
        let etch = NSImage(size: s, flipped: false) { r in
            symbol.draw(in: r)
            NSColor(white: 0, alpha: 0.42).set()
            r.fill(using: .sourceAtop)
            return true
        }
        etch.draw(in: box.offsetBy(dx: 0, dy: -px * 0.011))
        let glyph = NSImage(size: s, flipped: false) { r in
            symbol.draw(in: r)
            white(0.92).set()
            r.fill(using: .sourceAtop)
            return true
        }
        glyph.draw(in: box)
    }

    // Capacity bar under the chip — the app's whole point in one stroke.
    let barW = plate.width * 0.44
    let barH = max(1, px * 0.030)
    let bar = NSRect(x: (px - barW) / 2, y: plate.minY + plate.height * 0.185,
                     width: barW, height: barH)
    NSColor(white: 0, alpha: 0.30).setFill()
    NSBezierPath(roundedRect: bar, xRadius: barH / 2, yRadius: barH / 2).fill()
    let fill = NSRect(x: bar.minX, y: bar.minY, width: bar.width * 0.62, height: bar.height)
    white(0.92).setFill()
    NSBezierPath(roundedRect: fill, xRadius: barH / 2, yRadius: barH / 2).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// .iconset expects both scales of each nominal size.
let faces: [(name: String, px: CGFloat)] = [
    ("icon_16x16.png", 16),      ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),      ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),   ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),   ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),   ("icon_512x512@2x.png", 1024),
]

let fm = FileManager.default
try? fm.removeItem(atPath: iconsetPath)
try fm.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

for face in faces {
    let rep = drawIcon(px: face.px)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("could not encode \(face.name)")
    }
    try data.write(to: URL(fileURLWithPath: "\(iconsetPath)/\(face.name)"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetPath, "-o", outputPath]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }

try? fm.removeItem(atPath: iconsetPath)
print("wrote \(outputPath)")
