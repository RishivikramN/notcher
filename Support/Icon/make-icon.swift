// Draws Notcher's icon: a white island (capsule) on a black rounded square, flat.
//
// Usage: swift Support/Icon/make-icon.swift <output-dir>
// Writes AppIcon.iconset/ (all macOS sizes, each drawn at its own pixel size) and the
// menu-bar template images NotcherTray.png / NotcherTray@2x.png.

import AppKit
import SwiftUI

let ink = NSColor(srgbRed: 0.07, green: 0.07, blue: 0.08, alpha: 1)
let paper = NSColor(srgbRed: 0.97, green: 0.97, blue: 0.96, alpha: 1)

/// Apple's macOS icon grid on a 1024 canvas: an 824 pt body, 185 pt continuous corners,
/// and a soft drop shadow. The island is 520 × 160, centred.
func drawAppIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = size / 1024
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: scale, y: scale)

    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    // Continuous corners, like system icons (NSBezierPath's are plain circular arcs).
    let squircle = RoundedRectangle(cornerRadius: 185, style: .continuous).path(in: body).cgPath

    // Shadow only below the body (skipped at tiny sizes, where it just smudges).
    if size >= 64 {
        context.saveGState()
        // Shadow geometry is in device pixels, so it scales by hand.
        context.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 28 * scale, color: NSColor.black.withAlphaComponent(0.22).cgColor)
        context.setFillColor(ink.cgColor)
        context.addPath(squircle)
        context.fillPath()
        context.restoreGState()
    }
    context.setFillColor(ink.cgColor)
    context.addPath(squircle)
    context.fillPath()

    let island = CGRect(x: 512 - 260, y: 512 - 80, width: 520, height: 160)
    paper.setFill()
    NSBezierPath(roundedRect: island, xRadius: 80, yRadius: 80).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/// Menu-bar template: the same mark as an outline square with a solid island, 18 pt.
func drawTrayIcon(scale: CGFloat) -> NSBitmapImageRep {
    let points: CGFloat = 18
    let pixels = Int(points * scale)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    // Drawn in points: the context is in pixels until `size` is set, so scale by hand and set
    // the point size afterwards.
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current!.cgContext.scaleBy(x: scale, y: scale)

    NSColor.black.set()
    let frame = NSBezierPath(roundedRect: CGRect(x: 1.75, y: 1.75, width: 14.5, height: 14.5), xRadius: 4, yRadius: 4)
    frame.lineWidth = 1.5
    frame.stroke()
    NSBezierPath(roundedRect: CGRect(x: 4.75, y: 7.5, width: 8.5, height: 3), xRadius: 1.5, yRadius: 1.5).fill()

    NSGraphicsContext.restoreGraphicsState()
    rep.size = NSSize(width: points, height: points)
    return rep
}

func write(_ rep: NSBitmapImageRep, _ path: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let iconset = output + "/AppIcon.iconset"
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    write(drawAppIcon(size: CGFloat(points)), "\(iconset)/icon_\(points)x\(points).png")
    write(drawAppIcon(size: CGFloat(points * 2)), "\(iconset)/icon_\(points)x\(points)@2x.png")
}
write(drawTrayIcon(scale: 1), output + "/NotcherTray.png")
write(drawTrayIcon(scale: 2), output + "/NotcherTray@2x.png")
print("wrote \(iconset) and tray icons to \(output)")
