import AVFoundation
import ScreenCaptureKit

@MainActor
final class FaceTimeCaptureManager: NSObject, ObservableObject {

    // MARK: - State

    enum State { case idle, recording, stopping }
    @Published private(set) var state: State = .idle
    @Published private(set) var lastTranscriptURL: URL?
    @Published private(set) var statusMessage: String = "Idle"

    var remoteLabel: String = "Remote"

    // MARK: - Private

    // Mic capture
    private var audioEngine: AVAudioEngine?
    private var audioEngineObserver: Any?
    private var youRecorder: AudioRecorder?

    // Remote capture via SCStream (full display, system audio output)
    private var scStream: SCStream?
    private final class SCBridge: @unchecked Sendable { var recorder: AudioRecorder? }
    private let scBridge = SCBridge()

    private var callStart: Date?

    // MARK: - Public API

    func startCapture() {
        guard state == .idle else { return }
        state = .recording
        statusMessage = "Starting…"
        Task { await beginCapture() }
    }

    func stopCapture() {
        guard state == .recording else { return }
        state = .stopping
        statusMessage = "Stopping…"
        Task { await finishCapture() }
    }

    // MARK: - Capture lifecycle

    private func beginCapture() async {
        let callDate = Date()
        callStart = callDate
        let slug = slugDate(callDate)
        try? FileManager.default.createDirectory(at: VaultConfig.audioDir, withIntermediateDirectories: true)

        let youURL    = VaultConfig.audioDir.appendingPathComponent("facetime-\(slug)-you.wav")
        let remoteURL = VaultConfig.audioDir.appendingPathComponent("facetime-\(slug)-remote.wav")

        // ── Microphone (You) ────────────────────────────────────────────────
        let targetFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        if let rec = try? AudioRecorder(url: youURL, format: targetFormat) {
            youRecorder = rec
            startMicCapture(recorder: rec)
        } else {
            statusMessage = "Could not open mic output file"
        }

        // ── Remote audio ────────────────────────────────────────────────────
        // SCStream full-display audio capture is the reliable public API for system
        // output audio. ProcessAudioTap requires com.apple.private.coreaudio.process-tap
        // (private entitlement) for a global tap — not available to ad-hoc signed binaries.
        await startSCStreamFallback(remoteURL: remoteURL, targetFormat: targetFormat)

        if state != .stopping {
            statusMessage = "Recording…"
        }
    }

    private func finishCapture() async {
        // Stop mic
        stopMicCapture()

        // Stop remote capture
        var remoteResult: (url: URL, duration: Double)?
        if let stream = scStream {
            try? await stream.stopCapture()
            scStream = nil
            remoteResult = scBridge.recorder?.finalize()
            scBridge.recorder = nil
        }

        let youResult = youRecorder?.finalize()
        youRecorder = nil

        // Build audio file list
        var audioFiles: [AudioFile] = []
        if let (url, dur) = youResult    { audioFiles.append(AudioFile(url: url, speaker: "you",    duration: dur)) }
        if let (url, dur) = remoteResult { audioFiles.append(AudioFile(url: url, speaker: "remote", duration: dur)) }

        guard let callDate = callStart else {
            statusMessage = "No call date"; state = .idle; return
        }
        callStart = nil

        if audioFiles.isEmpty {
            statusMessage = "Nothing captured"; state = .idle; return
        }

        do {
            let url = try TranscriptWriter.write(
                segments:    [],         // transcription happens in post-processing
                audioFiles:  audioFiles,
                callDate:    callDate,
                remoteLabel: remoteLabel
            )
            lastTranscriptURL = url
            statusMessage = "Saved → \(url.lastPathComponent) (\(audioFiles.count) audio files)"
        } catch {
            statusMessage = "Write failed: \(error.localizedDescription)"
        }
        state = .idle
    }

    // MARK: - Mic engine

    /// Install a tap on AVAudioEngine.inputNode → downsample to 16 kHz mono → write to recorder.
    /// Re-installs automatically when the system input device changes (handles FaceTime / Wispr
    /// switching the default input mid-call).
    private func startMicCapture(recorder: AudioRecorder) {
        let engine = AVAudioEngine()
        audioEngine = engine
        installMicTap(engine: engine, recorder: recorder)

        audioEngineObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            // Device changed — restart the engine, keep writing to the same recorder
            Task { @MainActor [weak self] in
                guard let self, self.state == .recording else { return }
                guard let rec = self.youRecorder else { return }
                self.audioEngine?.inputNode.removeTap(onBus: 0)
                self.audioEngine?.reset()
                self.installMicTap(engine: self.audioEngine!, recorder: rec)
                try? self.audioEngine?.start()
            }
        }

