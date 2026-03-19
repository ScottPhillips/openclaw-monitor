import Foundation

// MARK: - CheckCommand

/// A shell command with optional output-pattern overrides.
/// Some `openclaw` commands always exit 0 even on failure and embed
/// failure text in stdout/stderr — `failurePatterns` catches those.
struct CheckCommand {
    let shell:           String
    let label:           String
    let failurePatterns: [String]   // case-insensitive; any match → failure

    init(_ shell: String, label: String = "", failurePatterns: [String] = []) {
        self.shell  = shell
        self.label  = label.isEmpty ? shell : label
        self.failurePatterns = failurePatterns
    }
}

// MARK: - CheckLevel

enum CheckLevel: String {
    case basic = "basic"
    case deep  = "deep"

    /// The reliable commands for a standard check.
    /// Only `openclaw gateway probe` and `openclaw health --json` exit non-zero
    /// on failure; the others need pattern matching.
    static let baseCommands: [CheckCommand] = [
        CheckCommand(
            "openclaw gateway probe",
            label: "RPC probe"
            // exits 1 on failure — no pattern needed
        ),
        CheckCommand(
            "openclaw health --json",
            label: "Health"
            // exits 1 on failure — no pattern needed
        ),
        CheckCommand(
            "curl -sf --connect-timeout 5 --max-time 10 http://127.0.0.1:18789/",
            label: "Dashboard"
            // curl -f exits non-zero on connection failure or HTTP error
        ),
        CheckCommand(
            "openclaw channels status --probe",
            label: "Channels",
            failurePatterns: ["Gateway not reachable", "Error:"]
            // exits 0 even when gateway is down
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
                    failurePatterns: ["critical"]
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
    let id:      String   // e.g. "default", "jarvis"
    let label:   String   // e.g. "@IamAbbyIrons_bot (jarvis)"
    let healthy: Bool
}

struct ChannelHealth {
    let id:       String          // e.g. "telegram"
    let label:    String          // e.g. "Telegram"
    let healthy:  Bool
    let accounts: [ChannelAccount] // populated when channel has >1 account
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

    private(set) var checkStatus:        CheckStatus    = .unknown
    private(set) var lastCheck:          Date?
    private(set) var lastResults:        [CheckResult]  = []
    private(set) var lastLevel:          CheckLevel     = .basic
    private(set) var reinstallSuggested: Bool           = false
    private(set) var openclawMissing:    Bool           = false
    private(set) var history:            [HistoryEvent] = []
    private(set) var channels:           [ChannelHealth] = []
    private(set) var controlPanelURL:    String         = "http://127.0.0.1:18789/"

    /// Called whenever any state changes — drives UI refresh.
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

    private var timer:      Timer?
    private var isBusy =    false

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

    func stopTimer()  { timer?.invalidate(); timer = nil }
    func restartTimer() { startPeriodicTimer() }

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
            appendHistory(HistoryEvent(date: Date(), kind: .checkFailed,
                summary: failureSummary(from: results)))
            await autoRepair()
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

        if code == 0 {
            notify(title: "Gateway started ✓", body: snippet)
        } else {
            notify(title: "Gateway start failed ✗", body: snippet)
        }

        let (allOk, results, _) = await executeCommands(for: .basic)
        applyResults(ok: allOk, results: results, level: .basic)

        if allOk {
            appendHistory(HistoryEvent(date: Date(), kind: .recovered, summary: "Healthy after manual restart"))
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

        if code == 0 {
            notify(title: "Gateway stopped", body: snippet)
        } else {
            notify(title: "Gateway stop failed ✗", body: snippet)
        }

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

        if code == 0 {
            notify(title: "Gateway reinstalled ✓", body: snippet)
        } else {
            notify(title: "Gateway reinstall failed ✗", body: snippet)
        }

        let (allOk, results, _) = await executeCommands(for: .basic)
        applyResults(ok: allOk, results: results, level: .basic)

        if allOk {
            appendHistory(HistoryEvent(date: Date(), kind: .recovered, summary: "Healthy after reinstall"))
        }

        isBusy = false
    }

    // MARK: - Auto-repair (runs while isBusy = true)

    private func autoRepair() async {
        appendHistory(HistoryEvent(date: Date(), kind: .restartAttempt, summary: "Auto-repair triggered"))

        // Try restart first; if the service isn't loaded, fall through to install.
        let (_, restartOutput) = await CommandRunner.run("openclaw gateway restart", timeout: 120)
        let serviceNotLoaded = restartOutput.lowercased().contains("not loaded")
                           || restartOutput.lowercased().contains("not installed")

        if serviceNotLoaded {
            notify(title: "OpenClaw check failed", body: "Gateway not running — installing and starting…")
            let (installCode, installOutput) = await CommandRunner.run("openclaw gateway install", timeout: 60)
            if installCode != 0 {
                notify(title: "Gateway install failed ✗", body: installOutput.isEmpty ? "(no output)" : String(installOutput.prefix(160)))
                reinstallSuggested = true
                onStatusChanged?()
                return
            }
        } else {
            notify(title: "OpenClaw check failed", body: "Attempting gateway restart…")
        }

        // Give the gateway time to come back up
        try? await Task.sleep(for: .seconds(10))

        let (allOk, results, _) = await executeCommands(for: .basic)
        applyResults(ok: allOk, results: results, level: .basic)

        if allOk {
            appendHistory(HistoryEvent(date: Date(), kind: .restartRecovered,
                summary: "All checks passed after restart"))
            notify(title: "OpenClaw ✓", body: "Gateway restart fixed the issue.")
        } else {
            appendHistory(HistoryEvent(date: Date(), kind: .checkFailed,
                summary: "Still failing after restart — " + failureSummary(from: results)))
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
        // Pre-flight: verify openclaw is on PATH
        let (whichCode, _) = await CommandRunner.run("which openclaw", timeout: 5)
        if whichCode != 0 {
            let r = CheckResult(command: "openclaw", exitCode: 127,
                                output: "openclaw not found on PATH.\nInstall it from https://openclaw.ai")
            return (false, [r], true)
        }

        var results: [CheckResult] = []
        var allOk = true

        for cmd in level.checkCommands {
            let (code, output) = await CommandRunner.run(cmd.shell)

            // Check exit code first, then scan for failure keywords in output
            var failed = (code != 0)
            if !failed && !cmd.failurePatterns.isEmpty {
                let lower = output.lowercased()
                failed = cmd.failurePatterns.contains { lower.contains($0.lowercased()) }
            }

            if failed { allOk = false }
            // Normalise exit code so failed-via-pattern also shows as non-zero
            let effectiveCode: Int32 = failed ? max(code, 1) : 0
            results.append(CheckResult(command: cmd.label, exitCode: effectiveCode, output: output))
        }

        return (allOk, results, false)
    }

    // MARK: - Control panel URL (fetched once on startup)

    func fetchControlPanelURL() async {
        let (_, output) = await CommandRunner.run("openclaw gateway status", timeout: 10)
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Dashboard: ") {
                let url = String(trimmed.dropFirst("Dashboard: ".count))
                            .trimmingCharacters(in: .whitespaces)
                if !url.isEmpty { controlPanelURL = url }
                break
            }
        }
    }

    private func applyResults(ok: Bool, results: [CheckResult], level: CheckLevel) {
        lastResults = results
        lastCheck   = Date()
        lastLevel   = level
        checkStatus = ok ? .ok : .failed

        // Parse channel health from the embedded health JSON, if present
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
        let probeOk    = (d["probe"] as? [String: Any])?["ok"] as? Bool ?? false
        // lastError is healthy only when it's JSON null (NSNull after deserialisation)
        let lastError  = d["lastError"]
        let hasError   = !(lastError is NSNull) && lastError != nil
        return configured && probeOk && !hasError
    }

    /// Returns account rows only when a channel has more than one account (e.g. Telegram with multiple bots).
    private func parseAccounts(from ch: [String: Any], channelId: String) -> [ChannelAccount] {
        guard let accounts = ch["accounts"] as? [String: Any], accounts.count > 1 else { return [] }

        // Preserve order: "default" first, then alphabetical
        let sorted = accounts.keys.sorted { a, b in a == "default" ? true : (b == "default" ? false : a < b) }

        return sorted.compactMap { accountId in
            guard let acc = accounts[accountId] as? [String: Any] else { return nil }
            let healthy = channelIsHealthy(acc)

            // Build a human-readable label, e.g. "@IamAbbyIrons_bot" or "@TheOGJarvis_bot (jarvis)"
            var label = accountId
            if let probe = acc["probe"] as? [String: Any],
               let bot   = probe["bot"]   as? [String: Any],
               let uname = bot["username"] as? String {
                label = "@\(uname)"
                if accountId != "default" { label += "  (\(accountId))" }
            } else if accountId == "default" {
                label = "default"
            }
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
        if history.count > 10 { history = Array(history.suffix(10)) }
        try? JSONEncoder().encode(history).write(to: historyFileURL)
        onStatusChanged?()
    }

    // MARK: - Helpers

    private func failureSummary(from results: [CheckResult]) -> String {
        results.filter { !$0.ok }.map { $0.command }.joined(separator: ", ")
    }

    /// Sends a macOS notification via osascript — works without a bundle ID.
    private func notify(title: String, body: String) {
        let t = title.replacingOccurrences(of: "\"", with: "'")
        let b = body.replacingOccurrences(of: "\"", with: "'")
        Task.detached(priority: .background) {
            _ = await CommandRunner.run(
                "osascript -e 'display notification \"\(b)\" with title \"\(t)\"'",
                timeout: 10
            )
        }
    }
}
