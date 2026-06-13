import Foundation

/// Centralised, UserDefaults-backed settings. Names and defaults mirror the
/// Windows Ditto registry/INI options (`CGetSetOptions`) so the behaviour
/// matches the original as closely as possible.
enum DittoSettings {
    private static let defaults = UserDefaults.standard

    // MARK: - Keys

    private enum Key {
        static let language = "Ditto.Language"
        static let maxHistory = "Ditto.MaxHistory"
        static let hotKey = "Ditto.HotKey"
        static let pollInterval = "Ditto.PollIntervalSeconds"
        static let allowDuplicates = "Ditto.AllowDuplicates"
        static let allowBackToBackDuplicates = "Ditto.AllowBackToBackDuplicates"
        static let updateTimeOnPaste = "Ditto.UpdateTimeOnPaste"
        static let hideOnPaste = "Ditto.HideDittoOnPaste"
        static let promptWhenDeleting = "Ditto.PromptWhenDeleting"
        static let playSoundOnCopy = "Ditto.PlaySoundOnCopy"
        static let showStartupMessage = "Ditto.ShowStartupMessage"

        // expiry
        static let checkExpired = "Ditto.CheckForExpiredEntries"
        static let expiredDays = "Ditto.ExpiredEntries"
        static let maxClipSizeBytes = "Ditto.MaxClipSizeInBytes"

        // appearance
        static let themeName = "Ditto.Theme2"
        static let fontSize = "Ditto.FontSize"
        static let linesPerRow = "Ditto.LinesPerRow"
        static let drawThumbnails = "Ditto.DrawThumbnail"
        static let pasteAsPlainTextByDefault = "Ditto.PasteAsPlainTextDefault"

        // window chrome
        static let alwaysOnTop = "Ditto.AlwaysOnTop"
        static let transparencyPercent = "Ditto.TransparencyPercent"
        static let showFirstTenText = "Ditto.ShowFirstTenText"
        static let windowPositioning = "Ditto.WindowPositioning"

        // search
        static let searchDescription = "Ditto.SearchDescription"
        static let searchFullText = "Ditto.SearchFullText"
        static let searchQuickPaste = "Ditto.SearchQuickPaste"
        static let regexSearch = "Ditto.RegExTextSearch"
        static let regexCaseInsensitive = "Ditto.RegexCaseInsensitive"

        // app filtering
        static let copyAppInclude = "Ditto.CopyAppInclude"
        static let copyAppExclude = "Ditto.CopyAppExclude"
        static let copyAppSeparator = "Ditto.CopyAppSeparator"

        // multi-paste
        static let multiPasteSeparator = "Ditto.MultiPasteSeparator"
        static let multiPasteReverse = "Ditto.MultiPasteReverse"
        static let saveMultiPaste = "Ditto.SaveMultiPaste"

        // slugify
        static let slugifySeparator = "Ditto.SlugifySeparator"

        // network
        static let sendRecvPort = "Ditto.SendRecvPort"
        static let networkPassword = "Ditto.NetworkStringPassword"
        static let disableReceive = "Ditto.DisableRecieve"
        static let allowFriends = "Ditto.AllowFriends"
        static let showReceivedClipNotification = "Ditto.ShowMsgWhenReceivingManualSentClip"

        // external
        static let diffApp = "Ditto.DiffApp"
        static let textEditorPath = "Ditto.TextEditorPath"
        static let imageEditorPath = "Ditto.ImageEditorPath"
        static let translateUrl = "Ditto.TranslateUrl"
        static let webSearchUrl = "Ditto.WebSearchUrl"
        static let qrCodeBorderPixels = "Ditto.QRCodeBorderPixels"
    }

    // MARK: - General / Limits

    static let maxHistoryOptions = [100, 500, 1_000, 2_000, 5_000]

    static var maxHistoryEntries: Int {
        get {
            let value = defaults.integer(forKey: Key.maxHistory)
            return maxHistoryOptions.contains(value) ? value : 500
        }
        set { defaults.set(newValue, forKey: Key.maxHistory) }
    }

    static var pollIntervalSeconds: Double {
        get { max(0.1, defaults.object(forKey: Key.pollInterval) as? Double ?? 0.5) }
        set { defaults.set(newValue, forKey: Key.pollInterval) }
    }

    static var allowDuplicates: Bool {
        get { defaults.bool(forKey: Key.allowDuplicates) }
        set { defaults.set(newValue, forKey: Key.allowDuplicates) }
    }

