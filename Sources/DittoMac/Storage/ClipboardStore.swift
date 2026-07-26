import AppKit
import Foundation

/// High-level clipboard history store. Wraps `MacClipboardDatabase` and adds
/// the behavioural rules from Windows Ditto: dedup, expiry, trimming, pinned
/// clips, paste-counting, groups, and copy buffers.
final class ClipboardStore {
    /// Whether history is actually reaching disk. Anything other than
    /// `.healthy` is surfaced in the UI (non-modally) so a clip is never shown
    /// as saved when it was not.
    enum Health: Equatable {
        case healthy
        /// The configured database could not be opened; the emergency file is
        /// in use instead. The original file was left untouched.
        case usingEmergencyDatabase(reason: String)
        /// Neither the configured nor the emergency database could be opened.
        /// History lives in memory only and is lost on quit.
        case memoryOnly(reason: String)
        /// The database opened, but the most recent write failed.
        case writeFailed(reason: String)

        var isHealthy: Bool { self == .healthy }

        var reason: String? {
            switch self {
            case .healthy: return nil
            case .usingEmergencyDatabase(let reason),
                 .memoryOnly(let reason),
                 .writeFailed(let reason):
                return reason
            }
        }
    }

    private static let recoveredQuarantinesKey = "Ditto.RecoveredQuarantinedDatabases"
    private let legacyFileURL: URL
    private let legacyDataDirectory: URL
    private let database: MacClipboardDatabase
    let databaseFileURL: URL
    /// False when history is held in memory only (no writable database).
    let isPersistent: Bool
    private(set) var entries: [ClipboardEntry] = []
    private(set) var groups: [ClipGroup] = []
    private var persistedEntriesByID: [UUID: ClipboardEntry] = [:]
    /// Blob keys orphaned by a delete/update. They are removed only after the
    /// matching entry change has actually committed, so a failed write can
    /// never strip payloads from rows that still exist.
    private var pendingBlobDeletions: Set<String> = []
    /// CRC of the most recent capture. Back-to-back duplicate suppression has
    /// to compare against this, not `entries.first` — the array is sorted with
    /// pinned clips on top, so `entries.first` is usually not the last capture.
    private var lastCapturedCRC: Int64?
    private var healthStorage: Health = .healthy

