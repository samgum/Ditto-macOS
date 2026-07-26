import AppKit
import Foundation

if CommandLine.arguments.contains("--selftest") {
    let exitCode = SelfTest.run()
    exit(exitCode)
}

// Layout check. Separate from --selftest because it needs a window server.
if CommandLine.arguments.contains("--selftest-ui") {
    let exitCode = LayoutSelfTest.run()
    exit(exitCode)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
