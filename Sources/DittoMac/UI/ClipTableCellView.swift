import AppKit
import Foundation

/// A row cell that draws the clip preview with optional thumbnail, color
/// swatch (for colour-code clips), a pinned/favorite indicator, and a small
/// "pasted" check. Replaces the default `NSTableCellView` so we can render
/// rich previews the way the Windows `QListCtrl` does.
final class ClipTableCellView: NSTableCellView {
    private let previewLabel = NSTextField(labelWithString: "")
    private let typeIcon = NSImageView()
    private let colorSwatch = NSView()
    private let thumbnailView = NSImageView()
    private let pinnedIcon = NSTextField(labelWithString: "")
    private let pastedDot = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        previewLabel.lineBreakMode = .byTruncatingTail
        previewLabel.maximumNumberOfLines = 2
        previewLabel.cell?.truncatesLastVisibleLine = true
        previewLabel.isBezeled = false
        previewLabel.drawsBackground = false
        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(previewLabel)

        typeIcon.imageAlignment = .alignCenter
        typeIcon.translatesAutoresizingMaskIntoConstraints = false
        typeIcon.contentTintColor = .secondaryLabelColor
        addSubview(typeIcon)

        colorSwatch.wantsLayer = true
        colorSwatch.layer?.cornerRadius = 4
        colorSwatch.translatesAutoresizingMaskIntoConstraints = false
        addSubview(colorSwatch)

        thumbnailView.imageAlignment = .alignLeft
        thumbnailView.imageScaling = .scaleProportionallyDown
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(thumbnailView)

        pinnedIcon.font = NSFont.systemFont(ofSize: 11)
        pinnedIcon.textColor = .systemYellow
        pinnedIcon.translatesAutoresizingMaskIntoConstraints = false
        pinnedIcon.isBezeled = false
        pinnedIcon.drawsBackground = false
        addSubview(pinnedIcon)

        pastedDot.wantsLayer = true
        pastedDot.layer?.cornerRadius = 3
        pastedDot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pastedDot)

        NSLayoutConstraint.activate([
            typeIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            typeIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            typeIcon.widthAnchor.constraint(equalToConstant: 18),
            typeIcon.heightAnchor.constraint(equalToConstant: 18),

            colorSwatch.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            colorSwatch.centerYAnchor.constraint(equalTo: centerYAnchor),
            colorSwatch.widthAnchor.constraint(equalToConstant: 16),
            colorSwatch.heightAnchor.constraint(equalToConstant: 16),

            thumbnailView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            thumbnailView.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbnailView.widthAnchor.constraint(equalToConstant: 48),
            thumbnailView.heightAnchor.constraint(equalToConstant: 48),

            previewLabel.leadingAnchor.constraint(equalTo: typeIcon.trailingAnchor, constant: 6),
            previewLabel.trailingAnchor.constraint(lessThanOrEqualTo: pinnedIcon.leadingAnchor, constant: -4),
            previewLabel.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            previewLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),

            pinnedIcon.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            pinnedIcon.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    func configure(entry: ClipboardEntry, store: ClipboardStore, drawThumbnails: Bool, theme: DittoTheme) {
        previewLabel.font = NSFont.systemFont(ofSize: CGFloat(DittoSettings.fontSize))
        previewLabel.textColor = theme.listBoxText

        let showsThumbnail = drawThumbnails && entry.isImage
        let showsColor = entry.detectedColorHex != nil
        let showsIcon = showsThumbnail == false && showsColor == false

        typeIcon.isHidden = !showsIcon
        colorSwatch.isHidden = !showsColor
        thumbnailView.isHidden = !showsThumbnail

        typeIcon.image = NSImage(systemSymbolName: Self.symbol(for: entry), accessibilityDescription: entry.typeLabel)

        if let hex = entry.detectedColorHex, let color = ColorCodeDetector.color(from: hex) {
            colorSwatch.layer?.backgroundColor = color.cgColor
            previewLabel.stringValue = hex.uppercased()
        } else {
            previewLabel.stringValue = entry.preview
        }

        if showsThumbnail, let imageBlobKey = entry.imageBlobKey, let data = store.blobData(named: imageBlobKey) {
            thumbnailView.image = NSImage(data: data)
        } else {
            thumbnailView.image = nil
        }

        pinnedIcon.stringValue = entry.favorite ? "★" : (entry.neverAutoDelete ? "📌" : "")
        pinnedIcon.isHidden = entry.isPinned == false
    }

    private static func symbol(for entry: ClipboardEntry) -> String {
        if entry.isFileDrop { return "doc.on.doc" }
        if entry.isImage { return "photo" }
        if entry.isRichText { return "text.alignleft" }
        if entry.isHTML { return "globe" }
        return "textformat"
    }
}
