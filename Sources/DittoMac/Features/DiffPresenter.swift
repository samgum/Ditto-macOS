import AppKit
import Foundation

/// Presents a two-clip comparison. If a diff app is configured (Windows
/// `DiffApp`), writes both clips to temp files and launches it; otherwise
/// shows a built-in side-by-side text comparison window.
enum DiffPresenter {
    static func present(left: ClipboardEntry, right: ClipboardEntry, store: ClipboardStore) {
        let leftText = left.text ?? store.fullText(for: left) ?? ""
        let rightText = right.text ?? store.fullText(for: right) ?? ""

        let diffApp = DittoSettings.diffApp
        if diffApp.isEmpty == false, FileManager.default.isExecutableFile(atPath: diffApp) || FileManager.default.fileExists(atPath: diffApp) {
            launchExternalDiff(app: diffApp, left: leftText, right: rightText)
            return
        }
        SideBySideDiffWindow.show(leftTitle: left.preview, leftText: leftText, rightTitle: right.preview, rightText: rightText)
    }

    private static func launchExternalDiff(app: String, left: String, right: String) {
        let temp = FileManager.default.temporaryDirectory
        let leftURL = temp.appendingPathComponent("ditto-left.txt")
        let rightURL = temp.appendingPathComponent("ditto-right.txt")
        try? left.write(to: leftURL, atomically: true, encoding: .utf8)
        try? right.write(to: rightURL, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: app)
        process.arguments = [leftURL.path, rightURL.path]
        try? process.run()
    }
}

final class SideBySideDiffWindow: NSWindowController {
    static func show(leftTitle: String, leftText: String, rightTitle: String, rightText: String) {
        let window = SideBySideDiffWindow(leftTitle: leftTitle, leftText: leftText, rightTitle: rightTitle, rightText: rightText)
        window.showWindow(nil)
        window.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    init(leftTitle: String, leftText: String, rightTitle: String, rightText: String) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = LocalizationManager.shared.text("compare_clips")
        window.center()
        super.init(window: window)

        let leftView = makeTextView(title: leftTitle, text: leftText)
        let rightView = makeTextView(title: rightTitle, text: rightText)
        let split = NSSplitView()
        split.isVertical = true
        split.translatesAutoresizingMaskIntoConstraints = false
        split.addArrangedSubview(leftView)
        split.addArrangedSubview(rightView)
        split.dividerStyle = .thin
        window.contentView = split
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: (window.contentView?.topAnchor)!),
            split.leadingAnchor.constraint(equalTo: (window.contentView?.leadingAnchor)!),
            split.trailingAnchor.constraint(equalTo: (window.contentView?.trailingAnchor)!),
            split.bottomAnchor.constraint(equalTo: (window.contentView?.bottomAnchor)!)
        ])
    }

    required init?(coder: NSCoder) { nil }

    private func makeTextView(title: String, text: String) -> NSView {
        let container = NSView()
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.boldSystemFont(ofSize: 12)
        label.translatesAutoresizingMaskIntoConstraints = false
        let textView = NSTextView()
        textView.isEditable = false
        textView.string = text
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }
}
