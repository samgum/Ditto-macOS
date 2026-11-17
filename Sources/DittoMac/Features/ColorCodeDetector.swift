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
        return normalizedHex(text)
    }

    static func color(from hex: String) -> NSColor? {
        guard let normalized = normalizedHex(hex) else { return nil }
        var value = normalized
        if value.hasPrefix("#") { value.removeFirst() }

        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 1

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
        case 8:
            guard let int = UInt64(value, radix: 16) else { return nil }
            red = CGFloat((int >> 24) & 0xff) / 255
            green = CGFloat((int >> 16) & 0xff) / 255
            blue = CGFloat((int >> 8) & 0xff) / 255
            alpha = CGFloat(int & 0xff) / 255
        default:
            return nil
        }
        return NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    private static func normalizedHex(_ text: String) -> String? {
        let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard lower.contains("\n") == false, lower.contains("\r") == false else { return nil }
        if lower.hasPrefix("#") {
            let rest = String(lower.dropFirst())
            if [3, 6, 8].contains(rest.count), rest.allSatisfy({ $0.isHexDigit }) {
                return "#\(rest)"
            }
            return nil
        }
        // rgb(r, g, b) / rgba(r, g, b, a) support (including standard CSS spaces).
        let inner: Substring?
        if lower.hasPrefix("rgba("), lower.hasSuffix(")") {
            inner = lower.dropFirst(5).dropLast()
        } else if lower.hasPrefix("rgb("), lower.hasSuffix(")") {
            inner = lower.dropFirst(4).dropLast()
        } else {
            inner = nil
        }
        if let inner {
            let rawParts = inner.split(separator: ",", omittingEmptySubsequences: false)
            guard rawParts.count == 3 || rawParts.count == 4 else { return nil }
            let parts = rawParts.compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == rawParts.count,
                  parts.prefix(3).allSatisfy({ (0...255).contains($0) }) else {
                return nil
            }
            if parts.count == 4 {
                guard (0...1).contains(parts[3]) else { return nil }
                let a = Int((parts[3] * 255.0).rounded())
                if a < 255 {
                    return String(format: "#%02x%02x%02x%02x", Int(parts[0]), Int(parts[1]), Int(parts[2]), a)
                }
            }
            return String(format: "#%02x%02x%02x", Int(parts[0]), Int(parts[1]), Int(parts[2]))
        }
        return nil
    }
}
