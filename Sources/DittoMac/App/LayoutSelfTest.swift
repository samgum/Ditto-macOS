import AppKit
import Foundation

/// GUI layout regression check. Run with `DittoMac --selftest-ui`.
///
/// Builds the real history window at the default and minimum sizes, in every
/// bundled language and in both appearances, and asserts that the header
/// controls never overlap each other or the clip list. It is a separate mode
/// from `--selftest` because it needs a window server; the headless self-test
/// stays usable in CI.
enum LayoutSelfTest {
    /// Window sizes the layout must hold at: the shipped default and the
    /// smallest size the window can be dragged to.
    private static let sizes: [(name: String, size: NSSize)] = [
        ("default 820x552", NSSize(width: 820, height: 552)),
        ("minimum 640x360", NSSize(width: 640, height: 360))
    ]

    static func run() -> Int32 {
        var passed = 0
        var failed = 0

        func check(_ name: String, _ condition: Bool) {
            if condition {
                passed += 1
                print("  ✓ \(name)")
            } else {
                failed += 1
                print("  ✗ \(name)")
            }
        }

        print("Ditto macOS layout self-test")

        let application = NSApplication.shared
        // Never show up in the Dock and never become the active application.
        application.setActivationPolicy(.prohibited)

        guard NSScreen.main != nil else {
            print("\nno window server available — run this check from a desktop session")
            return 2
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ditto-layout-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let store = ClipboardStore(databaseURL: temporaryDirectory.appendingPathComponent("layout.db"))
        for index in 0..<25 {
            _ = store.addClipboardPayload(
                text: "Layout probe clip \(index) — a reasonably long line of clipboard text",
                rtfData: nil,
                htmlData: nil,
                imageData: nil,
                fileURLs: []
            )
        }

        let originalLanguage = LocalizationManager.shared.currentLanguage
        let originalTheme = DittoSettings.themeName
        defer {
            LocalizationManager.shared.setLanguage(originalLanguage)
            DittoSettings.themeName = originalTheme
        }

        let delegate = LayoutProbeDelegate()

        for (themeName, themeLabel) in [("light", "light"), ("dark", "dark"), ("system", "system")] {
            DittoSettings.themeName = themeName
            for language in LocalizationManager.shared.languages {
                LocalizationManager.shared.setLanguage(language.code)
                let controller = HistoryWindowController(store: store, delegate: delegate, pasteHandler: {})
                guard let window = controller.window else {
                    check("window builds (\(language.code)/\(themeLabel))", false)
                    continue
                }
                for (sizeName, size) in sizes {
                    window.setContentSize(size)
                    let probe = controller.headerLayoutProbe()
                    let label = "\(language.code)/\(themeLabel)/\(sizeName)"

                    var overlap: String?
                    for outer in probe.indices {
                        for inner in (outer + 1)..<probe.count {
                            let a = probe[outer]
                            let b = probe[inner]
                            // Auto Layout can leave sub-pixel touching edges;
                            // only a real overlap counts.
                            let intersection = a.frame.intersection(b.frame)
                            if intersection.isNull == false,
                               intersection.width > 0.5,
                               intersection.height > 0.5 {
                                overlap = "\(a.name)/\(b.name)"
                            }
                        }
                    }
                    check("no overlapping controls — \(label)", overlap == nil)
                    if let overlap {
                        print("      overlap: \(overlap)")
                    }

                    // Every control must stay inside the window's content area.
                    let contentBounds = window.contentView?.bounds ?? .zero
                    let escaped = probe.filter { contentBounds.contains($0.frame) == false }.map(\.name)
                    check("all controls inside the content view — \(label)", escaped.isEmpty)
                    if escaped.isEmpty == false {
                        print("      outside: \(escaped.joined(separator: ", "))")
                    }

                    // The clip text is the point of the window; the type and
                    // date columns must stay compact.
                    let fraction = controller.clipColumnWidthFraction()
                    check("clip column keeps the majority of the width — \(label)", fraction > 0.5)
                }
                window.close()
            }
        }

        // Verify Preferences tab stability and secondary window layout integrity.
        let copyBufferManager = CopyBufferManager(store: store)
        let syncCoordinator = SyncCoordinator()
        let prefs = PreferencesWindowController(
            store: store,
            copyBufferManager: copyBufferManager,
            syncCoordinator: syncCoordinator,
            onChanged: {}
        )
        if let prefsWindow = prefs.window {
            prefsWindow.contentView?.layoutSubtreeIfNeeded()
            let initialFrame = prefsWindow.frame
            if let tabView = prefsWindow.contentView?.subviews.compactMap({ $0 as? NSTabView }).first {
                for index in 0..<tabView.numberOfTabViewItems {
                    tabView.selectTabViewItem(at: index)
                    prefsWindow.contentView?.layoutSubtreeIfNeeded()
                }
                tabView.selectTabViewItem(at: 0)
            }
            check("preferences frame stays stable across all tabs", prefsWindow.frame == initialFrame)
            prefsWindow.close()
        } else {
            check("preferences frame stays stable across all tabs", false)
        }

        if let sample = store.snapshotEntries().first {
            let props = ClipPropertiesWindowController(store: store, entry: sample, onChanged: {})
            props.window?.contentView?.layoutSubtreeIfNeeded()
            check("clip properties window builds cleanly", (props.window?.contentView?.bounds.width ?? 0) > 0)
            props.window?.close()

            let editor = ClipEditorWindowController(store: store, entry: sample, onChanged: {})
            editor.window?.contentView?.layoutSubtreeIfNeeded()
            check("clip editor window builds cleanly", (editor.window?.contentView?.bounds.width ?? 0) > 0)
            editor.window?.close()
        }

        let groups = GroupsWindowController(store: store, onChanged: {})
        groups.window?.contentView?.layoutSubtreeIfNeeded()
        check("groups window builds cleanly", (groups.window?.contentView?.bounds.width ?? 0) > 0)
        groups.window?.close()

        let stats = StatisticsWindowController()
        stats.refresh()
        stats.window?.contentView?.layoutSubtreeIfNeeded()
        check("statistics window builds cleanly", (stats.window?.contentView?.bounds.width ?? 0) > 0)
        stats.window?.close()

        let diff = SideBySideDiffWindow(leftTitle: "Left", leftText: "alpha\nbeta", rightTitle: "Right", rightText: "alpha\ngamma")
        diff.window?.contentView?.layoutSubtreeIfNeeded()
        check("side-by-side diff window builds cleanly", (diff.window?.contentView?.bounds.width ?? 0) > 0)
        diff.window?.close()

        print("\n\(passed) passed, \(failed) failed")
        return failed == 0 ? 0 : 1
    }
}

/// Minimal delegate so the history window can be built outside the AppDelegate.
private final class LayoutProbeDelegate: HistoryWindowDelegate {
    func pasteEntryIntoPreviousApp(_ entry: ClipboardEntry, options: SpecialPasteOptions) {}
    func showProperties(for entry: ClipboardEntry) {}
    func showEditor(for entry: ClipboardEntry) {}
    func showQRCode(for entry: ClipboardEntry) {}
    func showImageViewer(for entry: ClipboardEntry) {}
    func exportEntryAsText(_ entry: ClipboardEntry) {}
    func exportEntryAsImage(_ entry: ClipboardEntry) {}
    func exportEntryAsPDF(_ entry: ClipboardEntry) {}
    func webSearchEntry(_ entry: ClipboardEntry) {}
    func translateEntry(_ entry: ClipboardEntry) {}
    func emailEntry(_ entry: ClipboardEntry) {}
    func sendEntryToFriend(_ entry: ClipboardEntry, friendId: Int64?) {}
    func compareEntries(_ entries: [ClipboardEntry]) {}
    func copyEntryToBuffer(_ entry: ClipboardEntry, slot: Int) {}
}
