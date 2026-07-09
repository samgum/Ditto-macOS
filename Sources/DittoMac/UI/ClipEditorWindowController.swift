import AppKit
import Foundation

/// A simple rich-text editor for a clip. Edits update the stored text (and, if
/// the source had RTF, the RTF payload). Mirrors the Windows `EditWnd`.
final class ClipEditorWindowController: NSWindowController, NSTextViewDelegate {
    private let store: ClipboardStore
    private var entry: ClipboardEntry
    private let onChanged: () -> Void
    private let textView = NSTextView()
    private let saveButton = NSButton(title: "", target: nil, action: nil)
    private let saveAndClipboardButton = NSButton(title: "", target: nil, action: nil)
    private let closeButton = NSButton(title: "", target: nil, action: nil)

    var syncMonitor: (() -> Void)?

    init(store: ClipboardStore, entry: ClipboardEntry, onChanged: @escaping () -> Void) {
        self.store = store
        self.entry = entry
        self.onChanged = onChanged

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 440),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.applyDittoAppearance()
        window.title = LocalizationManager.shared.text("edit_clip")
        window.center()
        super.init(window: window)

        textView.delegate = self
        textView.font = NSFont.systemFont(ofSize: CGFloat(DittoSettings.fontSize))
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true

        if let key = entry.rtfBlobKey, let data = store.blobData(named: key),
           let attributed = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
            textView.textStorage?.setAttributedString(attributed)
        } else {
            textView.string = entry.text ?? ""
        }

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        saveButton.title = LocalizationManager.shared.text("save")
        saveButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"

        saveAndClipboardButton.title = LocalizationManager.shared.text("save") + " + " + LocalizationManager.shared.text("copy")
        saveAndClipboardButton.bezelStyle = .rounded
        saveAndClipboardButton.target = self
        saveAndClipboardButton.action = #selector(saveAndPutOnClipboard)

        closeButton.title = LocalizationManager.shared.text("close")
        closeButton.bezelStyle = .rounded
        closeButton.target = self
        closeButton.action = #selector(close)
        closeButton.keyEquivalent = "\u{1b}"

        let buttonRow = NSStackView(views: [NSView(), saveAndClipboardButton, saveButton, closeButton])
        buttonRow.orientation = .horizontal
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(scrollView)
        root.addSubview(buttonRow)
        window.contentView = root

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: buttonRow.topAnchor, constant: -12),

            buttonRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            buttonRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            buttonRow.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)
        ])
    }

    required init?(coder: NSCoder) { nil }

    @objc private func save() {
        let text = textView.string
        entry.text = text.isEmpty ? nil : text
        // Regenerate RTF from the rich text view if the clip was rich text.
        if entry.rtfBlobKey != nil {
            let attributed = textView.attributedString()
            if let data = try? attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
                entry.rtfBlobKey = store.saveBlob(data, fileExtension: "rtf") ?? entry.rtfBlobKey
            }
        }
        store.update(entry)
        onChanged()
        close()
    }

    /// Save and place the edited clip on the system clipboard (Windows
    /// EditWnd "Save & Close & put on clipboard").
    @objc private func saveAndPutOnClipboard() {
        save()
        store.copyToPasteboard(entry)
        syncMonitor?()
    }
}
