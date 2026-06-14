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

final class HistoryWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuDelegate {
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
    /// Lets the AppDelegate sync the clipboard monitor after Ditto writes the
    /// pasteboard, so restored content isn't re-captured as a new entry.
    var syncMonitor: (() -> Void)?

    private let searchField = NSSearchField()
    private let modePopup = NSPopUpButton()
    private let typeFilterPopup = NSPopUpButton()
    private let groupFilterPopup = NSPopUpButton()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let countLabel = NSTextField(labelWithString: "")
    private var pinButton: NSButton?
    private let previewPanel = NSTextView()
    private let previewScroll = NSScrollView()
    private var previewHeightConstraint: NSLayoutConstraint?
    private var scrollViewBottomToPreviewConstraint: NSLayoutConstraint?
    private var descriptionVisible = false
    private var filteredEntries: [ClipboardEntry] = []
    private var currentGroupFilter: GroupFilter = .all
    private var currentTypeFilter: TypeFilter = .all
    private var searchMode: SearchMode = DittoSettings.regexSearch ? .regex : .contains
    private var lastSearchQuery = ""
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
        filteredEntries = store.snapshotEntries()
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
        filteredEntries = store.snapshotEntries().filter { entry in
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
        let total = store.snapshotEntries().count
        if total == 0 {
            countLabel.stringValue = LocalizationManager.shared.text("no_clips")
        } else {
            countLabel.stringValue = "\(filteredEntries.count) / \(total)"
        }
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

    // MARK: - Drag OUT (drag a clip to another app)

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row < filteredEntries.count else { return nil }
        let entry = filteredEntries[row]
        let item = NSPasteboardItem()
        if let text = entry.text { item.setString(text, forType: .string) }
        if let imageBlobKey = entry.imageBlobKey, let data = store.blobData(named: imageBlobKey) {
            item.setData(data, forType: .png)
        }
        if let fileURLs = entry.fileURLs, fileURLs.isEmpty == false {
            item.setString(fileURLs.first ?? "", forType: .fileURL)
        }
        return item.string(forType: .string) != nil || item.data(forType: .png) != nil ? item : nil
    }

