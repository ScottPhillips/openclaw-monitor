import AppKit

@MainActor
final class StatusBarController {

    private let statusItem: NSStatusItem
    private let monitor:    Monitor

    // ── Static / rarely-changing menu items ──────────────────────────────────
    private let statusMenuItem    = NSMenuItem(title: "Status: —",           action: nil, keyEquivalent: "")
    private let failedChecksItem  = NSMenuItem(title: "",                    action: nil, keyEquivalent: "")
    private let timeMenuItem      = NSMenuItem(title: "Last check: never",   action: nil, keyEquivalent: "")
    private let uptimeMenuItem    = NSMenuItem(title: "",                    action: nil, keyEquivalent: "")
    private let notInstalledItem  = NSMenuItem(title: "",                    action: nil, keyEquivalent: "")
    private let intervalMenuItem  = NSMenuItem(title: "",                    action: nil, keyEquivalent: "")
    private let snoozeMenuItem    = NSMenuItem(title: "",                    action: nil, keyEquivalent: "")
    private let updateMenuItem    = NSMenuItem(title: "Check For Update…",   action: nil, keyEquivalent: "")

    // Channels: rebuilt on each refresh
    private let channelsMenuItem  = NSMenuItem(title: "⚪ Channels",         action: nil, keyEquivalent: "")

    // OpenClaw Server submenu items that need runtime updates
    private let serverMenuItem    = NSMenuItem(title: "OpenClaw Server",     action: nil, keyEquivalent: "")
    private let reinstallItem     = NSMenuItem(title: "Reinstall Gateway…",  action: nil, keyEquivalent: "")

    init(monitor: Monitor) {
        self.monitor  = monitor
        statusItem    = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        buildMenu()
        refreshDisplay()

        monitor.onStatusChanged = { [weak self] in self?.refreshDisplay() }
    }

    // MARK: - Menu construction

    private func buildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // ── Status section ────────────────────────────────────────────────────
        statusMenuItem.isEnabled   = false
        failedChecksItem.isEnabled = false
        timeMenuItem.isEnabled     = false
        uptimeMenuItem.isEnabled   = false
        notInstalledItem.isEnabled = false
        intervalMenuItem.isEnabled = false

        menu.addItem(statusMenuItem)
        menu.addItem(failedChecksItem)
        menu.addItem(timeMenuItem)
        menu.addItem(uptimeMenuItem)
        menu.addItem(notInstalledItem)

        // ── Channels submenu ──────────────────────────────────────────────────
        menu.addItem(.separator())
        channelsMenuItem.submenu = NSMenu()
        menu.addItem(channelsMenuItem)

