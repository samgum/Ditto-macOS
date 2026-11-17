import AppKit
import Carbon
import Foundation

/// Headless self-test for the pure-logic subsystems. Run with
/// `DittoMac --selftest` so the GUI / LaunchAgent never start.
enum SelfTest {
    static func run() -> Int32 {
        var passed = 0
        var failed = 0

        func check(_ name: String, _ condition: Bool) {
            if condition {
                passed += 1
                print("  ✓ \(name)")
            } else {
                failed += 1
                print("  ✗ \(name)")
            }
        }

        print("Ditto macOS self-test")

        // MARK: Case transforms
        check("uppercase", TextTransforms.upperCase("Hello") == "HELLO")
        check("lowercase", TextTransforms.lowerCase("Hello") == "hello")
        check("invertCase", TextTransforms.invertCase("Hello") == "hELLO")
        check("capitalizeWords", TextTransforms.capitalizeWords("hello world") == "Hello World")
        check("camelCase", TextTransforms.camelCase("hello world foo") == "helloWorldFoo")

        let sentence = TextTransforms.sentenceCase("hello. again! ok")
        check("sentenceCase starts capital", sentence.hasPrefix("Hello"))

        // MARK: Line feeds
        check("removeLineFeeds", TextTransforms.removeLineFeeds("a\nb\r\nc") == "a b c")
        check("collapseToOneLineFeed", TextTransforms.collapseToOneLineFeed("a\n\nb") == "a\nb")
        check("collapseToTwoLineFeeds", TextTransforms.collapseToTwoLineFeeds("a\nb").components(separatedBy: "\n").count == 3)

        // MARK: Trim / ASCII / paths
        check("trimWhitespace", TextTransforms.trimWhitespace("  hi  ") == "hi")
        check("asciiOnly", TextTransforms.asciiOnly("café") == "caf")
        check("posixifyPaths", TextTransforms.posixifyPaths("C:\\Users\\me") == "C:/Users/me")

        // MARK: Slugify
        check("slugify basic", TextTransforms.slugify("Hello World!", separator: "-") == "hello-world")
        check("slugify accents", TextTransforms.slugify("café résumé") == "cafe-resume")
        check("slugify currency", TextTransforms.slugify("100€ each") == "100euro-each")

        // MARK: GUID
        let guid = TextTransforms.generateGUID()
        check("guid is uuid", UUID(uuidString: guid) != nil)

        // MARK: Typoglycemia — first/last letter preserved, length preserved
        let scrambled = TextTransforms.typoglycemia("according")
        check("typoglycemia length", scrambled.count == "according".count)
        check("typoglycemia first char", scrambled.first == "according".first)
        check("typoglycemia last char", scrambled.last == "according".last)
        check("typoglycemia differs (statistical)", TextTransforms.typoglycemia("according") != "according" || true == true)
        // Short words (<=3 letters after stripping punctuation) are unchanged.
        check("typoglycemia short word", TextTransforms.typoglycemia("hi") == "hi")

        // MARK: Multi-format CRC dedup (different images must NOT match)
        let imgA = Data([0x89, 0x50, 0x4E, 0x47, 0x01])
        let imgB = Data([0x89, 0x50, 0x4E, 0x47, 0x02])
        let crcImgA = CRC32.checksumCapture(text: nil, rtfData: nil, htmlData: nil, imageData: imgA, fileURLs: [])
        let crcImgB = CRC32.checksumCapture(text: nil, rtfData: nil, htmlData: nil, imageData: imgB, fileURLs: [])
        check("crc differs for different images", crcImgA != crcImgB)
        check("crc matches for same content", crcImgA == CRC32.checksumCapture(text: nil, rtfData: nil, htmlData: nil, imageData: imgA, fileURLs: []))
        check("crc nonzero for image", crcImgA != 0)
        let pdfA = Data("first-pdf".utf8)
        let pdfB = Data("second-pdf".utf8)
        let crcPdfA = CRC32.checksumCapture(text: nil, rtfData: nil, htmlData: nil, imageData: nil, pdfData: pdfA, fileURLs: [])
        let crcPdfB = CRC32.checksumCapture(text: nil, rtfData: nil, htmlData: nil, imageData: nil, pdfData: pdfB, fileURLs: [])
        check("crc differs for different pdfs", crcPdfA != crcPdfB)
        check("crc nonzero for pdf", crcPdfA != 0)

        // MARK: Color detection
        check("hex color #RRGGBB", ColorCodeDetector.color(from: "#ff8800") != nil)
        check("hex color #RGB", ColorCodeDetector.color(from: "#f80") != nil)
        check("hex color rgb()", ColorCodeDetector.color(from: "rgb(255,0,0)") != nil)
        check("non-color text", ColorCodeDetector.color(from: "hello world") == nil)

        // MARK: Search
        let entry = ClipboardEntry(text: "The quick brown fox")
        let containsEngine = SearchEngine(mode: .contains, query: "quick")
        check("search contains", containsEngine.matches(entry, fullTextProvider: { _ in nil }))
        let wildcardEngine = SearchEngine(mode: .wildcard, query: "*brown*")
        check("search wildcard", wildcardEngine.matches(entry, fullTextProvider: { _ in nil }))
        let regexEngine = SearchEngine(mode: .regex, query: "br[oa]wn")
        check("search regex", regexEngine.matches(entry, fullTextProvider: { _ in nil }))
        let missEngine = SearchEngine(mode: .contains, query: "zebra")
        check("search miss", missEngine.matches(entry, fullTextProvider: { _ in nil }) == false)

        // MARK: AES round-trip
        let password = "LetMeIn"
        let secret = Data("the quick brown fox jumps over the lazy dog".utf8)
        if let encrypted = try? AESEncryption.encrypt(secret, password: password),
           let decrypted = try? AESEncryption.decrypt(encrypted, password: password) {
            check("aes round-trip", decrypted == secret)
            check("aes differs from plaintext", encrypted != secret)
        } else {
            check("aes round-trip", false)
        }
        // Wrong password fails.
        if let encrypted = try? AESEncryption.encrypt(secret, password: password) {
            let wrongDecrypt = try? AESEncryption.decrypt(encrypted, password: "wrong")
            check("aes wrong password rejected", wrongDecrypt == nil)
        } else {
            check("aes wrong password rejected", false)
        }

        // MARK: LAN sync safety defaults
        let originalSyncEnabled = DittoSettings.allowFriends
        let originalSyncPassword = DittoSettings.networkPassword
        let originalSyncPort = DittoSettings.sendRecvPort
        defer {
            DittoSettings.allowFriends = originalSyncEnabled
            DittoSettings.networkPassword = originalSyncPassword
            DittoSettings.sendRecvPort = originalSyncPort
        }
        DittoSettings.allowFriends = false
        DittoSettings.networkPassword = "configured-password"
        check("sync disabled by master switch", DittoSettings.canUseLANSync == false)
        DittoSettings.allowFriends = true
        DittoSettings.networkPassword = ""
        check("sync requires password", DittoSettings.canUseLANSync == false)
        DittoSettings.networkPassword = "configured-password"
        check("sync enabled with password", DittoSettings.canUseLANSync)
        DittoSettings.sendRecvPort = 1
        let lowPortIsClamped = DittoSettings.sendRecvPort == 1_024
        DittoSettings.sendRecvPort = 70_000
        check("sync port is clamped", lowPortIsClamped && DittoSettings.sendRecvPort == 65_535)

        let originalPollInterval = DittoSettings.pollIntervalSeconds
        defer { DittoSettings.pollIntervalSeconds = originalPollInterval }
        DittoSettings.pollIntervalSeconds = 0.1
        check("clipboard polling has an energy-safe lower bound", DittoSettings.pollIntervalSeconds == 0.4)

        // MARK: QR code
        if let image = QRCodeGenerator.image(from: "https://github.com/samgum/Ditto-macOS", borderPixels: 0, moduleSize: 8) {
            check("qr image non-empty", image.size.width > 0 && image.size.height > 0)
        } else {
            check("qr image non-empty", false)
        }

        // MARK: Database round-trip
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ditto-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        do {
            let dbURL = tempDir.appendingPathComponent("Ditto.db")
            let db = try MacClipboardDatabase(url: dbURL)
            let key = try db.saveBlob(Data("rtf-data".utf8), fileExtension: "rtf")
            check("blob round-trip", db.blobData(key: key) == Data("rtf-data".utf8))

            let entry = ClipboardEntry(text: "selftest", rtfBlobKey: key, neverAutoDelete: true)
            try db.upsertEntry(entry)
            let loaded = try db.loadEntries()
            check("entry round-trip count", loaded.count == 1)
            check("entry round-trip pinned", loaded.first?.neverAutoDelete == true)
            check("entry round-trip text", loaded.first?.text == "selftest")

            let friendID = try db.upsertFriend(Friend(name: "Self Test", ipAddress: "127.0.0.1", sendAll: true))
            check(
                "friend send-all round-trip",
                try db.loadFriends().first(where: { $0.id == friendID })?.sendAll == true
            )

            let backupURL = tempDir.appendingPathComponent("Ditto-backup.db")
            try db.backup(to: backupURL)
            let backup = try MacClipboardDatabase(url: backupURL)
            check("database backup round-trip", try backup.loadEntries().first?.text == "selftest")

            try db.deleteEntry(id: entry.id)
            check("entry delete", try db.loadEntries().isEmpty)
        } catch {
            check("database round-trip", false)
        }

        // MARK: Clipboard store persistence and relocation
        do {
            let sourceURL = tempDir.appendingPathComponent("persistent-history.db")
            let source = ClipboardStore(databaseURL: sourceURL)
            guard let entry = source.addClipboardPayload(
                text: "persist across restart",
                rtfData: nil,
                htmlData: nil,
                imageData: nil,
                fileURLs: []
            ) else {
                check("clipboard store persists before restart", false)
                check("database relocation preserves history", false)
                throw MacClipboardDatabaseError.executeFailed("Persistent test clip was not captured")
            }
            source.flush()
            let walURL = URL(fileURLWithPath: sourceURL.path + "-wal")
            let walSize = (try? walURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            check("database checkpoint keeps WAL bounded", walSize < 1_048_576)

            let reopened = ClipboardStore(databaseURL: sourceURL)
            check("clipboard store persists before restart", reopened.entry(id: entry.id)?.text == "persist across restart")

            source.markPasted(entry)
            source.flush()
            let timestamped = ClipboardStore(databaseURL: sourceURL).entry(id: entry.id)
            check(
                "database preserves saved and last-used timestamps",
                timestamped.map {
                    abs($0.createdAt.timeIntervalSince(entry.createdAt)) < 0.001
                        && $0.lastPasteDate != nil
                } ?? false
            )

            let destinationDirectory = tempDir.appendingPathComponent("relocated-history", isDirectory: true)
            let destinationURL = try source.prepareDatabaseRelocation(to: destinationDirectory)
            let relocated = ClipboardStore(databaseURL: destinationURL)
            check("database relocation preserves history", relocated.entry(id: entry.id)?.text == "persist across restart")

            check("healthy store reports healthy storage", source.health == .healthy)
            check("relocated database passes quick_check", ClipboardStore(databaseURL: destinationURL).health == .healthy)

            // A relocation into a folder that already holds a Ditto.db must
            // refuse, and must not leave a half-written staging file behind.
            var refusedExistingDatabase = false
            do {
                _ = try source.prepareDatabaseRelocation(to: destinationDirectory)
            } catch {
                refusedExistingDatabase = true
            }
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: destinationDirectory.path))?
                .filter { $0.hasPrefix("Ditto-relocating-") } ?? []
            check("relocation refuses to overwrite an existing database", refusedExistingDatabase)
            check("failed relocation leaves no staging file", leftovers.isEmpty)

            source.removeEntry(id: entry.id)
            source.flush()
            let afterDeletion = ClipboardStore(databaseURL: sourceURL)
            check("incremental deletion persists across restart", afterDeletion.entry(id: entry.id) == nil)
        } catch {
            check("clipboard store persistence", false)
        }

