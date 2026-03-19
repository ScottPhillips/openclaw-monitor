import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var monitor: Monitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let monitor = Monitor()
        self.monitor = monitor
        statusBarController = StatusBarController(monitor: monitor)

        // Fetch the control-panel URL and run initial check without blocking the UI
        Task {
            await monitor.fetchControlPanelURL()
            await monitor.runCheck(level: .basic)
        }

        monitor.startPeriodicTimer()
    }
}
