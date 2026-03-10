import AppKit
import AppShell

let application = NSApplication.shared
let delegate = MatrixApplicationDelegate()
application.setActivationPolicy(.regular)
application.delegate = delegate
application.run()
