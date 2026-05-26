import AppKit
import Combine

// Floating draggable HUD — always on top, no title bar, click-through background.
// Shows recording state and elapsed time. Draggable by clicking anywhere on it.

final class HUDWindow: NSPanel {

    private let label     = NSTextField(labelWithString: "ZenithOS")
    private let timerLabel = NSTextField(labelWithString: "")
    private let button    = NSButton()
    private var dragOrigin: NSPoint = .zero

    private var timer: Timer?
    private var elapsed: TimeInterval = 0

    var onToggle: (() -> Void)?

    // MARK: - Init

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 56),
            styleMask:   [.nonactivatingPanel, .fullSizeContentView],
            backing:     .buffered,
            defer:       false
        )
        isFloatingPanel          = true
        level                    = .floating
        isOpaque                 = false
        backgroundColor          = .clear
        hasShadow                = true
        isMovable                = false   // we handle dragging manually
        collectionBehavior       = [.canJoinAllSpaces, .stationary]
        animationBehavior        = .none

        buildContent()
        center()
        // Offset from centre so it doesn't land on top of the FaceTime window
        setFrameOrigin(NSPoint(
            x: frame.origin.x + 400,
            y: frame.origin.y + 200
        ))
    }

    // MARK: - Public

    func show()  { orderFront(nil) }
    func hide()  { orderOut(nil) }

    func setState(_ state: FaceTimeCaptureManager.State, message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch state {
            case .idle:
                self.button.title = "⏺  Record"
                self.button.contentTintColor = .white
                self.stopTimer()
                self.timerLabel.stringValue = message == "Idle" ? "" : message
            case .recording:
                self.button.title = "⏹  Stop"
                self.button.contentTintColor = .systemRed
                self.startTimer()
            case .stopping:
                self.button.title = "⏳"
                self.button.contentTintColor = .systemYellow
                self.stopTimer()
                self.timerLabel.stringValue = "Stopping…"
            }
        }
    }

    // MARK: - Build

    private func buildContent() {
        let cv = contentView!
        let blur = NSVisualEffectView(frame: cv.bounds)
        blur.autoresizingMask = [NSView.AutoresizingMask.width, NSView.AutoresizingMask.height]
        blur.material         = NSVisualEffectView.Material.hudWindow
        blur.blendingMode     = NSVisualEffectView.BlendingMode.behindWindow
        blur.state            = NSVisualEffectView.State.active
        blur.wantsLayer       = true
        blur.layer?.cornerRadius  = 12
        blur.layer?.masksToBounds = true
        cv.addSubview(blur)

        label.font          = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor     = NSColor.white.withAlphaComponent(0.6)
        label.frame         = NSRect(x: 12, y: 34, width: 80, height: 16)
        blur.addSubview(label)

        timerLabel.font         = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timerLabel.textColor    = NSColor.white.withAlphaComponent(0.5)
        timerLabel.alignment    = .right
        timerLabel.frame        = NSRect(x: 80, y: 34, width: 68, height: 16)
        blur.addSubview(timerLabel)

        button.title            = "⏺  Record"
        button.bezelStyle       = .rounded
        button.isBordered       = false
        button.font             = .systemFont(ofSize: 13, weight: .medium)
        button.contentTintColor = .white
        button.frame            = NSRect(x: 8, y: 6, width: 144, height: 26)
        button.target           = self
        button.action           = #selector(tapped)
        blur.addSubview(button)
    }

    // MARK: - Timer

    private func startTimer() {
        stopTimer()   // always kill any existing timer before starting a new one
        elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.elapsed += 1
            let m = Int(self.elapsed) / 60
            let s = Int(self.elapsed) % 60
            self.timerLabel.stringValue = String(format: "%02d:%02d", m, s)
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        elapsed = 0
    }

    // MARK: - Actions

    @objc private func tapped() { onToggle?() }

    // MARK: - Dragging

    override func mouseDown(with event: NSEvent) {
        dragOrigin = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        let current = event.locationInWindow
        let dx = current.x - dragOrigin.x
        let dy = current.y - dragOrigin.y
        setFrameOrigin(NSPoint(x: frame.origin.x + dx, y: frame.origin.y + dy))
    }
}
