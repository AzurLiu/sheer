// Sheer — a macOS 26/27-style transparent menu bar for macOS 15.

import AppKit

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
