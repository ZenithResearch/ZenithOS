import AppKit

// Top-level code in main.swift is nonisolated, but NSApplication.main() always
// runs on the main thread — assumeIsolated is correct here.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)   // no dock icon
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
