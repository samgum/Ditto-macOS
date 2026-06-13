import AppKit
import Foundation

/// Read/write clip metadata: description, quick-paste text, group, shortcut,
/// never-auto-delete, dates, and format list. Mirrors the Windows
/// `CopyProperties` dialog.
final class ClipPropertiesWindowController: NSWindowController {
    private let store: ClipboardStore
    private var entry: ClipboardEntry
    private let onChanged: () -> Void

    private let descriptionField = NSTextView()
    private let quickPasteField = NSTextField()
    private let neverAutoDeleteButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let favoriteButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let groupPopup = NSPopUpButton()
    private let infoLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "", target: nil, action: nil)
    private let closeButton = NSButton(title: "", target: nil, action: nil)
    private let formatsList = NSTextView()

    init(store: ClipboardStore, entry: ClipboardEntry, onChanged: @escaping () -> Void) {
        self.store = store
        self.entry = entry
        self.onChanged = onChanged

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = LocalizationManager.shared.text("clip_properties")
        window.center()
        super.init(window: window)
        configureContent()
        populate()
    }

    required init?(coder: NSCoder) { nil }

    private func configureContent() {
        guard let window else { return }

        descriptionField.isEditable = true
        descriptionField.font = NSFont.systemFont(ofSize: 13)
        descriptionField.translatesAutoresizingMaskIntoConstraints = false

        quickPasteField.translatesAutoresizingMaskIntoConstraints = false
        favoriteButton.target = self
        favoriteButton.action = #selector(toggleChanged)
        neverAutoDeleteButton.target = self
        neverAutoDeleteButton.action = #selector(toggleChanged)

        groupPopup.target = self
        groupPopup.action = #selector(groupChanged)
        groupPopup.translatesAutoresizingMaskIntoConstraints = false

        infoLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.translatesAutoresizingMaskIntoConstraints = false

        formatsList.isEditable = false
        formatsList.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        formatsList.translatesAutoresizingMaskIntoConstraints = false

        let descriptionScroll = NSScrollView()
        descriptionScroll.documentView = descriptionField
        descriptionScroll.hasVerticalScroller = true
        descriptionScroll.translatesAutoresizingMaskIntoConstraints = false

        let formatsScroll = NSScrollView()
        formatsScroll.documentView = formatsList
        formatsScroll.hasVerticalScroller = true
        formatsScroll.translatesAutoresizingMaskIntoConstraints = false

        saveButton.title = LocalizationManager.shared.text("save")
        saveButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"

        closeButton.title = LocalizationManager.shared.text("close")
        closeButton.bezelStyle = .rounded
        closeButton.target = self
        closeButton.action = #selector(close)
        closeButton.keyEquivalent = "\u{1b}"

        let grid = NSGridView(views: [
            [label(LocalizationManager.shared.text("clip")), descriptionScroll],
            [label(LocalizationManager.shared.text("quick_paste_text")), quickPasteField],
            [label(LocalizationManager.shared.text("group")), groupPopup],
            [NSView(), favoriteButton],
            [NSView(), neverAutoDeleteButton],
            [label(LocalizationManager.shared.text("type")), formatsScroll]
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false

        let buttonRow = NSStackView(views: [infoLabel, NSView(), saveButton, closeButton])
        buttonRow.orientation = .horizontal
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(grid)
        root.addSubview(buttonRow)
        window.contentView = root

        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            buttonRow.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 16),
            buttonRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            buttonRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            buttonRow.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),

            descriptionScroll.heightAnchor.constraint(equalToConstant: 90),
            formatsScroll.heightAnchor.constraint(equalToConstant: 70)
        ])
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.alignment = .right
        field.textColor = .secondaryLabelColor
        return field
    }

    private func populate() {
        descriptionField.string = entry.text ?? ""
        quickPasteField.stringValue = entry.quickPasteText ?? ""
        favoriteButton.title = LocalizationManager.shared.text("favorite")
        favoriteButton.state = entry.favorite ? .on : .off
        neverAutoDeleteButton.title = LocalizationManager.shared.text("never_auto_delete")
        neverAutoDeleteButton.state = entry.neverAutoDelete ? .on : .off

        groupPopup.removeAllItems()
        groupPopup.addItem(withTitle: LocalizationManager.shared.text("ungrouped"))
        var selectedIndex = 0
        for (index, group) in store.groups.enumerated() {
            groupPopup.addItem(withTitle: group.name)
            if entry.groupId == group.id { selectedIndex = index + 1 }
        }
        groupPopup.selectItem(at: selectedIndex)

        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        var lines: [String] = []
        lines.append("\(LocalizationManager.shared.text("date")): \(formatter.string(from: entry.createdAt))")
        if let lastPaste = entry.lastPasteDate {
            lines.append("\(LocalizationManager.shared.text("last_pasted")): \(formatter.string(from: lastPaste))")
        } else {
            lines.append("\(LocalizationManager.shared.text("last_pasted")): \(LocalizationManager.shared.text("never"))")
        }
        if let app = entry.sourceApp {
            lines.append("\(LocalizationManager.shared.text("source_app")): \(app)")
        }
        lines.append("\(LocalizationManager.shared.text("pastes")): \(entry.pasteCount)")

        var formats: [String] = []
        if entry.text != nil { formats.append("Plain Text") }
        if entry.rtfBlobKey != nil { formats.append("Rich Text Format") }
        if entry.htmlBlobKey != nil { formats.append("HTML Format") }
        if entry.imageBlobKey != nil { formats.append("PNG") }
        if let fileURLs = entry.fileURLs { formats.append("Files (\(fileURLs.count))") }
        lines.append("\n\(LocalizationManager.shared.text("type")):")
        lines.append(contentsOf: formats)

        infoLabel.stringValue = ""
        formatsList.string = lines.joined(separator: "\n")
    }

    @objc private func toggleChanged() { applyEdits() }
    @objc private func groupChanged() { applyEdits() }

    private func applyEdits() {
        entry.text = descriptionField.string.isEmpty ? nil : descriptionField.string
        entry.quickPasteText = quickPasteField.stringValue.isEmpty ? nil : quickPasteField.stringValue
        entry.isFavorite = favoriteButton.state == .on
        entry.neverAutoDelete = neverAutoDeleteButton.state == .on
        if groupPopup.indexOfSelectedItem == 0 {
            entry.groupId = nil
        } else {
            let index = groupPopup.indexOfSelectedItem - 1
            entry.groupId = store.groups[safe: index]?.id
        }
        store.update(entry)
        onChanged()
    }

    @objc private func save() {
        applyEdits()
        close()
    }
}
