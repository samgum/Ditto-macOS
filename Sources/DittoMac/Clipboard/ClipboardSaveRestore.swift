import AppKit
import Foundation

/// Snapshots the system pasteboard and restores it after a paste, so that
/// pasting a Ditto clip does not clobber whatever the user already had on the
/// clipboard. Mirrors the Windows `CClipboardSaveRestore` +
/// `RestoreClipboardDelay` (default 750 ms) behaviour.
final class ClipboardSaveRestore {
    struct Snapshot {
        let changeCount: Int
        let items: [NSPasteboardItem]
    }

    static func snapshot() -> Snapshot {
        let pasteboard = NSPasteboard.general
        let items = (pasteboard.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
        return Snapshot(changeCount: pasteboard.changeCount, items: items)
    }

    static func restore(_ snapshot: Snapshot, afterDelay delay: TimeInterval = 0.75) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let pasteboard = NSPasteboard.general
            // Only restore if the clipboard hasn't been changed by the user
            // since the snapshot (otherwise we'd overwrite a fresh copy).
            guard pasteboard.changeCount >= snapshot.changeCount else { return }
            pasteboard.clearContents()
            if snapshot.items.isEmpty == false {
                pasteboard.writeObjects(snapshot.items)
            }
        }
    }
}
