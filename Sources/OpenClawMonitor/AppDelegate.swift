import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var monitor: Monitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let monitor = Monitor()
        self.monitor = monitor
        statusBarController = StatusBarController(monitor: monitor)

        // Run initial check without blocking the UI
        Task {
            await monitor.runCheck(level: .basic)
        }

        monitor.startPeriodicTimer()
    }
}
