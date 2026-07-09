import AppKit
import Foundation

/// Snapshots the system pasteboard and restores it after a paste, so that
/// pasting a Ditto clip does not clobber whatever the user already had on the
/// clipboard. Mirrors the Windows `CClipboardSaveRestore` +
/// `RestoreClipboardDelay` (default 750 ms) behaviour.
final class ClipboardSaveRestore {
    struct Snapshot {
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
        return Snapshot(items: items)
    }

    static func restore(
        _ snapshot: Snapshot,
        onlyIfChangeCount expectedChangeCount: Int,
        afterDelay delay: TimeInterval = 1.2,
        onRestored: (() -> Void)? = nil
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let pasteboard = NSPasteboard.general
            // Only restore when Ditto's own pasteboard write is still current.
            // A different count means the user copied something new after the
            // paste, and restoring would overwrite that newer clipboard data.
            guard pasteboard.changeCount == expectedChangeCount else { return }
            pasteboard.clearContents()
            if snapshot.items.isEmpty == false {
                pasteboard.writeObjects(snapshot.items)
            }
            // Let the caller sync the monitor so the restored contents aren't
            // re-captured as a new history entry.
            onRestored?()
        }
    }
}
