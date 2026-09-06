// Renders the disk image's window background into docs/images/.
// Run with: swift Scripts/make-dmg-background.swift
//
// The window that opens when someone mounts the disk image is an ordinary
// Finder icon view with a picture behind it, so this is that picture. Finder
// draws the two icons and their labels on top; the art only has to leave room
// for them and make the direction to drag obvious.
//
// The artwork is procedural rather than drawn in a design tool, so this script
// is its source, and the type and the arrow come from the system: SF Pro and
// Apple's own arrow.right symbol. The render is committed like any other
// asset, so a release can be cut without running this.
//
// It is a PDF because Finder draws the picture at one image point per window
// point and refuses one whose pixels run past the window, so a 2x bitmap is
// not an option and a 1x one is visibly soft on a retina screen. Vector art is
// rasterised at whatever the display is.
//
// Finder anchors the picture at the top left of the content view and crops
// whatever does not fit, so the page is BLEED points taller than the layout:
// Scripts/make-dmg.sh asks for a content area slightly shorter than the art,
// and a title bar of an unexpected height on another release of macOS then
// crops more of the bleed rather than leaving a strip of the window's own
// background — which is dark in dark mode — showing beneath it.

import AppKit

let width: CGFloat = 640
let height: CGFloat = 400
let bleed: CGFloat = 32

// Where Finder is told to centre the two icons, and how big it draws them.
// Scripts/make-dmg.sh positions them at exactly these points.
let iconSize: CGFloat = 128
let iconCentres = (app: CGPoint(x: 168, y: 224), applications: CGPoint(x: 472, y: 224))

let title = "SpaceSwitchSpeed"
let subtitle = "Drag the app into Applications to install"

func colour(_ hex: UInt32) -> NSColor {
    NSColor(
        srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

let ink = colour(0x1D_1D_1F)
let secondary = colour(0x86_86_8B)
let arrowInk = colour(0xB0_B0_B8)
let accent = colour(0x58_78_FF)  // The blue the app icon's gradient starts from.

// Laid out from the top left, the way the window is read, and flipped on the
// way into Core Graphics.
func y(_ top: CGFloat) -> CGFloat { height + bleed - top }

func draw(into ctx: CGContext) {
    // A diagonal that carries a trace of the icon's own blue through the
    // middle of the window. Every colour is opaque: a PDF shading has no
    // alpha, so anything translucent here would be written out at full
    // strength.
    let paper = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            colour(0xFD_FD_FF).cgColor,
            accent.blended(withFraction: 0.94, of: colour(0xFF_FF_FF))!.cgColor,
            colour(0xEC_EC_F1).cgColor,
        ] as CFArray,
        locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(
        paper, start: CGPoint(x: 0, y: y(0)), end: CGPoint(x: width, y: y(height + bleed)),
        options: [])

    func write(_ string: String, font: NSFont, colour: NSColor, top: CGFloat) {
        let text = NSAttributedString(
            string: string,
            attributes: [.font: font, .foregroundColor: colour, .kern: font.pointSize * -0.012])
        let measured = text.size()
        text.draw(at: CGPoint(x: (width - measured.width) / 2, y: y(top) - measured.height))
    }

    write(title, font: .systemFont(ofSize: 21, weight: .semibold), colour: ink, top: 52)
    write(subtitle, font: .systemFont(ofSize: 13, weight: .regular), colour: secondary, top: 84)

    // The arrow is SF Pro's own, set as type rather than fetched as a symbol
    // image: an SF Symbol drawn into a PDF context comes out as a filled
    // rectangle, and a glyph stays a glyph. It is placed by the ink it puts on
    // the page, since the line box around an arrow is mostly air.
    let arrow = NSAttributedString(
        string: "\u{2192}",
        attributes: [.font: NSFont.systemFont(ofSize: 58, weight: .light), .foregroundColor: arrowInk]
    )
    let line = CTLineCreateWithAttributedString(arrow)
    let inked = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    ctx.textPosition = CGPoint(
        x: (iconCentres.app.x + iconCentres.applications.x) / 2 - inked.midX,
        y: y(iconCentres.app.y) - inked.midY)
    CTLineDraw(line, ctx)
}

let page = NSMutableData()
var box = CGRect(x: 0, y: 0, width: width, height: height + bleed)
let ctx = CGContext(consumer: CGDataConsumer(data: page)!, mediaBox: &box, nil)!
ctx.beginPDFPage(nil)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
draw(into: ctx)
NSGraphicsContext.restoreGraphicsState()
ctx.endPDFPage()
ctx.closePDF()

let output = URL(fileURLWithPath: "docs/images/dmg-background.pdf")
try FileManager.default.createDirectory(
    at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
try page.write(to: output)
print("wrote \(output.path)")
