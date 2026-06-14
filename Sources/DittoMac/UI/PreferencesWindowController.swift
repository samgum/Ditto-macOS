import AppKit
import Carbon
import Foundation

final class PreferencesWindowController: NSWindowController {
    private let store: ClipboardStore
    private let copyBufferManager: CopyBufferManager
    private let syncCoordinator: SyncCoordinator
    private let onChanged: () -> Void

    private let tabView = NSTabView()
    private let closeButton = NSButton(title: "", target: nil, action: nil)

    // General
    private let languagePopup = NSPopUpButton()
    private let hotKeyPopup = NSPopUpButton()
    private let maxHistoryPopup = NSPopUpButton()
    private let openAtLoginButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let playSoundButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let promptOnDeleteButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let startupMessageButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let updateTimeOnPasteButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let hideOnPasteButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)

    // Appearance
    private let themePopup = NSPopUpButton()
    private let accentWell = NSColorWell()
    private let fontSizePopup = NSPopUpButton()
    private let linesPerRowPopup = NSPopUpButton()
    private let drawThumbnailsButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let pasteAsPlainTextButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)

    // Capture
    private let excludeAppsField = NSTextField()
    private let includeAppsField = NSTextField()
    private let enableExpiryButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let expiryDaysField = NSTextField()
    private let maxClipSizeField = NSTextField()

    // Search
    private let searchDescriptionButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let searchFullTextButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let searchQuickPasteButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let regexCaseInsensitiveButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)

    // Behavior / multi-paste
    private let allowDuplicatesButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let multiPasteSeparatorField = NSTextField()
    private let multiPasteReverseButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let saveMultiPasteButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let slugifySeparatorField = NSTextField()

    // Network
    private let syncEnabledButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let syncReceiveButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let portField = NSTextField()
    private let passwordField = NSSecureTextField()

    // External
    private let diffAppField = NSTextField()
    private let translateUrlField = NSTextField()
    private let webSearchUrlField = NSTextField()
    private let databasePathField = NSTextField()
    private let databaseChooseButton = NSButton(title: "Choose…", target: nil, action: nil)
    private let regexFiltersField = NSTextField()

    private let loginAgent = LoginAgentManager()

    init(store: ClipboardStore, copyBufferManager: CopyBufferManager, syncCoordinator: SyncCoordinator, onChanged: @escaping () -> Void) {
        self.store = store
        self.copyBufferManager = copyBufferManager
        self.syncCoordinator = syncCoordinator
        self.onChanged = onChanged

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = LocalizationManager.shared.text("preferences")
        window.center()
        super.init(window: window)
        configureContent()
    }

    required init?(coder: NSCoder) { nil }

    func refreshText() {
        // Fully rebuild the content so EVERY label / checkbox / tab re-renders
        // in the current language (was only updating the title + popups, so the
        // window stayed stuck in the language it was first opened in).
        configureContent()
        window?.title = LocalizationManager.shared.text("preferences")
        populate()
    }

    private func configureContent() {
        guard let window else { return }

        // Make re-runnable: drop any previously-built tabs + checkbox boxes so
        // refreshText() can rebuild cleanly in a new language.
        while tabView.numberOfTabViewItems > 0 {
            tabView.removeTabViewItem(tabView.tabViewItems[0])
        }
        checkboxBoxes.removeAll()

        tabView.tabViewType = .topTabsBezelBorder
        tabView.translatesAutoresizingMaskIntoConstraints = false

        tabView.addTabViewItem(tab(LocalizationManager.shared.text("general")) { generalTab() })
        tabView.addTabViewItem(tab(LocalizationManager.shared.text("appearance")) { appearanceTab() })
        tabView.addTabViewItem(tab(LocalizationManager.shared.text("search_mode")) { searchTab() })
        tabView.addTabViewItem(tab(LocalizationManager.shared.text("advanced")) { advancedTab() })
        tabView.addTabViewItem(tab(LocalizationManager.shared.text("copy_buffers")) { copyBuffersTab() })
        tabView.addTabViewItem(tab(LocalizationManager.shared.text("network")) { networkTab() })
        tabView.addTabViewItem(tab(LocalizationManager.shared.text("friends")) { friendsPlaceholderTab() })

        closeButton.title = LocalizationManager.shared.text("close")
        closeButton.bezelStyle = .rounded
        closeButton.target = self
        closeButton.action = #selector(closeWindow)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.keyEquivalent = "\u{1b}"

        let root = NSView()
        root.addSubview(tabView)
        root.addSubview(closeButton)
        window.contentView = root

        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            tabView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            tabView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            tabView.bottomAnchor.constraint(equalTo: closeButton.topAnchor, constant: -12),

            closeButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            closeButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)
        ])

        populate()
        bindActions()
    }

    private func tab(_ title: String, _ build: () -> NSView) -> NSTabViewItem {
        let item = NSTabViewItem()
        item.label = title
        item.view = build()
        return item
    }

    // MARK: - Tabs

    private func generalTab() -> NSView {
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged)
        hotKeyPopup.target = self
        hotKeyPopup.action = #selector(hotKeyChanged)
        maxHistoryPopup.target = self
        maxHistoryPopup.action = #selector(maxHistoryChanged)
        bindCheckbox(openAtLoginButton, default: loginAgent.isEnabled) { [weak self] in self?.toggleLogin($0) }
        bindCheckbox(playSoundButton, default: DittoSettings.playSoundOnCopy) { DittoSettings.playSoundOnCopy = $0 }
        bindCheckbox(promptOnDeleteButton, default: DittoSettings.promptWhenDeleting) { DittoSettings.promptWhenDeleting = $0 }
        bindCheckbox(startupMessageButton, default: DittoSettings.showStartupMessage) { DittoSettings.showStartupMessage = $0 }
        bindCheckbox(updateTimeOnPasteButton, default: DittoSettings.updateTimeOnPaste) { DittoSettings.updateTimeOnPaste = $0 }
        bindCheckbox(hideOnPasteButton, default: DittoSettings.hideDittoOnPaste) { DittoSettings.hideDittoOnPaste = $0 }
        let restoreClipboardButton = NSButton(checkboxWithTitle: LocalizationManager.shared.text("restore_clipboard_after_paste"), target: nil, action: nil)
        bindCheckbox(restoreClipboardButton, default: DittoSettings.restoreClipboardAfterPaste) { DittoSettings.restoreClipboardAfterPaste = $0 }

        return grid([
            [label(LocalizationManager.shared.text("language")), languagePopup],
            [label(LocalizationManager.shared.text("hot_key")), hotKeyPopup],
            [label(LocalizationManager.shared.text("max_history")), maxHistoryPopup],
            [NSView(), openAtLoginButton],
            [NSView(), playSoundButton],
            [NSView(), promptOnDeleteButton],
            [NSView(), updateTimeOnPasteButton],
            [NSView(), hideOnPasteButton],
            [NSView(), restoreClipboardButton],
            [NSView(), startupMessageButton]
        ])
    }

    private func appearanceTab() -> NSView {
        themePopup.target = self
        themePopup.action = #selector(themeChanged)
        accentWell.target = self
        accentWell.action = #selector(accentChanged)
        fontSizePopup.target = self
        fontSizePopup.action = #selector(fontSizeChanged)
        linesPerRowPopup.target = self
        linesPerRowPopup.action = #selector(linesPerRowChanged)
        let alwaysOnTopButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        let showFirstTenButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        bindCheckbox(drawThumbnailsButton, default: DittoSettings.drawThumbnails) { DittoSettings.drawThumbnails = $0 }
        bindCheckbox(pasteAsPlainTextButton, default: DittoSettings.pasteAsPlainTextByDefault) { DittoSettings.pasteAsPlainTextByDefault = $0 }
        bindCheckbox(alwaysOnTopButton, default: DittoSettings.alwaysOnTop) { DittoSettings.alwaysOnTop = $0 }
        bindCheckbox(showFirstTenButton, default: DittoSettings.showFirstTenText) { DittoSettings.showFirstTenText = $0 }
        alwaysOnTopButton.title = LocalizationManager.shared.text("always_on_top")
        showFirstTenButton.title = LocalizationManager.shared.text("show_first_ten")

        openAtLoginButton.title = LocalizationManager.shared.text("open_at_login")
        playSoundButton.title = LocalizationManager.shared.text("play_sound_on_copy")
        promptOnDeleteButton.title = LocalizationManager.shared.text("prompt_on_delete")
        updateTimeOnPasteButton.title = LocalizationManager.shared.text("update_time_on_paste")
        hideOnPasteButton.title = LocalizationManager.shared.text("hide_on_paste")
        startupMessageButton.title = LocalizationManager.shared.text("show_startup_message")
        drawThumbnailsButton.title = LocalizationManager.shared.text("draw_thumbnails")
        pasteAsPlainTextButton.title = LocalizationManager.shared.text("paste_as_plain_text_default")

        return grid([
            [label(LocalizationManager.shared.text("theme")), themePopup],
            [label(LocalizationManager.shared.text("accent_color")), accentWell],
            [label(LocalizationManager.shared.text("font_size")), fontSizePopup],
            [label(LocalizationManager.shared.text("lines_per_row")), linesPerRowPopup],
            [NSView(), drawThumbnailsButton],
            [NSView(), pasteAsPlainTextButton],
            [NSView(), alwaysOnTopButton],
            [NSView(), showFirstTenButton]
        ])
    }

    private func searchTab() -> NSView {
        bindCheckbox(searchDescriptionButton, default: DittoSettings.searchDescription) { DittoSettings.searchDescription = $0 }
        bindCheckbox(searchFullTextButton, default: DittoSettings.searchFullText) { DittoSettings.searchFullText = $0 }
        bindCheckbox(searchQuickPasteButton, default: DittoSettings.searchQuickPaste) { DittoSettings.searchQuickPaste = $0 }
        bindCheckbox(regexCaseInsensitiveButton, default: DittoSettings.regexCaseInsensitive) { DittoSettings.regexCaseInsensitive = $0 }
        searchDescriptionButton.title = LocalizationManager.shared.text("description")
        searchFullTextButton.title = LocalizationManager.shared.text("full_text")
        searchQuickPasteButton.title = LocalizationManager.shared.text("quick_paste_text")
        regexCaseInsensitiveButton.title = LocalizationManager.shared.text("regex_case_insensitive")
        return grid([
            [label(LocalizationManager.shared.text("search_in")), NSView()],
            [NSView(), searchDescriptionButton],
            [NSView(), searchFullTextButton],
            [NSView(), searchQuickPasteButton],
            [NSView(), regexCaseInsensitiveButton]
        ])
    }

    private func advancedTab() -> NSView {
        includeAppsField.placeholderString = "*"
        excludeAppsField.placeholderString = ""
        includeAppsField.target = self
        includeAppsField.action = #selector(appFilterChanged)
        excludeAppsField.target = self
        excludeAppsField.action = #selector(appFilterChanged)
        bindCheckbox(enableExpiryButton, default: DittoSettings.checkExpiredEntries) { DittoSettings.checkExpiredEntries = $0 }
        bindCheckbox(allowDuplicatesButton, default: DittoSettings.allowDuplicates) { DittoSettings.allowDuplicates = $0 }
        bindCheckbox(multiPasteReverseButton, default: DittoSettings.multiPasteReverse) { DittoSettings.multiPasteReverse = $0 }
        bindCheckbox(saveMultiPasteButton, default: DittoSettings.saveMultiPaste) { DittoSettings.saveMultiPaste = $0 }
        expiryDaysField.target = self
        expiryDaysField.action = #selector(expiryDaysChanged)
        maxClipSizeField.target = self
        maxClipSizeField.action = #selector(maxClipSizeChanged)
        multiPasteSeparatorField.target = self
        multiPasteSeparatorField.action = #selector(multiPasteSeparatorChanged)
        slugifySeparatorField.target = self
        slugifySeparatorField.action = #selector(slugifySeparatorChanged)
        diffAppField.target = self
        diffAppField.action = #selector(diffAppChanged)
        translateUrlField.target = self
        translateUrlField.action = #selector(translateUrlChanged)
        webSearchUrlField.target = self
        webSearchUrlField.action = #selector(webSearchUrlChanged)
        regexFiltersField.placeholderString = "\\d{6}\npassword\nsecret"
        regexFiltersField.target = self
        regexFiltersField.action = #selector(regexFiltersChanged)

        enableExpiryButton.title = LocalizationManager.shared.text("enable_expiry")
        allowDuplicatesButton.title = LocalizationManager.shared.text("allow_duplicate_clips")
        multiPasteReverseButton.title = LocalizationManager.shared.text("multi_paste_reverse")
        saveMultiPasteButton.title = LocalizationManager.shared.text("multi_paste_save_new")

        return grid([
            [label(LocalizationManager.shared.text("include_apps")), includeAppsField],
            [label(LocalizationManager.shared.text("exclude_apps")), excludeAppsField],
            [NSView(), enableExpiryButton],
            [label(LocalizationManager.shared.text("expire_after_days")), expiryDaysField],
            [label(LocalizationManager.shared.text("max_clip_size")), maxClipSizeField],
            [NSView(), allowDuplicatesButton],
            [label(LocalizationManager.shared.text("multi_paste")), multiPasteSeparatorField],
            [NSView(), multiPasteReverseButton],
            [NSView(), saveMultiPasteButton],
            [label(LocalizationManager.shared.text("slugify")), slugifySeparatorField],
            [label(LocalizationManager.shared.text("diff_app")), diffAppField],
            [label(LocalizationManager.shared.text("translate")), translateUrlField],
            [label(LocalizationManager.shared.text("web_search")), webSearchUrlField],
            [label(LocalizationManager.shared.text("regex_filters")), regexFiltersField]
        ])
    }

    private func copyBuffersTab() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        let info = NSTextField(wrappingLabelWithString: LocalizationManager.shared.text("copy_buffers_desc"))
        info.font = NSFont.systemFont(ofSize: 11)
        info.textColor = .secondaryLabelColor
        stack.addArrangedSubview(info)
        for index in 0..<CopyBufferManager.slotCount {
            let slot = index + 1
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8
            let title = NSTextField(labelWithString: LocalizationManager.shared.text("copy_buffer_slot") + " \(slot)")
            let copyDisplay = NSTextField(labelWithString: copyBufferManager.slotHotKeys[index].copyKey?.displayString ?? LocalizationManager.shared.text("empty"))
            copyDisplay.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            let pasteDisplay = NSTextField(labelWithString: copyBufferManager.slotHotKeys[index].pasteKey?.displayString ?? LocalizationManager.shared.text("empty"))
            pasteDisplay.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            let copyButton = NSButton(title: LocalizationManager.shared.text("copy_buffer_copy_hotkey"), target: self, action: #selector(recordCopyKey(_:)))
            copyButton.tag = index
            let pasteButton = NSButton(title: LocalizationManager.shared.text("copy_buffer_paste_hotkey"), target: self, action: #selector(recordPasteKey(_:)))
            pasteButton.tag = index
            row.addArrangedSubview(title)
            row.addArrangedSubview(copyDisplay)
            row.addArrangedSubview(copyButton)
            row.addArrangedSubview(pasteDisplay)
            row.addArrangedSubview(pasteButton)
            stack.addArrangedSubview(row)
        }
        let container = NSView()
        container.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12)
        ])
        return container
    }

    private func networkTab() -> NSView {
        bindCheckbox(syncEnabledButton, default: !DittoSettings.disableReceive || DittoSettings.allowFriends) { [weak self] _ in self?.syncEnabledChanged() }
        bindCheckbox(syncReceiveButton, default: !DittoSettings.disableReceive) { [weak self] on in
            DittoSettings.disableReceive = !on
            // Restart the coordinator so the receive change takes effect now.
            self?.syncCoordinator.stop()
            self?.syncCoordinator.start()
        }
        portField.target = self
        portField.action = #selector(portChanged)
        passwordField.target = self
        passwordField.action = #selector(passwordChanged)
        syncEnabledButton.title = LocalizationManager.shared.text("sync_enabled")
        syncReceiveButton.title = LocalizationManager.shared.text("sync_receive")

        return grid([
            [NSView(), syncEnabledButton],
            [NSView(), syncReceiveButton],
            [label(LocalizationManager.shared.text("sync_port")), portField],
            [label(LocalizationManager.shared.text("sync_password")), passwordField]
        ])
    }

    private func friendsPlaceholderTab() -> NSView {
        let label = NSTextField(wrappingLabelWithString: LocalizationManager.shared.text("friends_desc"))
        label.font = NSFont.systemFont(ofSize: 12)
        let container = NSView()
        container.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16)
        ])
        return container
    }

    // MARK: - Helpers

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.alignment = .right
        field.textColor = .secondaryLabelColor
        return field
    }

    private func grid(_ rows: [[NSView]]) -> NSView {
        let gridView = NSGridView(views: rows)
        gridView.column(at: 0).xPlacement = .trailing
        gridView.column(at: 1).xPlacement = .fill
        gridView.rowSpacing = 10
        gridView.columnSpacing = 12
        let container = NSView()
        container.addSubview(gridView)
        gridView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            gridView.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            gridView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            gridView.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16)
        ])
        return container
    }

    private func bindCheckbox(_ button: NSButton, default value: Bool, _ handler: @escaping (Bool) -> Void) {
        button.state = value ? .on : .off
        button.target = self
        let box = CheckboxBox(handler: handler)
        button.target = box
        button.action = #selector(CheckboxBox.toggle(_:))
        checkboxBoxes.append(box)
    }

    private var checkboxBoxes: [CheckboxBox] = []

    private func bindActions() {
        closeButton.target = self
        closeButton.action = #selector(closeWindow)
    }

    // MARK: - Populate

    private func populate() {
        languagePopup.removeAllItems()
        for language in LocalizationManager.shared.languages {
            languagePopup.addItem(withTitle: language.name)
        }
        if let index = LocalizationManager.shared.languages.firstIndex(where: { $0.code == LocalizationManager.shared.currentLanguage }) {
            languagePopup.selectItem(at: index)
        }

        hotKeyPopup.removeAllItems()
        for choice in HotKeyChoice.allCases {
            hotKeyPopup.addItem(withTitle: choice.title)
        }
        if let index = HotKeyChoice.allCases.firstIndex(of: HotKeyChoice.currentChoice) {
            hotKeyPopup.selectItem(at: index)
        }

        maxHistoryPopup.removeAllItems()
        for option in DittoSettings.maxHistoryOptions {
            maxHistoryPopup.addItem(withTitle: option == 0 ? "∞ Unlimited" : "\(option)")
        }
        maxHistoryPopup.addItem(withTitle: "Custom…")
        if let index = DittoSettings.maxHistoryOptions.firstIndex(of: DittoSettings.maxHistoryEntries) {
            maxHistoryPopup.selectItem(at: index)
        } else {
            maxHistoryPopup.selectItem(at: maxHistoryPopup.numberOfItems - 1)
        }

        themePopup.removeAllItems()
        for mode in DittoTheme.Mode.allCases {
            themePopup.addItem(withTitle: mode.title)
        }
        if let index = DittoTheme.Mode.allCases.firstIndex(of: DittoTheme.current.mode) {
            themePopup.selectItem(at: index)
        }
        accentWell.color = DittoTheme.current.accent

        fontSizePopup.removeAllItems()
        for size in stride(from: 11, through: 18, by: 1) {
            fontSizePopup.addItem(withTitle: "\(size)")
        }
        fontSizePopup.selectItem(withTitle: "\(DittoSettings.fontSize)")

        linesPerRowPopup.removeAllItems()
        for lines in 1...4 {
            linesPerRowPopup.addItem(withTitle: "\(lines)")
        }
        linesPerRowPopup.selectItem(withTitle: "\(DittoSettings.linesPerRow)")

        includeAppsField.stringValue = DittoSettings.copyAppInclude
        excludeAppsField.stringValue = DittoSettings.copyAppExclude
        expiryDaysField.stringValue = "\(DittoSettings.expiredEntriesDays)"
        maxClipSizeField.stringValue = DittoSettings.maxClipSizeBytes == 0 ? "0" : "\(DittoSettings.maxClipSizeBytes / 1_000_000)"
        multiPasteSeparatorField.stringValue = DittoSettings.multiPasteSeparator
        slugifySeparatorField.stringValue = DittoSettings.slugifySeparator
        diffAppField.stringValue = DittoSettings.diffApp
        translateUrlField.stringValue = DittoSettings.translateUrl
        webSearchUrlField.stringValue = DittoSettings.webSearchUrl
        regexFiltersField.stringValue = DittoSettings.regexCopyFilters.joined(separator: "\n")
        portField.stringValue = "\(DittoSettings.sendRecvPort)"
        passwordField.stringValue = DittoSettings.networkPassword
    }

    // MARK: - Actions

    @objc private func languageChanged() {
        let selected = LocalizationManager.shared.languages[languagePopup.indexOfSelectedItem]
        LocalizationManager.shared.setLanguage(selected.code)
        onChanged()
    }

    @objc private func hotKeyChanged() {
        HotKeyChoice.currentChoice = HotKeyChoice.allCases[hotKeyPopup.indexOfSelectedItem]
        onChanged()
    }

    @objc private func maxHistoryChanged() {
        let index = maxHistoryPopup.indexOfSelectedItem
        if DittoSettings.maxHistoryOptions.indices.contains(index) {
            DittoSettings.maxHistoryEntries = DittoSettings.maxHistoryOptions[index]
            store.enforceLimit()
            onChanged()
        } else {
            // "Custom…" — prompt for a number
            let alert = NSAlert()
            alert.messageText = LocalizationManager.shared.text("max_history")
            alert.addButton(withTitle: LocalizationManager.shared.text("ok"))
            alert.addButton(withTitle: LocalizationManager.shared.text("cancel"))
            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
            input.stringValue = "\(DittoSettings.maxHistoryEntries)"
            alert.accessoryView = input
            if alert.runModal() == .alertFirstButtonReturn, let value = Int(input.stringValue), value > 0 {
                DittoSettings.maxHistoryEntries = value
                store.enforceLimit()
                onChanged()
            }
            populate()
        }
    }

    @objc private func themeChanged() {
        let index = themePopup.indexOfSelectedItem
        if let mode = DittoTheme.Mode.allCases[safe: index] {
            DittoTheme.setMode(mode)
            onChanged()
        }
    }

    @objc private func accentChanged() {
        DittoTheme.setAccent(accentWell.color)
    }

    @objc private func fontSizeChanged() {
        if let title = fontSizePopup.titleOfSelectedItem, let size = Int(title) {
            DittoSettings.fontSize = size
            onChanged()
        }
    }

    @objc private func linesPerRowChanged() {
        if let title = linesPerRowPopup.titleOfSelectedItem, let lines = Int(title) {
            DittoSettings.linesPerRow = lines
            onChanged()
        }
    }

    @objc private func toggleLogin(_ on: Bool) {
        if on { loginAgent.installOrRefresh() } else { loginAgent.disable() }
    }

    @objc private func appFilterChanged() {
        DittoSettings.copyAppInclude = includeAppsField.stringValue
        DittoSettings.copyAppExclude = excludeAppsField.stringValue
    }

    @objc private func expiryDaysChanged() {
        if let value = Int(expiryDaysField.stringValue) { DittoSettings.expiredEntriesDays = value }
    }

    @objc private func maxClipSizeChanged() {
        let trimmed = maxClipSizeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), value >= 0 else { return } // ignore garbage/empty
        DittoSettings.maxClipSizeBytes = value * 1_000_000
    }

    @objc private func multiPasteSeparatorChanged() {
        DittoSettings.multiPasteSeparator = multiPasteSeparatorField.stringValue
    }

    @objc private func slugifySeparatorChanged() {
        DittoSettings.slugifySeparator = slugifySeparatorField.stringValue
    }

    @objc private func diffAppChanged() { DittoSettings.diffApp = diffAppField.stringValue }
    @objc private func translateUrlChanged() { DittoSettings.translateUrl = translateUrlField.stringValue }
    @objc private func webSearchUrlChanged() { DittoSettings.webSearchUrl = webSearchUrlField.stringValue }

    @objc private func regexFiltersChanged() {
        let lines = regexFiltersField.stringValue
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
        DittoSettings.regexCopyFilters = lines
    }

    @objc private func syncEnabledChanged() {
        DittoSettings.allowFriends = syncEnabledButton.state == .on
        if syncEnabledButton.state == .on { syncCoordinator.start() } else { syncCoordinator.stop() }
    }

    @objc private func portChanged() {
        if let value = Int(portField.stringValue) { DittoSettings.sendRecvPort = value }
    }

    @objc private func passwordChanged() {
        DittoSettings.networkPassword = passwordField.stringValue
    }

    @objc private func recordCopyKey(_ sender: NSButton) {
        HotKeyRecorder.record { [weak self] hotKey in
            guard let hotKey else { return }
            self?.copyBufferManager.slotHotKeys[sender.tag].copyKey = hotKey
            self?.copyBufferManager.save()
            self?.onChanged()
        }
    }

    @objc private func recordPasteKey(_ sender: NSButton) {
        HotKeyRecorder.record { [weak self] hotKey in
            guard let hotKey else { return }
            self?.copyBufferManager.slotHotKeys[sender.tag].pasteKey = hotKey
            self?.copyBufferManager.save()
            self?.onChanged()
        }
    }

    @objc private func closeWindow() { close() }
}

