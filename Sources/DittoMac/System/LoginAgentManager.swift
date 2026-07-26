import Foundation

/// Installs a user LaunchAgent so Ditto starts once when the user logs in.
final class LoginAgentManager {
    private let label = "org.ditto-cp.DittoMac"
    private let legacyLabel = "org.ditto-cp.Ditto"

    private var launchAgentsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
    }

    private var plistURL: URL {
        launchAgentsDirectory.appendingPathComponent("\(label).plist")
    }

    private var legacyPlistURL: URL {
        launchAgentsDirectory.appendingPathComponent("\(legacyLabel).plist")
    }

    var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// True only when running from a real `.app` bundle. We refuse to install
    /// a LaunchAgent for a bare `swift run` executable (its path is ephemeral
    /// and would become stale after the build directory changes).
    private var isBundledApp: Bool {
        Bundle.main.bundleIdentifier?.isEmpty == false
            && Bundle.main.bundleURL.pathExtension == "app"
    }

    func installOrRefresh() {
        guard isBundledApp, let executableURL = Bundle.main.executableURL else { return }
        try? FileManager.default.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executableURL.path],
            "RunAtLoad": true,
            "ProcessType": "Background",
            "LimitLoadToSessionType": "Aqua"
        ]

        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else {
            return
        }
        // Old releases installed a second label with KeepAlive=true. Remove
        // its file so a crash cannot create an endless relaunch loop.
        try? FileManager.default.removeItem(at: legacyPlistURL)

        if let existingData = try? Data(contentsOf: plistURL),
           let existing = try? PropertyListSerialization.propertyList(from: existingData, format: nil),
           let existingDictionary = existing as? NSDictionary,
           existingDictionary.isEqual(to: plist) {
            return
        }

        try? data.write(to: plistURL, options: .atomic)
        let domain = "gui/\(getuid())"
        _ = runLaunchctl(arguments: ["bootout", "\(domain)/\(label)"])
        _ = runLaunchctl(arguments: ["bootstrap", domain, plistURL.path])
    }

    func disable() {
        let domain = "gui/\(getuid())"
        for (serviceLabel, url) in [(label, plistURL), (legacyLabel, legacyPlistURL)] {
            _ = runLaunchctl(arguments: ["bootout", domain, url.path])
            _ = runLaunchctl(arguments: ["bootout", "\(domain)/\(serviceLabel)"])
            try? FileManager.default.removeItem(at: url)
        }
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