    static var allowBackToBackDuplicates: Bool {
        get { defaults.bool(forKey: Key.allowBackToBackDuplicates) }
        set { defaults.set(newValue, forKey: Key.allowBackToBackDuplicates) }
    }

    static var updateTimeOnPaste: Bool {
        get { defaults.object(forKey: Key.updateTimeOnPaste) == nil ? true : defaults.bool(forKey: Key.updateTimeOnPaste) }
        set { defaults.set(newValue, forKey: Key.updateTimeOnPaste) }
    }

    static var hideDittoOnPaste: Bool {
        get { defaults.object(forKey: Key.hideOnPaste) == nil ? true : defaults.bool(forKey: Key.hideOnPaste) }
        set { defaults.set(newValue, forKey: Key.hideOnPaste) }
    }

    /// Put the user's previous clipboard back after pasting a Ditto clip, so
    /// Ditto doesn't clobber what they had copied (Windows
    /// RestoreClipboardDelay behaviour, default on).
    static var restoreClipboardAfterPaste: Bool {
        get { defaults.object(forKey: "Ditto.RestoreClipboardAfterPaste") == nil ? true : defaults.bool(forKey: "Ditto.RestoreClipboardAfterPaste") }
        set { defaults.set(newValue, forKey: "Ditto.RestoreClipboardAfterPaste") }
    }

    static var showSaveNotification: Bool {
        get { defaults.bool(forKey: "Ditto.ShowSaveNotification") }
        set { defaults.set(newValue, forKey: "Ditto.ShowSaveNotification") }
    }

    static var refreshAfterPaste: Bool {
        get { defaults.object(forKey: "Ditto.RefreshViewAfterPasting") == nil ? true : defaults.bool(forKey: "Ditto.RefreshViewAfterPasting") }
        set { defaults.set(newValue, forKey: "Ditto.RefreshViewAfterPasting") }
    }

    static var moveSelectionOnOpen: Bool {
        get { defaults.object(forKey: "Ditto.MoveSelectionOnOpenHotkey") == nil ? true : defaults.bool(forKey: "Ditto.MoveSelectionOnOpenHotkey") }
        set { defaults.set(newValue, forKey: "Ditto.MoveSelectionOnOpenHotkey") }
    }

    static var promptWhenDeleting: Bool {
        get { defaults.object(forKey: Key.promptWhenDeleting) == nil ? true : defaults.bool(forKey: Key.promptWhenDeleting) }
        set { defaults.set(newValue, forKey: Key.promptWhenDeleting) }
    }

    static var playSoundOnCopy: Bool {
        get { defaults.bool(forKey: Key.playSoundOnCopy) }
        set { defaults.set(newValue, forKey: Key.playSoundOnCopy) }
    }

    static var showStartupMessage: Bool {
        get { defaults.object(forKey: Key.showStartupMessage) == nil ? false : defaults.bool(forKey: Key.showStartupMessage) }
        set { defaults.set(newValue, forKey: Key.showStartupMessage) }
    }

    // MARK: - Expiry

    static var checkExpiredEntries: Bool {
        get { defaults.bool(forKey: Key.checkExpired) }
        set { defaults.set(newValue, forKey: Key.checkExpired) }
    }

    static var expiredEntriesDays: Int {
        get { max(1, defaults.object(forKey: Key.expiredDays) as? Int ?? 5) }
        set { defaults.set(newValue, forKey: Key.expiredDays) }
    }

    static var maxClipSizeBytes: Int {
        // 0 = unlimited, matches Windows default.
        get { max(0, defaults.object(forKey: Key.maxClipSizeBytes) as? Int ?? 0) }
        set { defaults.set(newValue, forKey: Key.maxClipSizeBytes) }
    }

    // MARK: - Appearance

    static var themeName: String {
        get { defaults.string(forKey: Key.themeName) ?? "system" }
        set { defaults.set(newValue, forKey: Key.themeName) }
    }

    static var fontSize: Int {
        get { max(10, defaults.object(forKey: Key.fontSize) as? Int ?? 13) }
        set { defaults.set(newValue, forKey: Key.fontSize) }
    }

    static var linesPerRow: Int {
        get { max(1, defaults.object(forKey: Key.linesPerRow) as? Int ?? 2) }
        set { defaults.set(newValue, forKey: Key.linesPerRow) }
    }

