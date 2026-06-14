import AppKit
import Carbon
import Foundation

/// Numbered copy/paste slots (1-5). Each slot remembers one clip; a global
/// hot key copies the current clipboard into a slot, and another hot key
/// pastes the slot back. Mirrors the Windows `CCopyBuffer` / CopyBuffers
/// table.
final class CopyBufferManager {
    static let slotCount = 5

    private let store: ClipboardStore
    private let copyBufferHotKeysKey = "Ditto.CopyBufferHotKeys"

    /// Serialised `[HotKey]` for copy/paste per slot (2 * slotCount entries:
    /// copy then paste).
    struct SlotHotKeys: Codable {
        var copyKey: HotKey?
        var pasteKey: HotKey?
    }

    var slotHotKeys: [SlotHotKeys]

    init(store: ClipboardStore) {
        self.store = store
        let stored = CopyBufferManager.loadStored()
        var keys: [SlotHotKeys] = []
        for index in 0..<CopyBufferManager.slotCount {
            keys.append(index < stored.count ? stored[index] : SlotHotKeys())
        }
        self.slotHotKeys = keys
    }

    /// Copy whatever is currently on the pasteboard into slot N.
    func captureCurrentClipboard(into slot: Int) {
        guard (1...CopyBufferManager.slotCount).contains(slot) else { return }
        let pasteboard = NSPasteboard.general
        let text = pasteboard.string(forType: .string)
        let rtfData = pasteboard.data(forType: .rtf)
        let htmlData = pasteboard.data(forType: .dittoHTML)
        let imageData = ClipboardMonitor.imageData(from: pasteboard)
        let fileURLs = ClipboardMonitor.fileURLs(from: pasteboard)

        // Save as a real history entry so it has an id, then bind it to the slot.
        store.addClipboardPayload(
            text: text,
            rtfData: rtfData,
            htmlData: htmlData,
            imageData: imageData,
            fileURLs: fileURLs,
            sourceApp: "Copy Buffer \(slot)"
        )
        if let entry = store.snapshotEntries().first {
            store.setCopyBuffer(slot: slot, entryId: entry.id)
        }
    }

    func entry(in slot: Int) -> ClipboardEntry? {
        guard let id = store.copyBuffer(for: slot) else { return nil }
        return store.entry(id: id)
    }

    func paste(slot: Int) -> ClipboardEntry? {
        guard let entry = entry(in: slot) else { return nil }
        store.copyToPasteboard(entry)
        return entry
    }

    // MARK: - Hot key persistence

    func save() {
        let data = (try? JSONEncoder().encode(slotHotKeys)) ?? Data()
        UserDefaults.standard.set(data, forKey: copyBufferHotKeysKey)
    }

    private static func loadStored() -> [SlotHotKeys] {
        guard let data = UserDefaults.standard.data(forKey: "Ditto.CopyBufferHotKeys"),
              let decoded = try? JSONDecoder().decode([SlotHotKeys].self, from: data) else {
            return []
        }
        return decoded
    }
}
