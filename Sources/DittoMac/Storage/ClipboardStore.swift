import AppKit
import Foundation

/// High-level clipboard history store. Wraps `MacClipboardDatabase` and adds
/// the behavioural rules from Windows Ditto: dedup, expiry, trimming, pinned
/// clips, paste-counting, groups, and copy buffers.
final class ClipboardStore {
    private let legacyFileURL: URL
    private let legacyDataDirectory: URL
    private let database: MacClipboardDatabase
    private(set) var entries: [ClipboardEntry] = []
    private(set) var groups: [ClipGroup] = []

    private let queue = DispatchQueue(label: "org.ditto-cp.DittoMac.store", qos: .userInitiated)

    /// Serializes ALL access to `entries` / `groups`. The in-memory arrays are
    /// mutated on background threads (clipboard poll queue, sync queue) while
    /// the main thread iterates them for the table — a concurrent insert/sort
    /// during iteration is a data race that EXC_BAD_ACCESSes (same bug class as
    /// the sqlite connection). Recursive so nested internal calls are safe.
    private let lock = NSRecursiveLock()

    /// A copy of the entries for off-thread readers (Array is COW, so this is
    /// a cheap snapshot taken under the lock).
    func snapshotEntries() -> [ClipboardEntry] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    func snapshotGroups() -> [ClipGroup] {
        lock.lock(); defer { lock.unlock() }
        return groups
    }