    static var drawThumbnails: Bool {
        get { defaults.object(forKey: Key.drawThumbnails) == nil ? true : defaults.bool(forKey: Key.drawThumbnails) }
        set { defaults.set(newValue, forKey: Key.drawThumbnails) }
    }

    static var pasteAsPlainTextByDefault: Bool {
        get { defaults.bool(forKey: Key.pasteAsPlainTextByDefault) }
        set { defaults.set(newValue, forKey: Key.pasteAsPlainTextByDefault) }
    }

    // MARK: - Window chrome

    static var alwaysOnTop: Bool {
        get { defaults.bool(forKey: Key.alwaysOnTop) }
        set { defaults.set(newValue, forKey: Key.alwaysOnTop) }
    }

    static var transparencyPercent: Double {
        get {
            let stored = defaults.object(forKey: Key.transparencyPercent) as? Double ?? 0
            return min(40, max(0, stored))
        }
        set { defaults.set(min(40, max(0, newValue)), forKey: Key.transparencyPercent) }
    }

    static var showFirstTenText: Bool {
        get { defaults.bool(forKey: Key.showFirstTenText) }
        set { defaults.set(newValue, forKey: Key.showFirstTenText) }
    }

    enum WindowPositioning: String, CaseIterable {
        case atCursor, previousPosition
        var title: String { self == .atCursor ? "Cursor" : "Previous" }
    }

    static var windowPositioning: WindowPositioning {
        get { WindowPositioning(rawValue: defaults.string(forKey: Key.windowPositioning) ?? "previousPosition") ?? .previousPosition }
        set { defaults.set(newValue.rawValue, forKey: Key.windowPositioning) }
    }

    /// The 10 global "paste position N" hot keys (1-based). Stored as the
    /// `HotKey.encoded` Int64; `nil` means unassigned (disabled), matching the
    /// Windows default for the first-ten paste accelerators.
    static var firstTenGlobalHotKeys: [HotKey?] {
        get {
            let stored = defaults.array(forKey: "Ditto.FirstTenHotKeys") as? [Int64] ?? []
            var result: [HotKey?] = Array(repeating: nil, count: 10)
            for index in 0..<10 {
                if index < stored.count, let hotKey = HotKey.decode(stored[index]) {
                    result[index] = hotKey
                }
            }
            return result
        }
        set {
            let raw = newValue.map { $0?.encoded ?? 0 }
            defaults.set(raw, forKey: "Ditto.FirstTenHotKeys")
        }
    }

    // MARK: - Search

    static var searchDescription: Bool {
        get { defaults.object(forKey: Key.searchDescription) == nil ? true : defaults.bool(forKey: Key.searchDescription) }
        set { defaults.set(newValue, forKey: Key.searchDescription) }
    }

    static var searchFullText: Bool {
        get { defaults.bool(forKey: Key.searchFullText) }
        set { defaults.set(newValue, forKey: Key.searchFullText) }
    }

    static var searchQuickPaste: Bool {
        get { defaults.bool(forKey: Key.searchQuickPaste) }
        set { defaults.set(newValue, forKey: Key.searchQuickPaste) }
    }

    static var regexSearch: Bool {
        get { defaults.bool(forKey: Key.regexSearch) }
        set { defaults.set(newValue, forKey: Key.regexSearch) }
    }

    static var regexCaseInsensitive: Bool {
        get { defaults.object(forKey: Key.regexCaseInsensitive) == nil ? true : defaults.bool(forKey: Key.regexCaseInsensitive) }
        set { defaults.set(newValue, forKey: Key.regexCaseInsensitive) }
    }

    // MARK: - App filtering

    static var copyAppInclude: String {
        get { defaults.string(forKey: Key.copyAppInclude) ?? "*" }
        set { defaults.set(newValue, forKey: Key.copyAppInclude) }
    }

    static var copyAppExclude: String {
        get { defaults.string(forKey: Key.copyAppExclude) ?? "" }
        set { defaults.set(newValue, forKey: Key.copyAppExclude) }
    }

    static var copyAppSeparator: String {
        get { defaults.string(forKey: Key.copyAppSeparator) ?? ";" }
        set { defaults.set(newValue, forKey: Key.copyAppSeparator) }
    }

    /// True when `bundleId` (or `*`) is allowed to be captured.
    static func shouldCapture(bundleId: String?) -> Bool {
        let excludes = tokens(copyAppExclude)
        if let bundleId, excludes.contains(where: { match(bundleId, against: $0) }) {
            return false
        }
        let includes = tokens(copyAppInclude)
        if includes.contains("*") || includes.isEmpty { return true }
        guard let bundleId else { return false }
        return includes.contains(where: { match(bundleId, against: $0) })
    }