    private(set) var health: Health {
        get { lock.lock(); defer { lock.unlock() }; return healthStorage }
        set {
            lock.lock()
            let changed = healthStorage != newValue
            healthStorage = newValue
            lock.unlock()
            guard changed else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                NotificationCenter.default.post(name: .dittoStorageHealthChanged, object: self)
            }
        }
    }

    private let queue = DispatchQueue(label: "org.ditto-cp.DittoMac.store", qos: .utility)

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
        let defaultURL = directory.appendingPathComponent("Ditto.db")
        let emergencyURL = directory.appendingPathComponent("Ditto-emergency.db")
        let requestedURL = databaseURL ?? DittoSettings.databaseURL ?? defaultURL
        do {
            database = try MacClipboardDatabase(url: requestedURL)
            databaseFileURL = requestedURL
            isPersistent = true
        } catch {
            // A failed open can be transient (permissions, a stale lock, or an
            // interrupted migration). Never rename the user's only database.
            let reason = Self.describe(error)
            NSLog("[Ditto] failed to open \(requestedURL.path): \(reason). The original file was left untouched; using \(emergencyURL.lastPathComponent).")
            do {
                database = try MacClipboardDatabase(url: emergencyURL)
                databaseFileURL = emergencyURL
                isPersistent = true
                healthStorage = .usingEmergencyDatabase(reason: reason)
            } catch {
                // Even the emergency file is unusable (read-only volume, no
                // space, revoked permissions). Keep the app alive on a volatile
                // database rather than aborting at launch, and say so loudly.
                NSLog("[Ditto] failed to open the emergency database: \(Self.describe(error)). History will not be saved to disk.")
                database = MacClipboardDatabase.inMemoryFallback()
                databaseFileURL = emergencyURL
                isPersistent = false
                healthStorage = .memoryOnly(reason: Self.describe(error))
            }
        }
        load()
        // Only the app's own store absorbs the recovery files sitting in the
        // application-support folder. A store opened on an explicit path — the
        // self-tests, an archive, a relocated copy being verified — must never
        // pull the live emergency database into itself.
        if databaseURL == nil,
           isPersistent,
           databaseFileURL.standardizedFileURL != emergencyURL.standardizedFileURL {
            recoverDatabases(
                in: directory,
                emergencyURL: emergencyURL,
                includeQuarantines: requestedURL.standardizedFileURL == defaultURL.standardizedFileURL
            )
        }
        if databaseURL == nil {
            // Same reasoning: the legacy history.json belongs to the app's own
            // database, not to whatever path a caller asked for.
            migrateLegacyJSONIfNeeded()
        }
        enforceExpiry()
    }

    /// Human-readable one-liner for an error, so failures reach the user as
    /// something actionable instead of "Operation failed."
    static func describe(_ error: Error) -> String {
        switch error {
        case let databaseError as MacClipboardDatabaseError:
            switch databaseError {
            case .openFailed(let message): return message
            case .prepareFailed(let message): return message
            case .executeFailed(let message): return message
            }
        default:
            return (error as NSError).localizedDescription
        }
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
        // Compare against the recorded last capture, not `entries.first`:
        // pinned clips sort to the top, so `entries.first` is frequently an old
        // pinned clip. Matching on it used to drop the capture entirely.
        if DittoSettings.allowBackToBackDuplicates == false,
           newCRC != 0,
           lastCapturedCRC == newCRC,
           let matchIndex = entries.firstIndex(where: { $0.crc == newCRC }) {
            // Re-use the same row rather than dropping the copy, like Windows.
            let entryID = entries[matchIndex].id
            if entries[matchIndex].isPinned == false {
                entries[matchIndex].clipOrder = nextClipOrder()
                entries[matchIndex].createdAt = Date()
                repinOrdering()
            }
            persist()
            return entries.first { $0.id == entryID }
        }

        // Global duplicate suppression — Windows keeps the SAME row and moves it
        // to the top, preserving favorite/pin/paste-count/group/shortcut. Mirror
        // that: promote the existing entry instead of delete+reinsert.
        if DittoSettings.allowDuplicates == false,
           newCRC != 0,
           let matchIndex = entries.firstIndex(where: { $0.crc == newCRC && $0.isPinned == false }) {
            let entryID = entries[matchIndex].id
            entries[matchIndex].clipOrder = nextClipOrder()
            entries[matchIndex].createdAt = Date()
            repinOrdering()
            lastCapturedCRC = newCRC
            persist()
            // `repinOrdering` re-sorts, so look the row up by id — indexing
            // with the stale offset returned an unrelated clip.
            return entries.first { $0.id == entryID }
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
        lastCapturedCRC = newCRC
        // Pinned clips always sit above the newest non-pinned clip.
        repinOrdering()
        trim()
        persist()
        return entry
    }

    /// One above the newest non-pinned clip, so a promoted duplicate lands at
    /// the top of the unpinned section.
    private func nextClipOrder() -> Double {
        let highest = entries.filter { $0.isPinned == false }.map(\.clipOrder).max()
        return (highest ?? Date().timeIntervalSince1970) + 1
    }

    // MARK: - Lookups

    func entry(id: UUID) -> ClipboardEntry? {
        lock.lock(); defer { lock.unlock() }
        return entries.first { $0.id == id }
    }

    func update(_ entry: ClipboardEntry) {
        lock.lock(); defer { lock.unlock() }
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        pendingBlobDeletions.formUnion(blobKeys(for: entries[index]))
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
        _ = try? database.upsertFriend(friend)
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
        try withArchiveDatabase(at: url) { archiveDatabase in
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
    }

    /// Opens a database we only want to read from.
    ///
    /// A read-only connection is preferred — it cannot alter the source. But a
    /// database still in WAL mode (every emergency and quarantined file is)
    /// needs a writable `-shm`, so a read-only open of one whose sidecar is
    /// missing fails with "unable to open database file" and the data becomes
    /// unrecoverable. In that case the file is copied — sidecars included — and
    /// the copy is opened read-write, so SQLite can replay the WAL while the
    /// original stays byte-for-byte untouched.
    private func withArchiveDatabase<T>(at url: URL, _ body: (MacClipboardDatabase) throws -> T) throws -> T {
        if let readable = Self.openReadOnly(url) {
            return try body(readable)
        }
        let copy = try Self.copyDatabaseForRecovery(at: url)
        defer { Self.removeDatabaseFiles(at: copy) }
        return try body(try MacClipboardDatabase(url: copy))
    }

    private static func openReadOnly(_ url: URL) -> MacClipboardDatabase? {
        guard let database = try? MacClipboardDatabase(url: url, useWAL: false, readOnly: true),
              (try? database.entryCount()) != nil else {
            return nil
        }
        return database
    }

    private static func copyDatabaseForRecovery(at url: URL) throws -> URL {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory
            .appendingPathComponent("ditto-recovery-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let copy = directory.appendingPathComponent(url.lastPathComponent)
        try manager.copyItem(at: url, to: copy)
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: url.path + suffix)
            guard manager.fileExists(atPath: sidecar.path) else { continue }
            try? manager.copyItem(at: sidecar, to: URL(fileURLWithPath: copy.path + suffix))
        }
        return copy
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
        lock.lock()
        entries.removeAll()
        groups.removeAll()
        pendingBlobDeletions.removeAll()
        lastCapturedCRC = nil
        lock.unlock()

        var failure: String?
        queue.sync {
            do {
                try database.removeAll()
                persistedEntriesByID.removeAll()
            } catch {
                failure = Self.describe(error)
                NSLog("[Ditto] failed to clear clipboard database: \(failure ?? "")")
            }
        }
        if let failure {
            health = .writeFailed(reason: failure)
        } else if isPersistent, case .writeFailed = health {
            health = .healthy
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            NotificationCenter.default.post(name: .dittoHistoryChanged, object: self)
        }
    }

    func enforceLimit() {
        lock.lock(); defer { lock.unlock() }
        trim()
        persist()
    }

    // MARK: - Database maintenance

    func backupDatabase(to url: URL) throws {
        flush()
        try database.backup(to: url)
    }

    /// Folder the one-click backups land in, next to the live database.
    var backupsDirectory: URL {
        databaseFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("Backups", isDirectory: true)
    }

    /// One-click, SQLite-consistent backup into `backupsDirectory`.
    @discardableResult
    func createTimestampedBackup() throws -> URL {
        guard isPersistent else {
            throw MacClipboardDatabaseError.executeFailed(
                "The current history is held in memory only and cannot be backed up"
            )
        }
        let url = backupsDirectory
            .appendingPathComponent("Ditto-Backup-\(Self.timestampFormatter.string(from: Date())).db")
        try backupDatabase(to: url)
        return url
    }

    /// Existing backups, newest first.
    func existingBackups() -> [(url: URL, date: Date, size: Int64)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: backupsDirectory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .filter { $0.pathExtension == "db" }
            .compactMap { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return (
                    url,
                    values?.contentModificationDate ?? Date(timeIntervalSince1970: 0),
                    Int64(values?.fileSize ?? 0)
                )
            }
            .sorted { $0.date > $1.date }
    }

    /// Creates a complete SQLite-consistent copy of the current history in a
    /// user-selected folder. The app switches to it after restart, while the
    /// previous database remains intact until the user confirms everything is
    /// present in the new location.
    ///
    /// The copy is written to a staging file, integrity-checked and row-counted
    /// against the live database, and only then renamed into place. Any failure
    /// removes the staging file, so a half-written relocation can never be
    /// adopted and never blocks a retry.
    func prepareDatabaseRelocation(to directory: URL) throws -> URL {
        let manager = FileManager.default
        let destination = directory.appendingPathComponent("Ditto.db")
        guard destination.standardizedFileURL != databaseFileURL.standardizedFileURL else {
            return destination
        }
        guard isPersistent else {
            throw MacClipboardDatabaseError.executeFailed(
                "The current history is held in memory only and cannot be relocated"
            )
        }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        guard manager.fileExists(atPath: destination.path) == false else {
            throw MacClipboardDatabaseError.executeFailed("A Ditto.db file already exists in the selected folder")
        }
        try verifyFreeSpace(in: directory)

        let staging = directory.appendingPathComponent("Ditto-relocating-\(UUID().uuidString).db")
        do {
            try backupDatabase(to: staging)
            let expectedCount = snapshotEntries().count
            let (checkResult, copiedCount) = try Self.inspect(databaseAt: staging)
            guard checkResult == "ok" else {
                throw MacClipboardDatabaseError.executeFailed(
                    "The copied database failed its integrity check (\(checkResult))"
                )
            }
            guard copiedCount >= expectedCount else {
                throw MacClipboardDatabaseError.executeFailed(
                    "The copy holds \(copiedCount) of \(expectedCount) clips"
                )
            }
            try manager.moveItem(at: staging, to: destination)
        } catch {
            Self.removeDatabaseFiles(at: staging)
            throw error
        }
        return destination
    }

    /// Opens `url` read-only just long enough to report its health, so the
    /// connection is closed before the caller renames the file.
    private static func inspect(databaseAt url: URL) throws -> (quickCheck: String, entryCount: Int) {
        let database = try MacClipboardDatabase(url: url, useWAL: false, readOnly: true)
        return (database.quickCheckResult(), try database.entryCount())
    }

    private static func removeDatabaseFiles(at url: URL) {
        let manager = FileManager.default
        for path in [url.path, url.path + "-wal", url.path + "-shm"] where manager.fileExists(atPath: path) {
            try? manager.removeItem(atPath: path)
        }
        // Recovery copies live in a throwaway directory of their own.
        let parent = url.deletingLastPathComponent()
        if parent.lastPathComponent.hasPrefix("ditto-recovery-") {
            try? manager.removeItem(at: parent)
        }
    }

    /// Bytes the live database currently occupies, including its WAL sidecar.
    func databaseByteSize() -> Int64 {
        let manager = FileManager.default
        return [databaseFileURL.path, databaseFileURL.path + "-wal"].reduce(into: Int64(0)) { total, path in
            let size = (try? manager.attributesOfItem(atPath: path)[.size] as? Int64) ?? nil
            total += size ?? 0
        }
    }

    /// Free capacity of the volume holding `directory`, or nil when unknown.
    static func availableCapacity(at directory: URL) -> Int64? {
        try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }

    private func verifyFreeSpace(in directory: URL) throws {
        guard let available = Self.availableCapacity(at: directory) else { return }
        // The copy needs room for the database plus a little slack for the
        // journal it writes while filling up.
        let required = databaseByteSize() + 8 * 1_024 * 1_024
        guard available >= required else {
            throw MacClipboardDatabaseError.executeFailed(
                "The selected volume has \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) free; "
                + "\(ByteCountFormatter.string(fromByteCount: required, countStyle: .file)) is needed"
            )
        }
    }

    /// Waits for all queued history writes and truncates the WAL. Call this
    /// before app termination and before creating a database relocation copy.
    @discardableResult
    func flush() -> Bool {
        let persisted = persist()
        queue.sync {}
        guard isPersistent else { return false }
        do {
            try database.checkpoint()
        } catch {
            // A busy checkpoint is not data loss (the WAL still holds the
            // committed pages), so this does not flip the health state.
            NSLog("[Ditto] failed to checkpoint clipboard database: \(Self.describe(error))")
            return persisted
        }
        return persisted
    }

    func compactDatabase() throws {
        flush()
        guard isPersistent else {
            throw MacClipboardDatabaseError.executeFailed(
                "The current history is held in memory only and cannot be compacted"
            )
        }
        try database.vacuum()
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
        // Match on ids: comparing whole entries made this O(n·m) over full
        // struct equality, which is measurable on large histories.
        let expiredIDs = Set(
            entries.filter { $0.createdAt < cutoff && $0.isPinned == false }.map(\.id)
        )
        guard expiredIDs.isEmpty == false else { return }
        removeEntries { expiredIDs.contains($0.id) }
        persist()
    }

    private func removeEntries(where predicate: (ClipboardEntry) -> Bool) {
        let removed = entries.filter(predicate)
        guard removed.isEmpty == false else { return }
        for entry in removed {
            try? database.clearCopyBufferReferences(for: entry.id)
        }
        entries.removeAll(where: predicate)
        if let lastCapturedCRC, removed.contains(where: { $0.crc == lastCapturedCRC }) {
            // The row the next capture would have been deduplicated against is
            // gone; forget it so re-copying the same content is stored again.
            self.lastCapturedCRC = nil
        }
        // Deleted lazily by `persist()` once the row removal has committed, and
        // only for keys no surviving clip still references.
        pendingBlobDeletions.formUnion(removed.flatMap(blobKeys(for:)))
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
        let nonPinnedBudget = limit
        let nonPinned = entries.filter { $0.isPinned == false }
        if nonPinned.count > nonPinnedBudget {
            let toRemove = Array(nonPinned.suffix(nonPinned.count - nonPinnedBudget))
            let removeIds = Set(toRemove.map(\.id))
            removeEntries { removeIds.contains($0.id) }
        }
    }

    private func load() {
        do {
            let loadedEntries = try database.loadEntries()
            entries = loadedEntries
            persistedEntriesByID = Dictionary(uniqueKeysWithValues: loadedEntries.map { ($0.id, $0) })
            // Seed back-to-back dedup from the newest clip on disk so the first
            // capture after a relaunch isn't stored twice.
            lastCapturedCRC = loadedEntries.max(by: { $0.createdAt < $1.createdAt })?.crc
        } catch {
            NSLog("[Ditto] failed to load clipboard entries: \(error)")
        }
        do {
            let loadedGroups = try database.loadGroups()
            groups = loadedGroups.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            NSLog("[Ditto] failed to load clipboard groups: \(error)")
        }
    }

    /// Writes the in-memory history to the database.
    ///
    /// Returns `false` when the write failed, so callers never report a clip as
    /// saved that is not on disk. The clip stays in memory (it remains
    /// pasteable) and `health` flips to `.writeFailed` so the UI can say so.
    @discardableResult
    private func persist() -> Bool {
        lock.lock()
        let snapshotByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        let referencedBlobKeys = Set(entries.flatMap(blobKeys(for:)))
        // Never drop a blob a surviving clip still points at — an archive
        // import re-uses the source keys, so a replaced clip can share them.
        let blobsToDelete = pendingBlobDeletions.subtracting(referencedBlobKeys)
        pendingBlobDeletions.removeAll()
        lock.unlock()

        var historyChanged = false
        var failure: String?

        queue.sync {
            let changedEntries = snapshotByID.values.filter {
                self.persistedEntriesByID[$0.id] != $0
            }
            let deletedIDs = self.persistedEntriesByID.keys.filter {
                snapshotByID[$0] == nil
            }
            guard changedEntries.isEmpty == false
                || deletedIDs.isEmpty == false
                || blobsToDelete.isEmpty == false else {
                return
            }
            historyChanged = changedEntries.isEmpty == false || deletedIDs.isEmpty == false
            do {
                if historyChanged {
                    try self.database.applyEntryChanges(
                        upserting: changedEntries,
                        deleting: deletedIDs
                    )
                    self.persistedEntriesByID = snapshotByID
                }
                // Only once the rows are gone: a rolled-back delete must not
                // leave surviving rows pointing at removed payloads.
                if blobsToDelete.isEmpty == false {
                    self.database.removeBlobs(keys: Array(blobsToDelete))
                }
            } catch {
                failure = Self.describe(error)
                NSLog("[Ditto] failed to persist clipboard entries: \(failure ?? "")")
            }
        }

        if let failure {
            // Retry the orphaned-blob sweep on the next write.
            lock.lock()
            pendingBlobDeletions.formUnion(blobsToDelete)
            lock.unlock()
            health = .writeFailed(reason: failure)
        } else if isPersistent, case .writeFailed = health {
            health = .healthy
        }

        if historyChanged {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                NotificationCenter.default.post(name: .dittoHistoryChanged, object: self)
            }
        }
        return failure == nil
    }

    private func recoverDatabases(
        in directory: URL,
        emergencyURL: URL,
        includeQuarantines: Bool
    ) {
        let manager = FileManager.default
        let previouslyRecovered = Set(UserDefaults.standard.stringArray(forKey: Self.recoveredQuarantinesKey) ?? [])
        guard let urls = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var recovered = previouslyRecovered
        var recoveredEntries = 0
        var recoveredEmergency = false
        for url in urls {
            let isEmergency = url.standardizedFileURL == emergencyURL.standardizedFileURL
            let isQuarantine = includeQuarantines
                && url.pathExtension == "db"
                && (
                    url.lastPathComponent.hasPrefix("Ditto.corrupt-")
                    || url.lastPathComponent.hasPrefix("Ditto-recovery-")
                )
            guard isEmergency || isQuarantine else { continue }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let marker = "\(url.path)|\(values?.fileSize ?? 0)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
            guard recovered.contains(marker) == false else { continue }

            let countBefore = snapshotEntries().count
            do {
                try importArchive(from: url)
                recoveredEntries += max(0, snapshotEntries().count - countBefore)
                recovered.insert(marker)
                if isEmergency { recoveredEmergency = true }
            } catch {
                // Keep the file in place for manual recovery if it genuinely
                // cannot be read. A failed recovery never deletes data.
                NSLog("[Ditto] unable to recover \(url.lastPathComponent): \(error)")
            }
        }
        if recoveredEntries > 0 || recoveredEmergency {
            flush()
            NSLog("[Ditto] recovered \(recoveredEntries) clipboard entries from previously quarantined databases.")
        }
        // Only after the merge has committed: the emergency file is reused
        // whenever the main database is unavailable, so leaving it in place
        // means the next failure grows it and re-imports everything again —
        // which resets paste counts, groups and favorites on those clips.
        // Archiving keeps the data without letting it be imported twice.
        if recoveredEmergency {
            archiveRecoveredEmergencyDatabase(at: emergencyURL, in: directory)
        }
        UserDefaults.standard.set(Array(recovered), forKey: Self.recoveredQuarantinesKey)
    }

    private func archiveRecoveredEmergencyDatabase(at emergencyURL: URL, in directory: URL) {
        let manager = FileManager.default
        let backups = directory.appendingPathComponent("Backups", isDirectory: true)
        do {
            try manager.createDirectory(at: backups, withIntermediateDirectories: true)
            let stamp = Self.timestampFormatter.string(from: Date())
            let archived = backups.appendingPathComponent("Ditto-emergency-recovered-\(stamp).db")
            try manager.moveItem(at: emergencyURL, to: archived)
            for suffix in ["-wal", "-shm"] {
                let sidecar = URL(fileURLWithPath: emergencyURL.path + suffix)
                if manager.fileExists(atPath: sidecar.path) {
                    try? manager.moveItem(at: sidecar, to: URL(fileURLWithPath: archived.path + suffix))
                }
            }
            NSLog("[Ditto] archived the recovered emergency database to \(archived.path)")
        } catch {
            NSLog("[Ditto] could not archive the recovered emergency database: \(Self.describe(error))")
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

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
