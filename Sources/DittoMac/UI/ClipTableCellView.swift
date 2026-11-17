import AppKit
import Foundation

/// A row cell that draws the clip preview with optional thumbnail, color
/// swatch (for colour-code clips), a pinned/favorite indicator, and a small
/// "pasted" check. Replaces the default `NSTableCellView` so we can render
/// rich previews the way the Windows `QListCtrl` does.
final class ClipTableCellView: NSTableCellView {
    private static let thumbnailCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 256
        return cache
    }()

    private let previewLabel = NSTextField(labelWithString: "")
    private let typeIcon = NSImageView()
    private let colorSwatch = NSView()
    private let thumbnailView = NSImageView()
    private let pinnedIcon = NSTextField(labelWithString: "")
    private let pastedDot = NSView()
    private let indexLabel = NSTextField(labelWithString: "")
    private var previewLeadingFromIcon: NSLayoutConstraint?
    private var previewLeadingFromThumb: NSLayoutConstraint?

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

        indexLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        indexLabel.textColor = .tertiaryLabelColor
        indexLabel.alignment = .center
        indexLabel.translatesAutoresizingMaskIntoConstraints = false
        indexLabel.isBezeled = false
        indexLabel.drawsBackground = false
        addSubview(indexLabel)

        // Two candidate leading constraints for the preview label: one anchored
        // to the type icon (text rows) and one to the thumbnail (image rows).
        // configure() activates the right one so the label sits to the RIGHT of
        // the thumbnail instead of overlapping it.
        previewLeadingFromIcon = previewLabel.leadingAnchor.constraint(equalTo: typeIcon.trailingAnchor, constant: 6)
        previewLeadingFromThumb = previewLabel.leadingAnchor.constraint(equalTo: thumbnailView.trailingAnchor, constant: 8)
        previewLeadingFromIcon?.isActive = true

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

            indexLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            indexLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            indexLabel.widthAnchor.constraint(equalToConstant: 14),

            previewLabel.trailingAnchor.constraint(lessThanOrEqualTo: pinnedIcon.leadingAnchor, constant: -4),
            previewLabel.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            previewLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),

            pinnedIcon.trailingAnchor.constraint(equalTo: indexLabel.leadingAnchor, constant: -2),
            pinnedIcon.centerYAnchor.constraint(equalTo: centerYAnchor),

            pastedDot.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            pastedDot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            pastedDot.widthAnchor.constraint(equalToConstant: 7),
            pastedDot.heightAnchor.constraint(equalToConstant: 7)
        ])
    }

    /// Show the 1-based index overlay for the first ten rows (row 9 == 10).
    func setIndex(_ index: Int?, enabled: Bool) {
        guard enabled, let index, index < 10 else {
            indexLabel.isHidden = true
            return
        }
        indexLabel.isHidden = false
        indexLabel.stringValue = "\(index == 9 ? 10 : index + 1)"
    }

    func configure(
        entry: ClipboardEntry,
        store: ClipboardStore,
        drawThumbnails: Bool,
        theme: DittoTheme,
        previewText: String
    ) {
        previewLabel.maximumNumberOfLines = DittoSettings.linesPerRow
        previewLabel.font = NSFont.systemFont(ofSize: CGFloat(DittoSettings.fontSize))
        previewLabel.textColor = theme.listBoxText

        let showsThumbnail = drawThumbnails && entry.isImage
        let showsColor = entry.detectedColorHex != nil
        let showsIcon = showsThumbnail == false && showsColor == false

        typeIcon.isHidden = !showsIcon
        colorSwatch.isHidden = !showsColor
        thumbnailView.isHidden = !showsThumbnail

        // Place the preview label to the right of whatever leading element is
        // shown (thumbnail for images, icon otherwise) — never overlapping.
        previewLeadingFromThumb?.isActive = showsThumbnail
        previewLeadingFromIcon?.isActive = !showsThumbnail

        typeIcon.image = NSImage(systemSymbolName: Self.symbol(for: entry), accessibilityDescription: entry.typeLabel)

        if let hex = entry.detectedColorHex, let color = ColorCodeDetector.color(from: hex) {
            colorSwatch.layer?.backgroundColor = color.cgColor
            let rawTrimmed = entry.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? hex
            if rawTrimmed.hasPrefix("#") {
                previewLabel.stringValue = hex.uppercased()
            } else {
                previewLabel.stringValue = "\(rawTrimmed)  (\(hex.uppercased()))"
            }
        } else {
            previewLabel.stringValue = ClipboardEntry.truncated(previewText)
        }

        if showsThumbnail, let imageBlobKey = entry.imageBlobKey {
            thumbnailView.image = Self.cachedThumbnail(for: imageBlobKey, store: store)
        } else {
            thumbnailView.image = nil
        }

        pinnedIcon.stringValue = entry.favorite ? "★" : (entry.neverAutoDelete ? "📌" : "")
        pinnedIcon.isHidden = entry.isPinned == false

        // Green dot for a clip pasted in the last 30s (Windows
        // ShowIfClipWasPasted / m_clipPastedColor).
        if let lastPaste = entry.lastPasteDate, Date().timeIntervalSince(lastPaste) < 30 {
            pastedDot.isHidden = false
            pastedDot.layer?.backgroundColor = theme.pastedIndicator.cgColor
        } else {
            pastedDot.isHidden = true
        }
    }

    private static func cachedThumbnail(for key: NSString, store: ClipboardStore) -> NSImage? {
        if let cached = thumbnailCache.object(forKey: key) {
            return cached
        }
        guard let data = store.blobData(named: key as String),
              let sourceImage = NSImage(data: data) else {
            return nil
        }
        let maxPixelDimension: CGFloat = 96
        let sourceSize = sourceImage.size
        guard sourceSize.width > maxPixelDimension || sourceSize.height > maxPixelDimension else {
            thumbnailCache.setObject(sourceImage, forKey: key)
            return sourceImage
        }
        let scale = min(maxPixelDimension / max(1, sourceSize.width), maxPixelDimension / max(1, sourceSize.height))
        let targetSize = NSSize(width: max(1, round(sourceSize.width * scale)), height: max(1, round(sourceSize.height * scale)))
        let thumbnail = NSImage(size: targetSize)
        thumbnail.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        sourceImage.draw(in: NSRect(origin: .zero, size: targetSize))
        thumbnail.unlockFocus()
        thumbnailCache.setObject(thumbnail, forKey: key)
        return thumbnail
    }

    private static func cachedThumbnail(for key: String, store: ClipboardStore) -> NSImage? {
        cachedThumbnail(for: key as NSString, store: store)
    }

    private static func symbol(for entry: ClipboardEntry) -> String {
        if entry.isFileDrop { return "doc.on.doc" }
        if entry.isImage { return "photo" }
        if entry.isPDF { return "doc.richtext" }
        if entry.isRichText { return "text.alignleft" }
        if entry.isHTML { return "globe" }
        return "textformat"
    }
}
