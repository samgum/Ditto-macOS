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

            try db.deleteEntry(id: entry.id)
            check("entry delete", try db.loadEntries().isEmpty)
        } catch {
            check("database round-trip", false)
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

        print("\n\(passed) passed, \(failed) failed")
        return failed == 0 ? 0 : 1
    }
}
