import AppKit

// LiveSubs is a menu-bar app (LSUIElement): no Dock icon, no main window.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
