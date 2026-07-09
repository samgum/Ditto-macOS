import AppKit
import Foundation

/// Copy/paste statistics window. Mirrors the Windows Options ▸ Stats tab.
final class StatisticsWindowController: NSWindowController {
    private let scrollView = NSTextView()
    private let resetButton = NSButton(title: "", target: nil, action: nil)

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.applyDittoAppearance()
        window.title = LocalizationManager.shared.text("statistics")
        window.center()
        super.init(window: window)

        scrollView.isEditable = false
        scrollView.drawsBackground = false
        scrollView.font = NSFont.systemFont(ofSize: 14)
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        resetButton.title = LocalizationManager.shared.text("reset_stats")
        resetButton.bezelStyle = .rounded
        resetButton.target = self
        resetButton.action = #selector(resetTrip)
        resetButton.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(scrollView)
        root.addSubview(resetButton)
        window.contentView = root

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: resetButton.topAnchor, constant: -12),
            resetButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            resetButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func refresh() {
        let stats = Statistics.shared
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        let report = """
        \(LocalizationManager.shared.text("trip"))  (\(formatter.string(from: stats.tripStartDate)))
        \(LocalizationManager.shared.text("copies")): \(stats.tripCopies)
        \(LocalizationManager.shared.text("pastes")): \(stats.tripPastes)

        \(LocalizationManager.shared.text("total"))  (\(formatter.string(from: stats.totalStartDate)))
        \(LocalizationManager.shared.text("copies")): \(stats.totalCopies)
        \(LocalizationManager.shared.text("pastes")): \(stats.totalPastes)
        """
        scrollView.string = report
    }

    @objc private func resetTrip() {
        Statistics.shared.resetTrip()
        refresh()
    }
}
