import AppKit
import Foundation

/// Window edge snapping — when the history window is dragged near a screen
/// edge, it snaps to it (like the Windows `MagneticWnd`). Implemented via
/// NSWindowDelegate's `windowDidMove`.
final class MagneticWindowDelegate: NSObject, NSWindowDelegate {
    static let shared = MagneticWindowDelegate()
    private let snapDistance: CGFloat = 20

    private override init() { super.init() }

    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let screen = window.screen ?? NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        var frame = window.frame
        var snapped = false

        // Snap to left edge
        if abs(frame.minX - visibleFrame.minX) < snapDistance {
            frame.origin.x = visibleFrame.minX
            snapped = true
        }
        // Snap to right edge
        if abs(frame.maxX - visibleFrame.maxX) < snapDistance {
            frame.origin.x = visibleFrame.maxX - frame.width
            snapped = true
        }
        // Snap to top edge
        if abs(frame.maxY - visibleFrame.maxY) < snapDistance {
            frame.origin.y = visibleFrame.maxY - frame.height
            snapped = true
        }
        // Snap to bottom edge
        if abs(frame.minY - visibleFrame.minY) < snapDistance {
            frame.origin.y = visibleFrame.minY
            snapped = true
        }

        if snapped {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                window.animator().setFrame(frame, display: true)
            })
        }
    }
}