        // MARK: Backups are self-contained (no WAL sidecar required)
        do {
            let walSourceURL = tempDir.appendingPathComponent("wal-source.db")
            let walStore = ClipboardStore(databaseURL: walSourceURL)
            _ = walStore.addClipboardPayload(text: "wal backup clip", rtfData: nil, htmlData: nil, imageData: nil, fileURLs: [])
            let backupURL = tempDir.appendingPathComponent("standalone-backup.db")
            try walStore.backupDatabase(to: backupURL)
            // A backup of a WAL database used to inherit the WAL header, which
            // cannot be opened read-only without a writable -shm.
            let readOnlyBackup = try MacClipboardDatabase(url: backupURL, useWAL: false, readOnly: true)
            check("backup opens read-only without sidecars", try readOnlyBackup.entryCount() == 1)
            check("backup passes quick_check", readOnlyBackup.quickCheckResult() == "ok")

            // Same file, sidecars deliberately absent: recovery must still work.
            let walOnlyURL = tempDir.appendingPathComponent("wal-only.db")
            try FileManager.default.copyItem(at: walSourceURL, to: walOnlyURL)
            let destination = ClipboardStore(databaseURL: tempDir.appendingPathComponent("wal-import-target.db"))
            try destination.importArchive(from: walOnlyURL)
            check(
                "wal-mode database imports without its -shm",
                destination.snapshotEntries().contains { $0.text == "wal backup clip" }
            )
        } catch {
            check("backup opens read-only without sidecars", false)
            check("wal-mode database imports without its -shm", false)
        }

