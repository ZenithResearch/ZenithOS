import AppKit

// MARK: - Feature protocol
// Every ZenithOS feature contributes menu items and manages its own lifecycle.
// Add new features here and register them in AppDelegate.features.
@MainActor
protocol ZenithFeature: AnyObject {
    var name: String { get }
    var menuItems: [NSMenuItem] { get }
    func setup()      // called once at launch
    func teardown()   // called on quit
}

// MARK: - AppDelegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var menu: NSMenu!

    // ── Registered features ────────────────────────────────────────────────
    // Add future features (dispatcher status, vault search, etc.) here.
    private lazy var features: [ZenithFeature] = [
        FaceTimeCaptureFeature()
    ]

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        features.forEach { $0.setup() }   // must run before buildStatusItem reads menuItems
        buildStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        features.forEach { $0.teardown() }
    }

    // MARK: Menu bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "ZenithOS")
            button.image?.isTemplate = true
        }

        menu = NSMenu()

        // Header
        let title = NSMenuItem(title: "ZenithOS", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())

        // Feature sections
        for feature in features {
            let header = NSMenuItem(title: feature.name, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            feature.menuItems.forEach { menu.addItem($0) }
            menu.addItem(.separator())
        }

        // Quit
        menu.addItem(NSMenuItem(title: "Quit ZenithOS", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }
}
