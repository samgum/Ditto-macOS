import Foundation

/// Installs a user LaunchAgent so Ditto starts on login and is restarted by
/// launchd after a crash (matching the Windows "Run on startup" + watchdog).
final class LoginAgentManager {
    private let label = "org.ditto-cp.DittoMac"

    private var launchAgentsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
    }

    private var plistURL: URL {
        launchAgentsDirectory.appendingPathComponent("\(label).plist")
    }

    var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// True only when running from a real `.app` bundle. We refuse to install
    /// a LaunchAgent for a bare `swift run` executable (its path is ephemeral
    /// and KeepAlive would endlessly respawn a stale binary).
    private var isBundledApp: Bool {
        Bundle.main.bundleIdentifier?.isEmpty == false
            && Bundle.main.bundleURL.pathExtension == "app"
    }

    func installOrRefresh() {
        guard isBundledApp, let executableURL = Bundle.main.executableURL else { return }
        try? FileManager.default.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)

        // KeepAlive with SuccessfulExit=false: launchd restarts ONLY after a
        // crash (non-zero exit), NOT after a normal quit. This prevents
        // multiple Ditto instances from piling up after a reboot or a manual
        // Quit — the #1 cause of the "apps lose focus" bug.
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executableURL.path],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Interactive"
        ]

        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else {
            return
        }
        try? data.write(to: plistURL, options: .atomic)

        // Bootout any previously-loaded instance that used the old KeepAlive
        // policy, then load the new one.
        let domain = "gui/\(getuid())"
        _ = runLaunchctl(arguments: ["bootout", "\(domain)/\(label)"])
        _ = runLaunchctl(arguments: ["bootstrap", domain, plistURL.path])
    }

    func disable() {
        let domain = "gui/\(getuid())"
        _ = runLaunchctl(arguments: ["bootout", domain, plistURL.path])
        _ = runLaunchctl(arguments: ["bootout", "\(domain)/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
    }

    private func runLaunchctl(arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
