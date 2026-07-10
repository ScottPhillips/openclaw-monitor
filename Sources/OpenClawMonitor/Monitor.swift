import Foundation

// MARK: - CheckCommand

struct CheckCommand {
    let shell:           String
    let label:           String
    let failurePatterns: [String]

    init(_ shell: String, label: String = "", failurePatterns: [String] = []) {
        self.shell           = shell
        self.label           = label.isEmpty ? shell : label
        self.failurePatterns = failurePatterns
    }
}

// MARK: - CheckLevel

enum CheckLevel: String {
    case basic = "basic"
    case deep  = "deep"

    static let baseCommands: [CheckCommand] = [
        CheckCommand("openclaw gateway probe", label: "RPC probe"),
        CheckCommand("openclaw health --json",  label: "Health"),
        CheckCommand(
            "curl -sf --connect-timeout 5 --max-time 10 http://127.0.0.1:18789/",
            label: "Dashboard"
        ),
        CheckCommand(
            "openclaw channels status --probe",
            label: "Channels",
            failurePatterns: ["Gateway not reachable"]
            // "Error:" intentionally excluded — per-channel error fields (e.g.
            // "error:channel stop timed out") are stale state, not gateway failures.
        ),
    ]

    var checkCommands: [CheckCommand] {
        switch self {
        case .basic:
            return CheckLevel.baseCommands
        case .deep:
            return CheckLevel.baseCommands + [
                CheckCommand(
                    "openclaw status --deep",
                    label: "Status (deep)",
                    failurePatterns: ["unreachable", "ECONNREFUSED", "connect failed", "RPC probe: failed"]
                ),
                CheckCommand(
                    "openclaw security audit --deep",
                    label: "Security audit",
                    failurePatterns: ["CRITICAL"]  // uppercase-only avoids false positives
                ),
            ]
        }
    }
}

// MARK: - CheckStatus

enum CheckStatus {
    case unknown, checking, ok, failed, notInstalled

    var emoji: String {
        switch self {
        case .unknown:      return "⚪"
        case .checking:     return "⟳"
        case .ok:           return "🟢"
        case .failed:       return "🔴"
        case .notInstalled: return "⚠️"
        }
    }
}

// MARK: - CheckResult

struct CheckResult {
    let command:  String
    let exitCode: Int32
    let output:   String
    var ok: Bool { exitCode == 0 }
}

// MARK: - Channel health

struct ChannelAccount {
    let id:      String
    let label:   String
    let healthy: Bool
}

struct ChannelHealth {
    let id:       String
    let label:    String
    let healthy:  Bool
    let accounts: [ChannelAccount]
}

// MARK: - HistoryEvent

struct HistoryEvent: Codable {
    let date:    Date
    let kind:    Kind
    let summary: String

    enum Kind: String, Codable {
        case checkFailed      = "Check Failed"
        case restartAttempt   = "Gateway Restart"
        case restartRecovered = "Recovered (restart)"
        case reinstallAttempt = "Gateway Reinstall"
        case recovered        = "Recovered"
    }

    var icon: String {
        switch kind {
        case .checkFailed:      return "✗"
        case .restartAttempt:   return "↺"
        case .restartRecovered: return "✓"
        case .reinstallAttempt: return "⚙"
        case .recovered:        return "✓"
        }
    }
}

// MARK: - Monitor

@MainActor
final class Monitor {

    // MARK: Published state

    private(set) var checkStatus:        CheckStatus     = .unknown
    private(set) var lastCheck:          Date?
    private(set) var lastResults:        [CheckResult]   = []
    private(set) var lastLevel:          CheckLevel      = .basic
    private(set) var reinstallSuggested: Bool            = false
    private(set) var openclawMissing:    Bool            = false
    private(set) var history:            [HistoryEvent]  = []
    private(set) var channels:           [ChannelHealth] = []
    private(set) var controlPanelURL:    String          = "http://127.0.0.1:18789/"
    private(set) var openclawVersion:    String          = ""
    private(set) var healthySince:       Date?
    private(set) var updateAvailable:    String?

    /// Non-nil while alerts are muted.
    var snoozeUntil: Date?

    var isSnoozed: Bool {
        guard let until = snoozeUntil else { return false }
        return Date() < until
    }

    /// Comma-separated names of currently failing checks, or empty string.
    var failedChecks: String {
        guard checkStatus == .failed else { return "" }
        let names = lastResults.filter { !$0.ok }.map { $0.command }
        return names.isEmpty ? "" : names.joined(separator: ", ")
    }

    var onStatusChanged: (() -> Void)?

