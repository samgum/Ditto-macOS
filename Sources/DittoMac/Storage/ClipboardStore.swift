import AppKit
import Foundation

/// High-level clipboard history store. Wraps `MacClipboardDatabase` and adds
/// the behavioural rules from Windows Ditto: dedup, expiry, trimming, pinned
/// clips, paste-counting, groups, and copy buffers.
final class ClipboardStore {
    private let legacyFileURL: URL
    private let legacyDataDirectory: URL
    private let database: MacClipboardDatabase
    let databaseFileURL: URL
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
        let url = databaseURL ?? DittoSettings.databaseURL ?? directory.appendingPathComponent("Ditto.db")
        databaseFileURL = url
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

    @discardableResult
    func addClipboardPayload(
        text: String?,
        rtfData: Data?,
        htmlData: Data?,
        imageData: Data?,
        pdfData: Data? = nil,
        fileURLs: [URL],
        sourceApp: String? = nil
    ) -> ClipboardEntry? {
        lock.lock(); defer { lock.unlock() }
        let normalizedText = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = fileURLs.map { $0.path }

        guard
            normalizedText?.isEmpty == false ||
            rtfData?.isEmpty == false ||
            htmlData?.isEmpty == false ||
            imageData?.isEmpty == false ||
            pdfData?.isEmpty == false ||
            files.isEmpty == false
        else {
            return nil
        }

        // Enforce max clip size (0 = unlimited).
        let maxSize = DittoSettings.maxClipSizeBytes
        if maxSize > 0 {
            let textSize = normalizedText?.utf8.count ?? 0
            let rtfSize = rtfData?.count ?? 0
            let htmlSize = htmlData?.count ?? 0
            let imageSize = imageData?.count ?? 0
            let pdfSize = pdfData?.count ?? 0
            let totalSize = textSize + rtfSize + htmlSize + imageSize + pdfSize
            if totalSize > maxSize {
                return nil
            }
        }

        // Multi-format CRC over every captured format's bytes, exactly like
        // Windows (GenerateCRC over all formats). Used for dedup so that two
        // different images / file lists don't falsely match each other just
        // because their text is nil.
        let newCRC = CRC32.checksumCapture(
            text: normalizedText, rtfData: rtfData, htmlData: htmlData,
            imageData: imageData, pdfData: pdfData, fileURLs: files
        )

        // Back-to-back duplicate suppression (identical to the last capture).
        if let first = entries.first,
           first.crc == newCRC,
           DittoSettings.allowBackToBackDuplicates == false {
            // Still bubble it to the top + refresh timestamp, like Windows
            // (it re-uses the same row rather than dropping the copy).
            if let idx = entries.indices.first, entries[idx].isPinned == false {
                entries[idx].clipOrder = (entries.map(\.clipOrder).max() ?? Date().timeIntervalSince1970) + 1
                entries[idx].createdAt = Date()
                repinOrdering()
                persist()
                return entries[idx]
            }
            return nil
        }

        // Global duplicate suppression — Windows keeps the SAME row and moves it
        // to the top, preserving favorite/pin/paste-count/group/shortcut. Mirror
        // that: promote the existing entry instead of delete+reinsert.
        if DittoSettings.allowDuplicates == false,
           let matchIndex = entries.firstIndex(where: { $0.crc == newCRC && $0.isPinned == false && $0.crc != 0 }) {
            entries[matchIndex].clipOrder = (entries.filter { $0.isPinned == false }.map(\.clipOrder).max() ?? Date().timeIntervalSince1970) + 1
            entries[matchIndex].createdAt = Date()
            repinOrdering()
            persist()
            return entries[matchIndex]
        }

        let rtfBlobKey = saveBlob(rtfData, fileExtension: "rtf")
        let htmlBlobKey = saveBlob(htmlData, fileExtension: "html")
        let imageBlobKey = saveBlob(imageData, fileExtension: "png")
        let pdfBlobKey = saveBlob(pdfData, fileExtension: "pdf")

        let entry = ClipboardEntry(
            id: UUID(),
            text: text,
            rtfBlobKey: rtfBlobKey,
            htmlBlobKey: htmlBlobKey,
            imageBlobKey: imageBlobKey,
            pdfBlobKey: pdfBlobKey,
            fileURLs: files.isEmpty ? nil : files,
            createdAt: Date(),
            crc: newCRC,
            sourceApp: sourceApp
        )

        entries.insert(entry, at: 0)
        // Pinned clips always sit above the newest non-pinned clip.
        repinOrdering()
        trim()
        persist()
        return entry
    }

