import AppKit
import Foundation

/// Tracks the application that was frontmost *before* Ditto took focus, so
/// that "paste into previous application" has a target. Mirrors the Windows
/// `ExternalWindowTracker` `m_activeWnd` concept.
final class ActiveAppTracker {
    static let shared = ActiveAppTracker()

    private var lastNonDittoApp: NSRunningApplication?
    private var pollTimer: Timer?

    private init() {}

    var previousApplication: NSRunningApplication? { lastNonDittoApp }

    func start() {
        recordIfNeeded()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.recordIfNeeded()
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func recordIfNeeded() {
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        if front.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastNonDittoApp = front
        }
    }
}
