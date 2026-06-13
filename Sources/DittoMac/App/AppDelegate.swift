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

    private var mainHotKeyId: UInt32?

    override init() {
        copyBufferManager = CopyBufferManager(store: store)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        ProcessInfo.processInfo.disableAutomaticTermination("Ditto monitors the clipboard from the menu bar.")

        if DittoSettings.showStartupMessage {
            showStartupMessageIfNeeded()
        }

        applyThemeGlobally()
        registerHotKeys()
        configureStatusItem()
        activeAppTracker.start()
        loginAgentManager.installOrRefresh()

        let monitor = ClipboardMonitor(store: store)
        monitor.onChange = { [weak self] in
            Statistics.shared.recordCopy()
            self?.historyWindowController?.refresh()
            self?.rebuildStatusMenuIfNeeded()
        }
        monitor.start()
        self.monitor = monitor

        store.enforceExpiry()
        registerNotifications()
        startSync()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Theme

    private func applyThemeGlobally() {
        NSApp.appearance = DittoTheme.current.effectiveAppearance
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
        hotKeyController = controller
    }

    private func handleHotKey(id: UInt32) {
        if id == mainHotKeyId {
            showHistory()
            return
        }
        // Copy-buffer hot keys.
        if let (slot, isPaste) = copyBufferHotKeyIds[id] {
            if isPaste {
                if let entry = copyBufferManager.paste(slot: slot) {
                    store.markPasted(entry)
                    Statistics.shared.recordPaste()
                    PasteSimulator.paste()
                }
            } else {
                copyBufferManager.captureCurrentClipboard(into: slot)
            }
        }
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

    // MARK: - Windows

    @objc func showHistory() {
        if historyWindowController == nil {
            historyWindowController = HistoryWindowController(
                store: store,
                delegate: self,
                pasteHandler: { [weak self] in
                    self?.pasteToPreviousApplication()
                }
            )
        }
        historyWindowController?.refresh()
        historyWindowController?.showWindow(nil)
        historyWindowController?.window?.makeKeyAndOrderFront(nil)
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
        alert.informativeText = "Ditto for macOS\n" + LocalizationManager.shared.text("version") + " \(version)\n\nA native macOS port of Ditto, the clipboard manager.\nhttps://github.com/samgum/Ditto-macOS"
        alert.alertStyle = .informational
        alert.runModal()
    }

    private func reregisterHotKeys() {
        hotKeyController?.unregisterAll()
        copyBufferHotKeyIds.removeAll()
        mainHotKeyId = nil
        guard let controller = hotKeyController else { return }
        if let choice = HotKeyChoice.currentChoice.hotKey {
            mainHotKeyId = controller.register(hotKey: choice)
        }
        registerCopyBufferHotKeys(controller: controller)
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
        if let statusMenu { rebuildStatusMenu(statusMenu) }
    }

    // MARK: - Paste

    private func pasteToPreviousApplication() {
        if DittoSettings.hideDittoOnPaste {
            historyWindowController?.window?.orderOut(nil)
        }
        let target = activeAppTracker.previousApplication
        if PasteSimulator.hasAccessibilityPermission == false {
            PasteSimulator.promptForAccessibility()
        }
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
              let id = UUID(uuidString: idString),
              let entry = store.entry(id: id) else { return }
        store.copyToPasteboard(entry)
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

        let groupsItem = addItem(menu, title: LocalizationManager.shared.text("group") + "s", action: #selector(showGroups), key: "")
        _ = groupsItem
        let friendsItem = addItem(menu, title: LocalizationManager.shared.text("friends"), action: #selector(showFriends), key: "")
        _ = friendsItem

        menu.addItem(.separator())

        addItem(menu, title: LocalizationManager.shared.text("import_history"), action: #selector(importHistory), key: "")
        addItem(menu, title: LocalizationManager.shared.text("import_windows_database"), action: #selector(importWindowsDatabase), key: "")
        addItem(menu, title: LocalizationManager.shared.text("export_history"), action: #selector(exportHistory), key: "")

        let recentEntries = Array(store.entries.prefix(10))
        if recentEntries.isEmpty == false {
            menu.addItem(.separator())
        }
        for (index, entry) in recentEntries.enumerated() {
            let prefix = index < 9 ? "\(index + 1)  " : ""
            let title = "\(prefix)[\(entry.typeLabel)] \(entry.preview)"
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
        store.copyToPasteboard(entry, options: options)
        store.markPasted(entry)
        Statistics.shared.recordPaste()
        pasteToPreviousApplication()
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
