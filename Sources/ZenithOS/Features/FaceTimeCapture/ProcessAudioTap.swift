import AVFoundation
import CoreAudio

/// Captures all system audio output using CATapDescription + a private aggregate device.
/// Works regardless of output device routing — including Bluetooth SCO/LE (AirPods in calls).
/// Available macOS 14.2+.
@available(macOS 14.2, *)
final class ProcessAudioTap {

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggID: AudioDeviceID = kAudioObjectUnknown
    private let engine = AVAudioEngine()
    private var recorder: AudioRecorder?

    enum Err: Error, LocalizedError {
        case tapCreate(OSStatus)
        case tapUID(OSStatus)
        case aggCreate(OSStatus)
        case noAudioUnit
        case devSet(OSStatus)
        case converter

        var errorDescription: String? {
            switch self {
            case .tapCreate(let s):  return "AudioHardwareCreateProcessTap failed (\(s))"
            case .tapUID(let s):     return "kAudioTapPropertyUID failed (\(s))"
            case .aggCreate(let s):  return "AudioHardwareCreateAggregateDevice failed (\(s))"
            case .noAudioUnit:       return "inputNode.audioUnit is nil"
            case .devSet(let s):     return "kAudioOutputUnitProperty_CurrentDevice failed (\(s))"
            case .converter:         return "AVAudioConverter init failed"
            }
        }
    }

    // MARK: - Start

    func start(outputURL: URL) throws {
        // 1. Global stereo tap — capture all processes (exclusive=true, processes=[])
        let desc = CATapDescription()
        desc.name      = "com.zenith.remote"
        desc.isExclusive = true   // "all processes EXCEPT those listed"
        desc.__processes = []    // exclude nobody → capture everything
        desc.isMono      = false

        var tID = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(desc, &tID), Err.tapCreate)
        tapID = tID

        // 2. Get the tap's UID so it can be referenced in the aggregate device dictionary.
        //    CoreAudio property values that are CFTypeRef require explicit memory rebinding
        //    to avoid the Swift "may contain an object reference" warning.
        var uidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var uidSz = UInt32(MemoryLayout<CFString>.size)
        var uidCF: CFString = "" as CFString
        let uidSt: OSStatus = withUnsafeMutablePointer(to: &uidCF) { ptr in
            ptr.withMemoryRebound(to: CFString.self, capacity: 1) { cfPtr in
                AudioObjectGetPropertyData(tID, &uidAddr, 0, nil, &uidSz, cfPtr)
            }
        }
        guard uidSt == noErr else { throw Err.tapUID(uidSt) }
        let uid = uidCF as String

        // 3. Create a private aggregate device containing the tap as its input stream
        let aggDesc: NSDictionary = [
            kAudioAggregateDeviceNameKey:         "com.zenith.tapdev",
            kAudioAggregateDeviceUIDKey:          UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey:    1,
            kAudioAggregateDeviceTapAutoStartKey: 1,
            kAudioAggregateDeviceTapListKey:      [[kAudioSubTapUIDKey: uid]] as [[String: Any]]
        ]
        var aID = AudioDeviceID(0)
        let aggSt = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aID)
        guard aggSt == noErr else {
            AudioHardwareDestroyProcessTap(tapID); tapID = kAudioObjectUnknown
            throw Err.aggCreate(aggSt)
        }
        aggID = aID

        // 4. Redirect AVAudioEngine's input node to the aggregate device
        guard let au = engine.inputNode.audioUnit else {
            destroy(); throw Err.noAudioUnit
        }
        var devID = aID
        let devSt = AudioUnitSetProperty(
            au, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0,
            &devID, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard devSt == noErr else { destroy(); throw Err.devSet(devSt) }

        // 5. Prepare engine so outputFormat reflects the aggregate device
        engine.prepare()

        // 6. Install tap → downsample to 16 kHz mono → AudioRecorder
        let src    = engine.inputNode.outputFormat(forBus: 0)
        let target = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        guard let cvt = AVAudioConverter(from: src, to: target) else {
            destroy(); throw Err.converter
        }

        recorder = try AudioRecorder(url: outputURL, format: target)
        let rec = recorder

        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: src) { buf, _ in
            let n = AVAudioFrameCount((Double(buf.frameLength) * 16000 / src.sampleRate).rounded(.up))
            guard n > 0, let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: n) else { return }
            var err: NSError?
            cvt.convert(to: out, error: &err) { _, st in st.pointee = .haveData; return buf }
            if err == nil { rec?.append(out) }
        }

        try engine.start()
    }

    // MARK: - Stop

    func stop() -> (url: URL, duration: Double)? {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let result = recorder?.finalize()
        recorder = nil
        destroy()
        return result
    }

    // MARK: - Private

    private func destroy() {
        if aggID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggID)
            aggID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    @inline(__always)
    private func check(_ status: OSStatus, _ make: (OSStatus) -> Err) throws {
        guard status == noErr else { throw make(status) }
    }
}
