import AppKit

if let code = BrowserRouting.handleHelperInvocation() { exit(code) }
if let code = GlobalPool.handleHelperInvocation() { exit(code) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
