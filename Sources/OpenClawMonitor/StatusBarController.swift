import AppKit

/// Owns the `NSStatusItem` and builds / updates the dropdown menu.
@MainActor
final class StatusBarController {

    private let statusItem: NSStatusItem
    private let monitor: Monitor

    // Menu items that need runtime updates
    private let statusMenuItem   = NSMenuItem(title: "Status: —",          action: nil, keyEquivalent: "")
    private let timeMenuItem     = NSMenuItem(title: "Last check: never",  action: nil, keyEquivalent: "")
    private let intervalMenuItem = NSMenuItem(title: "",                   action: nil, keyEquivalent: "")
    private let reinstallItem    = NSMenuItem(title: "Reinstall Gateway…", action: nil, keyEquivalent: "")

    init(monitor: Monitor) {
        self.monitor = monitor
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        buildMenu()
        refreshDisplay()

        monitor.onStatusChanged = { [weak self] in
            self?.refreshDisplay()
        }
    }

    // MARK: - Menu construction

    private func buildMenu() {
        let menu = NSMenu()

        // ── Status labels ────────────────────────────────────────────────────
        statusMenuItem.isEnabled   = false
        timeMenuItem.isEnabled     = false
        intervalMenuItem.isEnabled = false

        menu.addItem(statusMenuItem)
        menu.addItem(timeMenuItem)
        menu.addItem(.separator())

        // ── Check actions ────────────────────────────────────────────────────
        menu.addItem(makeItem("Check Now",          action: #selector(onCheckBasic)))
        menu.addItem(makeItem("Medium Check",       action: #selector(onCheckMedium)))
        menu.addItem(makeItem("Deep Check",         action: #selector(onCheckDeep)))
        menu.addItem(makeItem("Show Last Output…",  action: #selector(onShowOutput)))
        menu.addItem(.separator())

        // ── Repair actions ───────────────────────────────────────────────────
        menu.addItem(makeItem("Restart Gateway…",   action: #selector(onRestartGateway)))
        reinstallItem.target = self
        reinstallItem.action = #selector(onReinstallGateway)
        menu.addItem(reinstallItem)
        menu.addItem(.separator())

        // ── Settings ─────────────────────────────────────────────────────────
        menu.addItem(makeItem("Set Interval…",      action: #selector(onSetInterval)))
        updateIntervalLabel()
        menu.addItem(intervalMenuItem)
        menu.addItem(.separator())

        // ── Quit ─────────────────────────────────────────────────────────────
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func makeItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: - Display refresh

    private func refreshDisplay() {
        // Menu bar title
        statusItem.button?.title = "\(monitor.checkStatus.emoji) OClaw"

        // Status label
        switch monitor.checkStatus {
        case .unknown:  statusMenuItem.title = "Status: —"
        case .checking: statusMenuItem.title = "Status: checking…"
        case .ok:       statusMenuItem.title = "Status: OK ✓"
        case .failed:   statusMenuItem.title = "Status: Error ✗"
        }

        // Last-check timestamp
        if let date = monitor.lastCheck {
            let fmt = DateFormatter()
            fmt.dateFormat = "HH:mm:ss"
            timeMenuItem.title = "Last check: \(fmt.string(from: date))  [\(monitor.lastLevel.rawValue)]"
        }

        // Highlight reinstall item when auto-repair escalated
        if monitor.reinstallSuggested {
            reinstallItem.title = "⚠️ Reinstall Gateway…"
        } else {
            reinstallItem.title = "Reinstall Gateway…"
        }

        updateIntervalLabel()
    }

    private func updateIntervalLabel() {
        intervalMenuItem.title = "  Auto-check every \(monitor.intervalMinutes) min"
    }

    // MARK: - Check actions

    @objc private func onCheckBasic() {
        Task { await monitor.runCheck(level: .basic) }
    }

    @objc private func onCheckMedium() {
        Task { await monitor.runCheck(level: .medium) }
    }

    @objc private func onCheckDeep() {
        Task { await monitor.runCheck(level: .deep) }
    }

    @objc private func onShowOutput() {
        guard !monitor.lastResults.isEmpty else {
            alert(title: "No results yet", message: "Run a check first.")
            return
        }

        let text = monitor.lastResults.map { r in
            let mark  = r.ok ? "✓" : "✗"
            let lines = r.output.split(separator: "\n", maxSplits: 12, omittingEmptySubsequences: false)
            let body  = lines.prefix(12).joined(separator: "\n  ")
            let extra = lines.count > 12 ? "\n  … (\(lines.count - 12) more lines)" : ""
            return "\(mark)  \(r.command)\n  \(body)\(extra)"
        }.joined(separator: "\n\n")

        alertWithScrollableText(
            title:   "OpenClaw — Last Results [\(monitor.lastLevel.rawValue)]",
            content: text
        )
    }

    // MARK: - Repair actions

    @objc private func onRestartGateway() {
        guard confirm(title: "Restart Gateway?",
                      message: "Runs:  openclaw gateway restart") else { return }
        Task { await monitor.restartGateway() }
    }

    @objc private func onReinstallGateway() {
        guard confirm(title: "Reinstall Gateway?",
                      message: "Runs:  openclaw gateway reinstall\n\nThis may take several minutes.") else { return }
        Task { await monitor.reinstallGateway() }
    }

    // MARK: - Settings

    @objc private func onSetInterval() {
        let nsAlert = NSAlert()
        nsAlert.messageText     = "Set auto-check interval"
        nsAlert.informativeText = "Minutes between automatic basic checks (minimum 1)."
        nsAlert.addButton(withTitle: "Save")
        nsAlert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        field.stringValue = "\(monitor.intervalMinutes)"
        nsAlert.accessoryView = field

        // Focus the text field so the user can type immediately
        nsAlert.window.initialFirstResponder = field

        let response = nsAlert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        if let mins = Int(field.stringValue.trimmingCharacters(in: .whitespaces)), mins >= 1 {
            monitor.intervalMinutes = mins
            monitor.restartTimer()
            updateIntervalLabel()
        } else {
            alert(title: "Invalid input", message: "Please enter a whole number ≥ 1.")
        }
    }

    // MARK: - Alert helpers

    @discardableResult
    private func alert(title: String, message: String) -> NSApplication.ModalResponse {
        let a = NSAlert()
        a.messageText     = title
        a.informativeText = message
        a.addButton(withTitle: "OK")
        return a.runModal()
    }

    private func confirm(title: String, message: String) -> Bool {
        let a = NSAlert()
        a.messageText     = title
        a.informativeText = message
        a.addButton(withTitle: "Confirm")
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }

    /// Shows a scrollable text view inside an NSAlert — good for longer output.
    private func alertWithScrollableText(title: String, content: String) {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 320))
        scrollView.hasVerticalScroller   = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers    = true
        scrollView.borderType            = .bezelBorder

        let textView = NSTextView(frame: scrollView.bounds)
        textView.isEditable               = false
        textView.isSelectable             = true
        textView.font                     = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset       = NSSize(width: 6, height: 6)
        textView.string                   = content
        textView.backgroundColor          = NSColor.textBackgroundColor
        textView.autoresizingMask         = [.width, .height]
        scrollView.documentView           = textView

        let a = NSAlert()
        a.messageText   = title
        a.accessoryView = scrollView
        a.addButton(withTitle: "OK")
        a.runModal()
    }
}
