import AppKit
import Carbon
import CoreGraphics
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

    /// Cut the current selection into slot N (sends Cmd+X, then captures).
    func cutCurrentClipboard(into slot: Int) {
        // Send Cmd+X to the active app, then capture the result after a delay.
        DispatchQueue.global(qos: .userInitiated).async {
            let source = CGEventSource(stateID: .combinedSessionState)
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(7), keyDown: true) // X
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(7), keyDown: false)
            keyDown?.flags = .maskCommand
            keyUp?.flags = .maskCommand
            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.3)
            DispatchQueue.main.async {
                self.captureCurrentClipboard(into: slot)
            }
        }
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
        // Bind to the exact entry returned (not entries.first, which races with
        // concurrent captures).
        if let entry = store.addClipboardPayload(
            text: text,
            rtfData: rtfData,
            htmlData: htmlData,
            imageData: imageData,
            fileURLs: fileURLs,
            sourceApp: "Copy Buffer \(slot)"
        ) {
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
