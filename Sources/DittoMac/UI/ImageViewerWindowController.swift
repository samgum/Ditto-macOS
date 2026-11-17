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

        imageView.imageScaling = .scaleProportionallyDown
        if let imageBlobKey = entry.imageBlobKey,
           let data = store.blobData(named: imageBlobKey),
           let image = NSImage(data: data) {
            imageView.image = image
            imageView.frame = NSRect(
                x: 0,
                y: 0,
                width: max(600, image.size.width),
                height: max(440, image.size.height)
            )
        } else {
            imageView.frame = NSRect(x: 0, y: 0, width: 600, height: 440)
        }

        let root = NSView()
        root.addSubview(scrollView)
        window.contentView = root
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }
}