    // MARK: - Lookups

    func entry(id: UUID) -> ClipboardEntry? {
        lock.lock(); defer { lock.unlock() }
        return entries.first { $0.id == id }
    }

    func update(_ entry: ClipboardEntry) {
        lock.lock(); defer { lock.unlock() }
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        let oldBlobKeys = Set(blobKeys(for: entries[index]))
        entries[index] = entry
        let currentBlobKeys = Set(entries.flatMap(blobKeys(for:)))
        let obsoleteBlobKeys = oldBlobKeys
            .subtracting(Set(blobKeys(for: entry)))
            .subtracting(currentBlobKeys)
        database.removeBlobs(keys: Array(obsoleteBlobKeys))
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

        if let pdfBlobKey = transformed.pdfBlobKey, let data = blobData(named: pdfBlobKey) {
            let pdfItem = NSPasteboardItem()
            pdfItem.setData(data, forType: .pdf)
            pasteboardItems.append(pdfItem)
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
        lock.lock(); defer { lock.unlock() }
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
        lock.lock(); defer { lock.unlock() }
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

    @discardableResult
    func addGroup(name: String, parentId: Int64? = nil) -> Int64? {
        lock.lock(); defer { lock.unlock() }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        let group = ClipGroup(name: trimmed, parentId: parentId)
        do {
            let id = try database.insertGroup(group)
            groups.append(ClipGroup(id: id, name: trimmed, parentId: parentId, sortOrder: group.sortOrder, createdAt: group.createdAt))
            groups.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return id
        } catch {
            NSLog("Failed to insert group: \(error)")
            return nil
        }
    }

    func renameGroup(id: Int64, name: String) {
        lock.lock(); defer { lock.unlock() }
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        groups[index].name = trimmed
        try? database.updateGroup(groups[index])
    }

    func deleteGroup(id: Int64) {
        lock.lock(); defer { lock.unlock() }
        guard let deletedGroup = groups.first(where: { $0.id == id }) else { return }
        try? database.deleteGroup(id: id)
        groups.removeAll { $0.id == id }
        for index in groups.indices where groups[index].parentId == id {
            groups[index].parentId = deletedGroup.parentId
        }
        for index in entries.indices where entries[index].groupId == id {
            entries[index].groupId = deletedGroup.parentId
        }
        persist()
    }

    func groupName(for id: Int64?) -> String? {
        guard let id, let group = snapshotGroups().first(where: { $0.id == id }) else { return nil }
        return group.name
    }

    /// Full path "Parent / Child" for a group id, walking up the parent chain.
    func groupPath(for id: Int64?) -> String? {
        let snapshot = snapshotGroups()
        guard let id, let group = snapshot.first(where: { $0.id == id }) else { return nil }
        var names = [group.name]
        var current = group.parentId
        var visited: Set<Int64> = [group.id]
        while let parentId = current,
              let parent = snapshot.first(where: { $0.id == parentId }),
              visited.insert(parent.id).inserted {
            names.insert(parent.name, at: 0)
            current = parent.parentId
        }
        return names.joined(separator: " / ")
    }

    /// Groups in depth-first order with indentation depth, for tree display.
    func hierarchicalGroups() -> [(group: ClipGroup, depth: Int)] {
        let snapshot = snapshotGroups()
        var result: [(ClipGroup, Int)] = []
        let byParent: [Int64?: [ClipGroup]] = Dictionary(grouping: snapshot) { $0.parentId }
        var visited = Set<Int64>()
        func visit(_ parentId: Int64?, depth: Int) {
            let children = (byParent[parentId] ?? []).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            for child in children {
                guard visited.insert(child.id).inserted else { continue }
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
        // Snapshot under the lock so the writer holds its own COW copy and
        // can't race a concurrent mutation.
        try database.exportArchive(entries: snapshotEntries(), groups: snapshotGroups(), to: url)
    }

    func importArchive(from url: URL) throws {
        let archiveDatabase = try MacClipboardDatabase(url: url, useWAL: false, readOnly: true)
        let archivedGroups = try archiveDatabase.loadGroups()
        let groupIDs = importGroups(archivedGroups)
        var importedEntries = try archiveDatabase.loadEntries()
        for index in importedEntries.indices {
            if let groupID = importedEntries[index].groupId {
                importedEntries[index].groupId = groupIDs[groupID]
            }
            for key in [
                importedEntries[index].rtfBlobKey,
                importedEntries[index].htmlBlobKey,
                importedEntries[index].imageBlobKey,
                importedEntries[index].pdfBlobKey
            ].compactMap({ $0 }) {
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
        let result = try importer.importResult(from: url)
        let groupIDs = importGroups(result.groups)
        var importedEntries = result.entries
        for index in importedEntries.indices {
            if let groupID = importedEntries[index].groupId {
                importedEntries[index].groupId = groupIDs[groupID]
            }
        }
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
            entry.pdfBlobKey == nil ? "" : "pdf",
            entry.fileURLs?.joined(separator: "\u{1f}") ?? ""
        ].joined(separator: "\u{1e}")
    }

    // MARK: - Maintenance

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
        groups.removeAll()
        try? database.removeAll()
    }

    func enforceLimit() {
        lock.lock(); defer { lock.unlock() }
        trim()
        persist()
    }

    // MARK: - Database maintenance

    func backupDatabase(to url: URL) throws {
        try database.backup(to: url)
    }

    func compactDatabase() {
        try? database.vacuum()
    }

    /// Delete clips that have never been pasted and aren't pinned.
    func deleteNonUsedClips() {
        lock.lock(); defer { lock.unlock() }
        removeEntries { $0.pasteCount == 0 && $0.isPinned == false }
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
            try? database.clearCopyBufferReferences(for: entry.id)
        }
        entries.removeAll(where: predicate)
        let referencedBlobKeys = Set(entries.flatMap(blobKeys(for:)))
        let removedBlobKeys = Set(removed.flatMap(blobKeys(for:))).subtracting(referencedBlobKeys)
        database.removeBlobs(keys: Array(removedBlobKeys))
    }

    func saveBlob(_ data: Data?, fileExtension: String) -> String? {
        guard let data, data.isEmpty == false else { return nil }
        return try? database.saveBlob(data, fileExtension: fileExtension)
    }

    func blobData(named key: String) -> Data? {
        database.blobData(key: key)
    }

    private func blobKeys(for entry: ClipboardEntry) -> [String] {
        [entry.rtfBlobKey, entry.htmlBlobKey, entry.imageBlobKey, entry.pdfBlobKey].compactMap { $0 }
    }

    func imageData(for entry: ClipboardEntry) -> Data? {
        guard let imageBlobKey = entry.imageBlobKey else { return nil }
        return blobData(named: imageBlobKey)
    }

    func pdfData(for entry: ClipboardEntry) -> Data? {
        guard let pdfBlobKey = entry.pdfBlobKey else { return nil }
        return blobData(named: pdfBlobKey)
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

    /// Import groups before their clips and translate archived IDs to the
    /// current database's IDs, so importing an archive never creates broken
    /// group references or collides with a local group's numeric identifier.
    private func importGroups(_ archivedGroups: [ClipGroup]) -> [Int64: Int64] {
        lock.lock(); defer { lock.unlock() }
        var idMap: [Int64: Int64] = [:]
        var pending = archivedGroups

        while pending.isEmpty == false {
            var madeProgress = false
            var remaining: [ClipGroup] = []

            for group in pending {
                if let parentID = group.parentId, idMap[parentID] == nil {
                    remaining.append(group)
                    continue
                }

                let mappedParentID = group.parentId.flatMap { idMap[$0] }
                if let existing = groups.first(where: {
                    $0.parentId == mappedParentID &&
                    $0.name.localizedCaseInsensitiveCompare(group.name) == .orderedSame
                }) {
                    idMap[group.id] = existing.id
                } else if let newID = addGroup(name: group.name, parentId: mappedParentID) {
                    idMap[group.id] = newID
                }
                madeProgress = true
            }

            if madeProgress == false {
                for group in remaining {
                    if let newID = addGroup(name: group.name, parentId: nil) {
                        idMap[group.id] = newID
                    }
                }
                break
            }
            pending = remaining
        }

        return idMap
    }

    private func trim() {
        let limit = DittoSettings.maxHistoryEntries
        guard limit > 0 else { return } // 0 = unlimited
        // Pinned clips never count toward the limit.
        let pinnedCount = entries.filter(\.isPinned).count
        let nonPinnedBudget = max(1, limit - pinnedCount)
        let nonPinned = entries.filter { $0.isPinned == false }
        if nonPinned.count > nonPinnedBudget {
            let toRemove = Array(nonPinned.suffix(nonPinned.count - nonPinnedBudget))
            let removeIds = Set(toRemove.map(\.id))
            removeEntries { removeIds.contains($0.id) }
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
                pdfBlobKey: migrateLegacyBlob(legacyEntry.pdfBlobKey, fileExtension: "pdf"),
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
