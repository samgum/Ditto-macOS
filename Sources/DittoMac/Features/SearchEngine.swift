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
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return true }

        switch resolved {
        case .quickPasteOnly:
            return matchString(entry.quickPasteText ?? "")
        case .fullTextOnly:
            return matchString(fullTextProvider(entry) ?? entry.text ?? "")
        case .defaultTargets:
            var haystack = ""
            if DittoSettings.searchDescription { haystack += (entry.text ?? "") + "\n" }
            if DittoSettings.searchQuickPaste { haystack += (entry.quickPasteText ?? "") + "\n" }
            if DittoSettings.searchFullText { haystack += (fullTextProvider(entry) ?? "") + "\n" }
            if haystack.isEmpty {
                // No target enabled — fall back to the description text.
                haystack = entry.text ?? ""
            }
            return matchString(haystack)
        }
    }

    private func resolveTarget() -> ResolvedTarget {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/q ") || trimmed.hasPrefix("\\q ") {
            return .quickPasteOnly
        }
        if trimmed.hasPrefix("/f ") || trimmed.hasPrefix("\\f ") {
            return .fullTextOnly
        }
        return .defaultTargets
    }

    private func matchString(_ value: String) -> Bool {
        let trimmed = stripPrefix(query.trimmingCharacters(in: .whitespacesAndNewlines))
        switch mode {
        case .contains:
            return value.range(of: trimmed, options: caseSensitive ? [] : [.caseInsensitive, .diacriticInsensitive]) != nil
        case .wildcard:
            let pattern = "^" + NSRegularExpression.escapedPattern(for: trimmed)
                .replacingOccurrences(of: "\\*", with: ".*")
                .replacingOccurrences(of: "\\?", with: ".") + "$"
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
