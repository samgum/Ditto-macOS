import AppKit
import Foundation

/// A simple "fly to tray" save animation — an expanding/fading rectangle
/// briefly appears at the cursor position when a clip is captured, mimicking
/// the Windows `SaveAnimation` visual feedback.
final class SaveAnimation {
    static let shared = SaveAnimation()
    private var animationWindow: NSWindow?

    private init() {}

    func animate(at point: NSPoint? = nil) {
        let origin = point ?? NSEvent.mouseLocation
        DispatchQueue.main.async { [weak self] in
            self?.present(origin)
        }
    }

    private func present(_ origin: NSPoint) {
        // Clean up any previous animation window.
        animationWindow?.orderOut(nil)

        let size = NSSize(width: 120, height: 40)
        let frame = NSRect(
            x: origin.x - size.width / 2,
            y: origin.y - size.height / 2,
            width: size.width, height: size.height)

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        window.isMovable = false

        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(calibratedRed: 0.22, green: 0.48, blue: 0.92, alpha: 0.85).cgColor
        view.layer?.cornerRadius = 8

        let label = NSTextField(labelWithString: "✓")
        label.font = NSFont.boldSystemFont(ofSize: 18)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        window.contentView = view
        window.alphaValue = 1
        window.orderFrontRegardless()
        animationWindow = window

        // Animate: slide up + fade out over 0.5s.
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.5
            window.animator().setFrame(
                NSRect(x: frame.origin.x, y: frame.origin.y + 30,
                       width: frame.width, height: frame.height),
                display: true)
            window.animator().alphaValue = 0
        }, completionHandler: {
            window.orderOut(nil)
        })
    }
}
