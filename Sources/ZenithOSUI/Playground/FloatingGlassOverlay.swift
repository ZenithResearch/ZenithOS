import AppKit
import SwiftUI

@MainActor
final class FloatingGlassOverlay: ObservableObject {
    static let shared = FloatingGlassOverlay()

    @Published private(set) var isVisible = false
    @Published var draftText = ""
    @Published var responseText = ""
    @Published var errorMessage: String?
    @Published var isSending = false
    @Published var responseModel: String?
    @Published var responseBaseURL: String?
    @Published var lastSubmitted: String?

    private var panel: NSPanel?
    private let panelSize = NSSize(width: 680, height: 420)

    private init() {}

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.orderFrontRegardless()
        isVisible = true
    }

    func focus() {
        show()
        panel?.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
        isVisible = false
    }

    func submit() {
        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lastSubmitted = trimmed
        responseText = ""
        errorMessage = nil
        isSending = true
        draftText = ""

        Task {
            do {
                let result = try await PlaygroundInferenceClient().complete(prompt: trimmed)
                responseText = result.content
                responseModel = result.model
                responseBaseURL = result.baseURL
            } catch {
                errorMessage = error.localizedDescription
            }
            isSending = false
        }
    }

    func clear() {
        draftText = ""
        responseText = ""
        errorMessage = nil
        responseModel = nil
        responseBaseURL = nil
        lastSubmitted = nil
    }

    private func makePanel() -> NSPanel {
        let panel = ZenithFloatingGlassPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Zenith Playground"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
            .stationary
        ]

        let host = NSHostingController(rootView: FloatingGlassTextBox(overlay: self))
        host.view.frame = NSRect(origin: .zero, size: panelSize)
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentViewController = host
        return panel
    }

    private func position(_ panel: NSPanel) {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(
            x: screen.midX - panelSize.width / 2,
            y: screen.maxY - panelSize.height - 72
        )
        panel.setFrame(NSRect(origin: origin, size: panelSize), display: true)
    }
}

private final class ZenithFloatingGlassPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
