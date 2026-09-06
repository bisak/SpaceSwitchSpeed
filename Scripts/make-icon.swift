// Renders the app icon into the asset catalogue.
// Run with: swift Scripts/make-icon.swift
//
// The artwork is procedural rather than drawn in a design tool, so this script
// is its source. The rendered PNGs are committed like any other asset, so the
// project builds without running it.

import AppKit

func colour(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func render(_ size: CGFloat) -> Data {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icon artwork occupies the middle 824 of a 1024 canvas.
    let inset = size * 0.098
    let side = size - inset * 2
    let plate = CGRect(x: inset, y: inset, width: side, height: side)
    let radius = side * 0.225

    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [colour(88, 120, 255), colour(126, 74, 240)] as CFArray,
        locations: [0, 1])!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: plate.minX, y: plate.maxY),
        end: CGPoint(x: plate.maxX, y: plate.minY),
        options: [])
    ctx.restoreGState()

    func rounded(_ rect: CGRect, _ r: CGFloat, _ alpha: CGFloat) {
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha))
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
        ctx.fillPath()
    }

    // A panel arriving from the right, with the motion it left behind.
    let x = { (f: CGFloat) in plate.minX + side * f }
    let y = { (f: CGFloat) in plate.minY + side * f }

    rounded(
        CGRect(x: x(0.46), y: y(0.28), width: side * 0.34, height: side * 0.44),
        side * 0.06, 1.0)

    let trails: [(CGFloat, CGFloat, CGFloat)] = [
        (0.22, 0.615, 0.85), (0.16, 0.475, 0.6), (0.26, 0.335, 0.38),
    ]
    for (start, top, alpha) in trails {
        rounded(
            CGRect(x: x(start), y: y(top), width: side * (0.40 - start), height: side * 0.05),
            side * 0.025, alpha)
    }

    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

let appIcon = URL(fileURLWithPath: "Sources/SpaceSwitchSpeedApp/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: appIcon, withIntermediateDirectories: true)

let sizes = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
var images: [[String: String]] = []

for (points, scale) in sizes {
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try render(CGFloat(points * scale)).write(to: appIcon.appendingPathComponent(name))
    images.append([
        "filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)",
    ])
}

let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization
    .data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: appIcon.appendingPathComponent("Contents.json"))

print("wrote \(images.count) images to \(appIcon.path)")
