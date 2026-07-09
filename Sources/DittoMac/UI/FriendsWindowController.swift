import AppKit
import Foundation

/// LAN-sync friend management: add/remove peers, toggle send-all, and a manual
/// "send now" for the currently selected clip (handled by the AppDelegate via
/// the sync coordinator). Mirrors the Windows `OptionFriends` dialog.
final class FriendsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let store: ClipboardStore
    private let syncCoordinator: SyncCoordinator
    private let tableView = NSTableView()
    private var friends: [Friend] = []
    private let addButton = NSButton(title: "", target: nil, action: nil)
    private let removeButton = NSButton(title: "", target: nil, action: nil)

    init(store: ClipboardStore, syncCoordinator: SyncCoordinator) {
        self.store = store
        self.syncCoordinator = syncCoordinator

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.applyDittoAppearance()
        window.title = LocalizationManager.shared.text("friends")
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
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 28

        let columns = [
            (identifier: "name", title: LocalizationManager.shared.text("friend_name"), width: 160.0),
            (identifier: "ip", title: LocalizationManager.shared.text("friend_ip"), width: 210.0),
            (identifier: "sendall", title: LocalizationManager.shared.text("friend_send_all"), width: 120.0)
        ]
        for configuration in columns {
            let identifier = configuration.identifier
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = configuration.title
            column.width = configuration.width
            tableView.addTableColumn(column)
        }

        addButton.title = LocalizationManager.shared.text("add_friend")
        addButton.target = self
        addButton.action = #selector(addFriend)
        addButton.bezelStyle = .rounded
        removeButton.title = LocalizationManager.shared.text("remove_friend")
        removeButton.target = self
        removeButton.action = #selector(removeFriend)
        removeButton.bezelStyle = .rounded

        let buttonRow = NSStackView(views: [addButton, removeButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(scrollView)
        root.addSubview(buttonRow)
        window.contentView = root

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: buttonRow.topAnchor, constant: -12),
            buttonRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            buttonRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            buttonRow.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)
        ])
    }

    func refresh() {
        friends = store.loadFriends()
        tableView.reloadData()
    }

    func refreshText() {
        window?.title = LocalizationManager.shared.text("friends")
        for column in tableView.tableColumns {
            switch column.identifier.rawValue {
            case "name": column.title = LocalizationManager.shared.text("friend_name")
            case "ip": column.title = LocalizationManager.shared.text("friend_ip")
            case "sendall": column.title = LocalizationManager.shared.text("friend_send_all")
            default: break
            }
        }
        addButton.title = LocalizationManager.shared.text("add_friend")
        removeButton.title = LocalizationManager.shared.text("remove_friend")
        tableView.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { friends.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let friend = friends[safe: row] else { return nil }
        let identifier = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("name")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = identifier

        if identifier.rawValue == "sendall" {
            let checkbox: NSButton
            if let existing = cell.subviews.first as? NSButton {
                checkbox = existing
            } else {
                checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleSendAll(_:)))
                checkbox.translatesAutoresizingMaskIntoConstraints = false
                checkbox.toolTip = LocalizationManager.shared.text("friend_send_all")
                cell.addSubview(checkbox)
                NSLayoutConstraint.activate([
                    checkbox.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
                    checkbox.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            }
            checkbox.state = friend.sendAll ? .on : .off
            checkbox.tag = row
            checkbox.toolTip = LocalizationManager.shared.text("friend_send_all")
            return cell
        }

        let label = cell.textField ?? NSTextField(labelWithString: "")
        switch identifier.rawValue {
        case "ip": label.stringValue = "\(friend.ipAddress):\(friend.port)"
        default: label.stringValue = friend.name
        }
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

    @objc private func toggleSendAll(_ sender: NSButton) {
        guard friends.indices.contains(sender.tag) else { return }
        var friend = friends[sender.tag]
        friend.sendAll = sender.state == .on
        store.upsertFriend(friend)
        friends[sender.tag] = friend
    }

    @objc private func addFriend() {
        let alert = NSAlert()
        alert.messageText = LocalizationManager.shared.text("add_friend")
        alert.addButton(withTitle: LocalizationManager.shared.text("ok"))
        alert.addButton(withTitle: LocalizationManager.shared.text("cancel"))

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: LocalizationManager.shared.text("friend_name"))],
            [NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))],
            [NSTextField(labelWithString: LocalizationManager.shared.text("friend_ip"))],
            [NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))]
        ])
        let nameField = grid.cell(atColumnIndex: 0, rowIndex: 1).contentView as! NSTextField
        let ipField = grid.cell(atColumnIndex: 0, rowIndex: 3).contentView as! NSTextField
        alert.accessoryView = grid
        if alert.runModal() == .alertFirstButtonReturn {
            let friend = Friend(name: nameField.stringValue, ipAddress: ipField.stringValue, port: DittoSettings.sendRecvPort)
            store.upsertFriend(friend)
            refresh()
        }
    }

    @objc private func removeFriend() {
        let row = tableView.selectedRow
        guard let friend = friends[safe: row] else { return }
        store.deleteFriend(id: friend.id)
        refresh()
    }
}
