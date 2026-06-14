import AppKit
import Foundation

// Draws the DMG install background: a soft panel with a large arrow pointing
// from the app icon (left) to the Applications alias (right), like the
// classic "drag to install" layout. Written as a PNG to argv[1].

let w = 660, h = 400
let image = NSImage(size: NSSize(width: w, height: h))
image.lockFocus()

// Background gradient.
let bg = NSGradient(starting: NSColor(calibratedRed: 0.97, green: 0.97, blue: 0.98, alpha: 1),
                    ending: NSColor(calibratedRed: 0.90, green: 0.92, blue: 0.96, alpha: 1))
bg?.draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: -90)

// A large rounded arrow from x=200 -> x=460, centered vertically.
let cy: CGFloat = 200
let arrow = NSBezierPath()
let startX: CGFloat = 210
let endX: CGFloat = 450
let shaftHalf: CGFloat = 26
// shaft
arrow.move(to: NSPoint(x: startX, y: cy - shaftHalf))
arrow.line(to: NSPoint(x: endX - 70, y: cy - shaftHalf))
arrow.line(to: NSPoint(x: endX - 70, y: cy - shaftHalf - 26))
arrow.line(to: NSPoint(x: endX, y: cy))
arrow.line(to: NSPoint(x: endX - 70, y: cy + shaftHalf + 26))
arrow.line(to: NSPoint(x: endX - 70, y: cy + shaftHalf))
arrow.line(to: NSPoint(x: startX, y: cy + shaftHalf))
arrow.close()
NSColor(calibratedRed: 0.30, green: 0.55, blue: 0.95, alpha: 0.85).setFill()
arrow.fill()

// Small caption near the bottom.
let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.boldSystemFont(ofSize: 15),
    .foregroundColor: NSColor(calibratedWhite: 0.25, alpha: 1),
    .paragraphStyle: paragraph,
]
"Drag Ditto to the Applications folder".draw(
    with: NSRect(x: 0, y: 60, width: w, height: 22),
    options: [], attributes: attrs
)

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("failed to render dmg background\n".data(using: .utf8)!)
    exit(1)
}
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "dmg_background.png"
try png.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
