import AppKit
import Carbon
import CoreGraphics
import Foundation

/// Simulates the paste keystroke into the previously-focused application.
///
/// Mirrors the Windows `ExternalWindowTracker::SendPaste` / `ProcessPaste`
/// flow: activate the target app, then post a Cmd+V. Requires the
/// Accessibility permission (System Settings ▸ Privacy & Security ▸
/// Accessibility).
enum PasteSimulator {
    static func paste(afterDelay seconds: TimeInterval = 0.12) {
        let front = NSWorkspace.shared.frontmostApplication
        front?.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            postCommandV()
        }
    }

    /// Activate a specific app and paste into it.
    static func paste(into app: NSRunningApplication?, afterDelay seconds: TimeInterval = 0.18) {
        // Bring the target forward first; if no target is known, at least make
        // sure Ditto itself isn't the frontmost (it can't receive a paste).
        if let app {
            app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            waitForFrontmost(app, timeout: 0.45)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            postCommandV()
        }
    }

    /// Poll briefly until `app` is actually frontmost before posting the
    /// keystroke — activating is asynchronous and posting too early lands the
    /// paste in the wrong window.
    static func waitForFrontmost(_ app: NSRunningApplication, timeout: TimeInterval) {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if app.isFinishedLaunching == false { Thread.sleep(forTimeInterval: 0.02); continue }
            // isHidden / isActive reflect activation state reasonably well.
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { return }
            Thread.sleep(forTimeInterval: 0.03)
        }
    }

    static func postCommandV() {
        guard hasAccessibilityPermission else {
            NSLog("[Ditto] paste skipped — Accessibility permission not granted")
            return
        }
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    /// Check whether we (likely) have the Accessibility permission needed to
    /// synthesise keystrokes.
    static var hasAccessibilityPermission: Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func promptForAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