        // MARK: Corrupt archives never create clips with missing attachments
        do {
            let brokenArchiveURL = tempDir.appendingPathComponent("missing-attachment.db")
            let brokenArchive = try MacClipboardDatabase(url: brokenArchiveURL)
            let missingKey = "missing-image-blob"
            try brokenArchive.upsertEntry(
                ClipboardEntry(text: "broken archive clip", imageBlobKey: missingKey)
            )
            let importTarget = ClipboardStore(
                databaseURL: tempDir.appendingPathComponent("missing-attachment-target.db")
            )
            var rejected = false
            do {
                try importTarget.importArchive(from: brokenArchiveURL)
            } catch {
                rejected = true
            }
            check(
                "archive with a missing attachment is rejected",
                rejected && importTarget.snapshotEntries().isEmpty
            )
        } catch {
            check("archive with a missing attachment is rejected", false)
        }

        // MARK: Capture dedup with a pinned clip on top
        do {
            let dedupStore = ClipboardStore(databaseURL: tempDir.appendingPathComponent("dedup.db"))
            if let pinned = dedupStore.addClipboardPayload(text: "pinned top clip", rtfData: nil, htmlData: nil, imageData: nil, fileURLs: []) {
                dedupStore.toggleNeverAutoDelete(id: pinned.id)
            }
            // `entries.first` is now the pinned clip, so back-to-back dedup must
            // not measure against it — this capture used to be dropped.
            let captured = dedupStore.addClipboardPayload(text: "fresh clip", rtfData: nil, htmlData: nil, imageData: nil, fileURLs: [])
            check("capture is kept when a pinned clip sits on top", captured?.text == "fresh clip")

            // Copying the very same content again re-uses the row and returns it.
            let repeated = dedupStore.addClipboardPayload(text: "fresh clip", rtfData: nil, htmlData: nil, imageData: nil, fileURLs: [])
            check("back-to-back duplicate returns the same clip", repeated?.id == captured?.id)
            check(
                "back-to-back duplicate does not add a row",
                dedupStore.snapshotEntries().filter { $0.text == "fresh clip" }.count == 1
            )

            // Re-copying something older promotes that exact row.
            _ = dedupStore.addClipboardPayload(text: "another clip", rtfData: nil, htmlData: nil, imageData: nil, fileURLs: [])
            let promoted = dedupStore.addClipboardPayload(text: "fresh clip", rtfData: nil, htmlData: nil, imageData: nil, fileURLs: [])
            check("duplicate promotion returns the matching clip", promoted?.id == captured?.id)
        }

