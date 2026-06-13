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

    init(store: ClipboardStore, syncCoordinator: SyncCoordinator) {
        self.store = store
        self.syncCoordinator = syncCoordinator

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
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
        tableView.headerView = nil

        for identifier in ["name", "ip", "sendall"] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            tableView.addTableColumn(column)
        }

        let addButton = NSButton(title: LocalizationManager.shared.text("add_friend"), target: self, action: #selector(addFriend))
        addButton.bezelStyle = .rounded
        let removeButton = NSButton(title: LocalizationManager.shared.text("remove_friend"), target: self, action: #selector(removeFriend))
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

    func numberOfRows(in tableView: NSTableView) -> Int { friends.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let friend = friends[safe: row] else { return nil }
        let cell = tableView.makeView(withIdentifier: tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("name"), owner: self) as? NSTableCellView ?? NSTableCellView()
        let label = cell.textField ?? NSTextField(labelWithString: "")
        switch tableColumn?.identifier.rawValue {
        case "ip": label.stringValue = "\(friend.ipAddress):\(friend.port)"
        case "sendall": label.stringValue = friend.sendAll ? "✓" : ""
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

    @objc private func addFriend() {
        let alert = NSAlert()
        alert.messageText = LocalizationManager.shared.text("add_friend")
        alert.addButton(withTitle: "OK")
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
