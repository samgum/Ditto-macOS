import AppKit
import CoreImage
import Foundation

/// Generates a QR code image from text using CoreImage's `CIQRCodeGenerator`,
/// scaled up and optionally bordered — the macOS equivalent of the Windows
/// `CreateQRCodeImage` (which shells out to libqrencode).
enum QRCodeGenerator {
    static func image(from text: String, borderPixels: Int = DittoSettings.qrCodeBorderPixels, moduleSize: CGFloat = 10) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(text.data(using: .utf8), forKey: "inputMessage")
        // High error-correction to match QR_ECLEVEL_H.
        filter.setValue("H", forKey: "inputCorrectionLevel")

        guard let outputImage = filter.outputImage else { return nil }
        let transformed = outputImage.transformed(by: CGAffineTransform(scaleX: moduleSize, y: moduleSize))
        let rep = NSCIImageRep(ciImage: transformed)
        let qrImage = NSImage(size: rep.size)
        qrImage.addRepresentation(rep)

        if borderPixels > 0 {
            return withBorder(qrImage, border: borderPixels)
        }
        return qrImage
    }

    private static func withBorder(_ image: NSImage, border: Int) -> NSImage {
        let inset = CGFloat(border)
        let size = NSSize(width: image.size.width + inset * 2, height: image.size.height + inset * 2)
        let composited = NSImage(size: size)
        composited.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        image.draw(in: NSRect(x: inset, y: inset, width: image.size.width, height: image.size.height))
        composited.unlockFocus()
        return composited
    }
}