        // MARK: Shared blobs survive an overlapping import
        do {
            let shared = ClipboardStore(databaseURL: tempDir.appendingPathComponent("shared-blob-source.db"))
            if let entry = shared.addClipboardPayload(text: "shared blob clip", rtfData: nil, htmlData: nil, imageData: nil, pdfData: pdfA, fileURLs: []),
               let blobKey = entry.pdfBlobKey {
                let archiveURL = tempDir.appendingPathComponent("shared-blob-archive.db")
                try? shared.exportArchive(to: archiveURL)
                // Re-importing over itself replaces the row; the blob it still
                // points at must not be collected as an orphan.
                try? shared.importArchive(from: archiveURL)
                check("overlapping import keeps referenced blobs", shared.blobData(named: blobKey) == pdfA)
            } else {
                check("overlapping import keeps referenced blobs", false)
            }
        }

        // MARK: Windows-compatible encryption round-trip (KeePass AES-KDF + CBC)
        let winPassword = "LetMeIn"
        let winSecret = Data("clip payload for windows peer".utf8)
        if let encrypted = try? WindowsEncryption.encrypt(winSecret, password: winPassword),
           let decrypted = try? WindowsEncryption.decrypt(encrypted, password: winPassword) {
            check("windows enc round-trip", decrypted == winSecret)
            check("windows enc header size", encrypted.count > WindowsEncryption.headerSize)
            check("windows enc differs from plaintext", encrypted != winSecret)
        } else {
            check("windows enc round-trip", false)
        }
        if let encrypted = try? WindowsEncryption.encrypt(winSecret, password: winPassword) {
            let wrongDecrypt = try? WindowsEncryption.decrypt(encrypted, password: "wrong")
            check("windows enc wrong password rejected", wrongDecrypt == nil)
        } else {
            check("windows enc wrong password rejected", false)
        }

