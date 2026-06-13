import AppKit
import Foundation

if CommandLine.arguments.contains("--selftest") {
    let exitCode = SelfTest.run()
    exit(exitCode)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
