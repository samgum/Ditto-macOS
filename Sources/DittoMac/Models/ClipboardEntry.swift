import Foundation

/// One captured clipboard item, plus its metadata.
///
/// Mirrors the columns of the Windows Ditto `Main` table (lDate, mText,
/// lDontAutoDelete, lShortCut, lastPasteDate, clipOrder, …) while using a
/// UUID primary key and a separate blob store for the heavy format payloads.
struct ClipboardEntry: Codable, Equatable {
    let id: UUID
    var text: String?
    var rtfBlobKey: String?
    var htmlBlobKey: String?
    var imageBlobKey: String?
    var fileURLs: [String]?
    var createdAt: Date
    var lastPasteDate: Date?
    var isFavorite: Bool?
    var neverAutoDelete: Bool
    var quickPasteText: String?
    var clipOrder: Double
    var shortcutKey: Int
    var shortcutGlobal: Bool
    var crc: Int64?
    var sourceApp: String?
    var pasteCount: Int
    var groupId: Int64?

    init(
        id: UUID = UUID(),
        text: String? = nil,
        rtfBlobKey: String? = nil,
        htmlBlobKey: String? = nil,
        imageBlobKey: String? = nil,
        fileURLs: [String]? = nil,
        createdAt: Date = Date(),
        lastPasteDate: Date? = nil,
        isFavorite: Bool? = nil,
        neverAutoDelete: Bool = false,
        quickPasteText: String? = nil,
        clipOrder: Double = Date().timeIntervalSince1970,
        shortcutKey: Int = 0,
        shortcutGlobal: Bool = false,
        crc: Int64? = nil,
        sourceApp: String? = nil,
        pasteCount: Int = 0,
        groupId: Int64? = nil
    ) {
        self.id = id
        self.text = text
        self.rtfBlobKey = rtfBlobKey
        self.htmlBlobKey = htmlBlobKey
        self.imageBlobKey = imageBlobKey
        self.fileURLs = fileURLs
        self.createdAt = createdAt
        self.lastPasteDate = lastPasteDate
        self.isFavorite = isFavorite
        self.neverAutoDelete = neverAutoDelete
        self.quickPasteText = quickPasteText
        self.clipOrder = clipOrder
        self.shortcutKey = shortcutKey
        self.shortcutGlobal = shortcutGlobal
        self.crc = crc
        self.sourceApp = sourceApp
        self.pasteCount = pasteCount
        self.groupId = groupId
    }

    var favorite: Bool { isFavorite ?? false }

    /// A clip is "sticky" (pinned) when either the favorite star or the
    /// never-auto-delete flag is set. In Windows these are two separate
    /// mechanisms; here they collapse into one pinned concept that survives
    /// trimming and sorts to the top.
    var isPinned: Bool { neverAutoDelete || favorite }

    var isImage: Bool { imageBlobKey != nil }
    var isRichText: Bool { rtfBlobKey != nil }
    var isHTML: Bool { htmlBlobKey != nil }
    var isFileDrop: Bool { fileURLs?.isEmpty == false }
    var isText: Bool { text?.isEmpty == false && isRichText == false && isHTML == false }

    var typeLabel: String {
        if isFileDrop { return "Files" }
        if isImage { return "Image" }
        if isRichText { return "RTF" }
        if isHTML { return "HTML" }
        return "Text"
    }

    /// A short hex color string if the clip is (only) a color code, else nil.
    var detectedColorHex: String? { ColorCodeDetector.hex(from: self) }

    var searchableText: String {
        var values: [String] = []
        if let text { values.append(text) }
        if let quickPasteText, quickPasteText.isEmpty == false { values.append(quickPasteText) }
        if let fileURLs { values.append(contentsOf: fileURLs) }
        if let sourceApp { values.append(sourceApp) }
        values.append(typeLabel)
        return values.joined(separator: "\n")
    }

    var preview: String {
        if let fileURLs, fileURLs.isEmpty == false {
            let names = fileURLs.map { URL(fileURLWithPath: $0).lastPathComponent }
            return Self.truncated(names.joined(separator: ", "))
        }
        if let text { return Self.truncated(text) }
        return typeLabel
    }

    static func truncated(_ value: String) -> String {
        let normalized = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > 160 else { return normalized }
        let end = normalized.index(normalized.startIndex, offsetBy: 160)
        return String(normalized[..<end]) + "..."
    }
}

/// A clip group/folder. Supports unlimited nesting through `parentId`.
struct ClipGroup: Codable, Equatable {
    let id: Int64
    var name: String
    var parentId: Int64?
    var sortOrder: Double
    var createdAt: Date

    init(id: Int64 = 0, name: String, parentId: Int64? = nil, sortOrder: Double = Date().timeIntervalSince1970, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.parentId = parentId
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }
}
