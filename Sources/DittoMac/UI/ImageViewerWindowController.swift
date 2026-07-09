import AppKit
import Foundation

/// Full-size image preview window for image clips (Windows `ImageViewer`).
final class ImageViewerWindowController: NSWindowController {
    private let scrollView = NSScrollView()
    private let imageView = NSImageView()

    init(entry: ClipboardEntry, store: ClipboardStore) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.applyDittoAppearance()
        window.title = entry.preview
        window.center()
        super.init(window: window)

        scrollView.documentView = imageView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.frame = NSRect(x: 0, y: 0, width: 600, height: 440)
        if let imageBlobKey = entry.imageBlobKey, let data = store.blobData(named: imageBlobKey) {
            imageView.image = NSImage(data: data)
        }

        window.contentView = scrollView
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: (window.contentView?.topAnchor)!),
            scrollView.leadingAnchor.constraint(equalTo: (window.contentView?.leadingAnchor)!),
            scrollView.trailingAnchor.constraint(equalTo: (window.contentView?.trailingAnchor)!),
            scrollView.bottomAnchor.constraint(equalTo: (window.contentView?.bottomAnchor)!)
        ])
    }

    required init?(coder: NSCoder) { nil }
}
