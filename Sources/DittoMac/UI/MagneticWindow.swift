import AppKit
import Foundation

/// Window edge snapping — when the history window is dragged near a screen
/// edge, it snaps to it (like the Windows `MagneticWnd`). Implemented via
/// NSWindowDelegate's `windowDidMove`.
final class MagneticWindowDelegate: NSObject, NSWindowDelegate {
    static let shared = MagneticWindowDelegate()
    private let snapDistance: CGFloat = 20
    private var isSnapping = false

    private override init() { super.init() }

    func windowDidMove(_ notification: Notification) {
        guard isSnapping == false,
              NSEvent.pressedMouseButtons == 0,
              let window = notification.object as? NSWindow,
              let screen = window.screen ?? NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        var frame = window.frame
        var snapped = false

        // Snap to left edge
        let leftDelta = abs(frame.minX - visibleFrame.minX)
        if leftDelta > 0.5 && leftDelta < snapDistance {
            frame.origin.x = visibleFrame.minX
            snapped = true
        }
        // Snap to right edge
        let rightDelta = abs(frame.maxX - visibleFrame.maxX)
        if rightDelta > 0.5 && rightDelta < snapDistance {
            frame.origin.x = visibleFrame.maxX - frame.width
            snapped = true
        }
        // Snap to top edge
        let topDelta = abs(frame.maxY - visibleFrame.maxY)
        if topDelta > 0.5 && topDelta < snapDistance {
            frame.origin.y = visibleFrame.maxY - frame.height
            snapped = true
        }
        // Snap to bottom edge
        let bottomDelta = abs(frame.minY - visibleFrame.minY)
        if bottomDelta > 0.5 && bottomDelta < snapDistance {
            frame.origin.y = visibleFrame.minY
            snapped = true
        }

        if snapped {
            isSnapping = true
            window.setFrame(frame, display: true, animate: false)
            isSnapping = false
        }
    }
}
