import AppKit
import Foundation

/// A set of paste-time transformations. Mirrors `CSpecialPasteOptions` in the
/// Windows source: a bag of booleans plus an optional image-render request.
struct SpecialPasteOptions {
    var pasteAsPlainText = false
    var upperCase = false
    var lowerCase = false
    var capitalize = false
    var sentenceCase = false
    var camelCase = false
    var invertCase = false
    var removeLineFeeds = false
    var addOneLineFeed = false
    var addTwoLineFeeds = false
    var typoglycemia = false
    var trimWhiteSpace = false
    var posixifyPaths = false
    var slugify = false
    var asciiOnly = false
    var appendDateTime = false
    var generateGuid = false
    var pasteAsImage = false
    var pasteImagesHorizontal = false
    var pasteImagesVertically = false

    /// True if any flag is set that turns the clip into plain text only.
    var limitsFormatsToText: Bool {
        upperCase || lowerCase || capitalize || sentenceCase || camelCase || invertCase
            || removeLineFeeds || addOneLineFeed || addTwoLineFeeds || typoglycemia
            || trimWhiteSpace || posixifyPaths || slugify || asciiOnly || appendDateTime
            || generateGuid || pasteAsPlainText
    }

    /// Apply the transforms to a clip, returning a paste-ready snapshot. The
    /// blob reader closure decodes stored RTF/HTML/image payloads lazily.
    struct Result {
        var text: String?
        var rtfBlobKey: String?
        var htmlBlobKey: String?
        var imageBlobKey: String?
        var pdfBlobKey: String?
        var fileURLs: [String]?
        var stripFormatting: Bool
        var imageRepresentation: Data?
    }

    func apply(to entry: ClipboardEntry, blobReader: (String) -> Data?) -> Result {
        if generateGuid {
            return Result(
                text: TextTransforms.generateGUID(),
                rtfBlobKey: nil, htmlBlobKey: nil, imageBlobKey: nil, pdfBlobKey: nil, fileURLs: nil,
                stripFormatting: true, imageRepresentation: nil
            )
        }

        var text = entry.text
        var stripFormatting = pasteAsPlainText
        var imageRepresentation: Data? = nil

        // Mutually-exclusive text transform — mirrors Windows OleClipSource's
        // else-if chain: exactly ONE mutation runs, in this priority order.
        if limitsFormatsToText, let sourceText = text ?? plainText(from: entry, blobReader: blobReader) {
            var transformed = sourceText
            if removeLineFeeds {
                transformed = TextTransforms.removeLineFeeds(transformed)
            } else if addOneLineFeed {
                transformed = TextTransforms.collapseToOneLineFeed(transformed)
            } else if addTwoLineFeeds {
                transformed = TextTransforms.collapseToTwoLineFeeds(transformed)
            } else if upperCase {
                transformed = TextTransforms.upperCase(transformed)
            } else if lowerCase {
                transformed = TextTransforms.lowerCase(transformed)
            } else if invertCase {
                transformed = TextTransforms.invertCase(transformed)
            } else if capitalize {
                transformed = TextTransforms.capitalizeWords(transformed)
            } else if sentenceCase {
                transformed = TextTransforms.sentenceCase(transformed)
            } else if camelCase {
                transformed = TextTransforms.camelCase(transformed)
            } else if typoglycemia {
                transformed = TextTransforms.typoglycemia(transformed)
            } else if trimWhiteSpace {
                transformed = TextTransforms.trimWhitespace(transformed)
            } else if asciiOnly {
                transformed = TextTransforms.asciiOnly(transformed)
            } else if posixifyPaths {
                transformed = TextTransforms.posixifyPaths(transformed)
            } else if slugify {
                transformed = TextTransforms.slugify(transformed, separator: DittoSettings.slugifySeparator)
            } else if appendDateTime {
                transformed = TextTransforms.appendDateTime(transformed)
            }
            text = transformed
            stripFormatting = true
        }

        // Paste-as-image: Windows treats the clip text as an image FILE PATH
        // and loads the image bytes; fall back to rendering the text only when
        // it isn't a path to an existing image.
        if pasteAsImage, let finalText = text {
            if let imageData = ImageFileLoader.png(fromPath: finalText.trimmingCharacters(in: .whitespacesAndNewlines)) {
                imageRepresentation = imageData
            } else {
                imageRepresentation = ImageTextRenderer.png(from: finalText)
            }
            text = nil
            stripFormatting = true
        }

        return Result(
            text: text,
            rtfBlobKey: stripFormatting ? nil : entry.rtfBlobKey,
            htmlBlobKey: stripFormatting ? nil : entry.htmlBlobKey,
            imageBlobKey: pasteAsImage ? nil : entry.imageBlobKey,
            pdfBlobKey: stripFormatting ? nil : entry.pdfBlobKey,
            fileURLs: limitsFormatsToText ? nil : entry.fileURLs,
            stripFormatting: stripFormatting,
            imageRepresentation: imageRepresentation
        )
    }

    /// Extract plain text from RTF/HTML payloads when the entry has no plain
    /// text component of its own.
    private func plainText(from entry: ClipboardEntry, blobReader: (String) -> Data?) -> String? {
        if let key = entry.rtfBlobKey, let data = blobReader(key),
           let rtf = RTFTextExtractor.string(from: data) {
            return rtf
        }
        if let key = entry.htmlBlobKey, let data = blobReader(key) {
            return HTMLTextExtractor.string(from: data)
        }
        return nil
    }
}

/// Best-effort plain-text extraction from RTF data.
enum RTFTextExtractor {
    static func string(from data: Data) -> String? {
        guard let attributed = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) else {
            return nil
        }
        return attributed.string
    }
}

/// Best-effort plain-text extraction from HTML data.
enum HTMLTextExtractor {
    static func string(from data: Data) -> String? {
        guard let attributed = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil) else {
            return nil
        }
        return attributed.string
    }
}

/// Loads an image file from a path string and returns its PNG bytes, for the
/// Windows-compatible "paste as image" transform (which treats the clip text
/// as a file path).
enum ImageFileLoader {
    static func png(fromPath path: String) -> Data? {
        let url: URL
        if path.hasPrefix("/") || path.hasPrefix("~") {
            let expanded = (path as NSString).expandingTildeInPath
            url = URL(fileURLWithPath: expanded)
        } else if let parsed = URL(string: path), parsed.isFileURL {
            url = parsed
        } else {
            return nil
        }
        guard FileManager.default.fileExists(atPath: url.path),
              let image = NSImage(contentsOf: url) else {
            return nil
        }
        return NSImage.pngData(image)
    }
}

extension NSImage {
    static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

/// Renders a block of text into a PNG (for the "paste as image" transform).
enum ImageTextRenderer {
    static func png(from text: String) -> Data? {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.black
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let maxWidth: CGFloat = 800
        let bounding = attributed.boundingRect(with: NSSize(width: maxWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
        let size = NSSize(width: ceil(bounding.width) + 24, height: ceil(bounding.height) + 24)
        guard size.width > 0, size.height > 0 else { return nil }

        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        attributed.draw(in: NSRect(x: 12, y: 12, width: size.width - 24, height: size.height - 24))
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