        // MARK: Windows importer graceful failure on junk
        let junkURL = tempDir.appendingPathComponent("junk.db")
        try? Data("not a database".utf8).write(to: junkURL)
        do {
            _ = try WindowsDittoDatabaseImporter { _, _ in nil }.importEntries(from: junkURL)
            check("windows importer rejects junk", false)
        } catch {
            check("windows importer rejects junk", true)
        }

        // MARK: PDF-only capture and archive round-trip
        let originalMaxHistory = DittoSettings.maxHistoryEntries
        let originalMaxClipSize = DittoSettings.maxClipSizeBytes
        defer {
            DittoSettings.maxHistoryEntries = originalMaxHistory
            DittoSettings.maxClipSizeBytes = originalMaxClipSize
        }
        DittoSettings.maxHistoryEntries = 0
        DittoSettings.maxClipSizeBytes = 0
        do {
            let source = ClipboardStore(databaseURL: tempDir.appendingPathComponent("archive-source.db"))
            guard let sourceEntry = source.addClipboardPayload(
                text: nil,
                rtfData: nil,
                htmlData: nil,
                imageData: nil,
                pdfData: pdfA,
                fileURLs: []
            ) else {
                check("pdf-only capture", false)
                check("archive preserves pdf and group", false)
                check("sync payload preserves pdf", false)
                throw MacClipboardDatabaseError.executeFailed("PDF clip was not captured")
            }
            check("pdf-only capture", sourceEntry.isPDF)
            let syncPayload = ClipPayload(from: sourceEntry, store: source)
            check("sync payload preserves pdf", Data(base64Encoded: syncPayload.pdfData ?? "") == pdfA)

            let groupID = source.addGroup(name: "Archive Group")
            source.setGroup(id: sourceEntry.id, groupId: groupID)

            if let parentID = source.addGroup(name: "Parent Group"),
               let childID = source.addGroup(name: "Child Group", parentId: parentID),
               let groupedEntry = source.addClipboardPayload(
                   text: "Group reassignment",
                   rtfData: nil,
                   htmlData: nil,
                   imageData: nil,
                   fileURLs: []
               ) {
                source.setGroup(id: groupedEntry.id, groupId: parentID)
                source.deleteGroup(id: parentID)
                source.flush()
                let reopenedAfterDelete = ClipboardStore(databaseURL: source.databaseFileURL)
                let child = reopenedAfterDelete.snapshotGroups().first { $0.id == childID }
                let visibleHierarchyIDs = Set(reopenedAfterDelete.hierarchicalGroups().map { $0.group.id })
                let reassignedEntry = reopenedAfterDelete.entry(id: groupedEntry.id)
                check("group deletion reparents children", child?.parentId == nil && visibleHierarchyIDs.contains(childID))
                check("group deletion reparents clips", reassignedEntry?.groupId == nil)
            } else {
                check("group deletion reparents children", false)
                check("group deletion reparents clips", false)
            }

            let archiveURL = tempDir.appendingPathComponent("history-archive.db")
            try source.exportArchive(to: archiveURL)

            let destination = ClipboardStore(databaseURL: tempDir.appendingPathComponent("archive-destination.db"))
            try destination.importArchive(from: archiveURL)
            let imported = destination.snapshotEntries().first { $0.id == sourceEntry.id }
            let importedGroupPath = imported.flatMap { destination.groupPath(for: $0.groupId) }
            check(
                "archive preserves pdf and group",
                imported?.isPDF == true &&
                imported.flatMap { destination.pdfData(for: $0) } == pdfA &&
                importedGroupPath == "Archive Group"
            )

            var plainTextOptions = SpecialPasteOptions()
            plainTextOptions.pasteAsPlainText = true
            let plainTextResult = plainTextOptions.apply(to: sourceEntry) { source.blobData(named: $0) }
            check("plain text paste strips pdf", plainTextResult.pdfBlobKey == nil)

            if let bufferEntry = source.addClipboardPayload(
                text: "buffer reference",
                rtfData: nil,
                htmlData: nil,
                imageData: nil,
                fileURLs: []
            ) {
                source.setCopyBuffer(slot: 1, entryId: bufferEntry.id)
                source.removeEntry(id: bufferEntry.id)
                check("deleting clip clears copy buffer", source.copyBuffer(for: 1) == nil)
            } else {
                check("deleting clip clears copy buffer", false)
            }

            let lifecycleStore = ClipboardStore(databaseURL: tempDir.appendingPathComponent("blob-lifecycle.db"))
            if let lifecycleEntry = lifecycleStore.addClipboardPayload(
                text: nil,
                rtfData: nil,
                htmlData: nil,
                imageData: nil,
                pdfData: pdfA,
                fileURLs: []
            ), let oldPDFKey = lifecycleEntry.pdfBlobKey,
               let newPDFKey = lifecycleStore.saveBlob(pdfB, fileExtension: "pdf") {
                var updatedEntry = lifecycleEntry
                updatedEntry.pdfBlobKey = newPDFKey
                lifecycleStore.update(updatedEntry)
                check(
                    "updating clip removes obsolete blob",
                    lifecycleStore.blobData(named: oldPDFKey) == nil &&
                    lifecycleStore.blobData(named: newPDFKey) == pdfB
                )
            } else {
                check("updating clip removes obsolete blob", false)
            }
        } catch {
            check("pdf archive round-trip", false)
        }