/// Wraps a closure so an `NSButton` checkbox can invoke it via target/action.
final class CheckboxBox {
    private let handler: (Bool) -> Void
    init(handler: @escaping (Bool) -> Void) { self.handler = handler }
    @objc func toggle(_ sender: NSButton) { handler(sender.state == .on) }
}

/// Modal global hot-key recorder: presents a sheet and captures the next key
/// combination as a `HotKey`.
enum HotKeyRecorder {
    static func record(completion: @escaping (HotKey?) -> Void) {
        let alert = NSAlert()
        alert.messageText = LocalizationManager.shared.text("record_shortcut")
        alert.addButton(withTitle: LocalizationManager.shared.text("cancel"))
        let field = NSTextField(labelWithString: "…")
        field.alignment = .center
        field.font = NSFont.boldSystemFont(ofSize: 18)
        alert.accessoryView = field

        var monitor: Any?
        var finished = false
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard finished == false else { return event }
            let keyCode = UInt32(event.keyCode)
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let carbonMods = HotKeyRecorder.carbonFlags(from: modifiers)
            if carbonMods != 0 {
                finished = true
                if let monitor { NSEvent.removeMonitor(monitor) }
                completion(HotKey(keyCode: keyCode, modifiers: carbonMods))
                NSApp.abortModal()
                return nil
            }
            return event
        }

        alert.runModal()
        if finished == false, let monitor { NSEvent.removeMonitor(monitor) }
        if finished == false { completion(nil) }
    }

    private static func carbonFlags(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }
}
