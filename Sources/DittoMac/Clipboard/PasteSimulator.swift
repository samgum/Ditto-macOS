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
    static func paste(into app: NSRunningApplication?, afterDelay seconds: TimeInterval = 0.15) {
        app?.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            postCommandV()
        }
    }

    static func postCommandV() {
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
