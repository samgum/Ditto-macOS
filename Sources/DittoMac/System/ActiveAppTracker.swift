import AppKit
import Foundation

/// Tracks the application that was frontmost *before* Ditto took focus, so
/// that "paste into previous application" has a target. Mirrors the Windows
/// `ExternalWindowTracker` `m_activeWnd` concept.
final class ActiveAppTracker {
    static let shared = ActiveAppTracker()

    private var lastNonDittoApp: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?

    private init() {}

    var previousApplication: NSRunningApplication? { lastNonDittoApp }

    func start() {
        guard activationObserver == nil else { return }
        captureCurrentApplication()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.captureCurrentApplication()
        }
    }

    func stop() {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
    }

    /// Records the currently active app immediately before Ditto takes focus.
    /// This prevents a global hot key from pasting into a recently-active app.
    func captureCurrentApplication() {
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        if front.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastNonDittoApp = front
        }
    }
}
