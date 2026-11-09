import AppKit

// A dead helper must surface as an error from the write, not kill the app.
signal(SIGPIPE, SIG_IGN)

let application = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
application.delegate = delegate
application.setActivationPolicy(.accessory)  // menu-bar app: no Dock icon
application.run()