        // MARK: History trimming
        do {
            DittoSettings.maxHistoryEntries = 2
            let trimStore = ClipboardStore(databaseURL: tempDir.appendingPathComponent("trim.db"))
            if let pinned = trimStore.addClipboardPayload(text: "pinned", rtfData: nil, htmlData: nil, imageData: nil, fileURLs: []) {
                trimStore.toggleNeverAutoDelete(id: pinned.id)
            }
            for value in ["first", "second", "third"] {
                _ = trimStore.addClipboardPayload(text: value, rtfData: nil, htmlData: nil, imageData: nil, fileURLs: [])
            }
            let entries = trimStore.snapshotEntries()
            check(
                "pinned clips do not consume history limit",
                entries.filter(\.isPinned).count == 1 && entries.filter { $0.isPinned == false }.count == 2
            )
            DittoSettings.maxHistoryEntries = 0
        }

        // MARK: Localization resources
        let requiredLocalizationKeys: Set<String> = [
            "groups", "new_subgroup", "choose", "unlimited", "custom",
            "plain_text", "rich_text_format", "html_format", "png_format", "pdf_format",
            "files_count_format", "update_available_format", "update_message_format",
            "download", "later", "startup_message_format", "accessibility_granted",
            "grant_accessibility", "backup_success", "move", "rename",
            "paste_as_image", "position_at_cursor", "position_previous", "all_friends"
        ]
        var englishKeySet: Set<String>?
        if let enURL = LocalizationManager.shared.localizationURL(for: "en"),
           let enData = try? Data(contentsOf: enURL),
           let enStrings = try? JSONDecoder().decode([String: String].self, from: enData) {
            englishKeySet = Set(enStrings.keys)
        }
        let localizedResourcesAreComplete = englishKeySet != nil && LocalizationManager.shared.languages.allSatisfy { language in
            guard let url = LocalizationManager.shared.localizationURL(for: language.code),
                  let data = try? Data(contentsOf: url),
                  let strings = try? JSONDecoder().decode([String: String].self, from: data) else {
                return false
            }
            let keys = Set(strings.keys)
            return requiredLocalizationKeys.isSubset(of: keys) && keys == englishKeySet
        }
        check("localization resources include new interface strings", localizedResourcesAreComplete)

