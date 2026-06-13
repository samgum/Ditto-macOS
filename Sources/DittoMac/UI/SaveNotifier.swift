import AppKit
import Foundation

/// A transient, borderless popup that briefly confirms a clip was saved —
/// the macOS analogue of the Windows `SaveAnimation` / `Popup` feedback.
/// Appears near the menu-bar icon, fades after ~1.2 s.
final class SaveNotifier {
    static let shared = SaveNotifier()
    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?

    private init() {}

    func show(_ preview: String) {
        guard DittoSettings.showSaveNotification else { return }
        DispatchQueue.main.async { [weak self] in
            self?.present(preview)
        }
    }

    private func present(_ preview: String) {
        hideWorkItem?.cancel()

        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 280, height: 44),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.backgroundColor = NSColor.windowBackgroundColor
            panel.hasShadow = true
            panel.isMovable = false
            panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
            let label = NSTextField(labelWithString: "")
            label.font = NSFont.systemFont(ofSize: 12)
            label.textColor = .labelColor
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            panel.contentView = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 12),
                label.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -12),
                label.centerYAnchor.constraint(equalTo: panel.contentView!.centerYAnchor)
            ])
            self.panel = panel
        }

        let trimmed = preview.replacingOccurrences(of: "\n", with: " ⏎ ").trimmingCharacters(in: .whitespacesAndNewlines)
        let truncated = trimmed.count > 40 ? String(trimmed.prefix(40)) + "…" : trimmed
        (panel?.contentView as? NSTextField)?.stringValue = "✓ " + truncated
        panel?.alphaValue = 1

        // Position below the menu-bar icon, top-right of the screen.
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel?.setFrame(NSRect(x: frame.maxX - 300, y: frame.maxY - 56, width: 280, height: 44), display: true)
        }
        panel?.orderFrontRegardless()

        let workItem = DispatchWorkItem { [weak self] in
            self?.dismiss()
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: workItem)
    }

    private func dismiss() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            panel?.animator().alphaValue = 0
        }, completionHandler: {
            self.panel?.orderOut(nil)
        })
    }
}