    // MARK: Interval (UserDefaults)

    var intervalMinutes: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: "intervalMinutes")
            return v > 0 ? v : 30
        }
        set { UserDefaults.standard.set(newValue, forKey: "intervalMinutes") }
    }

    // MARK: Private

    private var timer:          Timer?
    private var isBusy =        false
    private var lastFailureKey: String?   // for notification deduplication

    private let historyFileURL: URL = {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".openclaw-monitor-history.json")
    }()

    // MARK: - Init

    init() { loadHistory() }

    // MARK: - Timer

    func startPeriodicTimer() {
        stopTimer()
        let secs = TimeInterval(intervalMinutes * 60)
        timer = Timer.scheduledTimer(withTimeInterval: secs, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.runCheck(level: .basic) }
        }
    }

    func stopTimer()    { timer?.invalidate(); timer = nil }
    func restartTimer() { startPeriodicTimer() }

    // MARK: - Snooze

    func snooze(hours: Double = 1) {
        snoozeUntil = Date().addingTimeInterval(hours * 3600)
        onStatusChanged?()
    }

    func unsnooze() {
        snoozeUntil = nil
        onStatusChanged?()
    }

    // MARK: - Public: run a check

    func runCheck(level: CheckLevel) async {
        guard !isBusy else { return }
        isBusy = true
        reinstallSuggested = false

        checkStatus = .checking
        onStatusChanged?()

        let (allOk, results, missing) = await executeCommands(for: level)
        openclawMissing = missing
        applyResults(ok: allOk, results: results, level: level)

        if !allOk && !missing {
            let key = failureSummary(from: results)
            if key != lastFailureKey {
                // New or changed failure — record history and attempt repair.
                appendHistory(HistoryEvent(date: Date(), kind: .checkFailed, summary: key))
                lastFailureKey = key
                await autoRepair()
            }
            // Same failure key as last check: skip notification and history spam.
        } else if allOk {
            lastFailureKey = nil
        }

        isBusy = false
    }

    // MARK: - Public: manual repair

    func restartGateway() async {
        guard !isBusy else { return }
        isBusy = true
        checkStatus = .checking
        onStatusChanged?()

        appendHistory(HistoryEvent(date: Date(), kind: .restartAttempt, summary: "Manual restart"))
        let (_, restartOut) = await CommandRunner.run("openclaw gateway restart", timeout: 120)
        let notLoaded = restartOut.lowercased().contains("not loaded")
                     || restartOut.lowercased().contains("not installed")

        let (code, output): (Int32, String)
        if notLoaded {
            (code, output) = await CommandRunner.run("openclaw gateway install", timeout: 60)
        } else {
            (code, output) = (0, restartOut)
        }
        let snippet = output.isEmpty ? "Done" : String(output.prefix(160))
        notify(title: code == 0 ? "Gateway started ✓" : "Gateway start failed ✗", body: snippet)

        let (allOk, results, _) = await executeCommands(for: .basic)
        applyResults(ok: allOk, results: results, level: .basic)
        if allOk {
            appendHistory(HistoryEvent(date: Date(), kind: .recovered,
                                       summary: "Healthy after manual restart"))
        }
        isBusy = false
    }

    func stopGateway() async {
        guard !isBusy else { return }
        isBusy = true
        checkStatus = .checking
        onStatusChanged?()

        let (code, output) = await CommandRunner.run("openclaw gateway stop", timeout: 60)
        let snippet = output.isEmpty ? "Done" : String(output.prefix(160))
        notify(title: code == 0 ? "Gateway stopped" : "Gateway stop failed ✗", body: snippet)

        let (allOk, results, _) = await executeCommands(for: .basic)
        applyResults(ok: allOk, results: results, level: .basic)
        isBusy = false
    }

    func reinstallGateway() async {
        guard !isBusy else { return }
        isBusy = true
        reinstallSuggested = false
        checkStatus = .checking
        onStatusChanged?()

        notify(title: "Reinstalling gateway…", body: "This may take a few minutes")
        appendHistory(HistoryEvent(date: Date(), kind: .reinstallAttempt, summary: "Manual reinstall"))

        let (code, output) = await CommandRunner.run("openclaw gateway reinstall", timeout: 300)
        let snippet = output.isEmpty ? "Done" : String(output.prefix(160))
        notify(title: code == 0 ? "Gateway reinstalled ✓" : "Gateway reinstall failed ✗", body: snippet)

        let (allOk, results, _) = await executeCommands(for: .basic)
        applyResults(ok: allOk, results: results, level: .basic)
        if allOk {
            appendHistory(HistoryEvent(date: Date(), kind: .recovered,
                                       summary: "Healthy after reinstall"))
        }
        isBusy = false
    }

    // MARK: - Auto-repair (runs while isBusy = true)

    private func autoRepair() async {
        appendHistory(HistoryEvent(date: Date(), kind: .restartAttempt, summary: "Auto-repair triggered"))

        let (_, restartOutput) = await CommandRunner.run("openclaw gateway restart", timeout: 120)
        let serviceNotLoaded = restartOutput.lowercased().contains("not loaded")
                           || restartOutput.lowercased().contains("not installed")

        if serviceNotLoaded {
            notify(title: "OpenClaw check failed", body: "Gateway not running — installing and starting…")
            let (installCode, installOutput) = await CommandRunner.run("openclaw gateway install", timeout: 60)
            if installCode != 0 {
                let body = installOutput.isEmpty ? "(no output)" : String(installOutput.prefix(160))
                notify(title: "Gateway install failed ✗", body: body)
                reinstallSuggested = true
                onStatusChanged?()
                return
            }
        } else {
            notify(title: "OpenClaw check failed", body: "Attempting gateway restart…")
        }

        try? await Task.sleep(for: .seconds(10))

        let (allOk, results, _) = await executeCommands(for: .basic)
        applyResults(ok: allOk, results: results, level: .basic)

        if allOk {
            appendHistory(HistoryEvent(date: Date(), kind: .restartRecovered,
                summary: "All checks passed after restart"))
            notify(title: "OpenClaw ✓", body: "Gateway restart fixed the issue.")
        } else {
            let key = failureSummary(from: results)
            appendHistory(HistoryEvent(date: Date(), kind: .checkFailed,
                summary: "Still failing after restart — " + key))
            notify(title: "OpenClaw still failing",
                   body: "Restart didn't help — try reinstalling from the menu.")
            reinstallSuggested = true
            onStatusChanged?()
        }
    }

    // MARK: - Core execution

    private func executeCommands(for level: CheckLevel) async
        -> (allOk: Bool, results: [CheckResult], openclawMissing: Bool)
    {
        let (whichCode, _) = await CommandRunner.run("which openclaw", timeout: 5)
        if whichCode != 0 {
            let r = CheckResult(command: "openclaw", exitCode: 127,
                                output: "openclaw not found on PATH.\nInstall from https://openclaw.ai")
            return (false, [r], true)
        }

        var results: [CheckResult] = []
        var allOk = true

        for cmd in level.checkCommands {
            let (code, rawOutput) = await CommandRunner.run(cmd.shell)
            let output = Monitor.stripDoctorWarnings(rawOutput)

            var failed = (code != 0)
            if !failed && !cmd.failurePatterns.isEmpty {
                let lower = output.lowercased()
                failed = cmd.failurePatterns.contains { lower.contains($0.lowercased()) }
            }

            if failed { allOk = false }
            let effectiveCode: Int32 = failed ? max(code, 1) : 0
            results.append(CheckResult(command: cmd.label, exitCode: effectiveCode, output: output))
        }

        return (allOk, results, false)
    }

    // MARK: - Doctor warning stripping

    private static func stripDoctorWarnings(_ raw: String) -> String {
        let boxChars: Set<Character> = ["│", "├", "─", "╮", "╯", " "]
        var result:    [String] = []
        var prevBlank = true  // suppress leading blank lines

        for line in raw.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty {
                let isBoxBorder = t.allSatisfy { boxChars.contains($0) }
                if isBoxBorder
                    || t.hasPrefix("◇")
                    || t.hasPrefix("[state-migrations]")
                    || t.hasPrefix("- Left plugin")
                    || t.hasPrefix("- Left legacy") {
                    continue
                }
            }
            let blank = t.isEmpty
            if blank && prevBlank { continue }  // collapse consecutive blanks
            result.append(line)
            prevBlank = blank
        }
        while result.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { result.removeLast() }
        return result.joined(separator: "\n")
    }

    // MARK: - Control panel URL

    func fetchControlPanelURL() async {
        let (_, output) = await CommandRunner.run("openclaw gateway status", timeout: 10)
        for line in output.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            // Parse port from: "Command: .../node ... gateway --port 18789"
            if t.hasPrefix("Command:"), let portRange = t.range(of: "--port ") {
                let rest = t[portRange.upperBound...]
                if let portStr = rest.components(separatedBy: " ").first,
                   let port = Int(portStr) {
                    controlPanelURL = "http://127.0.0.1:\(port)/"
                }
                break
            }
        }
    }

    // MARK: - OpenClaw version

    func fetchOpenClawVersion() async {
        let (code, output) = await CommandRunner.run("openclaw --version", timeout: 10)
        guard code == 0 else { return }
        // "OpenClaw 2026.6.11 (e085fa1)" → grab second token
        let parts = output.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        if parts.count >= 2 { openclawVersion = parts[1] }
    }

    // MARK: - Update check

    func checkForUpdate() async {
        guard let url = URL(string: "https://api.github.com/repos/ScottPhillips/openclaw-monitor/releases/latest")
        else { return }
        var request = URLRequest(url: url)
        request.setValue("OpenClawMonitor/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagName = json["tag_name"] as? String
        else { return }

        let latest  = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        updateAvailable = (latest != current) ? latest : nil
        onStatusChanged?()
    }

    // MARK: - applyResults

    private func applyResults(ok: Bool, results: [CheckResult], level: CheckLevel) {
        let wasOk = (checkStatus == .ok)

        lastResults = results
        lastCheck   = Date()
        lastLevel   = level

        if openclawMissing {
            checkStatus = .notInstalled
        } else {
            checkStatus = ok ? .ok : .failed
        }

        if !openclawMissing {
            if ok && !wasOk {
                healthySince = Date()
            } else if !ok {
                healthySince = nil
            }
        }

        if let healthResult = results.first(where: { $0.command == "Health" }), healthResult.ok {
            let parsed = parseChannels(from: healthResult.output)
            if !parsed.isEmpty { channels = parsed }
        }

        onStatusChanged?()
    }

    // MARK: - Channel JSON parsing

    private func parseChannels(from json: String) -> [ChannelHealth] {
        guard
            let data   = json.data(using: .utf8),
            let root   = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let chans  = root["channels"]      as? [String: Any],
            let order  = root["channelOrder"]  as? [String],
            let labels = root["channelLabels"] as? [String: String]
        else { return [] }

        return order.compactMap { id in
            guard let ch = chans[id] as? [String: Any] else { return nil }
            let label    = labels[id] ?? id.capitalized
            let healthy  = channelIsHealthy(ch)
            let accounts = parseAccounts(from: ch, channelId: id)
            return ChannelHealth(id: id, label: label, healthy: healthy, accounts: accounts)
        }
    }

    private func channelIsHealthy(_ d: [String: Any]) -> Bool {
        let configured = d["configured"] as? Bool ?? false
        let running    = d["running"]    as? Bool ?? false
        // `connected` is Telegram-specific; when absent treat as satisfied
        let connected  = d["connected"]  as? Bool ?? true
        let lastError  = d["lastError"]
        let hasError   = !(lastError is NSNull) && lastError != nil
        return configured && running && connected && !hasError
    }

    private func parseAccounts(from ch: [String: Any], channelId: String) -> [ChannelAccount] {
        guard let accounts = ch["accounts"] as? [String: Any], accounts.count > 1 else { return [] }
        let sorted = accounts.keys.sorted { a, b in
            a == "default" ? true : (b == "default" ? false : a < b)
        }
        return sorted.compactMap { accountId in
            guard let acc = accounts[accountId] as? [String: Any] else { return nil }
            let healthy = channelIsHealthy(acc)
            // Use the `name` field when present, fall back to accountId
            let label = accountId == "default"
                ? "default"
                : (acc["name"] as? String ?? accountId)
            return ChannelAccount(id: accountId, label: label, healthy: healthy)
        }
    }

    // MARK: - History persistence

    private func loadHistory() {
        guard
            let data   = try? Data(contentsOf: historyFileURL),
            let events = try? JSONDecoder().decode([HistoryEvent].self, from: data)
        else { return }
        history = events
    }

    private func appendHistory(_ event: HistoryEvent) {
        history.append(event)
        if history.count > 100 { history = Array(history.suffix(100)) }
        try? JSONEncoder().encode(history).write(to: historyFileURL)
        onStatusChanged?()
    }

    // MARK: - Helpers

    private func failureSummary(from results: [CheckResult]) -> String {
        results.filter { !$0.ok }.map { $0.command }.joined(separator: ", ")
    }

    private func notify(title: String, body: String) {
        guard !isSnoozed else { return }
        let t = title.replacingOccurrences(of: "\"", with: "'")
        let b = body.replacingOccurrences(of:  "\"", with: "'")
        Task.detached(priority: .background) {
            _ = await CommandRunner.run(
                "osascript -e 'display notification \"\(b)\" with title \"\(t)\"'",
                timeout: 10
            )
        }
    }
}
