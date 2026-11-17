import Foundation

/// Clipboard search. Mirrors the Windows modes: contains (substring),
/// wildcard (SQL-LIKE style * and ?), and regex. Search targets decide which
/// fields are inspected.
enum SearchMode: String, CaseIterable {
    case contains, wildcard, regex

    var title: String {
        switch self {
        case .contains: return LocalizationManager.shared.text("contains")
        case .wildcard: return LocalizationManager.shared.text("wildcard")
        case .regex: return LocalizationManager.shared.text("regex")
        }
    }
}

struct SearchEngine {
    var mode: SearchMode
    var query: String
    var caseSensitive: Bool = false

    /// Resolve inline `/q ` / `\q ` / `/f ` / `\f ` prefixes the way Windows
    /// Ditto does: quick-paste-only or full-text-only for this one query.
    enum ResolvedTarget {
        case defaultTargets
        case quickPasteOnly
        case fullTextOnly
    }

    var isEmpty: Bool { query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func matches(_ entry: ClipboardEntry, fullTextProvider: (ClipboardEntry) -> String?) -> Bool {
        let resolved = resolveTarget()
        let leadingTrimmed = String(query.drop(while: { $0.isWhitespace }))
        guard leadingTrimmed.isEmpty == false else { return true }
        let stripped = stripPrefix(leadingTrimmed).trimmingCharacters(in: .whitespacesAndNewlines)
        guard stripped.isEmpty == false else { return true }

        switch resolved {
        case .quickPasteOnly:
            return matchString(entry.quickPasteText ?? "", patternText: stripped)
        case .fullTextOnly:
            return matchString(fullTextProvider(entry) ?? entry.text ?? "", patternText: stripped)
        case .defaultTargets:
            var parts: [String] = []
            if DittoSettings.searchDescription {
                if let text = entry.text {
                    parts.append(text)
                } else {
                    parts.append(entry.preview)
                }
                if let fileURLs = entry.fileURLs {
                    parts.append(contentsOf: fileURLs)
                }
            }
            if DittoSettings.searchQuickPaste, let qpt = entry.quickPasteText { parts.append(qpt) }
            if DittoSettings.searchFullText { parts.append(fullTextProvider(entry) ?? "") }
            let haystack = parts.isEmpty ? (entry.text ?? entry.preview) : parts.joined(separator: "\n")
            return matchString(haystack, patternText: stripped)
        }
    }

    private func resolveTarget() -> ResolvedTarget {
        let leadingTrimmed = String(query.drop(while: { $0.isWhitespace }))
        if leadingTrimmed.hasPrefix("/q ") || leadingTrimmed.hasPrefix("\\q ") {
            return .quickPasteOnly
        }
        if leadingTrimmed.hasPrefix("/f ") || leadingTrimmed.hasPrefix("\\f ") {
            return .fullTextOnly
        }
        return .defaultTargets
    }

    private func matchString(_ value: String, patternText trimmed: String) -> Bool {
        switch mode {
        case .contains:
            return value.range(of: trimmed, options: caseSensitive ? [] : [.caseInsensitive, .diacriticInsensitive]) != nil
        case .wildcard:
            var pattern = "(?s)^"
            for char in trimmed {
                switch char {
                case "*": pattern += ".*"
                case "?": pattern += "."
                default: pattern += NSRegularExpression.escapedPattern(for: String(char))
                }
            }
            pattern += "$"
            let options: NSString.CompareOptions = caseSensitive ? [.regularExpression] : [.regularExpression, .caseInsensitive]
            return value.range(of: pattern, options: options) != nil
        case .regex:
            let options: NSString.CompareOptions = (caseSensitive || DittoSettings.regexCaseInsensitive == false)
                ? [.regularExpression]
                : [.regularExpression, .caseInsensitive]
            return value.range(of: trimmed, options: options) != nil
        }
    }

    private func stripPrefix(_ value: String) -> String {
        var result = value
        for prefix in ["/q ", "\\q ", "/f ", "\\f "] where result.hasPrefix(prefix) {
            result = String(result.dropFirst(prefix.count))
        }
        return result
    }
}
