import SwiftUI
import AppKit

struct ZenithMenuBarScene: Scene {
    @ObservedObject private var status: ZenithStatus

    init(status: ZenithStatus) {
        _status = ObservedObject(wrappedValue: status)
    }

    var body: some Scene {
        MenuBarExtra(status.statusText, systemImage: status.isRunning ? "bolt.circle.fill" : "bolt.slash.circle") {
            Text(status.statusText)

            if let error = status.lastError {
                Text(error)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Menu("Switch Model") {
                ForEach(status.modelChoices) { choice in
                    Button(choice.label) {
                        status.switchModel(choice)
                    }
                }
            }

            Toggle("Start/Stop ZenithOS", isOn: Binding(
                get: { status.isRunning },
                set: { status.setPower($0) }
            ))

            Button("Refresh") {
                Task { await status.refresh() }
            }

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