        // ── Check actions ─────────────────────────────────────────────────────
        menu.addItem(.separator())
        menu.addItem(makeItem("Basic Check",       action: #selector(onCheckBasic)))
        menu.addItem(makeItem("Deep Check",        action: #selector(onCheckDeep)))
        menu.addItem(makeItem("Show Last Output…", action: #selector(onShowOutput)))
        menu.addItem(makeItem("Show History…",     action: #selector(onShowHistory)))

        // ── OpenClaw Server submenu ───────────────────────────────────────────
        menu.addItem(.separator())
        buildServerSubmenu()
        menu.addItem(serverMenuItem)

        // ── Settings ──────────────────────────────────────────────────────────
        menu.addItem(.separator())
        menu.addItem(makeItem("Set Interval…", action: #selector(onSetInterval)))
        updateIntervalLabel()
        menu.addItem(intervalMenuItem)

        snoozeMenuItem.target = self
        snoozeMenuItem.action = #selector(onToggleSnooze)
        menu.addItem(snoozeMenuItem)

        // ── Update / About / Quit ─────────────────────────────────────────────
        menu.addItem(.separator())
        updateMenuItem.target = self
        updateMenuItem.action = #selector(onCheckForUpdate)
        menu.addItem(updateMenuItem)
        menu.addItem(makeItem("About OpenClaw Monitor…", action: #selector(onAbout)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func buildServerSubmenu() {
        let sub = NSMenu()
        sub.autoenablesItems = false

        sub.addItem(makeItem("Restart Gateway…", action: #selector(onRestartGateway)))
        sub.addItem(makeItem("Stop Gateway…",    action: #selector(onStopGateway)))
        sub.addItem(.separator())

        reinstallItem.target = self
        reinstallItem.action = #selector(onReinstallGateway)
        sub.addItem(reinstallItem)

        sub.addItem(.separator())
        sub.addItem(makeItem("Open Control Panel", action: #selector(onOpenControlPanel)))
        sub.addItem(makeItem("Open Gateway Log",   action: #selector(onOpenGatewayLog)))

        serverMenuItem.submenu = sub
    }

    private func makeItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: - Display refresh

    private func refreshDisplay() {
        // Status bar button: "🟢 3/4" when channel data is known, else "🟢 OClaw"
        let emoji = monitor.checkStatus.emoji
        if !monitor.channels.isEmpty {
            let healthy = monitor.channels.filter { $0.healthy }.count
            statusItem.button?.title = "\(emoji) \(healthy)/\(monitor.channels.count)"
        } else {
            statusItem.button?.title = "\(emoji) OClaw"
        }

        // Status label
        switch monitor.checkStatus {
        case .unknown:      statusMenuItem.title = "Status: —"
        case .checking:     statusMenuItem.title = "Status: checking…"
        case .ok:           statusMenuItem.title = "Status: OK ✓"
        case .failed:       statusMenuItem.title = "Status: Error ✗"
        case .notInstalled: statusMenuItem.title = "Status: openclaw not found"
        }

        // Failed check names (shown only when there are failures)
        let failed = monitor.failedChecks
        failedChecksItem.title    = failed.isEmpty ? "" : "  ↳ \(failed)"
        failedChecksItem.isHidden = failed.isEmpty

        // Timestamp + level
        if let date = monitor.lastCheck {
            let fmt = DateFormatter()
            fmt.dateFormat = "HH:mm:ss"
            timeMenuItem.title = "Last check: \(fmt.string(from: date))  [\(monitor.lastLevel.rawValue)]"
        }

        // Uptime ("Healthy since HH:MM")
        if let since = monitor.healthySince {
            let fmt = DateFormatter()
            fmt.dateFormat = "h:mm a"
            uptimeMenuItem.title    = "  Healthy since \(fmt.string(from: since))"
            uptimeMenuItem.isHidden = false
        } else {
            uptimeMenuItem.isHidden = true
        }

        // "not installed" hint
        notInstalledItem.title    = "  ↳ Install from openclaw.ai"
        notInstalledItem.isHidden = !monitor.openclawMissing

        // Channels submenu
        rebuildChannelsMenu()

        // Server submenu: highlight when reinstall is recommended
        if monitor.reinstallSuggested {
            serverMenuItem.title = "⚠️ OpenClaw Server"
            reinstallItem.title  = "⚠️ Reinstall Gateway…"
        } else {
            serverMenuItem.title = "OpenClaw Server"
            reinstallItem.title  = "Reinstall Gateway…"
        }

        // Interval label
        updateIntervalLabel()

        // Snooze toggle
        if monitor.isSnoozed {
            snoozeMenuItem.title = "🔔 Unmute Notifications"
        } else {
            snoozeMenuItem.title = "🔕 Mute Notifications for 1 hr"
        }

        // Update item
        if let latest = monitor.updateAvailable {
            updateMenuItem.title = "⬆️ Update Available: v\(latest)"
        } else {
            updateMenuItem.title = "Check For Update…"
        }
    }

    // MARK: - Channels submenu

    private func rebuildChannelsMenu() {
        let sub = NSMenu()
        sub.autoenablesItems = false

        if monitor.channels.isEmpty {
            channelsMenuItem.title = "⚪ Channels"
            let placeholder = NSMenuItem(title: "  No data yet — run a check", action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            sub.addItem(placeholder)
        } else {
            let allHealthy = monitor.channels.allSatisfy { $0.healthy }
            channelsMenuItem.title = (allHealthy ? "🟢" : "🔴") + " Channels"

            for ch in monitor.channels {
                let row = NSMenuItem(title: "\(ch.healthy ? "🟢" : "🔴")  \(ch.label)",
                                     action: nil, keyEquivalent: "")
                row.isEnabled = false
                sub.addItem(row)

                for acc in ch.accounts {
                    let aRow = NSMenuItem(title: "      \(acc.healthy ? "🟢" : "🔴")  \(acc.label)",
                                          action: nil, keyEquivalent: "")
                    aRow.isEnabled = false
                    sub.addItem(aRow)
                }
            }
        }

        channelsMenuItem.submenu = sub
    }

    private func updateIntervalLabel() {
        intervalMenuItem.title = "  Auto-check every \(monitor.intervalMinutes) min"
    }

    // MARK: - Check actions

    @objc private func onCheckBasic() {
        Task { await monitor.runCheck(level: .basic) }
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
            let lines = r.output.split(separator: "\n", maxSplits: 12,
                                       omittingEmptySubsequences: false)
            let body  = lines.prefix(12).joined(separator: "\n  ")
            let extra = lines.count > 12 ? "\n  … (\(lines.count - 12) more lines)" : ""
            return "\(mark)  \(r.command)\n  \(body)\(extra)"
        }.joined(separator: "\n\n")

        scrollableAlert(title: "OpenClaw — Last Results [\(monitor.lastLevel.rawValue)]", content: text)
    }

    @objc private func onShowHistory() {
        guard !monitor.history.isEmpty else {
            alert(title: "No history yet", message: "Events will appear here after the first check.")
            return
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd  HH:mm:ss"
        let text = monitor.history.reversed().map { e in
            "\(e.icon)  \(fmt.string(from: e.date))\n   \(e.kind.rawValue): \(e.summary)"
        }.joined(separator: "\n\n")
        scrollableAlert(title: "OpenClaw — Event History (last \(monitor.history.count))", content: text)
    }

    // MARK: - Server submenu actions

    @objc private func onRestartGateway() {
        guard confirm(title: "Restart Gateway?",
                      message: "Runs:  openclaw gateway restart\n\nIf the service is not loaded it will be installed and started.") else { return }
        Task { await monitor.restartGateway() }
    }

    @objc private func onStopGateway() {
        guard confirm(title: "Stop Gateway?",
                      message: "Runs:  openclaw gateway stop\n\nThe monitor will show 🔴 until the gateway is restarted.") else { return }
        Task { await monitor.stopGateway() }
    }

    @objc private func onReinstallGateway() {
        guard confirm(title: "Reinstall Gateway?",
                      message: "Runs:  openclaw gateway reinstall\n\nThis may take several minutes.") else { return }
        Task { await monitor.reinstallGateway() }
    }

    @objc private func onOpenControlPanel() {
        guard let url = URL(string: monitor.controlPanelURL) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func onOpenGatewayLog() {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let logPath = "/tmp/openclaw/openclaw-\(fmt.string(from: Date())).log"
        let logURL  = URL(fileURLWithPath: logPath)
        if FileManager.default.fileExists(atPath: logPath) {
            NSWorkspace.shared.open(logURL)
        } else {
            alert(title: "Log not found", message: "Expected:\n\(logPath)")
        }
    }

    // MARK: - Settings

    @objc private func onSetInterval() {
        let presets = [5, 15, 30, 60, 120]

        let a = NSAlert()
        a.messageText     = "Set auto-check interval"
        a.informativeText = "How often should OpenClaw Monitor check gateway health?"
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 180, height: 26), pullsDown: false)
        for mins in presets {
            let label = mins < 60 ? "\(mins) minutes" : "\(mins / 60) hour\(mins == 60 ? "" : "s")"
            popup.addItem(withTitle: label)
            popup.lastItem?.representedObject = mins
        }
        // Pre-select the closest preset to the current setting
        let current = monitor.intervalMinutes
        let closest = presets.min(by: { abs($0 - current) < abs($1 - current) }) ?? 30
        popup.selectItem(at: presets.firstIndex(of: closest) ?? 2)
        a.accessoryView = popup

        guard a.runModal() == .alertFirstButtonReturn else { return }
        if let mins = popup.selectedItem?.representedObject as? Int {
            monitor.intervalMinutes = mins
            monitor.restartTimer()
            updateIntervalLabel()
        }
    }

    @objc private func onToggleSnooze() {
        if monitor.isSnoozed {
            monitor.unsnooze()
        } else {
            monitor.snooze(hours: 1)
        }
    }

    // MARK: - Update check

    @objc private func onCheckForUpdate() {
        if monitor.updateAvailable != nil {
            // Update known — open the releases page directly.
            NSWorkspace.shared.open(URL(string: "https://github.com/ScottPhillips/openclaw-monitor/releases/latest")!)
            return
        }

        // Run the check; show result when done.
        Task {
            updateMenuItem.title = "Checking…"
            await monitor.checkForUpdate()
            if let latest = monitor.updateAvailable {
                let a = NSAlert()
                a.messageText     = "Update available: v\(latest)"
                a.informativeText = "A new version of OpenClaw Monitor is available on GitHub."
                a.addButton(withTitle: "View Release")
                a.addButton(withTitle: "Dismiss")
                if a.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(URL(string: "https://github.com/ScottPhillips/openclaw-monitor/releases/latest")!)
                }
            } else {
                alert(title: "Up to date", message: "You're running the latest version of OpenClaw Monitor.")
            }
        }
    }

    // MARK: - About

    @objc private func onAbout() {
        let monitorVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let ocVersion      = monitor.openclawVersion.isEmpty ? "unknown" : monitor.openclawVersion
        let updateNote     = monitor.updateAvailable.map { " — v\($0) available!" } ?? ""

        let a = NSAlert()
        a.messageText     = "OpenClaw Monitor  v\(monitorVersion)\(updateNote)"
        a.informativeText = """
            Monitors your OpenClaw gateway health and automatically \
            attempts recovery when checks fail.

            OpenClaw:  \(ocVersion)
            Checks:    RPC probe · Health · Dashboard · Channels
            Auto-repair: restart → install → suggest reinstall

            github.com/ScottPhillips/openclaw-monitor
            """
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "View on GitHub")
        if a.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(URL(string: "https://github.com/ScottPhillips/openclaw-monitor")!)
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

    private func scrollableAlert(title: String, content: String) {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 540, height: 320))
        scroll.hasVerticalScroller   = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers    = true
        scroll.borderType            = .bezelBorder

        let tv = NSTextView(frame: scroll.bounds)
        tv.isEditable         = false
        tv.isSelectable       = true
        tv.font               = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.textContainerInset = NSSize(width: 6, height: 6)
        tv.string             = content
        tv.backgroundColor    = NSColor.textBackgroundColor
        tv.autoresizingMask   = [.width, .height]
        scroll.documentView   = tv

        let a = NSAlert()
        a.messageText   = title
        a.accessoryView = scroll
        a.addButton(withTitle: "OK")
        a.runModal()
    }
}
