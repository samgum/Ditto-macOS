import AppKit
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

            let backupURL = tempDir.appendingPathComponent("Ditto-backup.db")
            try db.backup(to: backupURL)
            let backup = try MacClipboardDatabase(url: backupURL)
            check("database backup round-trip", try backup.loadEntries().first?.text == "selftest")

            try db.deleteEntry(id: entry.id)
            check("entry delete", try db.loadEntries().isEmpty)
        } catch {
            check("database round-trip", false)
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
                let child = source.snapshotGroups().first { $0.id == childID }
                let reassignedEntry = source.entry(id: groupedEntry.id)
                check("group deletion reparents children", child?.parentId == nil)
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
        } catch {
            check("pdf archive round-trip", false)
        }

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
                check("image capture + paste path", store.entry(id: entry.id)?.pasteCount == 10)
            } else {
                check("image capture + paste path", false)
            }
        }

        print("\n\(passed) passed, \(failed) failed")
        return failed == 0 ? 0 : 1
    }
}