    private static func tokens(_ raw: String) -> [String] {
        raw.components(separatedBy: copyAppSeparator)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
    }

    private static func match(_ value: String, against pattern: String) -> Bool {
        // Simple glob: * matches anything, ? matches one char.
        let regex = "^" + NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\?", with: ".") + "$"
        return value.range(of: regex, options: .regularExpression) != nil
    }

    // MARK: - Multi-paste

    static var multiPasteSeparator: String {
        get { defaults.string(forKey: Key.multiPasteSeparator) ?? "[LF]" }
        set { defaults.set(newValue, forKey: Key.multiPasteSeparator) }
    }

    /// Resolves the `[LF]` / `[CR]` / `[TAB]` style markers to real characters.
    static func resolveMultiPasteSeparator() -> String {
        multiPasteSeparator
            .replacingOccurrences(of: "[LF]", with: "\n")
            .replacingOccurrences(of: "[CR]", with: "\r")
            .replacingOccurrences(of: "[CRLF]", with: "\r\n")
            .replacingOccurrences(of: "[TAB]", with: "\t")
            .replacingOccurrences(of: "[SPACE]", with: " ")
    }

    static var multiPasteReverse: Bool {
        get { defaults.object(forKey: Key.multiPasteReverse) == nil ? true : defaults.bool(forKey: Key.multiPasteReverse) }
        set { defaults.set(newValue, forKey: Key.multiPasteReverse) }
    }

    static var saveMultiPaste: Bool {
        get { defaults.bool(forKey: Key.saveMultiPaste) }
        set { defaults.set(newValue, forKey: Key.saveMultiPaste) }
    }

    // MARK: - Slugify

    static var slugifySeparator: String {
        get { defaults.string(forKey: Key.slugifySeparator) ?? "-" }
        set { defaults.set(newValue, forKey: Key.slugifySeparator) }
    }

    // MARK: - Network

    static var sendRecvPort: Int {
        get { defaults.object(forKey: Key.sendRecvPort) as? Int ?? 23443 }
        set { defaults.set(newValue, forKey: Key.sendRecvPort) }
    }

    static var networkPassword: String {
        get { defaults.string(forKey: Key.networkPassword) ?? "LetMeIn" }
        set { defaults.set(newValue, forKey: Key.networkPassword) }
    }

    static var disableReceive: Bool {
        get { defaults.bool(forKey: Key.disableReceive) }
        set { defaults.set(newValue, forKey: Key.disableReceive) }
    }

    static var allowFriends: Bool {
        get { defaults.object(forKey: Key.allowFriends) == nil ? true : defaults.bool(forKey: Key.allowFriends) }
        set { defaults.set(newValue, forKey: Key.allowFriends) }
    }

    static var showReceivedClipNotification: Bool {
        get { defaults.object(forKey: Key.showReceivedClipNotification) == nil ? true : defaults.bool(forKey: Key.showReceivedClipNotification) }
        set { defaults.set(newValue, forKey: Key.showReceivedClipNotification) }
    }

    // MARK: - External tools

    static var diffApp: String {
        get { defaults.string(forKey: Key.diffApp) ?? "" }
        set { defaults.set(newValue, forKey: Key.diffApp) }
    }

    static var textEditorPath: String {
        get { defaults.string(forKey: Key.textEditorPath) ?? "" }
        set { defaults.set(newValue, forKey: Key.textEditorPath) }
    }

    static var imageEditorPath: String {
        get { defaults.string(forKey: Key.imageEditorPath) ?? "" }
        set { defaults.set(newValue, forKey: Key.imageEditorPath) }
    }

    static var translateUrl: String {
        get { defaults.string(forKey: Key.translateUrl) ?? "https://translate.google.com/?text=%s" }
        set { defaults.set(newValue, forKey: Key.translateUrl) }
    }

    static var webSearchUrl: String {
        get { defaults.string(forKey: Key.webSearchUrl) ?? "https://www.google.com/search?q=%s" }
        set { defaults.set(newValue, forKey: Key.webSearchUrl) }
    }

    static var qrCodeBorderPixels: Int {
        get { max(0, defaults.object(forKey: Key.qrCodeBorderPixels) as? Int ?? 30) }
        set { defaults.set(newValue, forKey: Key.qrCodeBorderPixels) }
    }
}
