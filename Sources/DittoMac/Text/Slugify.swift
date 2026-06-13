import Foundation

/// Pure-string text transforms used by Special Paste. Each function mirrors a
/// transform from the Windows `CSpecialPasteOptions` set.
enum TextTransforms {

    // MARK: - Case

    static func upperCase(_ s: String) -> String { s.uppercased() }

    static func lowerCase(_ s: String) -> String { s.lowercased() }

    static func invertCase(_ s: String) -> String {
        String(s.map { char in
            if char.isUppercase { return Character(char.lowercased()) }
            if char.isLowercase { return Character(char.uppercased()) }
            return char
        })
    }

    /// Title Case — capitalise the first letter of every word.
    static func capitalizeWords(_ s: String) -> String {
        s.capitalized
    }

    /// Sentence case — capitalise the first letter after sentence-ending
    /// punctuation, lowercasing the rest.
    static func sentenceCase(_ s: String) -> String {
        var result = ""
        var capitalizeNext = true
        for char in s {
            if capitalizeNext, char.isLetter {
                result.append(Character(char.uppercased()))
                capitalizeNext = false
            } else {
                result.append(Character(char.lowercased()))
            }
            if ".!?".contains(char) {
                capitalizeNext = true
            } else if char.isWhitespace {
                // keep capitalizeNext as-is so spaces after . capitalise
            } else {
                capitalizeNext = false
            }
        }
        return result
    }

    /// camelCase — remove non-alphanumerics and capitalise each subsequent
    /// word, lowercasing the first.
    static func camelCase(_ s: String) -> String {
        var words: [String] = []
        var current = ""
        for char in s {
            if char.isLetter || char.isNumber {
                current.append(char)
            } else if current.isEmpty == false {
                words.append(current)
                current = ""
            }
        }
        if current.isEmpty == false { words.append(current) }
        guard let first = words.first else { return "" }
        return first.lowercased() + words.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined()
    }

    // MARK: - Line feeds

    static func removeLineFeeds(_ s: String) -> String {
        s.components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
    }

    static func collapseToOneLineFeed(_ s: String) -> String {
        let lines = s.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.isEmpty == false }
        return lines.joined(separator: "\n")
    }

    static func collapseToTwoLineFeeds(_ s: String) -> String {
        let collapsed = collapseToOneLineFeed(s)
        return collapsed.replacingOccurrences(of: "\n", with: "\n\n")
    }

    static func trimWhitespace(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - ASCII

    static func asciiOnly(_ s: String) -> String {
        String(s.unicodeScalars.filter { $0.value < 128 }.map { Character($0) })
    }

    // MARK: - Paths

    /// Convert Windows-style backslash paths to POSIX forward-slash paths.
    static func posixifyPaths(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "/")
    }

    // MARK: - Typoglycemia

    /// Scramble the interior letters of each word while keeping the first and
    /// last letter fixed (the "typoglycemia" internet meme).
    static func typoglycemia(_ s: String) -> String {
        let words = s.components(separatedBy: " ")
        let result = words.map { word -> String in
            scrambleWord(word)
        }
        return result.joined(separator: " ")
    }

    private static func scrambleWord(_ word: String) -> String {
        var chars = Array(word)
        guard chars.count > 3 else { return word }
        let first = chars.first!
        let last = chars.last!
        var middle = Array(chars[1..<chars.count - 1])
        // Fisher-Yates shuffle that ignores non-letters.
        var indices = middle.indices.filter { middle[$0].isLetter }
        guard indices.count > 1 else { return word }
        // Deterministic-ish shuffle without Math.random: use a simple
        // position-based swap so the transform is reproducible per word.
        for i in stride(from: indices.count - 1, through: 1, by: -1) {
            let j = (i * 7 + middle.count * 13) % (i + 1)
            middle.swapAt(indices[i], indices[j])
            indices = middle.indices.filter { middle[$0].isLetter }
        }
        return String(first) + String(middle) + String(last)
    }

    // MARK: - Slugify

    /// URL-friendly slug. Ported from the Windows `Slugify.h` transliteration
    /// map: accents, Greek, Cyrillic, currency and symbol substitution.
    static func slugify(_ input: String, separator: String = "-") -> String {
        var transliterated = ""
        for scalar in input.unicodeScalars {
            transliterated += Slugify.transliterate(scalar)
        }
        let lowered = transliterated.lowercased()
        let allowed = lowered.unicodeScalars.filter { scalar in
            (scalar.value >= 0x30 && scalar.value <= 0x39) // 0-9
                || (scalar.value >= 0x61 && scalar.value <= 0x7A) // a-z
                || scalar == "-"
                || scalar.properties.isWhitespace
        }
        var collapsed = ""
        var previousWasSpace = false
        for scalar in allowed {
            if scalar.properties.isWhitespace {
                if previousWasSpace == false {
                    collapsed += separator
                    previousWasSpace = true
                }
            } else {
                collapsed.unicodeScalars.append(scalar)
                previousWasSpace = false
            }
        }
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: separator))
    }

    // MARK: - GUID

    static func generateGUID() -> String { UUID().uuidString }

    // MARK: - Date/time

    static func appendDateTime(_ s: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return s + (s.isEmpty ? "" : " ") + formatter.string(from: Date())
    }
}
