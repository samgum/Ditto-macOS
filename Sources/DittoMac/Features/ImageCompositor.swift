import AppKit
import Foundation

/// Combines several clip images into a single image, tiled horizontally or
/// stacked vertically — the macOS equivalent of the Windows
/// `CImageFormatAggregator(m_pasteImagesHorizontal)` multi-image paste.
enum ImageCompositor {
    static func combine(images: [NSImage], horizontal: Bool) -> NSImage? {
        let valid = images.filter { $0.isValid && $0.size.width > 0 && $0.size.height > 0 }
        guard valid.isEmpty == false else { return nil }

        let totalWidth = horizontal ? valid.reduce(0) { $0 + $1.size.width } : valid.map(\.size.width).max() ?? 0
        let totalHeight = horizontal ? valid.map(\.size.height).max() ?? 0 : valid.reduce(0) { $0 + $1.size.height }

        let size = NSSize(width: totalWidth, height: totalHeight)
        let combined = NSImage(size: size)
        combined.lockFocus()

        var originX: CGFloat = 0
        var originY: CGFloat = 0
        for image in valid {
            let drawRect: NSRect
            if horizontal {
                drawRect = NSRect(x: originX, y: 0, width: image.size.width, height: image.size.height)
                originX += image.size.width
            } else {
                // Stack bottom-up so the first image ends up on top.
                drawRect = NSRect(x: 0, y: totalHeight - originY - image.size.height, width: image.size.width, height: image.size.height)
                originY += image.size.height
            }
            image.draw(in: drawRect)
        }
        combined.unlockFocus()
        return combined
    }
}