    init(databaseURL: URL? = nil) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = appSupport.appendingPathComponent("Ditto", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        legacyFileURL = directory.appendingPathComponent("history.json")
        legacyDataDirectory = directory.appendingPathComponent("Data", isDirectory: true)
        let url = databaseURL ?? directory.appendingPathComponent("Ditto.db")
        // Recover from a corrupt database instead of crashing on launch: if
        // the DB can't be opened, quarantine it and start fresh.
        if let opened = try? MacClipboardDatabase(url: url) {
            database = opened
        } else {
            let corrupt = url.deletingPathExtension().appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).db")
            try? FileManager.default.moveItem(at: url, to: corrupt)
            NSLog("[Ditto] database was unreadable; moved to \(corrupt.lastPathComponent) and starting fresh.")
            // try! here is safe: the file no longer exists (moved), so a fresh
            // create can only fail on a truly unwritable disk.
            database = try! MacClipboardDatabase(url: url)
        }
        load()
        migrateLegacyJSONIfNeeded()
        enforceExpiry()
    }

    // MARK: - Capture

    func addClipboardPayload(
        text: String?,
        rtfData: Data?,
        htmlData: Data?,
        imageData: Data?,
        fileURLs: [URL],
        sourceApp: String? = nil
    ) {
        lock.lock(); defer { lock.unlock() }
        let normalizedText = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = fileURLs.map { $0.path }

        guard
            normalizedText?.isEmpty == false ||
            rtfData?.isEmpty == false ||
            htmlData?.isEmpty == false ||
            imageData?.isEmpty == false ||
            files.isEmpty == false
        else {
            return
        }

        // Enforce max clip size (0 = unlimited).
        let maxSize = DittoSettings.maxClipSizeBytes
        if maxSize > 0 {
            let textSize = normalizedText?.utf8.count ?? 0
            let rtfSize = rtfData?.count ?? 0
            let htmlSize = htmlData?.count ?? 0
            let imageSize = imageData?.count ?? 0
            let totalSize = textSize + rtfSize + htmlSize + imageSize
            if totalSize > maxSize {
                return
            }
        }

        // Back-to-back duplicate suppression.
        if let first = entries.first,
           first.text == text,
           first.fileURLs == files,
           (files.isEmpty == false || text != nil),
           DittoSettings.allowBackToBackDuplicates == false {
            return
        }

        // Global duplicate suppression.
        if DittoSettings.allowDuplicates == false, let text {
            removeEntries { $0.text == text && $0.fileURLs == files && !$0.isPinned }
        }

        let rtfBlobKey = saveBlob(rtfData, fileExtension: "rtf")
        let htmlBlobKey = saveBlob(htmlData, fileExtension: "html")
        let imageBlobKey = saveBlob(imageData, fileExtension: "png")

        let entry = ClipboardEntry(
            id: UUID(),
            text: text,
            rtfBlobKey: rtfBlobKey,
            htmlBlobKey: htmlBlobKey,
            imageBlobKey: imageBlobKey,
            fileURLs: files.isEmpty ? nil : files,
            createdAt: Date(),
            crc: CRC32.checksum(Data((normalizedText ?? "").utf8)),
            sourceApp: sourceApp
        )

        entries.insert(entry, at: 0)
        // Pinned clips always sit above the newest non-pinned clip.
        repinOrdering()
        trim()
        persist()
    }

    // MARK: - Lookups

    func entry(id: UUID) -> ClipboardEntry? {
        lock.lock(); defer { lock.unlock() }
        return entries.first { $0.id == id }
    }

    func update(_ entry: ClipboardEntry) {
        lock.lock(); defer { lock.unlock() }
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index] = entry
        persist()
    }

    // MARK: - Creation

    /// Insert a brand-new empty clip and return it (used by "New Clip").
    @discardableResult
    func createNewClip(text: String = "") -> ClipboardEntry {
        lock.lock(); defer { lock.unlock() }
        let entry = ClipboardEntry(text: text.isEmpty ? nil : text, neverAutoDelete: true)
        entries.insert(entry, at: 0)
        persist()
        return entry
    }

    // MARK: - Paste support

    func copyToPasteboard(_ entry: ClipboardEntry, options: SpecialPasteOptions = SpecialPasteOptions()) {
        let transformed = options.apply(to: entry, blobReader: { [weak self] key in
            self?.blobData(named: key)
        })

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        var pasteboardItems: [NSPasteboardItem] = []

        let item = NSPasteboardItem()
        var hasItemData = false

        if let text = transformed.text {
            item.setString(text, forType: .string)
            hasItemData = true
        }

        if transformed.stripFormatting == false {
            if let rtfBlobKey = transformed.rtfBlobKey, let data = blobData(named: rtfBlobKey) {
                item.setData(data, forType: .rtf)
                hasItemData = true
            }
            if let htmlBlobKey = transformed.htmlBlobKey, let data = blobData(named: htmlBlobKey) {
                item.setData(data, forType: NSPasteboard.PasteboardType.dittoHTML)
                hasItemData = true
            }
        }

        if hasItemData {
            pasteboardItems.append(item)
        }

        if transformed.imageRepresentation == nil, let imageBlobKey = transformed.imageBlobKey, let data = blobData(named: imageBlobKey) {
            let imageItem = NSPasteboardItem()
            imageItem.setData(data, forType: .png)
            // Also provide a TIFF representation — some apps (image editors,
            // Preview) read TIFF and ignore PNG on the pasteboard.
            if let image = NSImage(data: data), let tiff = image.tiffRepresentation {
                imageItem.setData(tiff, forType: .tiff)
            }
            pasteboardItems.append(imageItem)
        } else if let imageData = transformed.imageRepresentation {
            let imageItem = NSPasteboardItem()
            imageItem.setData(imageData, forType: .png)
            pasteboardItems.append(imageItem)
        }

        if let fileURLs = transformed.fileURLs {
            for fileURL in fileURLs.map({ URL(fileURLWithPath: $0) }) {
                let fileItem = NSPasteboardItem()
                fileItem.setString(fileURL.absoluteString, forType: .fileURL)
                pasteboardItems.append(fileItem)
            }
        }

        if pasteboardItems.isEmpty == false {
            pasteboard.writeObjects(pasteboardItems)
        }
    }

    /// Multi-paste: concatenate several clips with the configured separator.
    func multiPaste(_ selected: [ClipboardEntry]) -> String? {
        guard selected.isEmpty == false else { return nil }
        var ordered = selected
        if DittoSettings.multiPasteReverse { ordered.reverse() }
        let separator = DittoSettings.resolveMultiPasteSeparator()
        let combined = ordered
            .compactMap { $0.text }
            .joined(separator: separator)
        if DittoSettings.saveMultiPaste, combined.isEmpty == false {
            addClipboardPayload(text: combined, rtfData: nil, htmlData: nil, imageData: nil, fileURLs: [])
        }
        return combined.isEmpty ? nil : combined
    }

    func markPasted(_ entry: ClipboardEntry) {
        lock.lock(); defer { lock.unlock() }
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        var updated = entries[index]
        updated.pasteCount += 1
        updated.lastPasteDate = Date()
        if DittoSettings.updateTimeOnPaste {
            updated.clipOrder = Date().timeIntervalSince1970
        }
        entries[index] = updated
        if DittoSettings.updateTimeOnPaste {
            entries.sort { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
                return lhs.clipOrder > rhs.clipOrder
            }
        }
        persist()
    }

    // MARK: - Mutation

    func removeEntry(id: UUID) {
        lock.lock(); defer { lock.unlock() }
        removeEntries { $0.id == id }
        persist()
    }

    func toggleFavorite(id: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].isFavorite = !(entries[index].isFavorite ?? false)
        repinOrdering()
        persist()
    }

    func toggleNeverAutoDelete(id: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].neverAutoDelete.toggle()
        repinOrdering()
        persist()
    }

    func setGroup(id: UUID, groupId: Int64?) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].groupId = groupId
        persist()
    }

    func setQuickPasteText(id: UUID, text: String?) {
        lock.lock(); defer { lock.unlock() }
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].quickPasteText = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        persist()
    }

    func setShortcut(id: UUID, shortcutKey: Int, global: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].shortcutKey = shortcutKey
        entries[index].shortcutGlobal = global
        persist()
    }

    enum MoveDirection {
        case up, down, top, last
    }

    func moveClip(id: UUID, direction: MoveDirection) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let pinned = entries[index].isPinned
        let samePinned = entries.filter { $0.isPinned == pinned }
        let orders = samePinned.map(\.clipOrder)
        let highest = orders.max() ?? Date().timeIntervalSince1970
        let lowest = orders.min() ?? Date().timeIntervalSince1970
        switch direction {
        case .top, .up:
            entries[index].clipOrder = highest + 1
        case .last, .down:
            entries[index].clipOrder = lowest - 1
        }
        entries.sort { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            return lhs.clipOrder > rhs.clipOrder
        }
        persist()
    }

    private func repinOrdering() {
        entries.sort { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            return lhs.clipOrder > rhs.clipOrder
        }
    }

    // MARK: - Groups

    func addGroup(name: String, parentId: Int64? = nil) {
        lock.lock(); defer { lock.unlock() }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        let group = ClipGroup(name: trimmed, parentId: parentId)
        do {
            let id = try database.insertGroup(group)
            groups.append(ClipGroup(id: id, name: trimmed, parentId: parentId, sortOrder: group.sortOrder, createdAt: group.createdAt))
            groups.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            NSLog("Failed to insert group: \(error)")
        }
    }

    func renameGroup(id: Int64, name: String) {
        lock.lock(); defer { lock.unlock() }
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try? database.updateGroup(groups[index])
    }

    func deleteGroup(id: Int64) {
        lock.lock(); defer { lock.unlock() }
        try? database.deleteGroup(id: id)
        groups.removeAll { $0.id == id }
        for index in entries.indices where entries[index].groupId == id {
            entries[index].groupId = nil
        }
        persist()
    }

    func groupName(for id: Int64?) -> String? {
        guard let id, let group = groups.first(where: { $0.id == id }) else { return nil }
        return group.name
    }

    /// Full path "Parent / Child" for a group id, walking up the parent chain.
    func groupPath(for id: Int64?) -> String? {
        guard let id, let group = groups.first(where: { $0.id == id }) else { return nil }
        var names = [group.name]
        var current = group.parentId
        while let parentId = current, let parent = groups.first(where: { $0.id == parentId }), names.contains(parent.name) == false {
            names.insert(parent.name, at: 0)
            current = parent.parentId
        }
        return names.joined(separator: " / ")
    }

    /// Groups in depth-first order with indentation depth, for tree display.
    func hierarchicalGroups() -> [(group: ClipGroup, depth: Int)] {
        var result: [(ClipGroup, Int)] = []
        let byParent: [Int64?: [ClipGroup]] = Dictionary(grouping: groups) { $0.parentId }
        func visit(_ parentId: Int64?, depth: Int) {
            let children = (byParent[parentId] ?? []).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            for child in children {
                result.append((child, depth))
                visit(child.id, depth: depth + 1)
            }
        }
        visit(nil, depth: 0)
        return result
    }

    // MARK: - Copy buffers

    func copyBuffer(for slot: Int) -> UUID? {
        (try? database.loadCopyBuffers())?[slot]
    }

    func setCopyBuffer(slot: Int, entryId: UUID?) {
        lock.lock(); defer { lock.unlock() }
        try? database.setCopyBuffer(slot, entryId: entryId)
    }

    // MARK: - Friends

    func loadFriends() -> [Friend] {
        (try? database.loadFriends()) ?? []
    }

    func upsertFriend(_ friend: Friend) {
        try? database.upsertFriend(friend)
    }

    func deleteFriend(id: Int64) {
        try? database.deleteFriend(id: id)
    }

    // MARK: - Import / Export

    func exportArchive(to url: URL) throws {
        try database.exportArchive(entries: entries, to: url)
    }

    func importArchive(from url: URL) throws {
        let archiveDatabase = try MacClipboardDatabase(url: url, useWAL: false, readOnly: true)
        let importedEntries = try archiveDatabase.loadEntries()
        for entry in importedEntries {
            for key in [entry.rtfBlobKey, entry.htmlBlobKey, entry.imageBlobKey].compactMap({ $0 }) {
                guard let data = archiveDatabase.blobData(key: key) else { continue }
                _ = try? database.saveBlob(data, key: key, fileExtension: "")
            }
        }
        mergeImportedEntries(importedEntries)
    }

    @discardableResult
    func importWindowsDittoDatabase(from url: URL) throws -> Int {
        let importer = WindowsDittoDatabaseImporter { [weak self] data, fileExtension in
            self?.saveBlob(data, fileExtension: fileExtension)
        }
        let importedEntries = try importer.importEntries(from: url)
        mergeImportedEntries(importedEntries)
        return importedEntries.count
    }

    private func mergeImportedEntries(_ importedEntries: [ClipboardEntry]) {
        lock.lock(); defer { lock.unlock() }
        let importedKeys = Set(importedEntries.map(importKey(for:)))
        removeEntries { importedKeys.contains(importKey(for: $0)) }
        entries = (importedEntries + entries).sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            return lhs.createdAt > rhs.createdAt
        }
        trim()
        persist()
    }

    private func importKey(for entry: ClipboardEntry) -> String {
        [
            "\(Int(entry.createdAt.timeIntervalSince1970))",
            entry.text ?? "",
            entry.rtfBlobKey == nil ? "" : "rtf",
            entry.htmlBlobKey == nil ? "" : "html",
            entry.imageBlobKey == nil ? "" : "image",
            entry.fileURLs?.joined(separator: "\u{1f}") ?? ""
        ].joined(separator: "\u{1e}")
    }

    // MARK: - Maintenance

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        // Free the blobs of every entry before clearing.
        for entry in entries {
            removeBlobFiles(for: entry)
        }
        entries.removeAll()
        groups.removeAll()
        try? database.removeAll()
    }

    func enforceLimit() {
        lock.lock(); defer { lock.unlock() }
        trim()
        persist()
    }

    func enforceExpiry() {
        lock.lock(); defer { lock.unlock() }
        guard DittoSettings.checkExpiredEntries else { return }
        let cutoff = Date().addingTimeInterval(-TimeInterval(DittoSettings.expiredEntriesDays) * 86_400)
        let expired = entries.filter { $0.createdAt < cutoff && $0.isPinned == false }
        guard expired.isEmpty == false else { return }
        removeEntries { expired.contains($0) }
        persist()
    }

    private func removeEntries(where predicate: (ClipboardEntry) -> Bool) {
        let removed = entries.filter(predicate)
        for entry in removed {
            removeBlobFiles(for: entry)
        }
        entries.removeAll(where: predicate)
    }

    func saveBlob(_ data: Data?, fileExtension: String) -> String? {
        guard let data, data.isEmpty == false else { return nil }
        return try? database.saveBlob(data, fileExtension: fileExtension)
    }

    func blobData(named key: String) -> Data? {
        database.blobData(key: key)
    }

    private func removeBlobFiles(for entry: ClipboardEntry) {
        database.removeBlobs(keys: [entry.rtfBlobKey, entry.htmlBlobKey, entry.imageBlobKey].compactMap { $0 })
    }

    func imageData(for entry: ClipboardEntry) -> Data? {
        guard let imageBlobKey = entry.imageBlobKey else { return nil }
        return blobData(named: imageBlobKey)
    }

    /// Extracts plain text from RTF/HTML payloads when the entry has none.
    func fullText(for entry: ClipboardEntry) -> String? {
        if let key = entry.rtfBlobKey, let data = blobData(named: key),
           let text = RTFTextExtractor.string(from: data) {
            return text
        }
        if let key = entry.htmlBlobKey, let data = blobData(named: key) {
            return HTMLTextExtractor.string(from: data)
        }
        return nil
    }

    private func trim() {
        let maxEntries = max(DittoSettings.maxHistoryEntries, 1)
        // Pinned clips never count toward the limit.
        let pinnedCount = entries.filter(\.isPinned).count
        let nonPinnedBudget = max(1, maxEntries - pinnedCount)
        let nonPinned = entries.filter { $0.isPinned == false }
        if nonPinned.count > nonPinnedBudget {
            let toRemove = Array(nonPinned.suffix(nonPinned.count - nonPinnedBudget))
            for entry in toRemove {
                removeBlobFiles(for: entry)
            }
            let removeIds = Set(toRemove.map(\.id))
            entries.removeAll { removeIds.contains($0.id) }
        }
    }

    private func load() {
        if let loadedEntries = try? database.loadEntries() {
            entries = loadedEntries
        }
        if let loadedGroups = try? database.loadGroups() {
            groups = loadedGroups.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    private func persist() {
        // Snapshot under the lock so the background write is consistent and
        // can't race a concurrent mutation.
        lock.lock()
        let snapshot = entries
        let snapshotGroups = groups
        lock.unlock()
        queue.async { [database] in
            try? database.replaceEntries(snapshot)
            for group in snapshotGroups {
                try? database.updateGroup(group)
            }
        }
    }

    // MARK: - Legacy migration

    private func migrateLegacyJSONIfNeeded() {
        guard entries.isEmpty, let data = try? Data(contentsOf: legacyFileURL) else { return }
        guard let legacyEntries = try? JSONDecoder().decode([ClipboardEntry].self, from: data) else { return }

        let migratedEntries = legacyEntries.map { legacyEntry in
            ClipboardEntry(
                id: legacyEntry.id,
                text: legacyEntry.text,
                rtfBlobKey: migrateLegacyBlob(legacyEntry.rtfBlobKey, fileExtension: "rtf"),
                htmlBlobKey: migrateLegacyBlob(legacyEntry.htmlBlobKey, fileExtension: "html"),
                imageBlobKey: migrateLegacyBlob(legacyEntry.imageBlobKey, fileExtension: "png"),
                fileURLs: legacyEntry.fileURLs,
                createdAt: legacyEntry.createdAt,
                isFavorite: legacyEntry.isFavorite,
                neverAutoDelete: legacyEntry.neverAutoDelete
            )
        }
        entries = migratedEntries.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            return lhs.createdAt > rhs.createdAt
        }
        trim()
        persist()
    }

    private func migrateLegacyBlob(_ key: String?, fileExtension: String) -> String? {
        guard let key else { return nil }
        let legacyImagesDirectory = legacyFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("Images", isDirectory: true)
        let legacyURLs = [
            legacyDataDirectory.appendingPathComponent(key),
            legacyImagesDirectory.appendingPathComponent(key)
        ]
        for url in legacyURLs {
            if let data = try? Data(contentsOf: url), data.isEmpty == false {
                return saveBlob(data, fileExtension: fileExtension)
            }
        }
        return nil
    }
}

extension NSPasteboard.PasteboardType {
    static let dittoHTML = NSPasteboard.PasteboardType("public.html")
}
