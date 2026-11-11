import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize status bar controller
        statusBarController = StatusBarController()
        print("FSAPI Radio Controller started in menu bar.")
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// Run as menu bar agent app (LSUIElement = 1) without standard dock icon
app.setActivationPolicy(.accessory)
app.run()
