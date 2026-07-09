import AppKit
import Foundation

/// Manages clip groups: create, nest, rename, and delete. Mirrors the Windows
/// `GroupTree` window while exposing the model's parent-child hierarchy.
final class GroupsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let store: ClipboardStore
    private let onChanged: () -> Void
    private let tableView = NSTableView()
    private let nameField = NSTextField()
    private let addButton = NSButton(title: "", target: nil, action: nil)
    private let addSubgroupButton = NSButton(title: "", target: nil, action: nil)
    private let renameButton = NSButton(title: "", target: nil, action: nil)
    private let deleteButton = NSButton(title: "", target: nil, action: nil)

    init(store: ClipboardStore, onChanged: @escaping () -> Void) {
        self.store = store
        self.onChanged = onChanged

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 360),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.applyDittoAppearance()
        window.title = LocalizationManager.shared.text("groups")
        window.center()
        super.init(window: window)
        configureContent()
    }

    required init?(coder: NSCoder) { nil }

    private func configureContent() {
        guard let window else { return }

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        tableView.delegate = self
        tableView.dataSource = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.title = LocalizationManager.shared.text("group")
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.usesAlternatingRowBackgroundColors = true

        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.placeholderString = LocalizationManager.shared.text("group_name")

        addButton.title = LocalizationManager.shared.text("new_group")
        addButton.bezelStyle = .rounded
        addButton.target = self
        addButton.action = #selector(addGroup)
        addButton.translatesAutoresizingMaskIntoConstraints = false

        addSubgroupButton.title = LocalizationManager.shared.text("new_subgroup")
        addSubgroupButton.bezelStyle = .rounded
        addSubgroupButton.target = self
        addSubgroupButton.action = #selector(addSubgroup)
        addSubgroupButton.translatesAutoresizingMaskIntoConstraints = false

        renameButton.title = LocalizationManager.shared.text("edit_clip")
        renameButton.bezelStyle = .rounded
        renameButton.target = self
        renameButton.action = #selector(renameGroup)
        renameButton.translatesAutoresizingMaskIntoConstraints = false

        deleteButton.title = LocalizationManager.shared.text("delete")
        deleteButton.bezelStyle = .rounded
        deleteButton.target = self
        deleteButton.action = #selector(deleteGroup)
        deleteButton.translatesAutoresizingMaskIntoConstraints = false

        let buttonRow = NSStackView(views: [addButton, addSubgroupButton, renameButton, deleteButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(nameField)
        root.addSubview(buttonRow)
        root.addSubview(scrollView)
        window.contentView = root

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: nameField.topAnchor, constant: -12),

            nameField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            nameField.bottomAnchor.constraint(equalTo: buttonRow.topAnchor, constant: -8),

            buttonRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            buttonRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            buttonRow.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)
        ])
        updateButtonState()
    }

    func refresh() {
        tableView.reloadData()
        updateButtonState()
    }

    func refreshText() {
        window?.title = LocalizationManager.shared.text("groups")
        tableView.tableColumns.first?.title = LocalizationManager.shared.text("group")
        nameField.placeholderString = LocalizationManager.shared.text("group_name")
        addButton.title = LocalizationManager.shared.text("new_group")
        addSubgroupButton.title = LocalizationManager.shared.text("new_subgroup")
        renameButton.title = LocalizationManager.shared.text("edit_clip")
        deleteButton.title = LocalizationManager.shared.text("delete")
        refresh()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { store.hierarchicalGroups().count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let item = store.hierarchicalGroups()[safe: row] else { return nil }
        let group = item.group
        let cell = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("name"), owner: self) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = NSUserInterfaceItemIdentifier("name")
        let label = cell.textField ?? NSTextField(labelWithString: "")
        label.stringValue = String(repeating: "    ", count: item.depth) + group.name
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
        return cell
    }

    @objc private func addGroup() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.isEmpty == false else { return }
        store.addGroup(name: name)
        nameField.stringValue = ""
        onChanged()
        refresh()
    }

    @objc private func addSubgroup() {
        let row = tableView.selectedRow
        guard let parent = store.hierarchicalGroups()[safe: row]?.group else { return }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.isEmpty == false else { return }
        store.addGroup(name: name, parentId: parent.id)
        nameField.stringValue = ""
        onChanged()
        refresh()
    }

    @objc private func renameGroup() {
        let row = tableView.selectedRow
        guard let group = store.hierarchicalGroups()[safe: row]?.group else { return }
        let alert = NSAlert()
        alert.messageText = LocalizationManager.shared.text("group_name")
        alert.addButton(withTitle: LocalizationManager.shared.text("ok"))
        alert.addButton(withTitle: LocalizationManager.shared.text("cancel"))
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        input.stringValue = group.name
        alert.accessoryView = input
        if alert.runModal() == .alertFirstButtonReturn {
            store.renameGroup(id: group.id, name: input.stringValue)
            onChanged()
            refresh()
        }
    }

    @objc private func deleteGroup() {
        let row = tableView.selectedRow
        guard let group = store.hierarchicalGroups()[safe: row]?.group else { return }
        store.deleteGroup(id: group.id)
        onChanged()
        refresh()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtonState()
    }

    private func updateButtonState() {
        let hasSelection = tableView.selectedRow >= 0
        addSubgroupButton.isEnabled = hasSelection
        renameButton.isEnabled = hasSelection
        deleteButton.isEnabled = hasSelection
    }
}
