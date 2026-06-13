import AppKit
import Foundation

// Draws a Ditto-style application icon (clipboard + paste arrow) at 1024px
// and writes it as a PNG. The shell wrapper resizes it into an iconset and
// runs `iconutil` to produce AppIcon.icns.

let size = 1024
let image = NSImage(size: NSSize(width: size, height: size))

image.lockFocus()

let bounds = NSRect(x: 0, y: 0, width: size, height: size)
let board = NSBezierPath(roundedRect: NSRect(x: 96, y: 96, width: 832, height: 768), xRadius: 96, yRadius: 96)

// Board shadow
NSColor.black.withAlphaComponent(0.18).setFill()
NSBezierPath(roundedRect: NSRect(x: 120, y: 64, width: 832, height: 768), xRadius: 96, yRadius: 96).fill()

// Board background gradient (slate blue)
let gradient = NSGradient(starting: NSColor(calibratedRed: 0.30, green: 0.45, blue: 0.92, alpha: 1),
                          ending: NSColor(calibratedRed: 0.18, green: 0.30, blue: 0.72, alpha: 1))
gradient?.draw(in: board, angle: -90)

// Paper
let paper = NSBezierPath(roundedRect: NSRect(x: 200, y: 180, width: 624, height: 560), xRadius: 28, yRadius: 28)
NSColor.white.setFill()
paper.fill()

// Lined text placeholder
NSColor(calibratedRed: 0.80, green: 0.85, blue: 0.92, alpha: 1).setFill()
for i in 0..<5 {
    let y = 620 - i * 70
    NSBezierPath(roundedRect: NSRect(x: 248, y: CGFloat(y), width: 480, height: 22), xRadius: 11, yRadius: 11).fill()
}

// Clipboard clip at top
let clipBase = NSBezierPath(roundedRect: NSRect(x: 392, y: 820, width: 240, height: 96), xRadius: 24, yRadius: 24)
NSColor(calibratedRed: 0.55, green: 0.62, blue: 0.72, alpha: 1).setFill()
clipBase.fill()
let clipKnob = NSBezierPath(roundedRect: NSRect(x: 452, y: 860, width: 120, height: 56), xRadius: 18, yRadius: 18)
NSColor(calibratedRed: 0.40, green: 0.47, blue: 0.57, alpha: 1).setFill()
clipKnob.fill()

// Paste arrow (white, pointing down) over the paper
let arrow = NSBezierPath()
let cx: CGFloat = 512
let topY: CGFloat = 560
let arrowWidth: CGFloat = 90
let stemHeight: CGFloat = 150
// stem
arrow.move(to: NSPoint(x: cx - arrowWidth/2, y: topY))
arrow.line(to: NSPoint(x: cx + arrowWidth/2, y: topY))
arrow.line(to: NSPoint(x: cx + arrowWidth/2, y: topY - stemHeight))
arrow.line(to: NSPoint(x: cx + arrowWidth*1.1, y: topY - stemHeight))
arrow.line(to: NSPoint(x: cx, y: topY - stemHeight - 150))
arrow.line(to: NSPoint(x: cx - arrowWidth*1.1, y: topY - stemHeight))
arrow.line(to: NSPoint(x: cx - arrowWidth/2, y: topY - stemHeight))
arrow.close()

// Arrow with a subtle green tint (paste / success)
NSColor(calibratedRed: 0.16, green: 0.74, blue: 0.36, alpha: 1).setFill()
arrow.fill()
NSColor.white.setStroke()
arrow.lineWidth = 6
arrow.stroke()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("Failed to render icon PNG\n".data(using: .utf8)!)
    exit(1)
}

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
try png.write(to: URL(fileURLWithPath: outPath))
print("Wrote \(outPath) (\(png.count) bytes)")
