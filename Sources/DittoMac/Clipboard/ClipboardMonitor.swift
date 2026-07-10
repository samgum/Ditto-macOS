import AppKit
import Foundation

/// Polls `NSPasteboard.general` and feeds captured clips into the store.
///
/// macOS offers no clipboard-change notification, so like the original macOS
/// port we poll `changeCount` at a configurable interval. We also record the
/// frontmost application at capture time (Windows `ExternalWindowTracker`)
/// and honour the include/exclude app filters.
final class ClipboardMonitor {
    private let pasteboard = NSPasteboard.general
    private let store: ClipboardStore
    private var lastChangeCount: Int
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "org.ditto-cp.DittoMac.clipboard", qos: .utility)
    var onChange: ((ClipboardEntry) -> Void)?

    init(store: ClipboardStore) {
        self.store = store
        lastChangeCount = NSPasteboard.general.changeCount
    }

    func start() {
        // Idempotent: never stack a second timer if already running (a future
        // restart path would otherwise leak the old timer and poll at 2× rate).
        guard timer == nil else { return }
        let interval = DittoSettings.pollIntervalSeconds
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + interval,
            repeating: interval,
            leeway: .milliseconds(150)
        )
        timer.setEventHandler { [weak self] in
            self?.poll()
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Force an immediate capture poll (used after `NSPasteboard.writeObjects`
    /// by our own copy path to keep the change count in sync).
    func syncChangeCount() {
        let changeCount = pasteboard.changeCount
        queue.sync {
            lastChangeCount = changeCount
        }
    }

    private func poll() {
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        let frontApp = NSWorkspace.shared.frontmostApplication
        let bundleId = frontApp?.bundleIdentifier
        let appName = frontApp?.localizedName

        // Respect the Windows "Clipboard Viewer Ignore" / exclusion convention:
        // if the pasting app is Ditto itself, do not re-capture our own paste.
        if bundleId == Bundle.main.bundleIdentifier {
            return
        }

        // Honour the Windows/macOS exclusion markers: apps that place these
        // hint types on the pasteboard signal "do not record this."
        for excludeType in ClipboardMonitor.excludeFormatTypes {
            if pasteboard.types?.contains(excludeType) == true {
                return
            }
        }

        guard DittoSettings.shouldCapture(bundleId: bundleId) else { return }

        let text = pasteboard.string(forType: .string)

        // Regex copy filters — skip capturing clips that match any pattern
        // (e.g. passwords, tokens, one-time codes).
        if let text, DittoSettings.textMatchesCopyFilter(text) {
            return
        }
        let rtfData = pasteboard.data(forType: .rtf)
        let htmlData = pasteboard.data(forType: .dittoHTML)
        let imageData = ClipboardMonitor.imageData(from: pasteboard)
        let pdfData = pasteboard.data(forType: .pdf)
        let fileURLs = ClipboardMonitor.fileURLs(from: pasteboard)

        guard let entry = store.addClipboardPayload(
            text: text,
            rtfData: rtfData,
            htmlData: htmlData,
            imageData: imageData,
            pdfData: pdfData,
            fileURLs: fileURLs,
            sourceApp: appName
        ) else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.onChange?(entry)
        }

        if DittoSettings.playSoundOnCopy {
            NSSound(named: NSSound.Name("Tink"))?.play()
        }
    }

    static func imageData(from pasteboard: NSPasteboard) -> Data? {
        if let pngData = pasteboard.data(forType: .png) { return pngData }
        guard let tiffData = pasteboard.data(forType: .tiff),
              let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [NSURL]
        return urls?.map { $0 as URL } ?? []
    }

    /// Pasteboard types that signal "do not record this clip" — the macOS
    /// equivalent of the Windows `Clipboard Viewer Ignore` /
    /// `ExcludeClipboardContentFromMonitorProcessing` registered formats.
    /// Also honours the Windows 10 `CanIncludeInClipboardHistory`=false hint.
    static let excludeFormatTypes: [NSPasteboard.PasteboardType] = [
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"),
        NSPasteboard.PasteboardType("Clipboard Viewer Ignore"),
        NSPasteboard.PasteboardType("ExcludeClipboardContentFromMonitorProcessing"),
        NSPasteboard.PasteboardType("MicrosoftEdge Clipboard Format")
    ]
}
