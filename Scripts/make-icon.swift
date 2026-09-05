// Generates the app icon. Run with: swift Scripts/make-icon.swift
//
// Kept as source rather than a committed binary so the artwork can be adjusted
// without a design tool.

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
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [colour(88, 120, 255), colour(126, 74, 240)] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
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

    rounded(CGRect(x: x(0.46), y: y(0.28), width: side * 0.34, height: side * 0.44), side * 0.06, 1.0)

    let trails: [(CGFloat, CGFloat, CGFloat)] = [(0.22, 0.615, 0.85), (0.16, 0.475, 0.6), (0.26, 0.335, 0.38)]
    for (start, top, alpha) in trails {
        rounded(CGRect(x: x(start), y: y(top), width: side * (0.40 - start), height: side * 0.05),
                side * 0.025, alpha)
    }

    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: "build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    try render(CGFloat(points * scale)).write(to: iconset.appendingPathComponent(name))
}

let convert = Process()
convert.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
convert.arguments = ["-c", "icns", iconset.path, "-o", "Sources/SpaceSwitchApp/Resources/AppIcon.icns"]
try FileManager.default.createDirectory(
    at: URL(fileURLWithPath: "Sources/SpaceSwitchApp/Resources"), withIntermediateDirectories: true)
try convert.run()
convert.waitUntilExit()
print(convert.terminationStatus == 0 ? "wrote Sources/SpaceSwitchApp/Resources/AppIcon.icns" : "iconutil failed")
