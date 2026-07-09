import AppKit
import Foundation

/// Shows a generated QR code for a clip's text. macOS equivalent of the
/// Windows `QRCodeViewer`.
final class QRCodeWindowController: NSWindowController {
    private let imageView = NSImageView()

    init(text: String) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.applyDittoAppearance()
        window.title = LocalizationManager.shared.text("qr_code")
        window.center()
        super.init(window: window)

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.image = QRCodeGenerator.image(from: text)

        let saveButton = NSButton(title: LocalizationManager.shared.text("export_image_file"), target: nil, action: nil)
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(savePNG)

        let root = NSView()
        root.addSubview(imageView)
        root.addSubview(saveButton)
        window.contentView = root

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            imageView.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            imageView.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
            imageView.heightAnchor.constraint(lessThanOrEqualToConstant: 320),
            saveButton.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 16),
            saveButton.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            saveButton.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -16)
        ])
    }

    required init?(coder: NSCoder) { nil }

    @objc private func savePNG() {
        guard let tiff = imageView.image?.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "qrcode.png"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? png.write(to: url)
        }
    }
}
