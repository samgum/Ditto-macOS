import AppKit
import Carbon
import Foundation
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, HistoryWindowDelegate {
    private let store = ClipboardStore()
    private let loginAgentManager = LoginAgentManager()
    private let activeAppTracker = ActiveAppTracker.shared
    private let copyBufferManager: CopyBufferManager
    private var monitor: ClipboardMonitor?
    private var hotKeyController: HotKeyController?
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var historyWindowController: HistoryWindowController?
    private var preferencesWindowController: PreferencesWindowController?

    private var qrWindowController: QRCodeWindowController?
    private var propertiesWindowController: ClipPropertiesWindowController?
    private var editorWindowController: ClipEditorWindowController?
    private var statisticsWindowController: StatisticsWindowController?
    private var imageViewerWindowController: ImageViewerWindowController?
    private var groupsWindowController: GroupsWindowController?
    private var friendsWindowController: FriendsWindowController?

    private let syncCoordinator = SyncCoordinator()

    /// Held for the lifetime of the app to prevent App Nap — without this,
    /// macOS suspends the menu-bar process and it stops watching the
    /// clipboard / can't be summoned by the global hot key.
    private var keepAliveActivity: NSObjectProtocol?

    private var mainHotKeyId: UInt32?
    private var perClipHotKeyIds: [UInt32: UUID] = [:]
    private var firstTenHotKeyIds: [UInt32: Int] = [:]

    override init() {
        copyBufferManager = CopyBufferManager(store: store)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.log("launch begin; pid=\(ProcessInfo.processInfo.processIdentifier); bundle=\(Bundle.main.bundleIdentifier ?? "nil")")

        // Single-instance guard: if another Ditto is already running, activate
        // it and quit this one (the LaunchAgent / login item can otherwise
        // spawn duplicates).
        if isAlreadyRunning() {
            Self.log("another instance detected — exiting")
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.accessory)
        Self.log("activationPolicy set")
        ProcessInfo.processInfo.disableAutomaticTermination("Ditto monitors the clipboard from the menu bar.")
        ProcessInfo.processInfo.disableSuddenTermination()
        // Prevent App Nap so the process keeps running and the global hot key
        // stays responsive even when no window is open.
        keepAliveActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Ditto monitors the clipboard from the menu bar."
        )

        if DittoSettings.showStartupMessage {
            showStartupMessageIfNeeded()
        }

        applyThemeGlobally()
        Self.log("theme applied")
        registerHotKeys()
        Self.log("hotkeys registered")
        configureStatusItem()
        Self.log("status item configured")
        activeAppTracker.start()
        loginAgentManager.installOrRefresh()
        Self.log("login agent installed")

        let monitor = ClipboardMonitor(store: store)
        monitor.onChange = { [weak self] in
            Statistics.shared.recordCopy()
            self?.historyWindowController?.refresh()
            self?.rebuildStatusMenuIfNeeded()
            if let entry = self?.store.snapshotEntries().first {
                self?.syncCoordinator.broadcast(entry: entry)
                SaveNotifier.shared.show(entry.preview)
            }
        }
        monitor.start()
        self.monitor = monitor

        store.enforceExpiry()
        registerNotifications()
        startSync()
        Self.log("launch complete — status item should be visible")
    }

    /// Unbuffered stderr logger for launch diagnostics.
    static func log(_ message: String) {
        let line = "[Ditto] \(message)\n"
        FileHandle.standardError.write(line.data(using: .utf8) ?? Data())
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// True if another DittoMac process is already running (excluding self).
    /// Only matches by bundle identifier — a name-substring fallback matched
    /// unrelated menu-bar apps and killed legit launches.
    private func isAlreadyRunning() -> Bool {
        guard let bundleId = Bundle.main.bundleIdentifier else { return false }
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
        for app in apps where app.processIdentifier != selfPID {
            app.activate(options: [.activateIgnoringOtherApps])
            return true
        }
        return false
    }

    // MARK: - Theme

    private func applyThemeGlobally() {
        NSApp.appearance = DittoTheme.current.effectiveAppearance
        applyLayoutDirection()
    }

    private func applyLayoutDirection() {
        // Apply to every currently-open window. (NSApp.userInterfaceLayoutDirection
        // is read-only, so this runs again on language change once windows exist.)
        let direction: NSUserInterfaceLayoutDirection = LocalizationManager.shared.isRTL ? .rightToLeft : .leftToRight
        for window in NSApp.windows {
            window.contentView?.userInterfaceLayoutDirection = direction
        }
    }

    private func registerNotifications() {
        NotificationCenter.default.addObserver(forName: .dittoThemeChanged, object: nil, queue: .main) { [weak self] _ in
            self?.applyThemeGlobally()
            self?.historyWindowController?.refreshText()
            self?.historyWindowController?.refresh()
        }
        NotificationCenter.default.addObserver(forName: .dittoLanguageChanged, object: nil, queue: .main) { [weak self] _ in
            self?.refreshLocalizedText()
        }
        NotificationCenter.default.addObserver(forName: .dittoClipReceived, object: nil, queue: .main) { [weak self] notification in
            self?.handleReceivedClip(notification)
        }
    }

    private func handleReceivedClip(_ notification: Notification) {
        historyWindowController?.refresh()
        rebuildStatusMenuIfNeeded()
        guard DittoSettings.showReceivedClipNotification,
              let sender = notification.userInfo?["sender"] as? String else { return }
        let alert = NSAlert()
        alert.messageText = LocalizationManager.shared.text("clip_received") + " " + sender
        alert.runModal()
    }

    // MARK: - Hot keys

    private func registerHotKeys() {
        let controller = HotKeyController { [weak self] id in
            DispatchQueue.main.async {
                self?.handleHotKey(id: id)
            }
        }
        if let choice = HotKeyChoice.currentChoice.hotKey {
            mainHotKeyId = controller.register(hotKey: choice)
        }
        registerCopyBufferHotKeys(controller: controller)
        registerPerClipHotKeys(controller: controller)
        registerFirstTenHotKeys(controller: controller)
        hotKeyController = controller
    }

    private func handleHotKey(id: UInt32) {
        if id == mainHotKeyId {
            showHistory()
            return
        }
        if let entryId = perClipHotKeyIds[id] {
            pasteSpecificClip(id: entryId)
            return
        }
        if let position = firstTenHotKeyIds[id] {
            pastePosition(position)
            return
        }
        // Copy-buffer hot keys.
        if let (slot, isPaste) = copyBufferHotKeyIds[id] {
            if isPaste {
                let snapshot = DittoSettings.restoreClipboardAfterPaste ? ClipboardSaveRestore.snapshot() : nil
                if let entry = copyBufferManager.paste(slot: slot) {
                    store.markPasted(entry)
                    pasteToPreviousApplication()
                    if let snapshot { ClipboardSaveRestore.restore(snapshot) { [weak self] in self?.monitor?.syncChangeCount() } }
                }
            } else {
                copyBufferManager.captureCurrentClipboard(into: slot)
            }
        }
    }

    /// Paste the Nth entry (1-based, first ten) into the previous app.
    private func pastePosition(_ position: Int) {
        let index = position - 1
        guard let entry = store.snapshotEntries()[safe: index] else { return }
        pasteSpecificClip(id: entry.id)
    }

    private func pasteSpecificClip(id: UUID) {
        guard let entry = store.entry(id: id) else { return }
        // Snapshot the user's prior clipboard so we can restore it after the
        // paste (honors restoreClipboardAfterPaste, same as the other paths).
        let snapshot = DittoSettings.restoreClipboardAfterPaste ? ClipboardSaveRestore.snapshot() : nil
        store.copyToPasteboard(entry)
        // Sync the monitor's change count so it does NOT re-capture the clip
        // we just placed (otherwise the pasted item appears twice in history).
        monitor?.syncChangeCount()
        store.markPasted(entry)
        Statistics.shared.recordPaste()
        if DittoSettings.hideDittoOnPaste && DittoSettings.alwaysOnTop == false {
            historyWindowController?.window?.orderOut(nil)
        }
        let target = activeAppTracker.previousApplication
        PasteSimulator.paste(into: target)
        if let snapshot { ClipboardSaveRestore.restore(snapshot) { [weak self] in self?.monitor?.syncChangeCount() } }
    }

    private var copyBufferHotKeyIds: [UInt32: (Int, Bool)] = [:]

    private func registerCopyBufferHotKeys(controller: HotKeyController) {
        for (index, slotKeys) in copyBufferManager.slotHotKeys.enumerated() {
            let slot = index + 1
            if let copyKey = slotKeys.copyKey, let id = controller.register(hotKey: copyKey) {
                copyBufferHotKeyIds[id] = (slot, false)
            }
            if let pasteKey = slotKeys.pasteKey, let id = controller.register(hotKey: pasteKey) {
                copyBufferHotKeyIds[id] = (slot, true)
            }
        }
    }

    /// Register a global hot key for every clip that has shortcutKey > 0 and
    /// the global flag set (Windows `lShortCut` + `globalShortCut`).
    private func registerPerClipHotKeys(controller: HotKeyController) {
        perClipHotKeyIds.removeAll()
        for entry in store.snapshotEntries() where entry.shortcutKey > 0 && entry.shortcutGlobal {
            // shortcutKey stores a HotKey.encoded Int64.
            guard let hotKey = HotKey.decode(Int64(entry.shortcutKey)) else { continue }
            if let id = controller.register(hotKey: hotKey) {
                perClipHotKeyIds[id] = entry.id
            }
        }
    }

    /// Register the global first-ten paste hot keys (positions 1–10).
    private func registerFirstTenHotKeys(controller: HotKeyController) {
        firstTenHotKeyIds.removeAll()
        for (index, hotKey) in DittoSettings.firstTenGlobalHotKeys.enumerated() {
            guard let hotKey, let id = controller.register(hotKey: hotKey) else { continue }
            firstTenHotKeyIds[id] = index + 1
        }
    }

    // MARK: - Windows

    @objc func showHistory() {
        if historyWindowController == nil {
            let controller = HistoryWindowController(
                store: store,
                delegate: self,
                pasteHandler: { [weak self] in
                    self?.pasteToPreviousApplication()
                }
            )
            controller.syncMonitor = { [weak self] in self?.monitor?.syncChangeCount() }
            historyWindowController = controller
        }
        historyWindowController?.refresh()
        historyWindowController?.showWindow(nil)
        historyWindowController?.window?.makeKeyAndOrderFront(nil)
        historyWindowController?.applyOnShow()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showPreferences() {
        if preferencesWindowController == nil {
            preferencesWindowController = PreferencesWindowController(store: store, copyBufferManager: copyBufferManager, syncCoordinator: syncCoordinator) { [weak self] in
                self?.reregisterHotKeys()
                self?.store.enforceLimit()
                self?.historyWindowController?.refresh()
                self?.refreshLocalizedText()
                self?.applyThemeGlobally()
                self?.historyWindowController?.refresh()
            }
        }
        preferencesWindowController?.refreshText()
        preferencesWindowController?.showWindow(nil)
        preferencesWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showStatistics() {
        if statisticsWindowController == nil {
            statisticsWindowController = StatisticsWindowController()
        }
        statisticsWindowController?.refresh()
        statisticsWindowController?.showWindow(nil)
        statisticsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showGroups() {
        if groupsWindowController == nil {
            groupsWindowController = GroupsWindowController(store: store) { [weak self] in
                self?.historyWindowController?.refresh()
            }
        }
        groupsWindowController?.refresh()
        groupsWindowController?.showWindow(nil)
        groupsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showFriends() {
        if friendsWindowController == nil {
            friendsWindowController = FriendsWindowController(store: store, syncCoordinator: syncCoordinator)
        }
        friendsWindowController?.refresh()
        friendsWindowController?.showWindow(nil)
        friendsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showAbout() {
        let alert = NSAlert()
        alert.messageText = LocalizationManager.shared.text("about")
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        alert.informativeText = String(
            format: LocalizationManager.shared.text("about_body"),
            version
        )
        alert.alertStyle = .informational
        alert.runModal()
    }

    @objc func toggleAlwaysOnTopFromMenu() {
        DittoSettings.alwaysOnTop.toggle()
        historyWindowController?.applyWindowChromeFromOutside()
    }

    @objc func grantAccessibility() {
        // Remind the user (especially after an update) that the old entry must
        // be removed and the new one added — an ad-hoc signature changes each
        // build, so a stale entry won't grant. Then open System Settings.
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = LocalizationManager.shared.text("accessibility_required_title")
        alert.informativeText = LocalizationManager.shared.text("accessibility_setup_steps")
        alert.addButton(withTitle: LocalizationManager.shared.text("open_system_settings"))
        alert.addButton(withTitle: LocalizationManager.shared.text("close"))
        if alert.runModal() == .alertFirstButtonReturn {
            PasteSimulator.promptForAccessibility()
        }
    }

    private func reregisterHotKeys() {
        hotKeyController?.unregisterAll()
        copyBufferHotKeyIds.removeAll()
        perClipHotKeyIds.removeAll()
        firstTenHotKeyIds.removeAll()
        mainHotKeyId = nil
        guard let controller = hotKeyController else { return }
        if let choice = HotKeyChoice.currentChoice.hotKey {
            mainHotKeyId = controller.register(hotKey: choice)
        }
        registerCopyBufferHotKeys(controller: controller)
        registerPerClipHotKeys(controller: controller)
        registerFirstTenHotKeys(controller: controller)
    }

    // MARK: - Import / Export

    @objc func exportHistory() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "db") ?? .data]
        panel.nameFieldStringValue = "Ditto-History.db"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try self?.store.exportArchive(to: url)
                self?.showAlert(message: LocalizationManager.shared.text("export_success"))
            } catch {
                self?.showAlert(message: LocalizationManager.shared.text("operation_failed"))
            }
        }
    }

    @objc func importHistory() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "db") ?? .data]
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try self?.store.importArchive(from: url)
                self?.historyWindowController?.refresh()
                self?.showAlert(message: LocalizationManager.shared.text("import_success"))
            } catch {
                self?.showAlert(message: LocalizationManager.shared.text("operation_failed"))
            }
        }
    }

    @objc func importWindowsDatabase() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "db") ?? .data]
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let count = try self?.store.importWindowsDittoDatabase(from: url) ?? 0
                self?.historyWindowController?.refresh()
                self?.showAlert(message: LocalizationManager.shared.text("import_windows_success") + " (\(count))")
            } catch {
                self?.showAlert(message: LocalizationManager.shared.text("operation_failed"))
            }
        }
    }

    private func showAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = LocalizationManager.shared.text("app_name")
        alert.informativeText = message
        alert.runModal()
    }

    private func refreshLocalizedText() {
        historyWindowController?.refreshText()
        preferencesWindowController?.refreshText()
        // Re-localize any open secondary windows (titles are set at init time).
        groupsWindowController?.window?.title = LocalizationManager.shared.text("group") + "s"
        friendsWindowController?.window?.title = LocalizationManager.shared.text("friends")
        statisticsWindowController?.window?.title = LocalizationManager.shared.text("statistics")
        statisticsWindowController?.refresh()
        propertiesWindowController?.window?.title = LocalizationManager.shared.text("clip_properties")
        editorWindowController?.window?.title = LocalizationManager.shared.text("edit_clip")
        qrWindowController?.window?.title = LocalizationManager.shared.text("qr_code")
        imageViewerWindowController?.window?.title = LocalizationManager.shared.text("app_name")
        if let statusMenu { rebuildStatusMenu(statusMenu) }
    }

    // MARK: - Paste

    private func pasteToPreviousApplication() {
        // Hide after paste — UNLESS the window is pinned (always-on-top): a
        // pinned window is meant to stay open so you can paste item after item
        // without re-summoning Ditto each time.
        if DittoSettings.hideDittoOnPaste && DittoSettings.alwaysOnTop == false {
            historyWindowController?.window?.orderOut(nil)
        }
        let target = activeAppTracker.previousApplication
        // Always attempt the paste. Accessibility trust is surfaced via the
        // status-bar menu (✓ / ⚠ + "Grant Accessibility…") rather than a
        // per-paste prompt, which fired as a false alarm for users who had
        // already granted permission (the check is unreliable for rebuilt
        // ad-hoc binaries).
        // The caller already placed the clip on the pasteboard; sync the
        // monitor so it doesn't re-capture it as a new history entry.
        monitor?.syncChangeCount()
        Statistics.shared.recordPaste()
        PasteSimulator.paste(into: target)
    }

    // MARK: - Quit

    @objc func quit() {
        loginAgentManager.disable()
        NSApp.terminate(nil)
    }

    // MARK: - Status item

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            if let image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Ditto") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "Ditto"
            }
        }
        let menu = NSMenu()
        menu.delegate = self
        statusMenu = menu
        rebuildStatusMenu(menu)
        item.menu = menu
        statusItem = item
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildStatusMenu(menu)
    }

    @objc private func copyRecentMenuItem(_ sender: NSMenuItem) {
        guard let idString = sender.representedObject as? String,
              let id = UUID(uuidString: idString) else { return }
        // From the tray menu, selecting a recent item PASTES it into the
        // previous application (matches Windows behaviour), not just copy.
        pasteSpecificClip(id: id)
    }

    @objc private func pasteBufferFromMenu(_ sender: NSMenuItem) {
        guard let slot = sender.representedObject as? NSNumber else { return }
        let snapshot = DittoSettings.restoreClipboardAfterPaste ? ClipboardSaveRestore.snapshot() : nil
        guard let entry = copyBufferManager.paste(slot: slot.intValue) else { return }
        store.markPasted(entry)
        // pasteToPreviousApplication() already records the paste stat — don't
        // double-count it here.
        pasteToPreviousApplication()
        if let snapshot { ClipboardSaveRestore.restore(snapshot) { [weak self] in self?.monitor?.syncChangeCount() } }
    }

    @objc private func captureIntoBufferFromMenu(_ sender: NSMenuItem) {
        guard let slot = sender.representedObject as? NSNumber else { return }
        copyBufferManager.captureCurrentClipboard(into: slot.intValue)
    }

    private func rebuildStatusMenuIfNeeded() {
        guard let statusMenu, statusMenu.items.count > 0 else { return }
        // Only rebuild if currently showing recent items section.
        rebuildStatusMenu(statusMenu)
    }

    private func rebuildStatusMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        addItem(menu, title: LocalizationManager.shared.text("show_history"), action: #selector(showHistory), key: "")
        addItem(menu, title: LocalizationManager.shared.text("preferences"), action: #selector(showPreferences), key: ",")
        addItem(menu, title: LocalizationManager.shared.text("statistics"), action: #selector(showStatistics), key: "")
        menu.addItem(.separator())

        // Always-on-top toggle (accessible without opening the window).
        let onTop = addItem(menu, title: LocalizationManager.shared.text("always_on_top"), action: #selector(toggleAlwaysOnTopFromMenu), key: "")
        onTop.state = DittoSettings.alwaysOnTop ? .on : .off

        // Accessibility status (needed for paste). Lets the user open the
        // prompt directly from the menu bar.
        let axTitle = PasteSimulator.hasAccessibilityPermission
            ? "✓ Accessibility"
            : "⚠ Grant Accessibility…"
        addItem(menu, title: axTitle, action: #selector(grantAccessibility), key: "")

        let groupsItem = addItem(menu, title: LocalizationManager.shared.text("group") + "s", action: #selector(showGroups), key: "")
        _ = groupsItem
        let friendsItem = addItem(menu, title: LocalizationManager.shared.text("friends"), action: #selector(showFriends), key: "")
        _ = friendsItem

        // Copy Buffers submenu — paste from a numbered slot without a hot key.
        let bufferItem = NSMenuItem(title: LocalizationManager.shared.text("copy_buffers"), action: nil, keyEquivalent: "")
        let bufferSubmenu = NSMenu()
        for slot in 1...CopyBufferManager.slotCount {
            let preview: String
            if let entry = copyBufferManager.entry(in: slot) {
                preview = entry.preview.isEmpty ? LocalizationManager.shared.text("copy_buffer_empty") : entry.preview
            } else {
                preview = LocalizationManager.shared.text("copy_buffer_empty")
            }
            let truncated = preview.count > 32 ? String(preview.prefix(32)) + "…" : preview
            let pasteSlot = NSMenuItem(title: "\(slot)  \(truncated)", action: #selector(pasteBufferFromMenu(_:)), keyEquivalent: "")
            pasteSlot.target = self
            pasteSlot.representedObject = NSNumber(value: slot)
            bufferSubmenu.addItem(pasteSlot)
        }
        bufferSubmenu.addItem(.separator())
        let captureSlot = NSMenuItem(title: LocalizationManager.shared.text("capture_into_buffer"), action: nil, keyEquivalent: "")
        let captureSubmenu = NSMenu()
        for slot in 1...CopyBufferManager.slotCount {
            let item = NSMenuItem(title: "\(LocalizationManager.shared.text("copy_buffer_slot")) \(slot)", action: #selector(captureIntoBufferFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: slot)
            captureSubmenu.addItem(item)
        }
        captureSlot.submenu = captureSubmenu
        bufferSubmenu.addItem(captureSlot)
        bufferItem.submenu = bufferSubmenu
        menu.addItem(bufferItem)

        menu.addItem(.separator())

        addItem(menu, title: LocalizationManager.shared.text("import_history"), action: #selector(importHistory), key: "")
        addItem(menu, title: LocalizationManager.shared.text("import_windows_database"), action: #selector(importWindowsDatabase), key: "")
        addItem(menu, title: LocalizationManager.shared.text("export_history"), action: #selector(exportHistory), key: "")

        let recentEntries = Array(store.snapshotEntries().prefix(20))
        if recentEntries.isEmpty == false {
            menu.addItem(.separator())
        }
        for (index, entry) in recentEntries.enumerated() {
            let prefix = index < 9 ? "\(index + 1)  " : ""
            // Sanitize for a single-line menu title (newlines/tabs break it).
            let cleanPreview = entry.preview
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\t", with: " ")
            let title = "\(prefix)[\(entry.typeLabel)] \(cleanPreview)"
            let item = addItem(menu, title: title, action: #selector(copyRecentMenuItem(_:)), key: "")
            item.representedObject = entry.id.uuidString
        }

        menu.addItem(.separator())
        addItem(menu, title: LocalizationManager.shared.text("about"), action: #selector(showAbout), key: "")
        addItem(menu, title: LocalizationManager.shared.text("quit"), action: #selector(quit), key: "q")
    }

    @discardableResult
    private func addItem(_ menu: NSMenu, title: String, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    // MARK: - Sync

    private func startSync() {
        syncCoordinator.store = store
        syncCoordinator.start()
    }

    // MARK: - HistoryWindowDelegate

    func pasteEntryIntoPreviousApp(_ entry: ClipboardEntry, options: SpecialPasteOptions) {
        let snapshot = DittoSettings.restoreClipboardAfterPaste ? ClipboardSaveRestore.snapshot() : nil
        store.copyToPasteboard(entry, options: options)
        store.markPasted(entry)
        Statistics.shared.recordPaste()
        pasteToPreviousApplication()
        if let snapshot { ClipboardSaveRestore.restore(snapshot) { [weak self] in self?.monitor?.syncChangeCount() } }
    }

    func showProperties(for entry: ClipboardEntry) {
        propertiesWindowController = ClipPropertiesWindowController(store: store, entry: entry) { [weak self] in
            self?.historyWindowController?.refresh()
        }
        propertiesWindowController?.showWindow(nil)
        propertiesWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showEditor(for entry: ClipboardEntry) {
        editorWindowController = ClipEditorWindowController(store: store, entry: entry) { [weak self] in
            self?.historyWindowController?.refresh()
        }
        editorWindowController?.showWindow(nil)
        editorWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showQRCode(for entry: ClipboardEntry) {
        let text = entry.text ?? ""
        qrWindowController = QRCodeWindowController(text: text)
        qrWindowController?.showWindow(nil)
        qrWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showImageViewer(for entry: ClipboardEntry) {
        imageViewerWindowController = ImageViewerWindowController(entry: entry, store: store)
        imageViewerWindowController?.showWindow(nil)
        imageViewerWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func exportEntryAsText(_ entry: ClipboardEntry) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "clip.txt"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? entry.text?.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func exportEntryAsImage(_ entry: ClipboardEntry) {
        guard let imageBlobKey = entry.imageBlobKey, let data = store.blobData(named: imageBlobKey) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "clip.png"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? data.write(to: url)
        }
    }

    func webSearchEntry(_ entry: ClipboardEntry) {
        guard let text = entry.text else { return }
        openTemplateURL(DittoSettings.webSearchUrl, query: text)
    }

    func translateEntry(_ entry: ClipboardEntry) {
        guard let text = entry.text else { return }
        openTemplateURL(DittoSettings.translateUrl, query: text)
    }

    func emailEntry(_ entry: ClipboardEntry) {
        let service = NSSharingService(named: .composeEmail)
        service?.recipients = []
        service?.perform(withItems: [entry.text ?? entry.preview as NSString])
    }

    func sendEntryToFriend(_ entry: ClipboardEntry) {
        syncCoordinator.send(entry: entry)
    }

    func compareEntries(_ entries: [ClipboardEntry]) {
        guard entries.count >= 2 else { return }
        let left = entries[0]
        let right = entries[1]
        DiffPresenter.present(left: left, right: right, store: store)
    }

    func copyEntryToBuffer(_ entry: ClipboardEntry, slot: Int) {
        store.setCopyBuffer(slot: slot, entryId: entry.id)
    }

    // MARK: - Helpers

    private func openTemplateURL(_ template: String, query: String) {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = template.replacingOccurrences(of: "%s", with: encoded)
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    private var startupMessageShownKey = "Ditto.StartupMessageShown"

    private func showStartupMessageIfNeeded() {
        guard UserDefaults.standard.bool(forKey: startupMessageShownKey) == false else { return }
        UserDefaults.standard.set(true, forKey: startupMessageShownKey)
        let alert = NSAlert()
        alert.messageText = LocalizationManager.shared.text("app_name")
        alert.informativeText = "Ditto is running in the menu bar. \(LocalizationManager.shared.text("hot_key")): \(HotKeyChoice.currentChoice.title)\n\nTo enable paste, grant Accessibility permission in System Settings ▸ Privacy & Security."
        alert.runModal()
    }
}