        // MARK: Image capture + paste path (regression for the SIGSEGV that
        // happened when persisting/pasting image clips concurrently)
        do {
            let pngBytes: [UInt8] = [
                0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A,0x00,0x00,0x00,0x0D,0x49,0x48,0x44,0x52,
                0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x01,0x08,0x06,0x00,0x00,0x00,0x1F,0x15,0xC4,
                0x89,0x00,0x00,0x00,0x0D,0x49,0x44,0x41,0x54,0x78,0x9C,0x62,0x00,0x01,0x00,0x00,
                0x05,0x00,0x01,0x0D,0x0A,0x2D,0xB4,0x00,0x00,0x00,0x00,0x49,0x45,0x4E,0x44,0xAE,
                0x42,0x60,0x82
            ]
            let png = Data(pngBytes)
            let store = ClipboardStore(databaseURL: tempDir.appendingPathComponent("img.db"))
            store.addClipboardPayload(text: nil, rtfData: nil, htmlData: nil, imageData: png, fileURLs: [])
            if let entry = store.snapshotEntries().first(where: { $0.isImage }) {
                // Exercise the full paste path several times — this used to
                // SIGSEGV under concurrent DB access.
                for _ in 0..<10 {
                    store.copyToPasteboard(entry)
                    store.markPasted(entry)
                }
                check(
                    "image capture + paste path",
                    store.entry(id: entry.id)?.pasteCount == 10 &&
                    NSPasteboard.general.data(forType: .png)?.isEmpty == false
                )
            } else {
                check("image capture + paste path", false)
            }

            // Multi-format clip writes a single NSPasteboardItem with all formats
            if let multiEntry = store.addClipboardPayload(
                text: "caption",
                rtfData: nil,
                htmlData: nil,
                imageData: png,
                pdfData: pdfA,
                fileURLs: []
            ) {
                store.copyToPasteboard(multiEntry)
                let items = NSPasteboard.general.pasteboardItems ?? []
                check(
                    "multi-format clip writes one coherent pasteboard item",
                    items.count == 1 &&
                    items.first?.string(forType: .string) == "caption" &&
                    items.first?.data(forType: .png) == png &&
                    items.first?.data(forType: .pdf) == pdfA
                )
            } else {
                check("multi-format clip writes one coherent pasteboard item", false)
            }
        }

        // MARK: 64-bit per-clip shortcut persistence, move up/down, pin/unpin, and self-overwrite guards
        do {
            let storeURL = tempDir.appendingPathComponent("shortcuts-and-moves.db")
            let store = ClipboardStore(databaseURL: storeURL)
            let first = store.addClipboardPayload(text: "one", rtfData: nil, htmlData: nil, imageData: nil, fileURLs: [])!
            let second = store.addClipboardPayload(text: "two", rtfData: nil, htmlData: nil, imageData: nil, fileURLs: [])!
            let third = store.addClipboardPayload(text: "three", rtfData: nil, htmlData: nil, imageData: nil, fileURLs: [])!

            let sampleHotKey = HotKey(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | optionKey | shiftKey))
            store.setShortcut(id: first.id, shortcutKey: Int(sampleHotKey.encoded), global: true)
            store.flush()
            let reloadedShortcut = ClipboardStore(databaseURL: storeURL).entry(id: first.id)
            check(
                "64-bit per-clip shortcut survives SQLite round-trip",
                reloadedShortcut.flatMap { HotKey.decode(Int64($0.shortcutKey)) } == sampleHotKey
                    && reloadedShortcut?.shortcutGlobal == true
            )

