import AppKit
import Carbon
import Foundation

/// Actions the history window can ask its owner to perform (kept as a protocol
/// so the window stays decoupled from the AppDelegate).
protocol HistoryWindowDelegate: AnyObject {
    func pasteEntryIntoPreviousApp(_ entry: ClipboardEntry, options: SpecialPasteOptions)
    func showProperties(for entry: ClipboardEntry)
    func showEditor(for entry: ClipboardEntry)
    func showQRCode(for entry: ClipboardEntry)
    func showImageViewer(for entry: ClipboardEntry)
    func exportEntryAsText(_ entry: ClipboardEntry)
    func exportEntryAsImage(_ entry: ClipboardEntry)
    func webSearchEntry(_ entry: ClipboardEntry)
    func translateEntry(_ entry: ClipboardEntry)
    func emailEntry(_ entry: ClipboardEntry)
    func sendEntryToFriend(_ entry: ClipboardEntry)
    func compareEntries(_ entries: [ClipboardEntry])
    func copyEntryToBuffer(_ entry: ClipboardEntry, slot: Int)
}

final class HistoryWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private enum GroupFilter: Equatable {
        case all
        case favorites
        case ungrouped
        case group(Int64)
    }

    private enum TypeFilter: Equatable {
        case all, text, images, files, richText, html
    }

    private let store: ClipboardStore
    private weak var delegate: HistoryWindowDelegate?
    private let pasteHandler: () -> Void

    private let searchField = NSSearchField()
    private let modePopup = NSPopUpButton()
    private let typeFilterPopup = NSPopUpButton()
    private let groupFilterPopup = NSPopUpButton()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let countLabel = NSTextField(labelWithString: "")
    private let previewPanel = NSTextView()
    private let previewScroll = NSScrollView()
    private var previewHeightConstraint: NSLayoutConstraint?
    private var scrollViewBottomToPreviewConstraint: NSLayoutConstraint?
    private var descriptionVisible = false
    private var filteredEntries: [ClipboardEntry] = []
    private var currentGroupFilter: GroupFilter = .all
    private var currentTypeFilter: TypeFilter = .all
    private var searchMode: SearchMode = .contains
    private var keyEventMonitor: Any?
    private var themeObserver: NSObjectProtocol?

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    init(store: ClipboardStore, delegate: HistoryWindowDelegate, pasteHandler: @escaping () -> Void) {
        self.store = store
        self.delegate = delegate
        self.pasteHandler = pasteHandler

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 520),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = LocalizationManager.shared.text("app_name")
        window.center()
        window.minSize = NSSize(width: 560, height: 360)

        super.init(window: window)
        filteredEntries = store.entries
        configureContent()
        applyTheme()
        applyWindowChrome()

        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event) ?? event
        }
        themeObserver = NotificationCenter.default.addObserver(forName: .dittoThemeChanged, object: nil, queue: .main) { [weak self] _ in
            self?.applyTheme()
        }
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let keyEventMonitor { NSEvent.removeMonitor(keyEventMonitor) }
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
    }

    func refresh() { applySearch() }

    func refreshText() {
        window?.title = LocalizationManager.shared.text("app_name")
        searchField.placeholderString = LocalizationManager.shared.text("search")
        rebuildModePopup()
        rebuildTypeFilterPopup()
        rebuildGroupFilterPopup()
        tableView.tableColumns.first { $0.identifier.rawValue == "clip" }?.title = LocalizationManager.shared.text("clip")
        tableView.tableColumns.first { $0.identifier.rawValue == "type" }?.title = LocalizationManager.shared.text("type")
        tableView.tableColumns.first { $0.identifier.rawValue == "date" }?.title = LocalizationManager.shared.text("date")
        applySearch()
    }

    // MARK: - Filtering

    private func applySearch() {
        let engine = SearchEngine(mode: searchMode, query: searchField.stringValue)
        filteredEntries = store.entries.filter { entry in
            let matchesGroup: Bool
            switch currentGroupFilter {
            case .all: matchesGroup = true
            case .favorites: matchesGroup = entry.favorite
            case .ungrouped: matchesGroup = entry.groupId == nil
            case .group(let id): matchesGroup = entry.groupId == id
            }

            let matchesType: Bool
            switch currentTypeFilter {
            case .all: matchesType = true
            case .text: matchesType = entry.isText
            case .images: matchesType = entry.isImage
            case .files: matchesType = entry.isFileDrop
            case .richText: matchesType = entry.isRichText
            case .html: matchesType = entry.isHTML
            }

            let matchesSearch = engine.matches(entry) { [weak self] entry in
                self?.fullText(for: entry) ?? entry.text ?? ""
            }

            return matchesGroup && matchesType && matchesSearch
        }
        tableView.reloadData()
        countLabel.stringValue = "\(filteredEntries.count) / \(store.entries.count)"
    }

    private func fullText(for entry: ClipboardEntry) -> String? {
        if let key = entry.rtfBlobKey, let data = store.blobData(named: key),
           let text = RTFTextExtractor.string(from: data) {
            return text
        }
        if let key = entry.htmlBlobKey, let data = store.blobData(named: key) {
            return HTMLTextExtractor.string(from: data)
        }
        return nil
    }

    // MARK: - Table view

    func numberOfRows(in tableView: NSTableView) -> Int { filteredEntries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < filteredEntries.count else { return nil }
        let entry = filteredEntries[row]
        let identifier = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("clip")

        if identifier.rawValue == "type" {
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
            configureLabelCell(cell, text: entry.typeLabel)
            return cell
        }

        if identifier.rawValue == "date" {
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
            configureLabelCell(cell, text: dateFormatter.string(from: entry.createdAt))
            return cell
        }

        // Main clip cell — preview text + optional thumbnail / color swatch.
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? ClipTableCellView ?? ClipTableCellView()
        cell.identifier = identifier
        let theme = DittoTheme.current
        cell.configure(entry: entry, store: store, drawThumbnails: DittoSettings.drawThumbnails, theme: theme)
        cell.setIndex(row, enabled: DittoSettings.showFirstTenText)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowHeight row: Int) -> CGFloat {
        DittoSettings.drawThumbnails && filteredEntries[safe: row]?.isImage == true ? 56 : 28
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updatePreview()
    }

    private func configureLabelCell(_ cell: NSTableCellView, text: String) {
        let label = cell.textField ?? NSTextField(labelWithString: "")
        label.stringValue = text
        label.font = NSFont.systemFont(ofSize: CGFloat(DittoSettings.fontSize))
        label.textColor = DittoTheme.current.listBoxText
        label.lineBreakMode = .byTruncatingTail
        if cell.textField == nil {
            cell.textField = label
            cell.addSubview(label)
            label.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
    }

    // MARK: - Selection helpers

    var selectedEntries: [ClipboardEntry] {
        tableView.selectedRowIndexes.compactMap { filteredEntries[safe: $0] }
    }

    private var currentEntry: ClipboardEntry? {
        let row = tableView.selectedRow
        guard row >= 0, row < filteredEntries.count else { return nil }
        return filteredEntries[row]
    }

    // MARK: - Actions

    @objc private func searchChanged() { applySearch() }

    @objc private func modeChanged() {
        if let mode = SearchMode.allCases[safe: modePopup.indexOfSelectedItem] {
            searchMode = mode
            DittoSettings.regexSearch = mode == .regex
        }
        applySearch()
    }

    @objc private func typeFilterChanged() {
        switch typeFilterPopup.indexOfSelectedItem {
        case 1: currentTypeFilter = .text
        case 2: currentTypeFilter = .images
        case 3: currentTypeFilter = .files
        case 4: currentTypeFilter = .richText
        case 5: currentTypeFilter = .html
        default: currentTypeFilter = .all
        }
        applySearch()
    }

    @objc private func groupFilterChanged() {
        switch groupFilterPopup.indexOfSelectedItem {
        case 0: currentGroupFilter = .all
        case 1: currentGroupFilter = .favorites
        case 2: currentGroupFilter = .ungrouped
        default:
            let groups = store.groups
            let index = groupFilterPopup.indexOfSelectedItem - 3
            if let group = groups[safe: index] {
                currentGroupFilter = .group(group.id)
            } else {
                currentGroupFilter = .all
            }
        }
        applySearch()
    }

    @objc private func copySelectedEntry() {
        guard let entry = currentEntry else { return }
        store.copyToPasteboard(entry)
    }

    @objc private func pasteSelectedEntry() {
        guard let entry = currentEntry else { return }
        store.copyToPasteboard(entry)
        store.markPasted(entry)
        pasteHandler()
    }

    @objc private func pasteSpecial(_ sender: NSMenuItem) {
        guard let entry = currentEntry, let box = sender.representedObject as? SpecialPasteOptionsBox else { return }
        store.copyToPasteboard(entry, options: box.options)
        store.markPasted(entry)
        pasteHandler()
    }

    @objc private func pasteSpecialNoPaste(_ sender: NSMenuItem) {
        guard let entry = currentEntry, let box = sender.representedObject as? SpecialPasteOptionsBox else { return }
        store.copyToPasteboard(entry, options: box.options)
    }

    @objc private func deleteSelectedEntry() {
        let entries = selectedEntries
        guard entries.isEmpty == false else { return }
        if DittoSettings.promptWhenDeleting, entries.count > 0 {
            let alert = NSAlert()
            alert.messageText = LocalizationManager.shared.text("confirm_delete")
            alert.addButton(withTitle: LocalizationManager.shared.text("delete"))
            alert.addButton(withTitle: LocalizationManager.shared.text("cancel"))
            if alert.runModal() != .alertFirstButtonReturn { return }
        }
        for entry in entries { store.removeEntry(id: entry.id) }
        refresh()
    }

    @objc private func toggleFavoriteSelectedEntry() {
        guard let entry = currentEntry else { return }
        store.toggleFavorite(id: entry.id)
        refresh()
    }

    @objc private func toggleNeverAutoDeleteSelectedEntry() {
        guard let entry = currentEntry else { return }
        store.toggleNeverAutoDelete(id: entry.id)
        refresh()
    }

    @objc private func moveToTopSelectedEntry() {
        guard let entry = currentEntry else { return }
        store.moveClip(id: entry.id, direction: .top)
        refresh()
    }

    @objc private func moveUpSelectedEntry() {
        guard let entry = currentEntry else { return }
        store.moveClip(id: entry.id, direction: .up)
        refresh()
    }

    @objc private func moveDownSelectedEntry() {
        guard let entry = currentEntry else { return }
        store.moveClip(id: entry.id, direction: .down)
        refresh()
    }

    @objc private func moveLastSelectedEntry() {
        guard let entry = currentEntry else { return }
        store.moveClip(id: entry.id, direction: .last)
        refresh()
    }

    @objc private func setGroupForSelectedEntry(_ sender: NSMenuItem) {
        guard let entry = currentEntry else { return }
        if let groupId = sender.representedObject as? NSNumber {
            store.setGroup(id: entry.id, groupId: groupId.int64Value)
        } else if sender.tag == -1 {
            store.setGroup(id: entry.id, groupId: nil)
        }
        rebuildGroupFilterPopup()
        refresh()
    }

    @objc private func setGroupPrompt() {
        guard let entry = currentEntry else { return }
        let alert = NSAlert()
        alert.messageText = LocalizationManager.shared.text("set_group")
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: LocalizationManager.shared.text("cancel"))
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        input.stringValue = store.groupName(for: entry.groupId) ?? ""
        alert.accessoryView = input
        if alert.runModal() == .alertFirstButtonReturn {
            let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty {
                store.setGroup(id: entry.id, groupId: nil)
            } else {
                let existing = store.groups.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
                if let existing {
                    store.setGroup(id: entry.id, groupId: existing.id)
                } else {
                    store.addGroup(name: name)
                    if let created = store.groups.first(where: { $0.name == name }) {
                        store.setGroup(id: entry.id, groupId: created.id)
                    }
                }
            }
            rebuildGroupFilterPopup()
            refresh()
        }
    }

    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = LocalizationManager.shared.text("confirm_clear")
        alert.addButton(withTitle: LocalizationManager.shared.text("clear"))
        alert.addButton(withTitle: LocalizationManager.shared.text("cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            store.removeAll()
            refresh()
        }
    }

    @objc private func showProperties() {
        guard let entry = currentEntry else { return }
        delegate?.showProperties(for: entry)
    }

    @objc private func showEditor() {
        guard let entry = currentEntry else { return }
        delegate?.showEditor(for: entry)
    }

    @objc private func showQRCode() {
        guard let entry = currentEntry else { return }
        delegate?.showQRCode(for: entry)
    }

    @objc private func showImageViewer() {
        guard let entry = currentEntry, entry.isImage else { return }
        delegate?.showImageViewer(for: entry)
    }

    @objc private func exportAsText() {
        guard let entry = currentEntry else { return }
        delegate?.exportEntryAsText(entry)
    }

    @objc private func exportAsImage() {
        guard let entry = currentEntry else { return }
        delegate?.exportEntryAsImage(entry)
    }

    @objc private func webSearch() {
        guard let entry = currentEntry else { return }
        delegate?.webSearchEntry(entry)
    }

    @objc private func translate() {
        guard let entry = currentEntry else { return }
        delegate?.translateEntry(entry)
    }

    @objc private func emailClip() {
        guard let entry = currentEntry else { return }
        delegate?.emailEntry(entry)
    }

    @objc private func sendToFriend() {
        guard let entry = currentEntry else { return }
        delegate?.sendEntryToFriend(entry)
    }

    @objc private func compareSelected() {
        let entries = selectedEntries
        guard entries.count >= 2 else { return }
        delegate?.compareEntries(entries)
    }

    @objc private func pasteMultiImages(_ sender: NSMenuItem) {
        let horizontal = sender.tag == 1
        let images = selectedEntries.compactMap { entry -> NSImage? in
            guard let key = entry.imageBlobKey, let data = store.blobData(named: key) else { return nil }
            return NSImage(data: data)
        }
        guard images.count >= 2, let combined = ImageCompositor.combine(images: images, horizontal: horizontal) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(NSImage.pngData(combined), forType: .png)
        for entry in selectedEntries { store.markPasted(entry) }
        pasteHandler()
    }

    @objc private func copyToBuffer(_ sender: NSMenuItem) {
        guard let entry = currentEntry, let slot = sender.representedObject as? NSNumber else { return }
        delegate?.copyEntryToBuffer(entry, slot: slot.intValue)
    }

    @objc private func newClip() {
        let entry = store.createNewClip()
        delegate?.showEditor(for: entry)
        refresh()
    }

    // MARK: - Context menu

    func tableView(_ tableView: NSTableView, menuForTableColumn column: NSTableColumn?, row: Int) -> NSMenu? {
        guard filteredEntries.indices.contains(row) else { return nil }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        return buildContextMenu()
    }

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()

        let pasteItem = NSMenuItem(title: LocalizationManager.shared.text("paste"), action: #selector(pasteSelectedEntry), keyEquivalent: "")
        pasteItem.target = self
        menu.addItem(pasteItem)

        let copyItem = NSMenuItem(title: LocalizationManager.shared.text("copy"), action: #selector(copySelectedEntry), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)

        let specialPasteItem = NSMenuItem(title: LocalizationManager.shared.text("special_paste"), action: nil, keyEquivalent: "")
        specialPasteItem.submenu = buildSpecialPasteSubmenu()
        menu.addItem(specialPasteItem)

        menu.addItem(.separator())

        let propertiesItem = NSMenuItem(title: LocalizationManager.shared.text("clip_properties"), action: #selector(showProperties), keyEquivalent: "")
        propertiesItem.target = self
        menu.addItem(propertiesItem)

        let editItem = NSMenuItem(title: LocalizationManager.shared.text("edit_clip"), action: #selector(showEditor), keyEquivalent: "")
        editItem.target = self
        menu.addItem(editItem)

        if currentEntry?.isImage == true {
            let imageItem = NSMenuItem(title: LocalizationManager.shared.text("type") + ": " + (currentEntry?.typeLabel ?? ""), action: #selector(showImageViewer), keyEquivalent: "")
            imageItem.target = self
            menu.addItem(imageItem)
        }

        menu.addItem(.separator())

        let groupItem = NSMenuItem(title: LocalizationManager.shared.text("group"), action: nil, keyEquivalent: "")
        groupItem.submenu = buildGroupSubmenu()
        menu.addItem(groupItem)

        let bufferItem = NSMenuItem(title: LocalizationManager.shared.text("copy_buffers"), action: nil, keyEquivalent: "")
        bufferItem.submenu = buildBufferSubmenu()
        menu.addItem(bufferItem)

        let pinItem = NSMenuItem(title: LocalizationManager.shared.text("never_auto_delete"), action: #selector(toggleNeverAutoDeleteSelectedEntry), keyEquivalent: "")
        pinItem.target = self
        pinItem.state = (currentEntry?.isPinned == true) ? .on : .off
        menu.addItem(pinItem)

        let favItem = NSMenuItem(title: LocalizationManager.shared.text("favorite"), action: #selector(toggleFavoriteSelectedEntry), keyEquivalent: "")
        favItem.target = self
        favItem.state = (currentEntry?.favorite == true) ? .on : .off
        menu.addItem(favItem)

        let topItem = NSMenuItem(title: LocalizationManager.shared.text("move_top"), action: #selector(moveToTopSelectedEntry), keyEquivalent: "")
        topItem.target = self
        menu.addItem(topItem)

        let moveSubmenuItem = NSMenuItem(title: "…", action: nil, keyEquivalent: "")
        let moveSubmenu = NSMenu()
        let upItem = NSMenuItem(title: LocalizationManager.shared.text("move_up"), action: #selector(moveUpSelectedEntry), keyEquivalent: "")
        upItem.target = self
        let downItem = NSMenuItem(title: LocalizationManager.shared.text("move_down"), action: #selector(moveDownSelectedEntry), keyEquivalent: "")
        downItem.target = self
        let lastItem = NSMenuItem(title: LocalizationManager.shared.text("move_last"), action: #selector(moveLastSelectedEntry), keyEquivalent: "")
        lastItem.target = self
        moveSubmenu.addItem(upItem)
        moveSubmenu.addItem(downItem)
        moveSubmenu.addItem(lastItem)
        moveSubmenuItem.submenu = moveSubmenu
        moveSubmenuItem.title = LocalizationManager.shared.text("move_top").components(separatedBy: " to ").first ?? "Move"
        menu.addItem(moveSubmenuItem)

        menu.addItem(.separator())

        // View submenu: always-on-top, transparency, description pane.
        let viewSubmenuItem = NSMenuItem(title: LocalizationManager.shared.text("appearance"), action: nil, keyEquivalent: "")
        let viewSubmenu = NSMenu()
        let onTopItem = NSMenuItem(title: LocalizationManager.shared.text("always_on_top"), action: #selector(toggleAlwaysOnTop), keyEquivalent: "")
        onTopItem.target = self
        onTopItem.state = DittoSettings.alwaysOnTop ? .on : .off
        viewSubmenu.addItem(onTopItem)
        let transItem = NSMenuItem(title: LocalizationManager.shared.text("transparency"), action: #selector(toggleTransparency), keyEquivalent: "")
        transItem.target = self
        transItem.state = DittoSettings.transparencyPercent > 0 ? .on : .off
        viewSubmenu.addItem(transItem)
        let transUpItem = NSMenuItem(title: LocalizationManager.shared.text("transparency") + " +", action: #selector(increaseTransparency), keyEquivalent: "")
        transUpItem.target = self
        viewSubmenu.addItem(transUpItem)
        let transDownItem = NSMenuItem(title: LocalizationManager.shared.text("transparency") + " −", action: #selector(decreaseTransparency), keyEquivalent: "")
        transDownItem.target = self
        viewSubmenu.addItem(transDownItem)
        viewSubmenu.addItem(.separator())
        let descItem = NSMenuItem(title: LocalizationManager.shared.text("description_pane"), action: #selector(toggleDescription), keyEquivalent: "")
        descItem.target = self
        descItem.state = descriptionVisible ? .on : .off
        viewSubmenu.addItem(descItem)
        viewSubmenuItem.submenu = viewSubmenu
        menu.addItem(viewSubmenuItem)

        let qrItem = NSMenuItem(title: LocalizationManager.shared.text("qr_code"), action: #selector(showQRCode), keyEquivalent: "")
        qrItem.target = self
        menu.addItem(qrItem)

        let exportTextItem = NSMenuItem(title: LocalizationManager.shared.text("export_text_file"), action: #selector(exportAsText), keyEquivalent: "")
        exportTextItem.target = self
        menu.addItem(exportTextItem)

        let exportImageItem = NSMenuItem(title: LocalizationManager.shared.text("export_image_file"), action: #selector(exportAsImage), keyEquivalent: "")
        exportImageItem.target = self
        menu.addItem(exportImageItem)

        let searchItem = NSMenuItem(title: LocalizationManager.shared.text("web_search"), action: #selector(webSearch), keyEquivalent: "")
        searchItem.target = self
        menu.addItem(searchItem)

        let translateItem = NSMenuItem(title: LocalizationManager.shared.text("translate"), action: #selector(translate), keyEquivalent: "")
        translateItem.target = self
        menu.addItem(translateItem)

        let emailItem = NSMenuItem(title: LocalizationManager.shared.text("email_clip"), action: #selector(emailClip), keyEquivalent: "")
        emailItem.target = self
        menu.addItem(emailItem)

        let friendItem = NSMenuItem(title: LocalizationManager.shared.text("send_to_friend"), action: #selector(sendToFriend), keyEquivalent: "")
        friendItem.target = self
        menu.addItem(friendItem)

        if selectedEntries.count >= 2 {
            menu.addItem(.separator())
            let compareItem = NSMenuItem(title: LocalizationManager.shared.text("compare_clips"), action: #selector(compareSelected), keyEquivalent: "")
            compareItem.target = self
            menu.addItem(compareItem)

            let imageEntries = selectedEntries.filter { $0.isImage }
            if imageEntries.count >= 2 {
                let hItem = NSMenuItem(title: LocalizationManager.shared.text("multi_paste") + " (→)", action: #selector(pasteMultiImages(_:)), keyEquivalent: "")
                hItem.target = self
                hItem.tag = 1
                menu.addItem(hItem)
                let vItem = NSMenuItem(title: LocalizationManager.shared.text("multi_paste") + " (↓)", action: #selector(pasteMultiImages(_:)), keyEquivalent: "")
                vItem.target = self
                vItem.tag = 0
                menu.addItem(vItem)
            }
        }

        menu.addItem(.separator())

        let deleteItem = NSMenuItem(title: LocalizationManager.shared.text("delete"), action: #selector(deleteSelectedEntry), keyEquivalent: "")
        deleteItem.target = self
        menu.addItem(deleteItem)

        return menu
    }

    private func buildSpecialPasteSubmenu() -> NSMenu {
        let submenu = NSMenu()
        let items: [(String, WritableKeyPath<SpecialPasteOptions, Bool>)] = [
            (LocalizationManager.shared.text("paste_as_plain_text"), \SpecialPasteOptions.pasteAsPlainText),
            (LocalizationManager.shared.text("uppercase"), \SpecialPasteOptions.upperCase),
            (LocalizationManager.shared.text("lowercase"), \SpecialPasteOptions.lowerCase),
            (LocalizationManager.shared.text("capitalize"), \SpecialPasteOptions.capitalize),
            (LocalizationManager.shared.text("sentence_case"), \SpecialPasteOptions.sentenceCase),
            (LocalizationManager.shared.text("camel_case"), \SpecialPasteOptions.camelCase),
            (LocalizationManager.shared.text("invert_case"), \SpecialPasteOptions.invertCase),
            (LocalizationManager.shared.text("remove_line_feeds"), \SpecialPasteOptions.removeLineFeeds),
            (LocalizationManager.shared.text("add_one_line_feed"), \SpecialPasteOptions.addOneLineFeed),
            (LocalizationManager.shared.text("add_two_line_feeds"), \SpecialPasteOptions.addTwoLineFeeds),
            (LocalizationManager.shared.text("typoglycemia"), \SpecialPasteOptions.typoglycemia),
            (LocalizationManager.shared.text("trim_whitespace"), \SpecialPasteOptions.trimWhiteSpace),
            (LocalizationManager.shared.text("posixify_paths"), \SpecialPasteOptions.posixifyPaths),
            (LocalizationManager.shared.text("ascii_only"), \SpecialPasteOptions.asciiOnly),
            (LocalizationManager.shared.text("slugify"), \SpecialPasteOptions.slugify),
            (LocalizationManager.shared.text("append_date_time"), \SpecialPasteOptions.appendDateTime),
            (LocalizationManager.shared.text("generate_guid"), \SpecialPasteOptions.generateGuid)
        ]
        for (title, keyPath) in items {
            var options = SpecialPasteOptions()
            options[keyPath: keyPath] = true
            let item = NSMenuItem(title: title, action: #selector(pasteSpecial(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = SpecialPasteOptionsBox(options: options)
            submenu.addItem(item)
        }
        return submenu
    }

    private func buildGroupSubmenu() -> NSMenu {
        let submenu = NSMenu()
        let none = NSMenuItem(title: LocalizationManager.shared.text("ungrouped"), action: #selector(setGroupForSelectedEntry(_:)), keyEquivalent: "")
        none.target = self
        none.tag = -1
        submenu.addItem(none)
        submenu.addItem(.separator())
        for group in store.groups {
            let item = NSMenuItem(title: group.name, action: #selector(setGroupForSelectedEntry(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: group.id)
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let other = NSMenuItem(title: LocalizationManager.shared.text("set_group"), action: #selector(setGroupPrompt), keyEquivalent: "")
        other.target = self
        submenu.addItem(other)
        return submenu
    }

    private func buildBufferSubmenu() -> NSMenu {
        let submenu = NSMenu()
        for slot in 1...CopyBufferManager.slotCount {
            let title = LocalizationManager.shared.text("copy_buffer_slot") + " \(slot)"
            let item = NSMenuItem(title: title, action: #selector(copyToBuffer(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: slot)
            submenu.addItem(item)
        }
        return submenu
    }

    // MARK: - Keyboard

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard window?.isKeyWindow == true else { return event }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Cmd+1..0 → paste the Nth visible clip.
        if modifiers == .command, let scalar = event.charactersIgnoringModifiers?.lowercased().unicodeScalars.first, scalar.isASCII {
            let digit = scalar.value
            if digit >= 0x30 && digit <= 0x39 {
                let index = digit == 0x30 ? 9 : Int(digit - 0x31)
                if let entry = filteredEntries[safe: index] {
                    store.copyToPasteboard(entry)
                    store.markPasted(entry)
                    pasteHandler()
                    return nil
                }
            }
        }

        if modifiers == .command, let char = event.charactersIgnoringModifiers?.lowercased() {
            switch char {
            case "f": searchField.becomeFirstResponder(); return nil
            case "c": copySelectedEntry(); return nil
            case "v": pasteSelectedEntry(); return nil
            default: break
            }
        }

        // F3 toggles the description/preview pane (matches Windows default).
        if Int(event.keyCode) == kVK_F3 {
            toggleDescription()
            return nil
        }

        // Ctrl/Control + Up/Down/Home/End move the clip in the list.
        if modifiers == .control {
            switch Int(event.keyCode) {
            case kVK_UpArrow: moveUpSelectedEntry(); return nil
            case kVK_DownArrow: moveDownSelectedEntry(); return nil
            case kVK_Home: moveToTopSelectedEntry(); return nil
            case kVK_End: moveLastSelectedEntry(); return nil
            default: break
            }
        }

        if window?.firstResponder is NSTextView, searchField.currentEditor() != nil {
            if Int(event.keyCode) == kVK_Escape {
                window?.makeFirstResponder(tableView)
                return nil
            }
            return event
        }

        switch Int(event.keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter:
            pasteSelectedEntry()
            return nil
        case kVK_Delete:
            if modifiers == .option || modifiers == (.command) {
                deleteSelectedEntry()
                return nil
            }
            return event
        case kVK_ForwardDelete:
            deleteSelectedEntry()
            return nil
        case kVK_Escape:
            window?.orderOut(nil)
            return nil
        default:
            return event
        }
    }

    // MARK: - Layout

    private func configureContent() {
        guard let window else { return }

        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.backgroundColor = DittoTheme.current.listBoxOddRowBackground

        searchField.placeholderString = LocalizationManager.shared.text("search")
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.translatesAutoresizingMaskIntoConstraints = false

        modePopup.target = self
        modePopup.action = #selector(modeChanged)
        modePopup.translatesAutoresizingMaskIntoConstraints = false
        rebuildModePopup()

        typeFilterPopup.target = self
        typeFilterPopup.action = #selector(typeFilterChanged)
        typeFilterPopup.translatesAutoresizingMaskIntoConstraints = false
        rebuildTypeFilterPopup()

        groupFilterPopup.target = self
        groupFilterPopup.action = #selector(groupFilterChanged)
        groupFilterPopup.translatesAutoresizingMaskIntoConstraints = false
        rebuildGroupFilterPopup()

        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = DittoTheme.current.listBoxOddRowBackground
        tableView.rowHeight = 28
        tableView.headerView = nil
        tableView.allowsMultipleSelection = true
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(pasteSelectedEntry)
        tableView.menu = nil // built per-row via delegate

        let clipColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("clip"))
        clipColumn.title = LocalizationManager.shared.text("clip")
        clipColumn.width = 460
        clipColumn.resizingMask = .autoresizingMask
        tableView.addTableColumn(clipColumn)

        let typeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("type"))
        typeColumn.title = LocalizationManager.shared.text("type")
        typeColumn.width = 70
        tableView.addTableColumn(typeColumn)

        let dateColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("date"))
        dateColumn.title = LocalizationManager.shared.text("date")
        dateColumn.width = 130
        tableView.addTableColumn(dateColumn)

        scrollView.documentView = tableView

        previewPanel.isEditable = false
        previewPanel.drawsBackground = false
        previewPanel.font = NSFont.systemFont(ofSize: CGFloat(DittoSettings.fontSize))
        previewPanel.textContainerInset = NSSize(width: 8, height: 6)
        previewScroll.documentView = previewPanel
        previewScroll.hasVerticalScroller = true
        previewScroll.translatesAutoresizingMaskIntoConstraints = false
        previewScroll.wantsLayer = true
        previewScroll.layer?.backgroundColor = DittoTheme.current.listBoxEvenRowBackground.cgColor

        countLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = DittoTheme.current.captionText
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        let toolbar = makeToolbar()

        let root = NSView()
        root.addSubview(searchField)
        root.addSubview(modePopup)
        root.addSubview(typeFilterPopup)
        root.addSubview(groupFilterPopup)
        root.addSubview(scrollView)
        root.addSubview(previewScroll)
        root.addSubview(toolbar)
        root.addSubview(countLabel)
        window.contentView = root

        let previewHeight = previewScroll.heightAnchor.constraint(equalToConstant: 0)
        previewHeight.priority = .required
        previewHeightConstraint = previewHeight

        let scrollViewBottom = scrollView.bottomAnchor.constraint(equalTo: previewScroll.topAnchor, constant: descriptionVisible ? -4 : 0)
        scrollViewBottomToPreviewConstraint = scrollViewBottom

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            searchField.widthAnchor.constraint(equalToConstant: 220),

            modePopup.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            modePopup.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: 8),
            modePopup.widthAnchor.constraint(equalToConstant: 110),

            typeFilterPopup.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            typeFilterPopup.leadingAnchor.constraint(equalTo: modePopup.trailingAnchor, constant: 8),
            typeFilterPopup.widthAnchor.constraint(equalToConstant: 130),

            groupFilterPopup.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            groupFilterPopup.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            groupFilterPopup.widthAnchor.constraint(equalToConstant: 170),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollViewBottom,

            previewScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            previewScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            previewScroll.bottomAnchor.constraint(equalTo: toolbar.topAnchor, constant: -10),
            previewHeight,

            countLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            countLabel.bottomAnchor.constraint(equalTo: scrollView.topAnchor, constant: -2),

            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            toolbar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)
        ])
    }

    // MARK: - Window chrome (always-on-top, transparency, positioning)

    private func applyWindowChrome() {
        guard let window else { return }
        window.level = DittoSettings.alwaysOnTop ? .floating : .normal
        window.alphaValue = CGFloat(1.0 - DittoSettings.transparencyPercent / 100.0)
    }

    @objc private func toggleAlwaysOnTop() {
        DittoSettings.alwaysOnTop.toggle()
        applyWindowChrome()
    }

    @objc private func toggleTransparency() {
        if DittoSettings.transparencyPercent > 0 {
            DittoSettings.transparencyPercent = 0
        } else {
            DittoSettings.transparencyPercent = 14
        }
        applyWindowChrome()
    }

    @objc private func increaseTransparency() {
        DittoSettings.transparencyPercent = min(40, DittoSettings.transparencyPercent + 5)
        applyWindowChrome()
    }

    @objc private func decreaseTransparency() {
        DittoSettings.transparencyPercent = max(0, DittoSettings.transparencyPercent - 5)
        applyWindowChrome()
    }

    @objc private func toggleDescription() {
        descriptionVisible.toggle()
        previewHeightConstraint?.constant = descriptionVisible ? 160 : 0
        scrollViewBottomToPreviewConstraint?.constant = descriptionVisible ? -4 : 0
        updatePreview()
    }

    private func updatePreview() {
        guard descriptionVisible else { return }
        let entry = currentEntry
        if let imageBlobKey = entry?.imageBlobKey, let data = store.blobData(named: imageBlobKey) {
            previewPanel.string = "[\(entry?.typeLabel ?? "Image")] \(data.count) bytes"
        } else {
            previewPanel.string = entry?.text ?? store.fullText(for: entry ?? ClipboardEntry()) ?? ""
        }
    }

    private func makeToolbar() -> NSView {
        let buttons: [(String, Selector, String)] = [
            (LocalizationManager.shared.text("copy"), #selector(copySelectedEntry), "doc.on.doc"),
            (LocalizationManager.shared.text("paste"), #selector(pasteSelectedEntry), "arrow.down.doc"),
            (LocalizationManager.shared.text("favorite"), #selector(toggleFavoriteSelectedEntry), "star"),
            (LocalizationManager.shared.text("properties"), #selector(showProperties), "info.circle"),
            (LocalizationManager.shared.text("edit_clip"), #selector(showEditor), "square.and.pencil"),
            (LocalizationManager.shared.text("qr_code"), #selector(showQRCode), "qrcode"),
            (LocalizationManager.shared.text("delete"), #selector(deleteSelectedEntry), "trash"),
            (LocalizationManager.shared.text("clear"), #selector(clearHistory), "trash.circle")
        ]
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (title, action, symbol) in buttons {
            let button: NSButton
            if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
                button = NSButton(image: image, target: self, action: action)
                button.bezelStyle = .smallSquare
            } else {
                button = NSButton(title: title, target: self, action: action)
                button.bezelStyle = .rounded
            }
            button.toolTip = title
            stack.addArrangedSubview(button)
        }
        return stack
    }

    private func rebuildModePopup() {
        let selected = searchMode
        modePopup.removeAllItems()
        for mode in SearchMode.allCases {
            modePopup.addItem(withTitle: mode.title)
        }
        if let index = SearchMode.allCases.firstIndex(of: selected) {
            modePopup.selectItem(at: index)
        }
    }

    private func rebuildTypeFilterPopup() {
        let selected = currentTypeFilter
        typeFilterPopup.removeAllItems()
        typeFilterPopup.addItem(withTitle: LocalizationManager.shared.text("all_types"))
        typeFilterPopup.addItem(withTitle: LocalizationManager.shared.text("text_clips"))
        typeFilterPopup.addItem(withTitle: LocalizationManager.shared.text("image_clips"))
        typeFilterPopup.addItem(withTitle: LocalizationManager.shared.text("file_clips"))
        typeFilterPopup.addItem(withTitle: LocalizationManager.shared.text("rich_text_clips"))
        typeFilterPopup.addItem(withTitle: LocalizationManager.shared.text("html_clips"))
        switch selected {
        case .all: typeFilterPopup.selectItem(at: 0)
        case .text: typeFilterPopup.selectItem(at: 1)
        case .images: typeFilterPopup.selectItem(at: 2)
        case .files: typeFilterPopup.selectItem(at: 3)
        case .richText: typeFilterPopup.selectItem(at: 4)
        case .html: typeFilterPopup.selectItem(at: 5)
        }
    }

    private func rebuildGroupFilterPopup() {
        let selected = currentGroupFilter
        groupFilterPopup.removeAllItems()
        groupFilterPopup.addItem(withTitle: LocalizationManager.shared.text("all_groups"))
        groupFilterPopup.addItem(withTitle: LocalizationManager.shared.text("favorites"))
        groupFilterPopup.addItem(withTitle: LocalizationManager.shared.text("ungrouped"))
        let groups = store.groups
        for group in groups {
            groupFilterPopup.addItem(withTitle: group.name)
        }
        switch selected {
        case .all: groupFilterPopup.selectItem(at: 0)
        case .favorites: groupFilterPopup.selectItem(at: 1)
        case .ungrouped: groupFilterPopup.selectItem(at: 2)
        case .group(let id):
            if let index = groups.firstIndex(where: { $0.id == id }) {
                groupFilterPopup.selectItem(at: index + 3)
            } else {
                currentGroupFilter = .all
                groupFilterPopup.selectItem(at: 0)
            }
        }
    }

    private func applyTheme() {
        let theme = DittoTheme.current
        window?.appearance = theme.effectiveAppearance
        window?.backgroundColor = theme.mainWindowBackground
        scrollView.backgroundColor = theme.listBoxOddRowBackground
        tableView.backgroundColor = theme.listBoxOddRowBackground
        tableView.reloadData()
    }
}

/// Boxes a `SpecialPasteOptions` so it can ride along on an `NSMenuItem`.
final class SpecialPasteOptionsBox {
    let options: SpecialPasteOptions
    init(options: SpecialPasteOptions) { self.options = options }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