        do {
            try engine.start()
        } catch {
            statusMessage = "Mic engine failed: \(error.localizedDescription)"
        }
    }

    private func installMicTap(engine: AVAudioEngine, recorder: AudioRecorder) {
        let inputFormat  = engine.inputNode.outputFormat(forBus: 0)
        let targetFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        guard let cvt = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            statusMessage = "Mic converter failed"; return
        }
        let rec = recorder
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buf, _ in
            let n = AVAudioFrameCount((Double(buf.frameLength) * 16000 / inputFormat.sampleRate).rounded(.up))
            guard n > 0, let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: n) else { return }
            var err: NSError?
            cvt.convert(to: out, error: &err) { _, st in st.pointee = .haveData; return buf }
            if err == nil { rec.append(out) }
        }
    }

    private func stopMicCapture() {
        if let obs = audioEngineObserver {
            NotificationCenter.default.removeObserver(obs)
            audioEngineObserver = nil
        }
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
    }

    // MARK: - SCStream fallback (macOS < 14.2)

    private func startSCStreamFallback(remoteURL: URL, targetFormat: AVAudioFormat) async {
        do {
            scBridge.recorder = try? AudioRecorder(url: remoteURL, format: targetFormat)

            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else {
                statusMessage = "No display for audio capture"; return
            }

            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio              = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate                 = 16000
            config.channelCount               = 1
            config.minimumFrameInterval       = CMTime(value: 1, timescale: 1)
            config.width  = 2
            config.height = 2

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
            try await stream.startCapture()
            scStream = stream
        } catch {
            statusMessage = "Remote capture failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    private func slugDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return f.string(from: date)
    }
}

// MARK: - SCStreamDelegate (fallback)

extension FaceTimeCaptureManager: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            statusMessage = "Stream stopped: \(error.localizedDescription)"
            if state == .recording { await finishCapture() }
        }
    }
}

// MARK: - SCStreamOutput (fallback)

extension FaceTimeCaptureManager: SCStreamOutput {
    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio else { return }
        guard let rec = scBridge.recorder else { return }

        guard
            let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer),
            let formatDesc  = CMSampleBufferGetFormatDescription(sampleBuffer),
            let asbd        = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee
        else { return }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate:   asbd.mSampleRate,
            channels:     AVAudioChannelCount(asbd.mChannelsPerFrame),
            interleaved:  false
        ) else { return }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        pcm.frameLength = frameCount

        var ptr: UnsafeMutablePointer<Int8>?
        var len = 0
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr)
        guard let src = ptr else { return }

        let bpf = Int(asbd.mBytesPerFrame)
        for ch in 0 ..< Int(asbd.mChannelsPerFrame) {
            guard let dst = pcm.floatChannelData?[ch] else { continue }
            for f in 0 ..< Int(frameCount) {
                let offset = f * bpf + ch * MemoryLayout<Float>.size
                var v: Float = 0
                withUnsafeMutableBytes(of: &v) {
                    $0.copyMemory(from: UnsafeRawBufferPointer(start: src.advanced(by: offset),
                                                               count: MemoryLayout<Float>.size))
                }
                dst[f] = v
            }
        }

        // Downmix to mono if needed
        let mono: AVAudioPCMBuffer
        if pcm.format.channelCount == 1 {
            mono = pcm
        } else {
            let mf = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: pcm.format.sampleRate,
                                   channels: 1, interleaved: false)!
            let m = AVAudioPCMBuffer(pcmFormat: mf, frameCapacity: pcm.frameLength)!
            m.frameLength = pcm.frameLength
            if let s0 = pcm.floatChannelData?[0], let s1 = pcm.floatChannelData?[1],
               let d = m.floatChannelData?[0] {
                for i in 0 ..< Int(pcm.frameLength) { d[i] = (s0[i] + s1[i]) * 0.5 }
            }
            mono = m
        }

        rec.append(mono)
    }
}
