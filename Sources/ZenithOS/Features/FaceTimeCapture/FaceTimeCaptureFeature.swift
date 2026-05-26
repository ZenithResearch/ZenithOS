import AppKit
import Combine

@MainActor
final class FaceTimeCaptureFeature: ZenithFeature {

    let name = "FaceTime Capture"

    private let manager = FaceTimeCaptureManager()
    private let hud     = HUDWindow()

    private var startItem:  NSMenuItem!
    private var stopItem:   NSMenuItem!
    private var openItem:   NSMenuItem!
    private var hudItem:    NSMenuItem!
    private var statusItem: NSMenuItem!
    private var cancellables = Set<AnyCancellable>()

    var menuItems: [NSMenuItem] {
        [startItem, stopItem, openItem, hudItem, statusItem]
    }

    func setup() {
        startItem  = NSMenuItem(title: "▶  Start Recording",   action: #selector(start),    keyEquivalent: "r")
        stopItem   = NSMenuItem(title: "■  Stop Recording",    action: #selector(stop),     keyEquivalent: ".")
        openItem   = NSMenuItem(title: "Open Last Transcript", action: #selector(openLast), keyEquivalent: "")
        hudItem    = NSMenuItem(title: "Show HUD",             action: #selector(toggleHUD),keyEquivalent: "h")
        statusItem = NSMenuItem(title: "Idle",                 action: nil,                 keyEquivalent: "")

        [startItem, stopItem, openItem, hudItem, statusItem].forEach { $0?.target = self }
        stopItem.isEnabled   = false
        openItem.isEnabled   = false
        statusItem.isEnabled = false

        hud.onToggle = { [weak self] in
            guard let self else { return }
            switch self.manager.state {
            case .idle:        self.manager.startCapture()
            case .recording:   self.manager.stopCapture()
            default: break
            }
        }

        manager.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                self.syncMenuState()
                self.hud.setState(state, message: self.manager.statusMessage)
            }
            .store(in: &cancellables)

        manager.$statusMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] msg in
                self?.statusItem.title = "  \(msg)"
            }
            .store(in: &cancellables)

        manager.$lastTranscriptURL
            .receive(on: DispatchQueue.main)
            .sink { [weak self] url in self?.openItem.isEnabled = url != nil }
            .store(in: &cancellables)
    }

    func teardown() {
        if manager.state == .recording { manager.stopCapture() }
        hud.hide()
        cancellables.removeAll()
    }

    // MARK: - Actions

    @objc private func start()     { manager.startCapture(); hud.show() }
    @objc private func stop()      { manager.stopCapture() }
    @objc private func openLast()  {
        guard let url = manager.lastTranscriptURL else { return }
        NSWorkspace.shared.open(url)
    }
    @objc private func toggleHUD() {
        if hud.isVisible { hud.hide(); hudItem.title = "Show HUD" }
        else             { hud.show(); hudItem.title = "Hide HUD" }
    }

    // MARK: - State sync

    private func syncMenuState() {
        switch manager.state {
        case .idle:
            startItem.isEnabled = true
            stopItem.isEnabled  = false
        case .stopping:
            startItem.isEnabled = false
            stopItem.isEnabled  = false
        case .recording:
            startItem.isEnabled = false
            stopItem.isEnabled  = true
        }
    }
}
