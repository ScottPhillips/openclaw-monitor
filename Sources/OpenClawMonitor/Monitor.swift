import Foundation

// MARK: - Types

enum CheckLevel: String {
    case basic  = "basic"
    case medium = "medium"
    case deep   = "deep"

    var commands: [String] {
        switch self {
        case .basic:
            return [
                "openclaw status",
            ]
        case .medium:
            return [
                "openclaw status",
                "openclaw gateway status",
                "openclaw health --json",
            ]
        case .deep:
            return [
                "openclaw status",
                "openclaw gateway status",
                "openclaw health --json",
                "openclaw status --deep",
                "openclaw security audit --deep",
            ]
        }
    }
}

enum CheckStatus {
    case unknown, checking, ok, failed

    var emoji: String {
        switch self {
        case .unknown:  return "⚪"
        case .checking: return "⟳"
        case .ok:       return "🟢"
        case .failed:   return "🔴"
        }
    }
}

struct CheckResult {
    let command:  String
    let exitCode: Int32
    let output:   String
    var ok: Bool { exitCode == 0 }
}

// MARK: - Monitor

/// All state lives on the main actor so UI reads are always safe.
@MainActor
final class Monitor {

    // Published state (observed by StatusBarController via callback)
    private(set) var checkStatus: CheckStatus    = .unknown
    private(set) var lastCheck:   Date?
    private(set) var lastResults: [CheckResult]  = []
    private(set) var lastLevel:   CheckLevel     = .basic
    private(set) var reinstallSuggested          = false

    /// Called on every state change so the UI can refresh itself.
    var onStatusChanged: (() -> Void)?

    // MARK: Interval (persisted)

    var intervalMinutes: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: "intervalMinutes")
            return v > 0 ? v : 30
        }
        set { UserDefaults.standard.set(newValue, forKey: "intervalMinutes") }
    }

    // MARK: Private

    private var timer: Timer?
    private var isBusy = false   // guards against concurrent check/repair cycles

    // MARK: - Timer

    func startPeriodicTimer() {
        stopTimer()
        let secs = TimeInterval(intervalMinutes * 60)
        timer = Timer.scheduledTimer(withTimeInterval: secs, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.runCheck(level: .basic)
            }
        }
    }

    func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// Call after changing `intervalMinutes` to apply the new schedule.
    func restartTimer() {
        startPeriodicTimer()
    }

    // MARK: - Public check entry point

    func runCheck(level: CheckLevel) async {
        guard !isBusy else { return }
        isBusy = true
        reinstallSuggested = false

        checkStatus = .checking
        onStatusChanged?()

        let (ok, results) = await executeCommands(for: level)
        applyResults(ok: ok, results: results, level: level)

        if !ok {
            // Auto-repair: restart gateway, re-check, escalate to reinstall if needed
            await autoRepair()
        }

        isBusy = false
    }

    // MARK: - Manual repair (called from UI — guards isBusy itself)

    func restartGateway() async {
        guard !isBusy else { return }
        isBusy = true

        checkStatus = .checking
        onStatusChanged?()

        let (code, output) = await CommandRunner.run("openclaw gateway restart", timeout: 120)
        let snippet = output.isEmpty ? "Done" : String(output.prefix(140))

        if code == 0 {
            notify(title: "Gateway restarted ✓", body: snippet)
        } else {
            notify(title: "Gateway restart failed ✗", body: snippet)
        }

        let (ok, results) = await executeCommands(for: .basic)
        applyResults(ok: ok, results: results, level: .basic)

        isBusy = false
    }

    func reinstallGateway() async {
        guard !isBusy else { return }
        isBusy = true
        reinstallSuggested = false

        checkStatus = .checking
        onStatusChanged?()

        notify(title: "Reinstalling gateway…", body: "This may take a few minutes")

        let (code, output) = await CommandRunner.run("openclaw gateway reinstall", timeout: 300)
        let snippet = output.isEmpty ? "Done" : String(output.prefix(140))

        if code == 0 {
            notify(title: "Gateway reinstalled ✓", body: snippet)
        } else {
            notify(title: "Gateway reinstall failed ✗", body: snippet)
        }

        let (ok, results) = await executeCommands(for: .basic)
        applyResults(ok: ok, results: results, level: .basic)

        isBusy = false
    }

    // MARK: - Auto-repair (called while isBusy = true)

    private func autoRepair() async {
        notify(title: "OpenClaw check failed", body: "Attempting gateway restart…")

        let (restartCode, _) = await CommandRunner.run("openclaw gateway restart", timeout: 120)
        guard restartCode == 0 else {
            notify(title: "Gateway restart failed ✗", body: "Consider reinstalling from the menu.")
            reinstallSuggested = true
            onStatusChanged?()
            return
        }

        // Give the gateway a moment to come up
        try? await Task.sleep(for: .seconds(10))

        let (ok, results) = await executeCommands(for: .basic)
        applyResults(ok: ok, results: results, level: .basic)

        if ok {
            notify(title: "OpenClaw ✓", body: "Gateway restart fixed the issue.")
        } else {
            notify(title: "OpenClaw still failing", body: "Restart didn't help — try reinstalling from the menu.")
            reinstallSuggested = true
            onStatusChanged?()
        }
    }

    // MARK: - Helpers

    private func executeCommands(for level: CheckLevel) async -> (Bool, [CheckResult]) {
        var results: [CheckResult] = []
        var allOk = true
        for cmd in level.commands {
            let (code, output) = await CommandRunner.run(cmd)
            results.append(CheckResult(command: cmd, exitCode: code, output: output))
            if code != 0 { allOk = false }
        }
        return (allOk, results)
    }

    private func applyResults(ok: Bool, results: [CheckResult], level: CheckLevel) {
        lastResults = results
        lastCheck   = Date()
        lastLevel   = level
        checkStatus = ok ? .ok : .failed
        onStatusChanged?()
    }

    /// Sends a macOS notification. Works without a bundle ID by using osascript.
    private func notify(title: String, body: String) {
        let safeTitle = title.replacingOccurrences(of: "\"", with: "'")
        let safeBody  = body.replacingOccurrences(of: "\"", with: "'")
        let script    = "display notification \"\(safeBody)\" with title \"\(safeTitle)\""
        Task.detached(priority: .background) {
            _ = await CommandRunner.run("osascript -e '\(script)'", timeout: 10)
        }
    }
}
