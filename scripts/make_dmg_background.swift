import AppKit
import Foundation

// Beautified DMG background, using the battle-tested create-dmg layout:
// window 660×400, Ditto.app at {180,200}, Applications at {480,200}. The
// background draws two soft "card" drop-zones (forgiving of icon-position
// interpretation) with a clean arrow between them and a bilingual hint.

let w = 660, h = 400
let image = NSImage(size: NSSize(width: w, height: h))
image.lockFocus()

// Vertical gradient background (Ditto slate-blue).
let bg = NSGradient(colors: [
    NSColor(calibratedRed: 0.93, green: 0.95, blue: 0.99, alpha: 1),
    NSColor(calibratedRed: 0.82, green: 0.87, blue: 0.95, alpha: 1)
])!
bg.draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: -90)

// Full-height card panels so the icon lands inside regardless of Finder's
// vertical-position interpretation. Tall + wide enough to be foolproof.
let cardW: CGFloat = 200
let cardH: CGFloat = 340
let lc = CGPoint(x: 180, y: 200)
let rc = CGPoint(x: 480, y: 200)

func card(at c: CGPoint, fill: NSColor) {
    let r = NSRect(x: c.x - cardW/2, y: c.y - cardH/2, width: cardW, height: cardH)
    let path = NSBezierPath(roundedRect: r, xRadius: 28, yRadius: 28)
    fill.setFill()
    path.fill()
    NSColor.white.withAlphaComponent(0.7).setStroke()
    path.lineWidth = 2
    path.stroke()
}
card(at: lc, fill: NSColor.white.withAlphaComponent(0.5))
card(at: rc, fill: NSColor.white.withAlphaComponent(0.5))

// Thick arrow spanning the gap between the two cards, vertically centered.
let cy: CGFloat = 200
let arr = NSBezierPath()
let s: CGFloat = lc.x + cardW/2 + 6      // just past the left card
let e: CGFloat = rc.x - cardW/2 - 6      // just before the right card
let half: CGFloat = 24
arr.move(to: NSPoint(x: s, y: cy - half))
arr.line(to: NSPoint(x: e - 56, y: cy - half))
arr.line(to: NSPoint(x: e - 56, y: cy - half - 26))
arr.line(to: NSPoint(x: e, y: cy))
arr.line(to: NSPoint(x: e - 56, y: cy + half + 26))
arr.line(to: NSPoint(x: e - 56, y: cy + half))
arr.line(to: NSPoint(x: s, y: cy + half))
arr.close()
NSColor(calibratedRed: 0.22, green: 0.48, blue: 0.92, alpha: 0.92).setFill()
arr.fill()
NSColor.white.withAlphaComponent(0.6).setStroke()
arr.lineWidth = 3
arr.stroke()

// Bilingual hint near the bottom.
let para = NSMutableParagraphStyle()
para.alignment = .center
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.boldSystemFont(ofSize: 16),
    .foregroundColor: NSColor(calibratedWhite: 0.22, alpha: 1),
    .paragraphStyle: para,
]
"Drag Ditto to the Applications folder".draw(
    with: NSRect(x: 0, y: 70, width: w, height: 24),
    options: [], attributes: attrs)
let attrs2: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 14),
    .foregroundColor: NSColor(calibratedWhite: 0.30, alpha: 1),
    .paragraphStyle: para,
]
"把 Ditto 拖到 Applications 文件夹".draw(
    with: NSRect(x: 0, y: 44, width: w, height: 22),
    options: [], attributes: attrs2)

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