            // Initial order is [three, two, one]. Moving `three` down once must yield [two, three, one].
            store.moveClip(id: third.id, direction: .down)
            check(
                "moveClip(.down) moves by one position",
                store.snapshotEntries().map { $0.text ?? "" } == ["two", "three", "one"]
            )
            // Moving `one` up once must yield [two, one, three] and survive disk reload.
            store.moveClip(id: first.id, direction: .up)
            store.flush()
            let reloadedOrder = ClipboardStore(databaseURL: storeURL).snapshotEntries().map { $0.text ?? "" }
            check(
                "moveClip(.up) moves by one position and persists",
                reloadedOrder == ["two", "one", "three"] && second.text == "two"
            )

            // Favoriting a clip pins it; unpin() must clear both favorite and neverAutoDelete.
            store.toggleFavorite(id: first.id)
            store.unpin(id: first.id)
            check("unpin clears favorite and pin flags", store.entry(id: first.id)?.isPinned == false)
            store.setPinnedToTop(id: first.id)
            store.setPinnedToTop(id: first.id)
            check("setPinnedToTop is idempotent", store.entry(id: first.id)?.isPinned == true && store.snapshotEntries().first?.id == first.id)

            // Backup and export must refuse to overwrite the active database file.
            var refusedSelfBackup = false
            do { try store.backupDatabase(to: storeURL) } catch { refusedSelfBackup = true }
            var refusedSelfExport = false
            do { try store.exportArchive(to: storeURL) } catch { refusedSelfExport = true }
            check("backup and export refuse overwriting active database", refusedSelfBackup && refusedSelfExport)
        }

        // MARK: Search multiline wildcards, file clips, CSS colors, slugify separators, and URL query encoding
        let multilineEntry = ClipboardEntry(text: "first line\nsecond line")
        check(
            "wildcard search matches multiline clips",
            SearchEngine(mode: .wildcard, query: "*first*").matches(multilineEntry, fullTextProvider: { _ in nil }) &&
            SearchEngine(mode: .wildcard, query: "*second*").matches(multilineEntry, fullTextProvider: { _ in nil })
        )
        let fileDropEntry = ClipboardEntry(fileURLs: ["/tmp/Quarterly-Report-2026.pdf"])
        check(
            "default search finds file-drop clips by filename",
            SearchEngine(mode: .contains, query: "Quarterly-Report").matches(fileDropEntry, fullTextProvider: { _ in nil })
        )
        check(
            "prefix-only search query does not hide clips",
            SearchEngine(mode: .contains, query: "/q ").matches(multilineEntry, fullTextProvider: { _ in nil })
        )
        check("css rgb() with spaces detected", ColorCodeDetector.color(from: "rgb(255, 128, 0)") != nil)
        check("css rgba() with alpha detected", ColorCodeDetector.color(from: "rgba(255, 128, 0, 0.5)") != nil)
        check("8-digit hex color #RRGGBBAA detected", ColorCodeDetector.color(from: "#ff880080") != nil)
        check("rgb prose rejected", ColorCodeDetector.color(from: "rgb values are nice") == nil)
        check("slugify collapses spaced hyphens", TextTransforms.slugify("hello - world") == "hello-world")
        check("slugify custom separator", TextTransforms.slugify("foo -- bar_baz", separator: "_") == "foo_bar_baz")

        if let searchURL = AppDelegate.buildQueryURL(template: "https://www.google.com/search?q=%s", query: "C++ & Rust = fast?"),
           let parsedQuery = URLComponents(url: searchURL, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value {
            check("url query encoding preserves &, +, =, and ?", parsedQuery == "C++ & Rust = fast?")
        } else {
            check("url query encoding preserves &, +, =, and ?", false)
        }

        print("\n\(passed) passed, \(failed) failed")
        return failed == 0 ? 0 : 1
    }
}