    // MARK: - Drag IN (drop files/text onto the list)

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        return .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        let pb = info.draggingPasteboard
        // Accept text
        if let text = pb.string(forType: .string), text.isEmpty == false {
            store.addClipboardPayload(text: text, rtfData: nil, htmlData: nil, imageData: nil, fileURLs: [])
            refresh()
            return true
        }
        // Accept images
        if let imageData = ClipboardMonitor.imageData(from: pb) {
            store.addClipboardPayload(text: nil, rtfData: nil, htmlData: nil, imageData: imageData, fileURLs: [])
            refresh()
            return true
        }
        // Accept files
        let fileURLs = ClipboardMonitor.fileURLs(from: pb)
        if fileURLs.isEmpty == false {
            store.addClipboardPayload(text: nil, rtfData: nil, htmlData: nil, imageData: nil, fileURLs: fileURLs)
            refresh()
            return true
        }
        return false
    }

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
        DittoSettings.drawThumbnails && filteredEntries[safe: row]?.isImage == true ? 56 : CGFloat(20 + DittoSettings.linesPerRow * 14)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updatePreview()
        // Re-validate toolbar buttons (enabled/disabled by selection).
        NSApp.sendAction(#selector(NSUserInterfaceValidations.validateUserInterfaceItem(_:)), to: nil, from: nil)
    }

    // MARK: - UI validation (disable actions when nothing is selected)

    private let selectionRequiredSelectors: Set<Selector> = [
        #selector(copySelectedEntry), #selector(pasteSelectedEntry), #selector(deleteSelectedEntry),
        #selector(toggleFavoriteSelectedEntry), #selector(toggleNeverAutoDeleteSelectedEntry),
        #selector(moveToTopSelectedEntry), #selector(moveUpSelectedEntry), #selector(moveDownSelectedEntry),
        #selector(moveLastSelectedEntry), #selector(showProperties), #selector(showEditor),
        #selector(showQRCode), #selector(showImageViewer), #selector(exportAsText), #selector(exportAsImage),
        #selector(webSearch), #selector(translate), #selector(emailClip), #selector(sendToFriend),
        #selector(shareEntry)
    ]

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if let action = item.action, selectionRequiredSelectors.contains(action) {
            return currentEntry != nil
        }
        return true
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

    @objc private func searchChanged() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty == false {
            lastSearchQuery = query
        }
        applySearch()
    }

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
            let groups = store.hierarchicalGroups().map(\.group)
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
        // Advance the monitor past this write so Ditto doesn't re-capture the
        // clip it just placed (same fix as the paste paths).
        syncMonitor?()
    }

    @objc private func pasteSelectedEntry() {
        guard let entry = currentEntry else { return }
        let snapshot = DittoSettings.restoreClipboardAfterPaste ? ClipboardSaveRestore.snapshot() : nil
        // Honor the "paste as plain text by default" preference.
        var options = SpecialPasteOptions()
        options.pasteAsPlainText = DittoSettings.pasteAsPlainTextByDefault
        store.copyToPasteboard(entry, options: options)
        syncMonitor?()
        store.markPasted(entry)
        pasteHandler()
        if let snapshot { ClipboardSaveRestore.restore(snapshot) { [weak self] in self?.syncMonitor?() } }
        if DittoSettings.refreshAfterPaste {
            refresh()
        }
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
        syncMonitor?()
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

    @objc private func pinToTopSelectedEntry() {
        guard let entry = currentEntry else { return }
        store.toggleNeverAutoDelete(id: entry.id) // pin
        store.moveClip(id: entry.id, direction: .top)
        refresh()
    }

    @objc private func unpinSelectedEntry() {
        guard let entry = currentEntry else { return }
        store.toggleNeverAutoDelete(id: entry.id) // unpin
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
        alert.addButton(withTitle: LocalizationManager.shared.text("ok"))
        alert.addButton(withTitle: LocalizationManager.shared.text("cancel"))
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        input.stringValue = store.groupName(for: entry.groupId) ?? ""
        alert.accessoryView = input
        if alert.runModal() == .alertFirstButtonReturn {
            let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty {
                store.setGroup(id: entry.id, groupId: nil)
            } else {
                let existing = store.snapshotGroups().first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
                if let existing {
                    store.setGroup(id: entry.id, groupId: existing.id)
                } else {
                    store.addGroup(name: name)
                    if let created = store.snapshotGroups().first(where: { $0.name == name }) {
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

    @objc private func sendToSpecificFriend(_ sender: NSMenuItem) {
        guard let entry = currentEntry else { return }
        // Friend ID is stored in representedObject; the delegate handles the send.
        delegate?.sendEntryToFriend(entry)
    }

    @objc private func shareEntry() {
        guard let entry = currentEntry else { return }
        var items: [Any] = []
        // For images, share the NSImage (enables AirDrop, Messages, etc.)
        if let imageBlobKey = entry.imageBlobKey, let data = store.blobData(named: imageBlobKey), let image = NSImage(data: data) {
            items.append(image)
        } else if let text = entry.text {
            items.append(text)
        }
        if let fileURLs = entry.fileURLs {
            items.append(contentsOf: fileURLs.map { URL(fileURLWithPath: $0) })
        }
        guard items.isEmpty == false else { return }
        let picker = NSSharingServicePicker(items: items)
        if let rowView = tableView.rowView(atRow: tableView.selectedRow, makeIfNecessary: false) {
            picker.show(relativeTo: rowView.bounds, of: rowView, preferredEdge: .minY)
        } else {
            picker.show(relativeTo: tableView.bounds, of: tableView, preferredEdge: .minY)
        }
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

    /// NSTableView has no per-row menu delegate; the right pattern is to give
    /// the table a menu whose NSMenuDelegate rebuilds it from `clickedRow`
    /// just before it opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let row = tableView.clickedRow
        if row >= 0, filteredEntries.indices.contains(row) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        menu.items = buildContextMenu().items
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

        // Pin to top (never-delete + highest order) / unpin.
        if currentEntry?.isPinned == true {
            let unpinItem = NSMenuItem(title: LocalizationManager.shared.text("remove_pin"), action: #selector(unpinSelectedEntry), keyEquivalent: "")
            unpinItem.target = self
            menu.addItem(unpinItem)
        } else {
            let pinTopItem = NSMenuItem(title: LocalizationManager.shared.text("pin_to_top"), action: #selector(pinToTopSelectedEntry), keyEquivalent: "")
            pinTopItem.target = self
            menu.addItem(pinTopItem)
        }

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

        // Send to specific friend submenu
        let friends = store.loadFriends()
        if friends.isEmpty == false {
            let sendToSubmenuItem = NSMenuItem(title: LocalizationManager.shared.text("send_to_friend"), action: nil, keyEquivalent: "")
            let sendToSubmenu = NSMenu()
            for friend in friends {
                let item = NSMenuItem(title: friend.name, action: #selector(sendToSpecificFriend(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = friend.id
                sendToSubmenu.addItem(item)
            }
            sendToSubmenuItem.submenu = sendToSubmenu
            menu.addItem(sendToSubmenuItem)
        }

        let shareItem = NSMenuItem(title: LocalizationManager.shared.text("share"), action: #selector(shareEntry), keyEquivalent: "")
        shareItem.target = self
        menu.addItem(shareItem)

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
        for group in store.snapshotGroups() {
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
                } else {
                    NSSound.beep() // out of range — let the user know
                }
                // Always consume the digit so it doesn't fall through to the
                // text-edit / default handlers, even when out of range.
                return nil
            }
        }

        if modifiers == .command, let char = event.charactersIgnoringModifiers?.lowercased() {
            switch char {
            case "f": searchField.becomeFirstResponder(); return nil
            case "c": copySelectedEntry(); return nil
            case "v": pasteSelectedEntry(); return nil
            case "n": newClip(); return nil
            case "e": showEditor(); return nil
            default: break
            }
        }

        // Alt+C cancels/clears the active filter (Windows CANCELFILTER).
        if modifiers == .option, let char = event.charactersIgnoringModifiers?.lowercased(), char == "c" {
            searchField.stringValue = ""
            currentGroupFilter = .all
            currentTypeFilter = .all
            rebuildGroupFilterPopup()
            rebuildTypeFilterPopup()
            applySearch()
            return nil
        }

        // Alt+Enter opens clip properties (Windows CLIP_PROPERTIES).
        if modifiers == .option, Int(event.keyCode) == kVK_Return {
            showProperties()
            return nil
        }

        // F3 toggles the description/preview pane — but only when the table
        // (not a text field) has focus, so it doesn't steal the key from the
        // search box.
        if Int(event.keyCode) == kVK_F3, window?.firstResponder is NSTextView == false {
            toggleDescription()
            return nil
        }

        // Description pane navigation + word-wrap (only when pane is visible
        // and the table has focus).
        if descriptionVisible, window?.firstResponder is NSTextView == false {
            let char = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if char == "n" {
                let next = min(tableView.selectedRow + 1, filteredEntries.count - 1)
                if next > tableView.selectedRow { tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false) }
                return nil
            }
            if char == "p" {
                let prev = max(tableView.selectedRow - 1, 0)
                if prev < tableView.selectedRow { tableView.selectRowIndexes(IndexSet(integer: prev), byExtendingSelection: false) }
                return nil
            }
            if char == "w" {
                previewPanel.textContainer?.widthTracksTextView = !(previewPanel.textContainer?.widthTracksTextView ?? false)
                previewPanel.textContainer?.containerSize = NSSize(
                    width: previewPanel.bounds.width - 16,
                    height: .greatestFiniteMagnitude)
                return nil
            }
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
            // Up arrow recalls the last search (APPLY_LAST_SEARCH).
            if Int(event.keyCode) == kVK_UpArrow, lastSearchQuery.isEmpty == false {
                searchField.stringValue = lastSearchQuery
                applySearch()
                return nil
            }
            // Down/Up arrow (without modifiers) jumps into the list so you can
            // arrow-navigate results without leaving the search box's context.
            if modifiers.isEmpty {
                if Int(event.keyCode) == kVK_DownArrow, filteredEntries.isEmpty == false {
                    window?.makeFirstResponder(tableView)
                    if tableView.selectedRow < 0 { tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
                    return nil
                }
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
        tableView.menu = NSMenu()
        tableView.menu?.delegate = self
        // Enable drag-out (to other apps) and drag-in (files/text onto list).
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        tableView.registerForDraggedTypes([.string, .png, .tiff, .fileURL])

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

    private func applySelectionColors() {
        let theme = DittoTheme.current
        if window?.isKeyWindow == true {
            tableView.selectionHighlightStyle = .regular
        } else {
            tableView.selectionHighlightStyle = .sourceList
        }
        _ = theme.listBoxSelectedNoFocusBackground
    }

    private func applyWindowChrome() {
        guard let window else { return }
        // .floating keeps the window above normal-level windows of all apps;
        // the collection behavior lets it stay visible across spaces/full-screen
        // so it truly "pins" on top. Re-applied on every show because macOS can
        // reset the level after the window is ordered out.
        window.level = DittoSettings.alwaysOnTop ? .floating : .normal
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.alphaValue = CGFloat(1.0 - DittoSettings.transparencyPercent / 100.0)
        // Keep the pin button's state in sync.
        pinButton?.state = DittoSettings.alwaysOnTop ? .on : .off
    }

    /// Called by the AppDelegate right after showing the window, so the
    /// always-on-top / transparency actually apply on each summon.
    func applyOnShow() {
        applyWindowChrome()
        // Position the window. .atCursor places it near the mouse pointer
        // (Ditto's popup-at-cursor behaviour); .previousPosition keeps the last
        // frame the user left it at.
        if DittoSettings.windowPositioning == .atCursor, let window {
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.main?.visibleFrame ?? .zero
            var origin = NSPoint(x: mouse.x + 12, y: mouse.y - window.frame.height / 2)
            // Keep it fully on-screen.
            origin.x = min(max(origin.x, screen.minX), screen.maxX - window.frame.width)
            origin.y = min(max(origin.y, screen.minY), screen.maxY - window.frame.height)
            window.setFrameOrigin(origin)
        }
        // Auto-focus the search box when the window opens, so typing filters
        // immediately (Ditto's default behaviour).
        window?.makeFirstResponder(searchField)
    }

    /// Re-apply always-on-top / transparency after the setting changes
    /// (callable from the AppDelegate's menu-bar toggle).
    func applyWindowChromeFromOutside() {
        applyWindowChrome()
    }

    @objc private func toggleAlwaysOnTop() {
        DittoSettings.alwaysOnTop.toggle()
        // The pin button is the sender; its state is already flipped by the
        // toggle button type — re-apply chrome (which also resyncs state).
        applyWindowChrome()
        // Re-order to front so the level change takes effect immediately.
        window?.makeKeyAndOrderFront(nil)
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
        if let imageBlobKey = entry?.imageBlobKey, let data = store.blobData(named: imageBlobKey),
           let image = NSImage(data: data) {
            // Embed the image as a text attachment so the preview shows the
            // actual picture, not just a byte-count placeholder.
            let attachment = NSTextAttachment()
            attachment.attachmentCell = NSTextAttachmentCell(imageCell: image)
            let attr = NSAttributedString(attachment: attachment)
            previewPanel.textStorage?.setAttributedString(attr)
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

        // Pin / always-on-top toggle — lives ON the window (a thumbtack), not
        // hidden in the menu bar. Toggling it pins the window above all apps.
        let pinTitle = LocalizationManager.shared.text("always_on_top")
        if let image = NSImage(systemSymbolName: "pin", accessibilityDescription: pinTitle) {
            let pin = NSButton(image: image, target: self, action: #selector(toggleAlwaysOnTop))
            pin.bezelStyle = .smallSquare
            pin.setButtonType(.toggle)
            pin.state = DittoSettings.alwaysOnTop ? .on : .off
            pin.toolTip = pinTitle
            pinButton = pin
            stack.addArrangedSubview(pin)
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
        let hierarchy = store.hierarchicalGroups()
        let groups = hierarchy.map(\.group)
        for (group, depth) in hierarchy {
            let indent = String(repeating: "    ", count: depth)
            groupFilterPopup.addItem(withTitle: indent + group.name)
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
