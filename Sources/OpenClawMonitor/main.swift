import AppKit

let app = NSApplication.shared
// Hide from Dock — this is a menu bar-only app
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate

app.run()
