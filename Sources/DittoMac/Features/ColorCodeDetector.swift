import AppKit
import Foundation

/// Detects whether a clip is (only) a colour code and produces the matching
/// `NSColor`. Mirrors the Windows `DrawCopiedColorCode` feature where a clip
/// whose text is a hex colour (#RRGGBB, #RGB, rgb(), etc.) is drawn with a
/// little colour swatch in the list.
enum ColorCodeDetector {
    static func hex(from entry: ClipboardEntry) -> String? {
        guard let text = entry.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              entry.isRichText == false, entry.isHTML == false, entry.isImage == false else {
            return nil
        }
        // The clip must be a *single token* colour value, not arbitrary text.
        guard text.contains(where: { $0.isWhitespace }) == false else { return nil }
        return normalizedHex(text)
    }

    static func color(from hex: String) -> NSColor? {
        guard let normalized = normalizedHex(hex) else { return nil }
        var value = normalized
        if value.hasPrefix("#") { value.removeFirst() }

        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0

        switch value.count {
        case 3:
            if let r = UInt8(String(repeating: value.first!, count: 2), radix: 16),
               let g = UInt8(String(repeating: value.dropFirst().first!, count: 2), radix: 16),
               let b = UInt8(String(repeating: value.dropFirst(2).first!, count: 2), radix: 16) {
                red = CGFloat(r) / 255; green = CGFloat(g) / 255; blue = CGFloat(b) / 255
            } else { return nil }
        case 6:
            guard let int = UInt32(value, radix: 16) else { return nil }
            red = CGFloat((int >> 16) & 0xff) / 255
            green = CGFloat((int >> 8) & 0xff) / 255
            blue = CGFloat(int & 0xff) / 255
        default:
            return nil
        }
        return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    private static func normalizedHex(_ text: String) -> String? {
        let lower = text.lowercased()
        if lower.hasPrefix("#") {
            let rest = String(lower.dropFirst())
            if [3, 6].contains(rest.count), rest.allSatisfy({ $0.isHexDigit }) {
                return "#\(rest)"
            }
        }
        if [3, 6].contains(lower.count), lower.allSatisfy({ $0.isHexDigit }) {
            return "#\(lower)"
        }
        // rgb(r,g,b) / rgba(...) support.
        if lower.hasPrefix("rgb") {
            let stripped = lower
                .replacingOccurrences(of: "rgba", with: "")
                .replacingOccurrences(of: "rgb", with: "")
                .replacingOccurrences(of: "(", with: "")
                .replacingOccurrences(of: ")", with: "")
            let parts = stripped.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count >= 3, parts.allSatisfy({ (0...255).contains($0) }) {
                return String(format: "#%02x%02x%02x", Int(parts[0]), Int(parts[1]), Int(parts[2]))
            }
        }
        return nil
    }
}
