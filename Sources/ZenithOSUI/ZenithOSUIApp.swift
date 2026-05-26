import SwiftUI

@main
struct ZenithOSUIApp: App {
    @StateObject private var hub = HubStore()
    @StateObject private var inferenceStatus = ZenithStatus()

    var body: some Scene {
        WindowGroup("ZenithOS") {
            ContentView()
                .environmentObject(hub)
                .environmentObject(inferenceStatus)
                .frame(minWidth: 640, minHeight: 480)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}   // hide New Window
            CommandMenu("Workspace") {
                Button("Show All Tabs") {
                    NotificationCenter.default.post(name: .zenithShowTabOverview, object: nil)
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            }
            CommandMenu("Three.js") {
                Button("Editor") {
                    ThreeEditorWindowController.shared.show()
                }
                .keyboardShortcut("3", modifiers: [.command, .shift])

                Button("DevTools") {
                    ThreeDevToolsWindowController.shared.show()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }

        ZenithMenuBarScene(status: inferenceStatus)
    }
}
